// Self-checking testbench helpers. `include this INSIDE the testbench module.
//
//   `CHECK(cond, "message")          counts one check; fails if cond is false
//   `CHECK_EQ(got, expected, "msg")  counts one check; 4-state compare (X != anything)
//   `DONE                            prints the CHECKS summary, PASS or FAIL, and exits
//
// The Makefile requires every bench to print PASS and a CHECKS line.
`ifndef CHECK_VH
`define CHECK_VH
integer __checks = 0;
integer __errors = 0;
`define CHECK(cond, msg) \
  begin __checks = __checks + 1; \
    if (!(cond)) begin __errors = __errors + 1; \
      $display("FAIL: %s (%s line %0d, t=%0t)", msg, `__FILE__, `__LINE__, $time); end end
`define CHECK_EQ(got, exp, msg) \
  begin __checks = __checks + 1; \
    if ((got) !== (exp)) begin __errors = __errors + 1; \
      $display("FAIL: %s: got 0x%0h expected 0x%0h (%s line %0d, t=%0t)", msg, got, exp, `__FILE__, `__LINE__, $time); end end
`define DONE \
  begin $display("CHECKS: %0d passed, %0d failed", __checks - __errors, __errors); \
    if (__errors != 0) begin $display("FAIL"); $fatal(1); end \
    else $display("PASS"); $finish; end
// Every bench must arm a watchdog so a hung design fails instead of running forever.
`define WATCHDOG(ns) \
  initial begin #(ns); $display("FAIL: watchdog timeout after %0d ns", ns); $fatal(1); end
`endif
