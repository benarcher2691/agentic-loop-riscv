`timescale 1ns/1ps
// RTL vs post-synthesis co-simulation, DRIVEN (audit A8/A20). Both SOCs get
// the same clock and the same RXD stimulus — a full monitor session: the
// banner, V, a 1-byte W of 0x15 to the LED word 0x400004, an R of that word,
// an uploaded 3-instruction G routine (writes a word to RAM, RETs) with code
// and data readbacks, and a final live V. The vacuous prints of the old
// 40k-cycle idle run are now assertions:
//   - zero port mismatches: LEDS/TXD equal on every one of TOTAL_CYCLES
//   - the decoded TXD byte streams are identical RTL vs netlist (one serial
//     receiver per DUT, byte-compared after every exchange)
//   - TXD transition count > 200 (the session is ~43 frames, ~240 edges)
//   - at least one real LED change, and final LEDS == 5'b10101 on BOTH dies
module equiv_tb;
  `include "check.vh"
  `WATCHDOG(100_000_000)

  localparam integer TOTAL_CYCLES = 150000;   // ~12.5 ms at 12 MHz

  reg CLK = 0; reg RXD = 1;
  wire TXD_r, TXD_s; wire [4:0] LEDS_r, LEDS_s;
  SOC       rtl (.CLK(CLK), .RXD(RXD), .TXD(TXD_r), .LEDS(LEDS_r));
  SOC_synth syn (.CLK(CLK), .RXD(RXD), .TXD(TXD_s), .LEDS(LEDS_s));
  always #41.667 CLK = ~CLK;
  // The emitter's data/o_ready regs have no power-on values; on hardware the
  // FFs power up 0 (which the synthesized side models). The RTL side needs
  // the same kick (see io_tb/soc_tb) or its UART handshake stays X and the
  // banner writes are never accepted.
  initial rtl.uart.data = 10'd0;

  // ---- every-cycle port equivalence + activity counters ------------------
  integer cyc = 0, mism = 0, led_changes = 0, txd_edges = 0;
  reg [4:0] last_led = 5'bx;
  reg       last_txd = 1'bx;
  always @(posedge CLK) begin
    cyc = cyc + 1;
    if (LEDS_r !== LEDS_s || TXD_r !== TXD_s) begin
      mism = mism + 1;
      if (mism <= 5) $display("MISMATCH cycle %0d: rtl LEDS=%b TXD=%b  synth LEDS=%b TXD=%b", cyc, LEDS_r, TXD_r, LEDS_s, TXD_s);
    end
    if (LEDS_r !== last_led) begin
      if (last_led !== 5'bx) led_changes = led_changes + 1; // power-on X->0 is not a change
      last_led = LEDS_r;
    end
    if (TXD_r !== last_txd) begin txd_edges = txd_edges + 1; last_txd = TXD_r; end
  end

  // ---- protocol buffers (declared before the tasks that use them) --------
  reg [7:0] txbuf  [0:63];
  reg [7:0] rbuf_r [0:63];   // bytes decoded from the RTL die's TXD
  reg [7:0] rbuf_s [0:63];   // bytes decoded from the netlist die's TXD

  // ---- serial models (same shape as tb/monitor_tb.v) ---------------------
  localparam real BITNS = 1000000000.0 / 115200.0;   // 8680.6 ns per bit

  task send_byte;
    input [7:0] b;
    integer k;
    begin
      RXD = 1'b0;              // start bit
      #(BITNS);
      for (k = 0; k < 8; k = k + 1) begin
        RXD = b[k];            // data bits, LSB first
        #(BITNS);
      end
      RXD = 1'b1;              // stop bit
      #(BITNS);
    end
  endtask

  // One serial receiver PER DUT: decode one 8N1 frame from that die's TXD,
  // with the start-bit validation a real UART receiver does: half a bit
  // into every falling edge, re-sample — only a line still LOW is a real
  // start bit. This matters here: the netlist's TXD (the provided emitter's
  // combinational `data[0] | !(|data)` re-factored into a LUT tree) shows a
  // ONE-DELTA low glitch at frame end that the RTL (atomic 10-bit reg
  // update) never produces — verified with an event log at t=92626000 ps:
  // TXD_s 1->0->1 inside one time step. The glitch is sub-clock (the
  // every-cycle port check cannot see it) and far too short to disturb a
  // real 115200-baud receiver, but a bare @(negedge) catches it and then
  // samples the whole frame one bit-time early. Validating the start bit
  // makes the receiver a faithful hardware model instead of an edge counter.
  task recv_r;
    output [7:0] b;
    integer k;
    begin : frame
      forever begin
        @(negedge TXD_r);        // candidate start bit edge
        #(BITNS * 0.5);          // centre of the start bit
        if (TXD_r === 1'b0) begin
          for (k = 0; k < 8; k = k + 1) begin
            #(BITNS);            // centre of data bit k
            b[k] = TXD_r;        // LSB first
          end
          disable frame;
        end
        // else: hazard glitch, wait for the next falling edge
      end
    end
  endtask
  task recv_s;
    output [7:0] b;
    integer k;
    begin : frame
      forever begin
        @(negedge TXD_s);
        #(BITNS * 0.5);
        if (TXD_s === 1'b0) begin
          for (k = 0; k < 8; k = k + 1) begin
            #(BITNS);
            b[k] = TXD_s;
          end
          disable frame;
        end
      end
    end
  endtask

  // Receive n bytes into each die's buffer. The two receivers always run
  // beside each other (a reply's first start bit can land in the mid-stop
  // of the previous frame, so a sequential recv would miss the edge).
  task recv_n_r;
    input integer n;
    integer k;
    begin for (k = 0; k < n; k = k + 1) recv_r(rbuf_r[k]); end
  endtask
  task recv_n_s;
    input integer n;
    integer k;
    begin for (k = 0; k < n; k = k + 1) recv_s(rbuf_s[k]); end
  endtask

  // Send txlen bytes from txbuf while BOTH dies' receivers collect rxlen
  // reply bytes; then byte-compare the two decoded streams.
  task exchange;
    input integer txlen;
    input integer rxlen;
    integer j;
    begin
      fork
        begin : snd
          integer i;
          for (i = 0; i < txlen; i = i + 1) send_byte(txbuf[i]);
        end
        begin : rcvR
          recv_n_r(rxlen);
        end
        begin : rcvS
          recv_n_s(rxlen);
        end
      join
      for (j = 0; j < rxlen; j = j + 1)
        `CHECK_EQ(rbuf_r[j], rbuf_s[j], "TXD byte identical RTL vs netlist")
    end
  endtask

  // Fill txbuf[1..4] / txbuf[5..8] with addr / len, little-endian.
  task put_addr_len;
    input [31:0] addr;
    input [31:0] len;
    begin
      txbuf[1] = addr[ 7: 0]; txbuf[2] = addr[15: 8];
      txbuf[3] = addr[23:16]; txbuf[4] = addr[31:24];
      txbuf[5] = len[ 7: 0];  txbuf[6] = len[15: 8];
      txbuf[7] = len[23:16];  txbuf[8] = len[31:24];
    end
  endtask

  task cmd_V;
    begin
      txbuf[0] = "V";
      exchange(1, 4);
      `CHECK_EQ(rbuf_r[0], 8'h52, "V: byte0 is 'R'")
      `CHECK_EQ(rbuf_r[1], 8'h56, "V: byte1 is 'V'")
      `CHECK_EQ(rbuf_r[2], 8'h33, "V: byte2 is '3'")
      `CHECK_EQ(rbuf_r[3], 8'h32, "V: byte3 is '2'")
    end
  endtask

  // Data bytes must already sit in txbuf[9 .. 9+len-1].
  task cmd_W;
    input [31:0] addr;
    input [31:0] len;
    begin
      txbuf[0] = "W";
      put_addr_len(addr, len);
      exchange(9 + len, 1);
      `CHECK_EQ(rbuf_r[0], 8'h4B, "W replies K")
    end
  endtask

  task cmd_R;
    input [31:0] addr;
    input [31:0] len;
    begin
      txbuf[0] = "R";
      put_addr_len(addr, len);
      exchange(9, len);
    end
  endtask

  task cmd_G;
    input [31:0] addr;
    begin
      txbuf[0] = "G";
      put_addr_len(addr, 32'd0);
      exchange(5, 1);
      `CHECK_EQ(rbuf_r[0], 8'h4B, "G replies K after the routine returns")
    end
  endtask

  // ---- the uploaded G routine: 3 instructions, writes a word, RETs -------
  reg [31:0] MEM [0:2];    // the lib assembles into a module-level array named MEM
  `include "../lib/riscv_assembly.v"
  initial begin
    ADDI(x10, x0, 8'h15);      // x10 = 0x15
    SW(x10, x0, 1280);         // [0x500] = x10   (the word write)
    JALR(x0, x1, 0);           // RET
    endASM();
    // Hand-assembled cross-checks (one per instruction class used):
    // ADDI: imm=0x015<<20 | rd=10<<7 | op=0x13
    `CHECK_EQ(MEM[0], 32'h01500513, "ADDI x10,x0,0x15 hand encoding")
    // SW x10,0x500(x0): imm[11:5]=0x28<<25 | rs2=10<<20 | f3=2<<12 | op=0x23
    `CHECK_EQ(MEM[1], 32'h50A02023, "SW x10,0x500(x0) hand encoding")
    // JALR x0,0(x1): the standard RET word
    `CHECK_EQ(MEM[2], 32'h00008067, "RET hand encoding")
  end

  // ---- the driven session -------------------------------------------------
  reg [95:0] BANNER_STR = "Loop RISC-V\n";  // first char in the MSBs
  reg  [7:0] banner [0:11];
  reg [31:0] w;
  integer i;

  initial begin
    for (i = 0; i < 12; i = i + 1)
      banner[i] = BANNER_STR[(11-i)*8 +: 8];

    // Banner: 12 frames, decoded independently from each die's TXD.
    fork
      recv_n_r(12);
      recv_n_s(12);
    join
    for (i = 0; i < 12; i = i + 1) begin
      `CHECK_EQ(rbuf_r[i], banner[i], "banner byte (rtl)")
      `CHECK_EQ(rbuf_s[i], banner[i], "banner byte (netlist)")
    end

    // V: the identity string, sent through PUT32 (4 nested PUTBYTE calls).
    cmd_V;

    // 1-byte W of 0x15 to the LED word 0x400004: the byte store hits lane 0
    // and ioLedsW gates on mem_wmask[0], so ledReg takes 0x15 = 5'b10101.
    txbuf[9] = 8'h15;
    cmd_W(32'h00400004, 32'd1);

    // R the word back: {27'd0, ledReg}.
    cmd_R(32'h00400004, 32'd4);
    `CHECK_EQ(rbuf_r[0], 8'h15, "LED word byte 0 reads back 0x15")
    `CHECK_EQ(rbuf_r[1], 8'h00, "LED word byte 1 reads back 0x00")
    `CHECK_EQ(rbuf_r[2], 8'h00, "LED word byte 2 reads back 0x00")
    `CHECK_EQ(rbuf_r[3], 8'h00, "LED word byte 3 reads back 0x00")

    // Upload the 3-instruction routine to 0x500, read the code back, call
    // it with G, then R the word it wrote. The routine is a leaf: it only
    // clobbers x10 (caller-saved per the monitor convention) and RETs.
    for (i = 0; i < 3; i = i + 1) begin
      txbuf[9 + 4*i + 0] = MEM[i][ 7: 0];
      txbuf[9 + 4*i + 1] = MEM[i][15: 8];
      txbuf[9 + 4*i + 2] = MEM[i][23:16];
      txbuf[9 + 4*i + 3] = MEM[i][31:24];
    end
    cmd_W(32'h00000500, 32'd12);
    cmd_R(32'h00000500, 32'd12);
    for (i = 0; i < 3; i = i + 1) begin
      w = {rbuf_r[4*i+3], rbuf_r[4*i+2], rbuf_r[4*i+1], rbuf_r[4*i]};
      `CHECK_EQ(w, MEM[i], "uploaded instruction reads back unchanged")
    end
    cmd_G(32'h00000500);
    cmd_R(32'h00000500, 32'd4);
    w = {rbuf_r[3], rbuf_r[2], rbuf_r[1], rbuf_r[0]};
    `CHECK_EQ(w, 32'h00000015, "G routine wrote 0x15 to 0x500")

    // Live V: the monitor survived the G call.
    cmd_V;

    // Soak the rest of the run: both dies idle with the monitor polling RX.
    // Any port disagreement or stray TXD edge still counts.
    wait (cyc >= TOTAL_CYCLES);

    // ---- the assertions (vacuous prints before this task) ------------------
    $display("cycles=%0d led_changes=%0d txd_edges=%0d mismatches=%0d final rtl=%b synth=%b",
             cyc, led_changes, txd_edges, mism, LEDS_r, LEDS_s);
    `CHECK(mism == 0, "zero port mismatches (LEDS/TXD equal every cycle)")
    `CHECK(txd_edges > 200, "TXD transition count > 200 (a real session ran)")
    `CHECK(led_changes >= 1, "at least one LED change")
    `CHECK_EQ(LEDS_r, 5'b10101, "final LEDS rtl == 5'b10101")
    `CHECK_EQ(LEDS_s, 5'b10101, "final LEDS netlist == 5'b10101")
    `CHECK_EQ(TXD_r, 1'b1, "TXD rtl idle high at the end")
    `CHECK_EQ(TXD_s, 1'b1, "TXD netlist idle high at the end")
    `DONE
  end
endmodule
