`timescale 1ns/1ps
`default_nettype none
// SOC smoke test: Processor + Memory run the small ADDI program from the ROM.
// LEDS are driven by the IO write register (address bit 22 space) since the
// memory-mapped IO task — the ADDI program never touches IO, so LEDS stay
// dark; the x1 walk it used to display is still checked via RegisterBank.
// The program walks x1 through 1,3,7,15,31 — one ADDI every 3 CPU cycles —
// and halts on EBREAK with PC frozen at 20. The ROM words are duplicated
// here hand-assembled; the cross-check against dut.memory.MEM catches the
// assembler output and the copy drifting apart.
module soc_tb;
  `include "check.vh"
  `WATCHDOG(1_000_000)

  reg        CLK = 0;
  reg        RXD = 1;
  wire       TXD;
  wire [4:0] LEDS;

  SOC #(.SLOW(0)) dut (.CLK(CLK), .RXD(RXD), .TXD(TXD), .LEDS(LEDS));

  always #41.667 CLK = ~CLK;   // 12 MHz

  // Hand-assembled copy of the ROM program (must match rtl/memory.v).
  reg [31:0] EXP [0:5];
  initial begin
    EXP[0] = 32'h00100093;  // addi x1,x0,1
    EXP[1] = 32'h00208093;  // addi x1,x1,2
    EXP[2] = 32'h00408093;  // addi x1,x1,4
    EXP[3] = 32'h00808093;  // addi x1,x1,8
    EXP[4] = 32'h01008093;  // addi x1,x1,16
    EXP[5] = 32'h00100073;  // ebreak
  end

  // LEDS after each of the first 15 post-reset edges: the LED register only
  // moves on an IO write, and this program makes none — LEDS stay dark.
  reg [4:0] EXP_LEDS [0:14];
  integer i;

  initial begin
    for (i = 0; i < 15; i = i + 1) EXP_LEDS[i] = 5'd0;

    `CHECK_EQ(TXD, 1'b1, "TXD idles high")

    // Power-on reset: PC held at 0, x1 = 0, LEDS dark.
    for (i = 0; i < 16; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(LEDS, 5'd0, "LEDS dark during reset")
    end
    `CHECK_EQ(dut.clockworks.resetn, 1'b1, "reset released after 16 cycles")
    `CHECK_EQ(dut.processor.PC, 32'd0, "PC starts at 0")

    // Program run: one ADDI every 3 edges, LEDS dark (no IO writes yet).
    for (i = 0; i < 15; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(LEDS, EXP_LEDS[i], "LEDS stay dark: no IO write in this program")
    end
    `CHECK_EQ(dut.processor.PC, 32'd20, "PC at the EBREAK after the five ADDIs")
    `CHECK_EQ(dut.processor.RegisterBank[1], 32'd31, "x1 = 1+2+4+8+16 = 31")

    // EBREAK halts: LEDS and PC frozen.
    repeat (10) begin
      @(posedge CLK); #1;
      `CHECK_EQ(LEDS, 5'd0, "LEDS frozen after EBREAK")
      `CHECK_EQ(dut.processor.PC, 32'd20, "PC frozen after EBREAK")
    end

    // The ROM words match the hand-assembled copies.
    for (i = 0; i < 6; i = i + 1)
      `CHECK_EQ(dut.memory.MEM[i], EXP[i], "ROM word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
