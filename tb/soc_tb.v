`timescale 1ns/1ps
`default_nettype none
// SOC smoke test: the fetch machine walks the ROM program word by word and
// LEDS show mem_rdata[4:0]. The ROM constants are duplicated here as an
// independent copy; the cross-check against dut.MEM catches drift.
//
// Timing (SLOW = 0, one LED word per CLK edge): PC is held at 0 through the
// 16-cycle power-on reset, so LEDS show ROM word 0 during reset and for one
// more edge; from the first post-reset edge the display is exactly periodic,
// word w for one clock, wrapping 15 -> 0.
module soc_tb;
  `include "check.vh"
  `WATCHDOG(1_000_000)

  reg        CLK = 0;
  reg        RXD = 1;
  wire       TXD;
  wire [4:0] LEDS;

  SOC #(.SLOW(0)) dut (.CLK(CLK), .RXD(RXD), .TXD(TXD), .LEDS(LEDS));

  always #41.667 CLK = ~CLK;   // 12 MHz

  // Independent copy of the ROM program (must match rtl/memory.v).
  reg [31:0] EXP [0:15];
  initial begin
    EXP[0]  = 32'h00000001;
    EXP[1]  = 32'h00000002;
    EXP[2]  = 32'h00000004;
    EXP[3]  = 32'h00000008;
    EXP[4]  = 32'h00000010;
    EXP[5]  = 32'h00000015;
    EXP[6]  = 32'h0000000A;
    EXP[7]  = 32'hDEADBEEF;
    EXP[8]  = 32'h0000001F;
    EXP[9]  = 32'h00000000;
    EXP[10] = 32'h80000015;
    EXP[11] = 32'h7FFFFFFF;
    EXP[12] = 32'h0000000C;
    EXP[13] = 32'h00000003;
    EXP[14] = 32'h00000018;
    EXP[15] = 32'hCAFEBABE;
  end

  integer i, pass, w;

  initial begin
    `CHECK_EQ(TXD, 1'b1, "TXD idles high")

    // Power-on reset: PC held at 0, strobe high, so LEDS already show word 0.
    for (i = 0; i < 16; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(LEDS, EXP[0][4:0], "LEDS show ROM word 0 during reset")
    end
    `CHECK_EQ(dut.clockworks.resetn, 1'b1, "reset released after 16 cycles")
    `CHECK_EQ(dut.PC, 32'd0, "PC starts at 0")

    // Two full passes over the ROM, word by word (edge, then sample).
    for (pass = 0; pass < 2; pass = pass + 1)
      for (w = 0; w < 16; w = w + 1) begin
        @(posedge CLK); #1;
        `CHECK_EQ(LEDS, EXP[w][4:0], "LEDS follow the ROM word by word")
        if (pass == 0 && w == 0)
          `CHECK_EQ(dut.PC, 32'd4, "PC advances by 4 out of reset")
        if (pass == 1 && w == 0)
          `CHECK_EQ(dut.PC, 32'd4, "PC wrapped to 0, then advanced by 4")
      end

    // After two passes (32 words) PC has wrapped back to 0 and LEDS still
    // show the last word of the second pass.
    `CHECK_EQ(dut.PC, 32'd0, "PC wrapped after the last initialised word")
    `CHECK_EQ(LEDS, EXP[15][4:0], "LEDS show the last word after two passes")

    // The bench copy and the ROM must agree.
    for (i = 0; i < 16; i = i + 1)
      `CHECK_EQ(dut.memory.MEM[i], EXP[i], "ROM word matches the bench's independent copy")

    `DONE
  end
endmodule
`default_nettype wire
