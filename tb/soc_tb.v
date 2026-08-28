`timescale 1ns/1ps
`default_nettype none
// SOC smoke test: Processor + Memory run the small ADDI program from the ROM;
// LEDS show x1[4:0]. The program walks x1 through 1,3,7,15,31 — one ADDI
// every 3 CPU cycles — and halts on EBREAK with PC frozen at 20. The ROM
// words are duplicated here hand-assembled; the cross-check against
// dut.memory.MEM catches the assembler output and the copy drifting apart.
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

  // LEDS after each of the first 15 post-reset edges: x1 changes on the edge
  // that completes each ADDI (FETCH_INSTR, FETCH_REGS, EXECUTE = 3 edges).
  reg [4:0] EXP_LEDS [0:14];
  integer i;

  initial begin
    EXP_LEDS[0]  = 5'd0;  EXP_LEDS[1]  = 5'd0;
    EXP_LEDS[2]  = 5'd1;  EXP_LEDS[3]  = 5'd1;  EXP_LEDS[4]  = 5'd1;
    EXP_LEDS[5]  = 5'd3;  EXP_LEDS[6]  = 5'd3;  EXP_LEDS[7]  = 5'd3;
    EXP_LEDS[8]  = 5'd7;  EXP_LEDS[9]  = 5'd7;  EXP_LEDS[10] = 5'd7;
    EXP_LEDS[11] = 5'd15; EXP_LEDS[12] = 5'd15; EXP_LEDS[13] = 5'd15;
    EXP_LEDS[14] = 5'd31;

    `CHECK_EQ(TXD, 1'b1, "TXD idles high")

    // Power-on reset: PC held at 0, x1 = 0, LEDS dark.
    for (i = 0; i < 16; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(LEDS, 5'd0, "LEDS dark during reset")
    end
    `CHECK_EQ(dut.clockworks.resetn, 1'b1, "reset released after 16 cycles")
    `CHECK_EQ(dut.processor.PC, 32'd0, "PC starts at 0")

    // Program run: one ADDI every 3 edges, LEDS = x1[4:0].
    for (i = 0; i < 15; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(LEDS, EXP_LEDS[i], "LEDS walk 0,1,3,7,15,31, one ADDI every 3 edges")
    end
    `CHECK_EQ(dut.processor.PC, 32'd20, "PC at the EBREAK after the five ADDIs")
    `CHECK_EQ(dut.processor.RegisterBank[1], 32'd31, "x1 = 1+2+4+8+16 = 31")

    // EBREAK halts: LEDS and PC frozen.
    repeat (10) begin
      @(posedge CLK); #1;
      `CHECK_EQ(LEDS, 5'd31, "LEDS frozen after EBREAK")
      `CHECK_EQ(dut.processor.PC, 32'd20, "PC frozen after EBREAK")
    end

    // The ROM words match the hand-assembled copies.
    for (i = 0; i < 6; i = i + 1)
      `CHECK_EQ(dut.memory.MEM[i], EXP[i], "ROM word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
