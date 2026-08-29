`default_nettype none
// Purely combinational RV32I ALU, resource-shared for the hx1k:
//   * one 33-bit subtractor (aluMinus) produces SUB, EQ, LT and LTU;
//     ADD is the only other adder.
//   * one right-shifter produces SRL/SRA; SLL runs through the same
//     shifter on bit-reversed operands (flip32 is pure wiring, no cells).
//   funct3 000: ADD (funct7_5=0) / SUB (funct7_5=1)
//   funct3 001: SLL          101: SRL (funct7_5=0) / SRA (funct7_5=1)
//   funct3 010: SLT          011: SLTU
//   funct3 100: XOR          110: OR     111: AND
// Shift amount is always in2[4:0]. EQ/LT/LTU compare in1 vs in2 directly
// (for branches); SLT/SLTU reuse them so the two paths cannot disagree.
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
  // Pure wiring: bit reversal, used to turn the right-shifter into a
  // left-shifter (flip, shift right, flip back == shift left).
  function [31:0] flip32;
    input [31:0] x;
    integer k;
    begin
      for (k = 0; k < 32; k = k + 1) flip32[k] = x[31-k];
    end
  endfunction

  wire [4:0] sh = in2[4:0];

  // Shared subtraction: {1'b1,~in2} + {1'b0,in1} + 1 = 2^33 + in1 - in2.
  // Bit 32 is the unsigned borrow (in1 < in2); the low word is in1 - in2.
  wire [32:0] aluMinus = {1'b1, ~in2} + {1'b0, in1} + 33'd1;
  assign EQ  = (aluMinus[31:0] == 32'd0);
  assign LTU = aluMinus[32];
  // Signs equal: signed order == unsigned order. Signs differ: in1 < in2
  // exactly when in1 is the negative one.
  assign LT  = (in1[31] ^ in2[31]) ? in1[31] : aluMinus[32];

  // Shared shifter: right shift with optional sign fill. SLL feeds the
  // bit-reversed operand through and the output mux reverses the result
  // (flip32 is pure wiring, so the reversal costs no mux of its own —
  // the SLL arm simply reads shRight's bits the other way round); its
  // fill bit is forced 0 (SLL never sign-fills, whatever funct7_5 is).
  wire        isSLL   = (funct3 == 3'b001);
  wire [31:0] shOp    = isSLL ? flip32(in1) : in1;
  wire        shFill  = isSLL ? 1'b0 : (funct7_5 & in1[31]);
  wire [31:0] shRight = $signed({shFill, shOp}) >>> sh;

  always @(*) begin
    case (funct3)
      3'b000:  out = funct7_5 ? aluMinus[31:0] : (in1 + in2);
      3'b001:  out = flip32(shRight);
      3'b010:  out = {31'b0, LT};
      3'b011:  out = {31'b0, LTU};
      3'b100:  out = in1 ^ in2;
      3'b101:  out = shRight;
      3'b110:  out = in1 | in2;
      3'b111:  out = in1 & in2;
      default: out = 32'h00000000;
    endcase
  end
endmodule
`default_nettype wire