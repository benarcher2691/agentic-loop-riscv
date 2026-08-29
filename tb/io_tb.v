`timescale 1ns/1ps
`default_nettype none
// Memory-mapped IO: address bit 22 selects IO space instead of RAM.
//   0x400004  LEDS write        (word offset bit 2)
//   0x400008  UART data write   (word offset bit 3)
//   0x400010  UART status read  (word offset bit 4), bit 9 = busy
// The program writes 5'b10101 to the LEDS port and sends "OK\n" through
// corescore_emitter_uart (12 MHz / 115200 baud), waiting on the busy bit
// between bytes. The bench carries a serial receiver model that samples TXD
// at 115200 baud, mid-bit, and checks the three bytes. The program is
// assembled into the bench's own MEM and copied into dut.memory.MEM during
// the power-on reset window; every word is cross-checked against a
// hand-assembled copy (python bit-slicer, spec formulas).
module io_tb;
  `include "check.vh"
  `WATCHDOG(2_000_000)

  reg CLK = 0;
  reg RXD = 1;
  wire       TXD;
  wire [4:0] LEDS;

  SOC #(.SLOW(0)) dut (.CLK(CLK), .RXD(RXD), .TXD(TXD), .LEDS(LEDS));

  always #41.667 CLK = ~CLK;   // 12 MHz

  // The emitter's data register has no power-on value, so in RTL simulation
  // o_ready would never resolve (|data stays X; on hardware the FFs power
  // up 0). One hierarchical write at time 0 kicks it into its idle state.
  initial dut.uart.data = 10'd0;

  // ---- the program -------------------------------------------------------
  reg [31:0] MEM [0:31];
  `include "riscv_assembly.v"
  integer W1 = 28, W2 = 44, W3 = 60;   // busy-wait loop heads (byte addrs)
  integer i;

  // Hand-assembled copy (independent encoder, spec formulas).
  reg [31:0] EXP [0:18];
  initial begin
    EXP[ 0] = 32'h004002B7;  // lui x5,0x400        (x5 = 0x400000 IO base)
    EXP[ 1] = 32'h01500313;  // addi x6,x0,21       (0b10101)
    EXP[ 2] = 32'h0062A223;  // sw x6,4(x5)         LEDS <- 21
    EXP[ 3] = 32'h04F00513;  // addi x10,x0,79      'O'
    EXP[ 4] = 32'h04B00593;  // addi x11,x0,75      'K'
    EXP[ 5] = 32'h00A00613;  // addi x12,x0,10      '\n'
    EXP[ 6] = 32'h00A2A423;  // sw x10,8(x5)        UART data <- 'O'
    EXP[ 7] = 32'h0102A683;  // W1: lw x13,16(x5)   UART status
    EXP[ 8] = 32'h2006F693;  // andi x13,x13,0x200  busy -> bit 9
    EXP[ 9] = 32'hFE069CE3;  // bne x13,x0,W1
    EXP[10] = 32'h00B2A423;  // sw x11,8(x5)        UART data <- 'K'
    EXP[11] = 32'h0102A683;  // W2: lw x13,16(x5)
    EXP[12] = 32'h2006F693;  // andi x13,x13,0x200
    EXP[13] = 32'hFE069CE3;  // bne x13,x0,W2
    EXP[14] = 32'h00C2A423;  // sw x12,8(x5)        UART data <- '\n'
    EXP[15] = 32'h0102A683;  // W3: lw x13,16(x5)
    EXP[16] = 32'h2006F693;  // andi x13,x13,0x200
    EXP[17] = 32'hFE069CE3;  // bne x13,x0,W3
    EXP[18] = 32'h00100073;  // ebreak
  end

  initial begin
    #1;   // the lib's `initial memPC = 0` has run
    // NOTE: the lib's LUI/AUIPC take the FINAL rd value (not the imm20
    // field). Its SRLI macro is fine (audit A16: the old "buggy SRLI"
    // claim here was stale — RType with rs2 = imm[4:0] and funct7 0 is
    // exactly the SRLI encoding); ANDI is used below simply to mask the
    // status word's busy bit.
    LUI(x5, 32'h00400000);
    ADDI(x6, x0, 21);
    SW(x6, x5, 4);
    ADDI(x10, x0, 79);
    ADDI(x11, x0, 75);
    ADDI(x12, x0, 10);
    SW(x10, x5, 8);
    Label(W1); LW(x13, x5, 16);
    ANDI(x13, x13, 512);
    BNE(x13, x0, LabelRef(W1));
    SW(x11, x5, 8);
    Label(W2); LW(x13, x5, 16);
    ANDI(x13, x13, 512);
    BNE(x13, x0, LabelRef(W2));
    SW(x12, x5, 8);
    Label(W3); LW(x13, x5, 16);
    ANDI(x13, x13, 512);
    BNE(x13, x0, LabelRef(W3));
    EBREAK();
    endASM();
    for (i = 0; i < 19; i = i + 1)
      `CHECK_EQ(MEM[i], EXP[i], "assembled word matches the hand encoding")
    // Load the program while the CPU is held by power-on reset (resetn is
    // low for the first 16 CLK cycles; this runs at time 1 ns).
    for (i = 0; i < 19; i = i + 1)
      dut.memory.MEM[i] = MEM[i];
  end

  // ---- serial receiver model: 115200 baud, sample mid-bit ----------------
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

  reg [7:0] b0, b1, b2;

  initial begin
    // LEDS dark through reset and the first instructions (the LED register
    // only changes on an IO write, which happens a few cycles later).
    repeat (20) begin
      @(posedge CLK); #1;
      `CHECK_EQ(LEDS, 5'b00000, "LEDS dark during reset / before the IO write")
    end

    // The program's SW to 0x400004 must drive the SOC's LEDS port.
    i = 0;
    while (LEDS !== 5'b10101 && i < 200) begin
      @(posedge CLK); #1;
      i = i + 1;
    end
    `CHECK_EQ(LEDS, 5'b10101, "program wrote 5'b10101 to the LEDS port")

    // "OK\n" over the UART, one byte at a time (the program waits on the
    // busy bit; a broken wait would drop bytes and show up here).
    recv_byte(b0);
    recv_byte(b1);
    recv_byte(b2);
    `CHECK_EQ(b0, 8'h4F, "received 'O'")
    `CHECK_EQ(b1, 8'h4B, "received 'K'")
    `CHECK_EQ(b2, 8'h0A, "received newline")

    // The program halts at the EBREAK (byte 72); LEDS keep the pattern.
    i = 0;
    while (dut.processor.PC !== 32'd72 && i < 4000) begin
      @(posedge CLK); #1;
      i = i + 1;
    end
    `CHECK_EQ(dut.processor.PC, 32'd72, "PC frozen at the EBREAK")
    repeat (10) begin
      @(posedge CLK); #1;
      `CHECK_EQ(dut.processor.PC, 32'd72, "PC stays frozen after EBREAK")
    end
    `CHECK_EQ(LEDS, 5'b10101, "LEDS keep the written pattern after halt")
    `CHECK_EQ(dut.processor.RegisterBank[6], 32'd21, "x6 = 0b10101")
    `CHECK_EQ(dut.processor.RegisterBank[13], 32'd0,
              "x13 = 0: last status read said not busy (busy is bit 9)")
    // The IO stores must not have leaked into the RAM: program words intact.
    `CHECK_EQ(dut.memory.MEM[1], EXP[1], "IO LEDS write did not corrupt RAM word 1")
    `CHECK_EQ(dut.memory.MEM[2], EXP[2], "IO LEDS write did not corrupt RAM word 2")

    `DONE
  end
endmodule
`default_nettype wire
