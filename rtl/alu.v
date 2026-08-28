`default_nettype none
// Purely combinational RV32I ALU.
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
  wire [4:0]  sh  = in2[4:0];
  wire [31:0] sra = $signed(in1) >>> sh;

  always @(*) begin
    case (funct3)
      3'b000:  out = funct7_5 ? (in1 - in2) : (in1 + in2);
      3'b001:  out = in1 << sh;
      3'b010:  out = {31'b0, LT};
      3'b011:  out = {31'b0, LTU};
      3'b100:  out = in1 ^ in2;
      3'b101:  out = funct7_5 ? sra : (in1 >> sh);
      3'b110:  out = in1 | in2;
      3'b111:  out = in1 & in2;
      default: out = 32'h00000000;
    endcase
  end

  assign EQ  = (in1 == in2);
  assign LT  = ($signed(in1) < $signed(in2));
  assign LTU = (in1 < in2);
endmodule
`default_nettype wire
