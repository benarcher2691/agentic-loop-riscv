`default_nettype none
// Purely combinational RV32I ALU, resource-shared for the hx1k (434 LUT4):
//   * one 33-bit subtractor (aluMinus) produces SUB, EQ, LT and LTU; ADD is
//     the only other adder. EQ/LT/LTU compare in1 vs in2 on EVERY vector
//     (tb/alu_tb.v checks them for all funct3/funct7_5 combinations), so the
//     always-on compare subtractor can never be merged into the ADD/SUB
//     adder — two adders are a hard floor.
//   * one LEFT-shifter produces SLL directly; SRL/SRA feed the bit-reversed
//     operand through the same shifter and reverse the result (flip32 is
//     pure wiring, no cells). The reversal mux is selected by funct3[2]:
//     SLL (001) and SRL/SRA (101) differ only in that bit and every other
//     encoding is a don't-care for the shifter, so no isSLL decoder is
//     needed. The left-shift fill lands in the low bits; after the output
//     reversal those are the high bits of the SRL/SRA result, so the fill
//     bit is simply the sign in1[31] gated by funct7_5 (SRA).
//   * the output mux is split on funct3[2] into two full 4-arm cases on
//     funct3[1:0] (no defaults, no nested ternaries) plus one final 2:1.
//     abc maps this ~50 LUT4 better than a single 8-arm case (funct3),
//     which leaves the three logic ops at ~1 LUT4 per bit.
//   funct3 000: ADD (funct7_5=0) / SUB (funct7_5=1)
//   funct3 001: SLL          101: SRL (funct7_5=0) / SRA (funct7_5=1)
//   funct3 010: SLT          011: SLTU
//   funct3 100: XOR          110: OR     111: AND
// Shift amount is always in2[4:0]. SLT/SLTU reuse LT/LTU so the two paths
// cannot disagree.
module ALU (
  input  wire [31:0] in1,
  input  wire [31:0] in2,
  input  wire [2:0]  funct3,
  input  wire        funct7_5,
  output reg  [31:0] out,
  output wire        EQ,
  output wire        LT,
  output wire        LTU
);
  // Pure wiring: bit reversal, used to turn the left-shifter into a
  // right-shifter (reverse, shift left, reverse back == shift right).
  function [31:0] flip32;
    input [31:0] x;
    integer k;
    begin
      for (k = 0; k < 32; k = k + 1) flip32[k] = x[31-k];
    end
  endfunction

  wire [4:0] sh = in2[4:0];

  // Shared subtraction: {1'b0,in1} - {1'b0,in2} = in1 - in2 in 33 bits.
  // Bit 32 is the unsigned borrow (in1 < in2); the low word is in1 - in2.
  wire [32:0] aluMinus = {1'b0, in1} - {1'b0, in2};
  assign EQ  = (aluMinus[31:0] == 32'd0);
  assign LTU = aluMinus[32];
  // Signs equal: signed order == unsigned order. Signs differ: in1 < in2
  // exactly when in1 is the negative one.
  assign LT  = (in1[31] ^ in2[31]) ? in1[31] : aluMinus[32];
  wire [31:0] addOut = in1 + in2;
  wire [31:0] addSub = funct7_5 ? aluMinus[31:0] : addOut;

  // Shared shifter: five log-shift stages of 2:1 muxes, shifting LEFT by
  // sh[k] at stage k, fill bits entering from the bottom. SLL shifts in1
  // itself; SRL/SRA shift bit-reversed in1 (mux selected by funct3[2]).
  wire [31:0] shIn = funct3[2] ? flip32(in1) : in1;
  wire        fill = funct3[2] & funct7_5 & in1[31];
  wire [31:0] s0 = sh[0] ? {shIn[30:0], fill} : shIn;
  wire [31:0] s1 = sh[1] ? {s0[29:0], fill, fill} : s0;
  wire [31:0] s2 = sh[2] ? {s1[27:0], fill, fill, fill, fill} : s1;
  wire [31:0] s3 = sh[3] ? {s2[23:0], fill, fill, fill, fill, fill, fill, fill, fill} : s2;
  wire [31:0] s4 = sh[4] ? {s3[15:0], fill, fill, fill, fill, fill, fill, fill, fill,
                            fill, fill, fill, fill, fill, fill, fill, fill} : s3;
  wire [31:0] shLeft    = s4;             // SLL result (in1 << sh)
  wire [31:0] shLeftRev = flip32(s4);     // SRL/SRA result (in1 >> sh)

  // Output select, split on funct3[2]: the data half (f3[2]=0) is
  // ADD/SUB, SLL, SLT, SLTU; the logic half (f3[2]=1) is XOR, SRL/SRA,
  // OR, AND. Both inner cases are full 4-way selects on funct3[1:0].
  reg [31:0] dataOut, logicOut;
  always @(*) begin
    case (funct3[1:0])
      2'b00: dataOut = addSub;              // ADD/SUB (f3=000)
      2'b01: dataOut = shLeft;              // SLL     (f3=001)
      2'b10: dataOut = {31'b0, LT};         // SLT     (f3=010)
      2'b11: dataOut = {31'b0, LTU};        // SLTU    (f3=011)
    endcase
  end
  always @(*) begin
    case (funct3[1:0])
      2'b00: logicOut = in1 ^ in2;          // XOR     (f3=100)
      2'b01: logicOut = shLeftRev;          // SRL/SRA (f3=101)
      2'b10: logicOut = in1 | in2;          // OR      (f3=110)
      2'b11: logicOut = in1 & in2;          // AND     (f3=111)
    endcase
  end
  always @(*) out = funct3[2] ? logicOut : dataOut;
endmodule
`default_nettype wire
