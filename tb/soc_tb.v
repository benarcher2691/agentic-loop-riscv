`timescale 1ns/1ps
`default_nettype none
// Smoke test for the top level. Extend as SOC grows (see TASKS.md).
// SLOW = 0 so the LED counter runs at CLK speed in simulation.
module soc_tb;
  `include "check.vh"
  `WATCHDOG(1_000_000)

  reg        CLK = 0;
  reg        RXD = 1;
  wire       TXD;
  wire [4:0] LEDS;

  SOC #(.SLOW(0)) dut (.CLK(CLK), .RXD(RXD), .TXD(TXD), .LEDS(LEDS));

  always #41.667 CLK = ~CLK;   // 12 MHz

  integer   i;
  integer   wait_edges;
  reg [4:0] expected;

  initial begin
    `CHECK_EQ(TXD, 1'b1, "TXD idles high")

    // LEDS held at 0 during the 16-cycle power-on reset
    for (i = 0; i < 16; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(LEDS, 5'd0, "LEDS = 0 during power-on reset")
    end

    // first increment out of reset (LEDS must leave 0 within a few cycles)
    wait_edges = 0;
    while (LEDS !== 5'd1 && wait_edges < 100) begin
      @(posedge CLK); #1;
      wait_edges = wait_edges + 1;
    end
    `CHECK_EQ(LEDS, 5'd1, "LEDS starts incrementing after reset")

    // exactly +1 per clock; 5-bit expected wraps 31 -> 0 naturally
    expected = 5'd1;
    for (i = 0; i < 70; i = i + 1) begin
      @(posedge CLK); #1;
      expected = expected + 5'd1;
      `CHECK_EQ(LEDS, expected, "LEDS increments by exactly 1 per clock")
    end

    `DONE
  end
endmodule
`default_nettype wire
