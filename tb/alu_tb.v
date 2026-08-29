`timescale 1ns/1ps
`default_nettype none
// ALU bench. Two layers of checking:
//   1. Hand-anchored literal checks: expected values worked out on paper
//      (overflow wrap, sign extension, SRA sign fill, signed vs unsigned).
//   2. A behavioural reference task: drives one (in1, in2, funct3, funct7_5)
//      vector and checks out/EQ/LT/LTU against plain Verilog operators
//      ($signed, >>>, <) — independent of the DUT's implementation.
//
// The ALU shares a single add/sub unit, so its compare outputs EQ/LT/LTU are
// defined ONLY while it subtracts. The bench therefore drives `cmp` (which
// forces a subtract, exactly as the Processor does for branch compares) to a
// second phase of each vector and checks EQ/LT/LTU there, still against an
// independent behavioural reference — never against the DUT's own `out`.
module alu_tb;
  `include "check.vh"
  `WATCHDOG(1_000_000)

  reg  [31:0] in1 = 32'h0, in2 = 32'h0;
  reg  [2:0]  funct3 = 3'b0;
  reg         funct7_5 = 1'b0;
  reg         cmp = 1'b0;
  wire [31:0] out;
  wire        EQ, LT, LTU;

  ALU dut (.in1(in1), .in2(in2), .funct3(funct3), .funct7_5(funct7_5),
           .cmp(cmp), .out(out), .EQ(EQ), .LT(LT), .LTU(LTU));

  // ---- compare reference: force subtract, check the three flags ----
  // Independent of the DUT: EQ/LT/LTU are compared to ==, $signed<, <.
  task check_cmp(input [31:0] a, input [31:0] b);
    begin
      in1 = a; in2 = b; cmp = 1'b1; #1;
      `CHECK_EQ(EQ,  (a == b), "EQ")
      `CHECK_EQ(LT,  ($signed(a) < $signed(b)), "LT")
      `CHECK_EQ(LTU, (a < b), "LTU")
      cmp = 1'b0;
    end
  endtask

  // ---- behavioural reference: one vector, out + the three flags ----
  task check_op(input [31:0] a, input [31:0] b, input [2:0] f3, input f5);
    reg [31:0] eout;
    reg [4:0]  sh;
    begin
      // Compare outputs are defined only while subtracting; validate them in
      // a forced-subtract phase first (same operands, independent reference).
      check_cmp(a, b);
      // Op phase last, so `out` is left settled for any following
      // hand-anchored out check (cmp back to 0 = the op's natural mode).
      in1 = a; in2 = b; funct3 = f3; funct7_5 = f5; cmp = 1'b0;
      sh = b[4:0];
      case (f3)
        3'b000: eout = f5 ? (a - b) : (a + b);
        3'b001: eout = a << sh;
        3'b010: eout = {31'b0, $signed(a) < $signed(b)};
        3'b011: eout = {31'b0, a < b};
        3'b100: eout = a ^ b;
        3'b101: begin
                  eout = a >> sh;                   // SRL
                  if (f5) eout = $signed(a) >>> sh; // SRA — standalone assignment:
                                                    // inside the f5-ternary iverilog
                                                    // applies the unsigned context and
                                                    // silently does a logical shift
                end
        3'b110: eout = a | b;
        3'b111: eout = a & b;
      endcase
      #1;
      `CHECK_EQ(out, eout, "out")
    end
  endtask

  integer errors_before;

  // all ten op variants on one operand pair
  task sweep_pair(input [31:0] a, input [31:0] b);
    begin
      check_op(a, b, 3'b000, 1'b0); // ADD
      check_op(a, b, 3'b000, 1'b1); // SUB
      check_op(a, b, 3'b001, 1'b0); // SLL
      check_op(a, b, 3'b010, 1'b0); // SLT
      check_op(a, b, 3'b011, 1'b0); // SLTU
      check_op(a, b, 3'b100, 1'b0); // XOR
      check_op(a, b, 3'b101, 1'b0); // SRL
      check_op(a, b, 3'b101, 1'b1); // SRA
      check_op(a, b, 3'b110, 1'b0); // OR
      check_op(a, b, 3'b111, 1'b0); // AND
    end
  endtask

  reg [31:0] evals [0:4];
  reg [31:0] ra, rb;
  reg [2:0]  rf3;
  reg        rf5;
  integer    i, j, seed;

  initial begin
    // ---- hand-anchored literals (independent of the reference task) ----
    // ADD: 0x7FFFFFFF + 1 wraps to 0x80000000
    check_op(32'h7FFFFFFF, 32'h00000001, 3'b000, 1'b0);
    `CHECK_EQ(out, 32'h80000000, "hand: 0x7FFFFFFF+1 = 0x80000000")
    // SUB: 0 - 1 = 0xFFFFFFFF
    check_op(32'h00000000, 32'h00000001, 3'b000, 1'b1);
    `CHECK_EQ(out, 32'hFFFFFFFF, "hand: 0-1 = -1")
    // SLL: 1 << 31 = 0x80000000
    check_op(32'h00000001, 32'd31, 3'b001, 1'b0);
    `CHECK_EQ(out, 32'h80000000, "hand: 1<<31")
    // SRA: 0x80000000 >> 31 arithmetically = all ones
    check_op(32'h80000000, 32'd31, 3'b101, 1'b1);
    `CHECK_EQ(out, 32'hFFFFFFFF, "hand: SRA 0x80000000>>31")
    // SRA: 0x80000000 >> 1 = 0xC0000000 (sign fill)
    check_op(32'h80000000, 32'd1, 3'b101, 1'b1);
    `CHECK_EQ(out, 32'hC0000000, "hand: SRA 0x80000000>>1")
    // SRL of the same word: 0x80000000 >> 31 = 1
    check_op(32'h80000000, 32'd31, 3'b101, 1'b0);
    `CHECK_EQ(out, 32'h00000001, "hand: SRL 0x80000000>>31")
    // SLT signed: 0x80000000 < 1 (signed) is true
    check_op(32'h80000000, 32'h00000001, 3'b010, 1'b0);
    `CHECK_EQ(out, 32'h00000001, "hand: SLT min<1")
    // SLTU unsigned: 0x80000000 < 1 is false
    check_op(32'h80000000, 32'h00000001, 3'b011, 1'b0);
    `CHECK_EQ(out, 32'h00000000, "hand: SLTU min<1")
    // flags: equal operands (forced subtract)
    check_cmp(32'h00000005, 32'h00000005);
    // flags: -1 vs 0 — signed less, unsigned greater
    check_cmp(32'hFFFFFFFF, 32'h00000000);

    // ---- edge-value sweep: 0, 1, -1, 0x7FFFFFFF, 0x80000000, all op variants ----
    evals[0] = 32'h00000000;
    evals[1] = 32'h00000001;
    evals[2] = 32'hFFFFFFFF; // -1
    evals[3] = 32'h7FFFFFFF;
    evals[4] = 32'h80000000;
    for (i = 0; i < 5; i = i + 1)
      for (j = 0; j < 5; j = j + 1)
        sweep_pair(evals[i], evals[j]);

    // ---- explicit shift amounts 0/1/2/4/16/31 for SLL/SRL/SRA on every edge value ----
    for (i = 0; i < 5; i = i + 1) begin
      check_op(evals[i], 32'd0,  3'b001, 1'b0);
      check_op(evals[i], 32'd1,  3'b001, 1'b0);
      check_op(evals[i], 32'd2,  3'b001, 1'b0);
      check_op(evals[i], 32'd4,  3'b001, 1'b0);
      check_op(evals[i], 32'd16, 3'b001, 1'b0);
      check_op(evals[i], 32'd31, 3'b001, 1'b0);
      check_op(evals[i], 32'd0,  3'b101, 1'b0);
      check_op(evals[i], 32'd1,  3'b101, 1'b0);
      check_op(evals[i], 32'd2,  3'b101, 1'b0);
      check_op(evals[i], 32'd4,  3'b101, 1'b0);
      check_op(evals[i], 32'd16, 3'b101, 1'b0);
      check_op(evals[i], 32'd31, 3'b101, 1'b0);
      check_op(evals[i], 32'd0,  3'b101, 1'b1);
      check_op(evals[i], 32'd1,  3'b101, 1'b1);
      check_op(evals[i], 32'd2,  3'b101, 1'b1);
      check_op(evals[i], 32'd4,  3'b101, 1'b1);
      check_op(evals[i], 32'd16, 3'b101, 1'b1);
      check_op(evals[i], 32'd31, 3'b101, 1'b1);
    end

    // ---- 256 pseudo-random vectors, fixed seed (deterministic across runs) ----
    seed = 32'h00C0FFEE;
    for (i = 0; i < 256; i = i + 1) begin
      ra  = $random(seed);
      rb  = $random(seed);
      rf3 = $random(seed) & 7;
      rf5 = $random(seed) & 1;
      check_op(ra, rb, rf3, rf5);
    end

    `DONE
  end
endmodule
`default_nettype wire
