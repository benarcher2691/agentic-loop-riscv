`default_nettype none
// RV32I instruction decoder: purely combinational, one word in, everything out.
//
// Class flags are one-hot over the 10 base opcode classes (all zero together
// for any other opcode). Register ids and funct fields sit at fixed bit
// positions in every format, so they are extracted unconditionally.
// Immediates, exactly as the spec defines them:
//   Iimm = sx(instr[31:20])                                          (JALR, loads, ALU-imm)
//   Simm = sx(instr[31:25] || instr[11:7])                           (stores)
//   Bimm = sx(instr[31] || instr[7] || instr[30:25] || instr[11:8] || 0) (branches, bit 0 = 0)
//   Uimm = instr[31:12] || 12'b0                                     (LUI, AUIPC)
//   Jimm = sx(instr[31] || instr[19:12] || instr[20] || instr[30:21] || 0) (JAL, bit 0 = 0)
module Decoder (
    input  wire [31:0] instr,
    output wire        isALUreg,   // OP      0110011
    output wire        isALUimm,   // OP-IMM  0010011
    output wire        isBranch,   // BRANCH  1100011
    output wire        isJALR,     // JALR    1100111
    output wire        isJAL,      // JAL     1101111
    output wire        isAUIPC,    // AUIPC   0010111
    output wire        isLUI,      // LUI     0110111
    output wire        isLoad,     // LOAD    0000011
    output wire        isStore,    // STORE   0100011
    output wire        isSYSTEM,   // SYSTEM  1110011
    output wire [4:0]  rs1Id,
    output wire [4:0]  rs2Id,
    output wire [4:0]  rdId,
    output wire [2:0]  funct3,
    output wire [6:0]  funct7,
    output wire [31:0] Iimm,
    output wire [31:0] Simm,
    output wire [31:0] Bimm,
    output wire [31:0] Uimm,
    output wire [31:0] Jimm
);
    wire [6:0] opcode = instr[6:0];

    assign isALUreg  = (opcode == 7'b0110011);
    assign isALUimm  = (opcode == 7'b0010011);
    assign isBranch  = (opcode == 7'b1100011);
    assign isJALR    = (opcode == 7'b1100111);
    assign isJAL     = (opcode == 7'b1101111);
    assign isAUIPC   = (opcode == 7'b0010111);
    assign isLUI     = (opcode == 7'b0110111);
    assign isLoad    = (opcode == 7'b0000011);
    assign isStore   = (opcode == 7'b0100011);
    assign isSYSTEM  = (opcode == 7'b1110011);

    assign rs1Id  = instr[19:15];
    assign rs2Id  = instr[24:20];
    assign rdId   = instr[11:7];
    assign funct3 = instr[14:12];
    assign funct7 = instr[31:25];

    assign Iimm = {{20{instr[31]}}, instr[31:20]};
    assign Simm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    assign Bimm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
    assign Uimm = {instr[31:12], 12'b0};
    assign Jimm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
endmodule
`default_nettype wire
