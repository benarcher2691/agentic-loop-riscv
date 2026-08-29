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

  // ---- uploaded G routine, assembled with the lib ------------------------
  // sum = add of the 8 words at 0x400 into 0x420, then RET. Leaf: no push.
  reg [31:0] MEM [0:15];   // the lib assembles into a module-level array named MEM
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
  end

  // ---- test sequence ------------------------------------------------------
  reg [95:0] BANNER_STR = "Loop RISC-V\n";  // first char in the MSBs
  reg  [7:0] banner [0:11];
  reg  [7:0] b;
  reg  [31:0] words [0:7];
  reg  [31:0] sum, w;
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
