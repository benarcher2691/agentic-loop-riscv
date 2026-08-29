`timescale 1ns/1ps
`default_nettype none
// Clockworks bench:
//   - SLOW = 0: clk follows CLK exactly (passthrough)
//   - SLOW = 3: exactly one clk rising edge per 8 CLK edges over 64 cycles,
//     high for 4 of every 8 cycles
//   - resetn: low for the first 16 CLK cycles after power-up, then high forever
//   - RESET_CYCLES override: a #(.RESET_CYCLES(64)) instance holds resetn low
//     for exactly 64 CLK cycles, then high forever (hardware waits 2^16 clocks
//     for the block RAM to become readable; FAST_SIM defaults to 16)
module clockworks_tb;
  `include "check.vh"
  `WATCHDOG(1_000_000)

  reg  CLK = 0;
  wire clk0, resetn0;   // SLOW = 0 instance
  wire clk3, resetn3;   // SLOW = 3 instance
  wire resetn64;        // RESET_CYCLES = 64 instance

  Clockworks #(.SLOW(0)) dut0 (.CLK(CLK), .clk(clk0), .resetn(resetn0));
  Clockworks #(.SLOW(3)) dut3 (.CLK(CLK), .clk(clk3), .resetn(resetn3));
  Clockworks #(.SLOW(0), .RESET_CYCLES(64)) dut64 (.CLK(CLK), .clk(), .resetn(resetn64));

  always #41.667 CLK = ~CLK;   // 12 MHz

  integer i;
  integer rising, high;
  integer last_rise_i, spacing_i;
  reg     prev3;

  initial begin
    // --- power-up state, before the first CLK edge ---
    `CHECK_EQ(clk0,    1'b0, "SLOW=0: clk follows CLK (low at power-up)")
    `CHECK_EQ(clk3,    1'b0, "SLOW=3: divided clk starts low")
    `CHECK_EQ(resetn0, 1'b0, "resetn low at power-up (SLOW=0)")
    `CHECK_EQ(resetn3, 1'b0, "resetn low at power-up (SLOW=3)")
    `CHECK_EQ(resetn64, 1'b0, "resetn low at power-up (RESET_CYCLES=64)")

    // --- first 16 CLK cycles: resetn low, SLOW=0 clk tracks CLK every edge ---
    for (i = 0; i < 15; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(clk0, 1'b1, "SLOW=0: clk high when CLK high")
      `CHECK_EQ(resetn0, 1'b0, "resetn low during first 16 cycles (SLOW=0)")
      `CHECK_EQ(resetn3, 1'b0, "resetn low during first 16 cycles (SLOW=3)")
      `CHECK_EQ(resetn64, 1'b0, "resetn64 low: cycle < 64")
      @(negedge CLK); #1;
      `CHECK_EQ(clk0, 1'b0, "SLOW=0: clk low when CLK low")
    end
    // 16th posedge: POR counter reaches 16, resetn releases
    @(posedge CLK); #1;
    `CHECK_EQ(resetn0, 1'b1, "resetn high after 16 CLK cycles (SLOW=0)")
    `CHECK_EQ(resetn3, 1'b1, "resetn high after 16 CLK cycles (SLOW=3)")
    `CHECK_EQ(resetn64, 1'b0, "resetn64 still low at cycle 16 (16 < 64)")

    // --- resetn stays high forever ---
    for (i = 0; i < 10; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(resetn0, 1'b1, "resetn stays high (SLOW=0)")
      `CHECK_EQ(resetn3, 1'b1, "resetn stays high (SLOW=3)")
    end

    // --- RESET_CYCLES=64: low for exactly 64 CLK cycles, then high forever ---
    // Posedges 17..63 have elapsed: 16 (above) + 10 (stay-high loop) = 26.
    // resetn64 must still be low after posedge 63 and high after posedge 64.
    for (i = 26; i < 63; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(resetn64, 1'b0, "resetn64 low: cycle < 64")
    end
    @(posedge CLK); #1;   // 64th posedge: POR counter reaches 64
    `CHECK_EQ(resetn64, 1'b1, "resetn64 high after exactly 64 CLK cycles")
    for (i = 0; i < 10; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(resetn64, 1'b1, "resetn64 stays high forever")
    end

    // --- SLOW=3: one rising edge per 8 CLK edges over a 64-cycle window ---
    // clk3 is sampled 1 ns after every CLK posedge (NBA values settled);
    // rising edges are detected between consecutive samples.
    rising = 0; high = 0; prev3 = 1'b0; last_rise_i = -1;
    for (i = 0; i < 64; i = i + 1) begin
      @(posedge CLK); #1;
      if (clk3 === 1'b1) high = high + 1;
      if (prev3 === 1'b0 && clk3 === 1'b1) begin
        rising = rising + 1;
        if (last_rise_i != -1) begin
          spacing_i = i - last_rise_i;
          `CHECK_EQ(spacing_i, 8, "SLOW=3: rising edge every 8 CLK edges")
        end
        last_rise_i = i;
      end
      prev3 = clk3;
    end
    `CHECK_EQ(rising, 8,  "SLOW=3: exactly 8 clk rising edges in 64 CLK cycles")
    `CHECK_EQ(high, 32,   "SLOW=3: clk high exactly 4 of every 8 cycles")

    `DONE
  end
endmodule
`default_nettype wire
