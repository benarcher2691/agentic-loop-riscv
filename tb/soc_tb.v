`timescale 1ns/1ps
`default_nettype none
// Smoke test for the top level. Extend as SOC grows (see TASKS.md).
module soc_tb;
  `include "check.vh"
  `WATCHDOG(1_000_000)

  reg        CLK = 0;
  reg        RXD = 1;
  wire       TXD;
  wire [4:0] LEDS;

  SOC dut (.CLK(CLK), .RXD(RXD), .TXD(TXD), .LEDS(LEDS));

  always #41.667 CLK = ~CLK;   // 12 MHz

  initial begin
    repeat (10) @(posedge CLK);
    `CHECK(LEDS !== 5'bxxxxx, "LEDS are driven (not X)")
    `CHECK_EQ(TXD, 1'b1, "TXD idles high")
    `DONE
  end
endmodule
`default_nettype wire
