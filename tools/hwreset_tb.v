`timescale 1ns/1ps
// Hardware-reset pin: compiled WITHOUT -DFAST_SIM, so Clockworks uses its
// hardware RESET_CYCLES (65536 — the iCE40 BRAM-readiness margin, the one
// field bug; see docs/decisions.md and audit A-delta). Asserts resetn is low
// for exactly 65,536 CLK cycles and then high forever. Kills the mutant
// RESET_CYCLES 65536->16, which survives every FAST_SIM-compiled stage.
module hwreset_tb;
  `include "check.vh"
  `WATCHDOG(20_000_000)   // 65,536 cycles at 83.3 ns ≈ 5.5 ms; 20 ms guard

  reg CLK = 0;
  wire clk, resetn;
  Clockworks #(.SLOW(0)) dut (.CLK(CLK), .clk(clk), .resetn(resetn));
  always #41.667 CLK = ~CLK;

  integer i;
  initial begin
    `CHECK_EQ(resetn, 1'b0, "resetn low at power-up")
    for (i = 0; i < 65536; i = i + 1) begin
      @(posedge CLK);
      if (resetn !== 1'b0 && i < 65535) begin
        `CHECK_EQ(resetn, 1'b0, "resetn must stay low through cycle 65535")
        i = 65536; // bail after first failure
      end
    end
    @(posedge CLK); @(posedge CLK);
    `CHECK_EQ(resetn, 1'b1, "resetn high after 65,536 cycles")
    repeat (2000) @(posedge CLK);
    `CHECK_EQ(resetn, 1'b1, "resetn stays high forever")
    `DONE
  end
endmodule
