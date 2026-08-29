`timescale 1ns/1ps
`default_nettype none
// Monitor command protocol, end to end. The resident program prints the
// banner, then runs the monitor command loop forever: read a command byte
// with GETBYTE, dispatch, repeat. Commands (multi-byte values are
// little-endian 32-bit, moved via GET32/PUT32 — non-leaf helpers that call
// GETBYTE/PUTBYTE four times through the stack):
//   'V' (0x56)          -> PUT32 the 4 bytes "RV32"
//   'W' addr len data.. -> write len bytes to addr (RAM or IO), reply 'K'
//   'R' addr len        -> send the len bytes read from addr
//   'G' addr            -> call the routine at addr (RET returns), reply 'K'
//   anything else       -> reply '?'
// The bench drives the protocol over the serial models: banner, V, W of 8
// words at 0x400 + R readback, an uploaded sum routine (via W) run with G,
// the LED word written and read back, an unknown command, and a final V to
// prove the monitor survived the G call (which may clobber everything but
// sp).
module monitor_tb;
  `include "check.vh"
  `WATCHDOG(200_000_000)

  reg        CLK = 0;
  reg        RXD = 1;
  wire       TXD;
  wire [4:0] LEDS;

  SOC #(.SLOW(0)) dut (.CLK(CLK), .RXD(RXD), .TXD(TXD), .LEDS(LEDS));

  always #41.667 CLK = ~CLK;   // 12 MHz

  // The emitter's data register has no power-on value (X in RTL sim would
  // stall o_ready forever); one hierarchical write kicks it into idle.
  initial dut.uart.data = 10'd0;

  // ---- serial models (same shape as monitor_io_tb) -----------------------
  localparam real BITNS = 1000000000.0 / 115200.0;   // 8680.6 ns per bit

  task recv_byte;
    output [7:0] b;
    integer k;
    begin
      @(negedge TXD);          // start bit edge
      #(BITNS * 1.5);          // centre of data bit 0
      for (k = 0; k < 8; k = k + 1) begin
        b[k] = TXD;            // LSB first
        #(BITNS);
      end
      `CHECK_EQ(TXD, 1'b1, "stop bit is high")
    end
  endtask

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

  // ---- protocol buffers and exchanges ------------------------------------
  reg [7:0] txbuf [0:255];
  reg [7:0] rxbuf [0:255];

  // Send txlen bytes from txbuf while receiving rxlen bytes into rxbuf.
  // ONE forked pair: the reply's first start bit can land in the mid-stop
  // of the last command byte (a sequential recv would miss the edge).
  task exchange;
    input integer txlen;
    input integer rxlen;
    begin
      fork
        begin : snd
          integer i;
          for (i = 0; i < txlen; i = i + 1) send_byte(txbuf[i]);
        end
        begin : rcv
          integer j;
          for (j = 0; j < rxlen; j = j + 1) recv_byte(rxbuf[j]);
        end
      join
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
      `CHECK_EQ(rxbuf[0], 8'h52, "V: byte0 is 'R'")
      `CHECK_EQ(rxbuf[1], 8'h56, "V: byte1 is 'V'")
      `CHECK_EQ(rxbuf[2], 8'h33, "V: byte2 is '3'")
      `CHECK_EQ(rxbuf[3], 8'h32, "V: byte3 is '2'")
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
      `CHECK_EQ(rxbuf[0], 8'h4B, "W replies K")
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

  // T5(c): a W command split in half — 'W' plus the first 2 address bytes,
  // then 50 bit-times of dead line (RXD idles high), then the rest. The
  // monitor's GETBYTE loop must simply wait; the reply's first start bit can
  // land in the mid-stop of the last data byte, so the receiver is forked
  // with the sender of the second half (same rule as exchange).
  task cmd_W_split;
    input [31:0] addr;
    input [31:0] len;
    integer i2;
    begin
      txbuf[0] = "W";
      put_addr_len(addr, len);
      send_byte(txbuf[0]);          // 'W'
      send_byte(txbuf[1]);          // addr byte 0
      send_byte(txbuf[2]);          // addr byte 1 — then silence
      repeat (50) #(BITNS);
      fork
        begin : snd2
          for (i2 = 3; i2 < 9 + len; i2 = i2 + 1) send_byte(txbuf[i2]);
        end
        begin : rcv2
          recv_byte(rxbuf[0]);
        end
      join
      `CHECK_EQ(rxbuf[0], 8'h4B, "split W (50 bit-times of silence mid-command) replies K")
    end
  endtask

  // ---- uploaded G routines, assembled with the lib -----------------------
  // sum = add of the 8 words at 0x400 into 0x420, then RET. Leaf: no push.
  // T5(c) adds a second routine (words 10..47): clobber EVERY register
  // except x2 (sp) — including x1 (ra) and x5 — then still return cleanly.
  reg [31:0] MEM [0:47];   // the lib assembles into a module-level array named MEM
  `include "../lib/riscv_assembly.v"
  integer L0_ = 12;   // word 3 (byte 12): the loop head, hand-counted
  initial begin
    ADDI(x10, x0, 1024);        // ptr = 0x400
    ADDI(x11, x0, 0);           // sum = 0
    ADDI(x12, x0, 8);           // count = 8
    Label(L0_);
    LW(x13, x10, 0);
    ADD(x11, x11, x13);
    ADDI(x10, x10, 4);
    ADDI(x12, x12, -1);
    BNE(x12, x0, LabelRef(L0_));
    SW(x11, x0, 1056);          // 0x420: sum word
    JALR(x0, x1, 0);            // RET
    // Encoding cross-checks against hand-assembled hex (one per new class):
    // LW x13,0(x10): imm=0 rs1=01010 f3=010 rd=01101 op=0000011
    `CHECK_EQ(MEM[3], 32'h00052683, "LW x13,0(x10) hand encoding")
    // ADD x11,x11,x13: f7=0 rs2=01101 rs1=01011 f3=000 rd=01011 op=0110011
    `CHECK_EQ(MEM[4], 32'h00D585B3, "ADD x11,x11,x13 hand encoding")
    // JALR x0,0(x1): the standard RET word
    `CHECK_EQ(MEM[9], 32'h00008067, "RET hand encoding")

    // ---- T5(c): the register-wrecking routine (words 10..47, 152 bytes) ----
    // The trick that makes "clobber x1" and "return" compatible: the saved
    // return address lives in a scratch word at 0x1000, and x1's clobber
    // value LUI(x1,1) = 0x1000 IS that address — so the final LW x1,0(x1)
    // reloads the RA through the clobbered register itself. x5's clobber
    // (0x5000) is pinned explicitly in the checks below. The LED store runs
    // FIRST so x10/x11 end up clobbered too (0xA000/0xB000).
    LUI(x10, 32'h00400000);     // word 10: x10 = 0x00400000
    ADDI(x10, x10, 4);          // word 11: x10 = 0x00400004, the LED word
    ADDI(x11, x0, 8'h15);       // word 12: 0x15 -> 5'b10101
    SW(x11, x10, 0);            // word 13: LEDs on
    LUI(x5, 32'h00001000);      // word 14: x5 = 0x1000, scratch for the RA
    SW(x1, x5, 0);              // word 15: save the return address
    LUI(x1, 32'h00001000);      // word 16: clobber x1 -> 0x1000
    LUI(x3,  32'h00003000);     // words 17..45: clobber x3..x31 to N<<12
    LUI(x4,  32'h00004000);     // (x2 = sp is the one register left alone)
    LUI(x5,  32'h00005000);
    LUI(x6,  32'h00006000);
    LUI(x7,  32'h00007000);
    LUI(x8,  32'h00008000);
    LUI(x9,  32'h00009000);
    LUI(x10, 32'h0000A000);
    LUI(x11, 32'h0000B000);
    LUI(x12, 32'h0000C000);
    LUI(x13, 32'h0000D000);
    LUI(x14, 32'h0000E000);
    LUI(x15, 32'h0000F000);
    LUI(x16, 32'h00010000);
    LUI(x17, 32'h00011000);
    LUI(x18, 32'h00012000);
    LUI(x19, 32'h00013000);
    LUI(x20, 32'h00014000);
    LUI(x21, 32'h00015000);
    LUI(x22, 32'h00016000);
    LUI(x23, 32'h00017000);
    LUI(x24, 32'h00018000);
    LUI(x25, 32'h00019000);
    LUI(x26, 32'h0001A000);
    LUI(x27, 32'h0001B000);
    LUI(x28, 32'h0001C000);
    LUI(x29, 32'h0001D000);
    LUI(x30, 32'h0001E000);
    LUI(x31, 32'h0001F000);     // word 45
    LW(x1, x1, 0);              // word 46: x1 = saved RA, via clobbered x1
    JALR(x0, x1, 0);            // word 47: RET
    endASM();
    // Encoding cross-checks for the new routine (hand-assembled):
    // LUI x10,0x00400: imm20=0x00400|rd=10<<7=0x500|op=0x37
    `CHECK_EQ(MEM[10], 32'h00400537, "LUI x10,0x00400000 hand encoding")
    // SW x1,0(x5): rs2=00001 rs1=00101 f3=010 imm=0 op=0100011
    `CHECK_EQ(MEM[15], 32'h0012A023, "SW x1,0(x5) hand encoding")
    // LW x1,0(x1): imm=0 rs1=00001 f3=010 rd=00001 op=0000011
    `CHECK_EQ(MEM[46], 32'h0000A083, "LW x1,0(x1) hand encoding")
    // LUI x31,0x1F: imm20=0x1F|rd=31<<7=0xF80|op=0x37
    `CHECK_EQ(MEM[45], 32'h0001FFB7, "LUI x31,0x0001F000 hand encoding")
  end

  // ---- test sequence ------------------------------------------------------
  reg [95:0] BANNER_STR = "Loop RISC-V\n";  // first char in the MSBs
  reg  [7:0] banner [0:11];
  reg  [7:0] b;
  reg  [31:0] words [0:7];
  reg  [31:0] sum, w, savedRa;
  reg  [31:0] snap [1:32];   // register-file snapshot taken by watchClobber
  integer i;

  initial begin
    for (i = 0; i < 12; i = i + 1)
      banner[i] = BANNER_STR[(11-i)*8 +: 8];

    `CHECK_EQ(TXD, 1'b1, "TXD idles high before the first byte")

    // Banner: 12 bytes, in order, clean framing.
    for (i = 0; i < 12; i = i + 1) begin
      recv_byte(b);
      `CHECK_EQ(b, banner[i], "banner byte received in order")
    end

    // V: the identity string, sent through PUT32 (4 nested PUTBYTE calls).
    cmd_V;

    // W 8 words at 0x400, then R them back byte by byte. The set includes
    // +1/-1 and 0x7FFFFFFF/0x80000000 so the G sum below wraps for real.
    words[0] = 32'h0000000A;
    words[1] = 32'h00000014;
    words[2] = 32'h0000001E;
    words[3] = 32'h00000028;
    words[4] = 32'hFFFFFFFB;   // -5
    words[5] = 32'h7FFFFFFF;
    words[6] = 32'h80000000;
    words[7] = 32'h00000003;
    sum = 32'd0;
    for (i = 0; i < 8; i = i + 1) begin
      sum = sum + words[i];    // independent 2^32-wrapping reference
      txbuf[9 + 4*i + 0] = words[i][ 7: 0];
      txbuf[9 + 4*i + 1] = words[i][15: 8];
      txbuf[9 + 4*i + 2] = words[i][23:16];
      txbuf[9 + 4*i + 3] = words[i][31:24];
    end
    // Hand-computed sum of the chosen words: 10+20+30+40-5 = 95;
    // 95 + 0x7FFFFFFF = 0x8000005E; + 0x80000000 = 0x5E; + 3 = 0x61.
    `CHECK_EQ(sum, 32'h00000061, "bench sum model matches the hand sum")
    cmd_W(32'h00000400, 32'd32);

    cmd_R(32'h00000400, 32'd32);
    for (i = 0; i < 8; i = i + 1) begin
      w = {rxbuf[4*i+3], rxbuf[4*i+2], rxbuf[4*i+1], rxbuf[4*i]};
      `CHECK_EQ(w, words[i], "uploaded word reads back unchanged")
    end

    // ---- T5(c): zero-length R — zero data bytes, then a live V ------------
    // The monitor must send NOTHING for an R of length 0 and go straight
    // back to GETBYTE. The following V proves both: if any stray byte had
    // been emitted, it would be consumed as V's first reply byte and the
    // 'R' check below would fail.
    cmd_R(32'h00000400, 32'd0);
    cmd_V;

    // ---- T5(c): zero-length W — K, memory untouched ------------------------
    cmd_W(32'h00000400, 32'd0);
    cmd_R(32'h00000400, 32'd32);
    for (i = 0; i < 8; i = i + 1) begin
      w = {rxbuf[4*i+3], rxbuf[4*i+2], rxbuf[4*i+1], rxbuf[4*i]};
      `CHECK_EQ(w, words[i], "zero-length W left memory untouched")
    end

    // ---- T5(c): split W — command bytes with a 50 bit-time gap -------------
    // Four bytes 0D F0 C3 A5 (word 0xA5C3F00D) to fresh RAM at 0x430, sent
    // as 'W' + 2 address bytes, silence, then the rest. Readback proves the
    // command completed normally despite the dead time.
    txbuf[9] = 8'h0D; txbuf[10] = 8'hF0; txbuf[11] = 8'hC3; txbuf[12] = 8'hA5;
    cmd_W_split(32'h00000430, 32'd4);
    cmd_R(32'h00000430, 32'd4);
    w = {rxbuf[3], rxbuf[2], rxbuf[1], rxbuf[0]};
    `CHECK_EQ(w, 32'hA5C3F00D, "split W wrote the word intact")

    // G: upload the sum routine (10 words = 40 bytes) to 0x600 via W, call
    // it with G, then R the sum word at 0x420. The routine is a leaf: it
    // clobbers x10-x13 (caller-saved per the monitor convention) but not
    // sp, and returns with RET.
    for (i = 0; i < 10; i = i + 1) begin
      txbuf[9 + 4*i + 0] = MEM[i][ 7: 0];
      txbuf[9 + 4*i + 1] = MEM[i][15: 8];
      txbuf[9 + 4*i + 2] = MEM[i][23:16];
      txbuf[9 + 4*i + 3] = MEM[i][31:24];
    end
    cmd_W(32'h00000600, 32'd40);
    txbuf[0] = "G";
    put_addr_len(32'h00000600, 32'd0);
    exchange(5, 1);
    `CHECK_EQ(rxbuf[0], 8'h4B, "G replies K after the routine returns")
    cmd_R(32'h00000420, 32'd4);
    w = {rxbuf[3], rxbuf[2], rxbuf[1], rxbuf[0]};
    `CHECK_EQ(w, sum, "G routine summed the 8 words into 0x420")

    // The LED word: write the FULL 32-bit word 0x00000015 as FOUR bytes — this
    // is exactly what `hw.py poke 0x400004 0x15` does. Regression for the byte-
    // write clobber: the low byte (0x15) must light 5'b10101 and the three high
    // zero bytes must NOT clear it (they hit other lanes; ledReg gates on
    // mem_wmask[0]). Then R it back as {27'd0, ledReg}.
    txbuf[9]  = 8'h15;   // -> 0x400004 lane 0 (sets ledReg)
    txbuf[10] = 8'h00;   // -> 0x400005 lane 1 (must not clobber)
    txbuf[11] = 8'h00;   // -> 0x400006 lane 2
    txbuf[12] = 8'h00;   // -> 0x400007 lane 3
    cmd_W(32'h00400004, 32'd4);
    `CHECK_EQ(LEDS, 5'b10101, "byte-wise 4-byte W keeps LEDS 5'b10101 (high zero bytes do not clobber)")
    cmd_R(32'h00400004, 32'd4);
    `CHECK_EQ(rxbuf[0], 8'h15, "LED word byte 0 reads back 0x15")
    `CHECK_EQ(rxbuf[1], 8'h00, "LED word byte 1 reads back 0x00")
    `CHECK_EQ(rxbuf[2], 8'h00, "LED word byte 2 reads back 0x00")
    `CHECK_EQ(rxbuf[3], 8'h00, "LED word byte 3 reads back 0x00")

    // ---- T5(c): G a routine that clobbers EVERY register except x2 --------
    // Upload the 38-word routine (words 10..47 of MEM) to 0x700 and call it.
    // It lights the LEDs, saves the RA to 0x1000, wrecks x1 and x3..x31 with
    // LUI garbage (x5 -> 0x5000), reloads the RA through the clobbered x1
    // and RETs. The monitor must reply K, keep the LEDs, and stay alive.
    for (i = 0; i < 38; i = i + 1) begin
      txbuf[9 + 4*i + 0] = MEM[10 + i][ 7: 0];
      txbuf[9 + 4*i + 1] = MEM[10 + i][15: 8];
      txbuf[9 + 4*i + 2] = MEM[10 + i][23:16];
      txbuf[9 + 4*i + 3] = MEM[10 + i][31:24];
    end
    cmd_W(32'h00000700, 32'd152);
    // G it, with a concurrent watcher sampling the register file while the
    // routine's final LW x1,0(x1) (0x700 + 36*4 = 0x790) is in flight. That
    // is the only moment every clobber is visible: after the return, the
    // monitor's own K-reply code runs and re-trashes registers BY DESIGN
    // (x1 becomes its PUTBYTE link, x5/x9/x10 its helpers) — the convention
    // says the callee owns everything but sp, so post-return values prove
    // nothing. The snapshot proves the clobbers; the K reply proves the
    // return still worked with x1 freshly restored from the wreckage.
    fork
      begin : watchClobber
        integer g2;
        g2 = 0;
        while ((dut.processor.PC !== 32'h790) && g2 < 200000) begin
          @(posedge CLK); #1;
          g2 = g2 + 1;
        end
        `CHECK_EQ(dut.processor.PC, 32'h790,
                  "watcher caught the routine's final LW x1,0(x1) in flight")
        for (i = 1; i < 32; i = i + 1) snap[i] = dut.processor.RegisterBank[i];
      end
      begin : runClobberG
        txbuf[0] = "G";
        put_addr_len(32'h00000700, 32'd0);
        exchange(5, 1);
      end
    join
    `CHECK_EQ(rxbuf[0], 8'h4B, "clobber-G replies K after the routine returns")
    `CHECK_EQ(LEDS, 5'b10101, "clobber-G lit the LEDs before wrecking the registers")
    `CHECK_EQ(snap[1], 32'h00001000,
              "x1 clobbered to 0x1000 at the routine's last load (RA long gone)")
    `CHECK_EQ(snap[2], 32'h1800, "sp (x2) untouched by the clobber-G")
    for (i = 3; i < 32; i = i + 1)
      `CHECK_EQ(snap[i], i << 12, "xN holds its LUI clobber N<<12 at the routine's last load")
    `CHECK_EQ(dut.processor.RegisterBank[2], 32'h1800,
              "sp still 0x1800 after the whole exchange: no stack drift")
    // The RA the routine saved at 0x1000: a real monitor call-site address,
    // not the scratch word and not 0 — the K reply proves the restore used it.
    cmd_R(32'h00001000, 32'd4);
    savedRa = {rxbuf[3], rxbuf[2], rxbuf[1], rxbuf[0]};
    `CHECK(savedRa != 32'h1000 && savedRa != 32'd0,
           "saved RA is a monitor call-site address, not the scratch word")
    cmd_R(32'h00400004, 32'd4);
    `CHECK_EQ(rxbuf[0], 8'h15, "LED word byte 0 still 0x15 after the clobber-G")
    // Live V: the monitor survived the destruction of every register but sp.
    cmd_V;

    // Unknown command: 'X' replies '?'.
    txbuf[0] = "X";
    exchange(1, 1);
    `CHECK_EQ(rxbuf[0], 8'h3F, "unknown command replies '?'")

    // Survival: G may clobber everything but sp, yet the monitor loop is
    // still fully alive — another V round trip proves it.
    cmd_V;

    // Idle state: back in the MAIN GETBYTE poll with sp at the convention
    // value (no stack drift across the whole session).
    i = 0;
    while ((dut.processor.PC < 32'd348 || dut.processor.PC >= 32'd364) && i < 100000) begin
      @(posedge CLK); #1;
      i = i + 1;
    end
    `CHECK(dut.processor.PC >= 32'd348 && dut.processor.PC < 32'd364,
           "PC polls in the GETBYTE loop (bytes 348..363) while idle")
    `CHECK_EQ(dut.processor.RegisterBank[2], 32'h1800,
              "sp back at 0x1800 after the whole session: no stack drift")

    `DONE
  end
endmodule
`default_nettype wire
