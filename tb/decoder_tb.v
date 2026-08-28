`timescale 1ns/1ps
`default_nettype none
// Decoder parts 1+2+3: opcode classes, register/funct fields, and immediates.
// Hand-encoded instructions covering every RV32I opcode class. Every vector
// checks all ten class flags (exactly one high), rs1/rs2/rd/funct3/funct7,
// and ALL FIVE immediate outputs.
// Note the field overlaps: in I/S/B/U/J formats the rs2/rd/funct7 fields sit
// where immediate bits live, so their "expected" values here are the raw
// instruction bits at those positions, worked out by hand per vector.
// Immediates: the five expected values per vector are the spec formulas
//   Iimm = sx(instr[31:20])    Simm = sx({instr[31:25], instr[11:7]})
//   Bimm = sx({instr[31], instr[7], instr[30:25], instr[11:8], 1'b0})
//   Uimm = {instr[31:12], 12'b0}
//   Jimm = sx({instr[31], instr[19:12], instr[20], instr[30:21], 1'b0})
// applied to the hand-encoded word. An immediate that does not fit the
// word's format still has that defined raw-bit value, so it is checked too;
// each comment calls out the value that is meaningful for the instruction.
module decoder_tb;
  `include "check.vh"
  `WATCHDOG(100_000)

  reg  [31:0] instr = 32'h00000000;
  wire        isALUreg, isALUimm, isBranch, isJALR, isJAL;
  wire        isAUIPC, isLUI, isLoad, isStore, isSYSTEM;
  wire [4:0]  rs1Id, rs2Id, rdId;
  wire [2:0]  funct3;
  wire [6:0]  funct7;
  wire [31:0] Iimm, Simm, Bimm, Uimm, Jimm;

  Decoder dut (.instr(instr), .isALUreg(isALUreg), .isALUimm(isALUimm),
               .isBranch(isBranch), .isJALR(isJALR), .isJAL(isJAL),
               .isAUIPC(isAUIPC), .isLUI(isLUI), .isLoad(isLoad),
               .isStore(isStore), .isSYSTEM(isSYSTEM),
               .rs1Id(rs1Id), .rs2Id(rs2Id), .rdId(rdId),
               .funct3(funct3), .funct7(funct7),
               .Iimm(Iimm), .Simm(Simm), .Bimm(Bimm), .Uimm(Uimm), .Jimm(Jimm));

  // ---- Assembler cross-check (decoder part 3) ----
  // One word per class is built with the lib/riscv_assembly.v encoder tasks
  // (spec packing), then fed through the Decoder: it must recover the fields
  // and immediates that were passed in. MEM is required by the lib include.
  reg [31:0] MEM [0:15];
  `include "riscv_assembly.v"

  // Drive one word, then check the one-hot class flags (exactly flag `c` is
  // high, c = 0..9 in the order below), the register ids, the funct fields,
  // and all five immediates (eI/eS/eB/eU/eJ).
  task check_vec(input [31:0] w, input integer c,
                 input [4:0] ers1, input [4:0] ers2, input [4:0] erd,
                 input [2:0] ef3, input [6:0] ef7,
                 input [31:0] eI, input [31:0] eS, input [31:0] eB,
                 input [31:0] eU, input [31:0] eJ);
    begin
      instr = w;
      #1;
      `CHECK_EQ(isALUreg,  (c == 0), "class flag isALUreg")
      `CHECK_EQ(isALUimm,  (c == 1), "class flag isALUimm")
      `CHECK_EQ(isBranch,  (c == 2), "class flag isBranch")
      `CHECK_EQ(isJALR,    (c == 3), "class flag isJALR")
      `CHECK_EQ(isJAL,     (c == 4), "class flag isJAL")
      `CHECK_EQ(isAUIPC,   (c == 5), "class flag isAUIPC")
      `CHECK_EQ(isLUI,     (c == 6), "class flag isLUI")
      `CHECK_EQ(isLoad,    (c == 7), "class flag isLoad")
      `CHECK_EQ(isStore,   (c == 8), "class flag isStore")
      `CHECK_EQ(isSYSTEM,  (c == 9), "class flag isSYSTEM")
      `CHECK_EQ(rs1Id, ers1, "rs1 field")
      `CHECK_EQ(rs2Id, ers2, "rs2 field")
      `CHECK_EQ(rdId,  erd,  "rd field")
      `CHECK_EQ(funct3, ef3, "funct3 field")
      `CHECK_EQ(funct7, ef7, "funct7 field")
      `CHECK_EQ(Iimm, eI, "Iimm")
      `CHECK_EQ(Simm, eS, "Simm")
      `CHECK_EQ(Bimm, eB, "Bimm")
      `CHECK_EQ(Uimm, eU, "Uimm")
      `CHECK_EQ(Jimm, eJ, "Jimm")
    end
  endtask

  initial begin
    // R-type: add x3,x1,x2 = 0000000_00010_00001_000_00011_0110011
    check_vec(32'h002081B3, 0, 5'd1, 5'd2, 5'd3, 3'b000, 7'b0000000,
              32'h00000002, 32'h00000003, 32'h00000802, 32'h00208000, 32'h00008002);

    // I-type ALU-imm, positive: addi x1,x0,5 -> Iimm = 5.
    // rs2 field overlaps imm[4:0] = 5.
    check_vec(32'h00500093, 1, 5'd0, 5'd5, 5'd1, 3'b000, 7'b0000000,
              32'h00000005, 32'h00000001, 32'h00000800, 32'h00500000, 32'h00000804);

    // I-type ALU-imm, negative: addi x1,x0,-1 -> Iimm = 32'hFFFFFFFF (-1).
    // rs2 = imm[4:0] = 31, funct7 = imm[11:5] = 127.
    check_vec(32'hFFF00093, 1, 5'd0, 5'd31, 5'd1, 3'b000, 7'b1111111,
              32'hFFFFFFFF, 32'hFFFFFFE1, 32'hFFFFFFE0, 32'hFFF00000, 32'hFFF00FFE);

    // LOAD, positive offset: lw x2,4(x1) -> Iimm = 4.
    // rs2 field overlaps imm[4:0] = 4.
    check_vec(32'h0040A103, 7, 5'd1, 5'd4, 5'd2, 3'b010, 7'b0000000,
              32'h00000004, 32'h00000002, 32'h00000002, 32'h0040A000, 32'h0000A004);

    // LOAD, negative offset: lw x3,-8(x2) -> Iimm = 32'hFFFFFFF8 (-8).
    // rs2 = imm[4:0] = 24, funct7 = imm[11:5] = 127.
    check_vec(32'hFF812183, 7, 5'd2, 5'd24, 5'd3, 3'b010, 7'b1111111,
              32'hFFFFFFF8, 32'hFFFFFFE3, 32'hFFFFFFE2, 32'hFF812000, 32'hFFF127F8);

    // STORE, negative offset: sw x2,-4(x1) -> Simm = 32'hFFFFFFFC (-4).
    // rd field overlaps imm[4:0] = 11100 = 28; funct7 overlaps imm[11:5].
    check_vec(32'hFE20AE23, 8, 5'd1, 5'd2, 5'd28, 3'b010, 7'b1111111,
              32'hFFFFFFE2, 32'hFFFFFFFC, 32'hFFFFF7FC, 32'hFE20A000, 32'hFFF0A7E2);

    // STORE, positive offset: sw x2,16(x1) -> Simm = 16.
    // rd field overlaps imm[4:0] = 10000 = 16.
    check_vec(32'h0020A823, 8, 5'd1, 5'd2, 5'd16, 3'b010, 7'b0000000,
              32'h00000002, 32'h00000010, 32'h00000010, 32'h0020A000, 32'h0000A002);

    // BRANCH: beq x1,x2,8 -> Bimm = 8.
    // rd field overlaps imm[4:1|11] = 01000 = 8.
    check_vec(32'h00208463, 2, 5'd1, 5'd2, 5'd8, 3'b000, 7'b0000000,
              32'h00000002, 32'h00000008, 32'h00000008, 32'h00208000, 32'h00008002);

    // BRANCH forward bne: bne x1,x2,16 -> Bimm = 16.
    // rd field overlaps imm[4:1|11] = 10000 = 16.
    check_vec(32'h00209863, 2, 5'd1, 5'd2, 5'd16, 3'b001, 7'b0000000,
              32'h00000002, 32'h00000010, 32'h00000010, 32'h00209000, 32'h00009002);

    // BRANCH backward bne: bne x1,x2,-8 -> Bimm = 32'hFFFFFFF8 (-8).
    // imm[12]=imm[11]=1, imm[10:5]=111111, imm[4:1]=1100 -> rd field = 11001 = 25.
    check_vec(32'hFE209CE3, 2, 5'd1, 5'd2, 5'd25, 3'b001, 7'b1111111,
              32'hFFFFFFE2, 32'hFFFFFFF9, 32'hFFFFFFF8, 32'hFE209000, 32'hFFF097E2);

    // BRANCH backward beq: beq x1,x2,-8 -> Bimm = 32'hFFFFFFF8 (-8).
    check_vec(32'hFE208CE3, 2, 5'd1, 5'd2, 5'd25, 3'b000, 7'b1111111,
              32'hFFFFFFE2, 32'hFFFFFFF9, 32'hFFFFFFF8, 32'hFE208000, 32'hFFF087E2);

    // JALR: jalr x5,x6,64 -> Iimm = 64.
    // rs2 = imm[4:0] = 0, funct7 = imm[11:5] = 0000010 = 2.
    check_vec(32'h040302E7, 3, 5'd6, 5'd0, 5'd5, 3'b000, 7'b0000010,
              32'h00000040, 32'h00000045, 32'h00000844, 32'h04030000, 32'h00030040);

    // JAL: jal x1,16 -> Jimm = 16.
    // rs1 = 0; rs2 overlaps imm bits = 10000 = 16; funct7 = imm[19:12] high bit = 0.
    check_vec(32'h010000EF, 4, 5'd0, 5'd16, 5'd1, 3'b000, 7'b0000000,
              32'h00000010, 32'h00000001, 32'h00000800, 32'h01000000, 32'h00000010);

    // JAL backward: jal x0,-8 -> Jimm = 32'hFFFFFFF8 (-8).
    // imm[20]=imm[11]=1, imm[10:1]=1111111100, imm[19:12]=11111111.
    check_vec(32'hFF9FF06F, 4, 5'd31, 5'd25, 5'd0, 3'b111, 7'b1111111,
              32'hFFFFFFF9, 32'hFFFFFFE0, 32'hFFFFF7E0, 32'hFF9FF000, 32'hFFFFFFF8);

    // JAL edge: jal x1,4094 -> Jimm = 32'h00000FFE. imm[11]=1 but imm[20]=0:
    // a decoder that swaps these two J-imm bits would sign-extend wrongly.
    check_vec(32'h7FF000EF, 4, 5'd0, 5'd31, 5'd1, 3'b000, 7'b0111111,
              32'h000007FF, 32'h000007E1, 32'h00000FE0, 32'h7FF00000, 32'h00000FFE);

    // AUIPC: auipc x5,0x12345 -> Uimm = 0x12345000.
    // U-type: rs1/rs2/funct3/funct7 are raw immediate bits, not registers.
    check_vec(32'h12345297, 5, 5'd8, 5'd3, 5'd5, 3'b101, 7'b0001001,
              32'h00000123, 32'h00000125, 32'h00000924, 32'h12345000, 32'h00045922);

    // LUI, bit 31 clear: lui x5,0x12345 -> Uimm = 0x12345000.
    check_vec(32'h123452B7, 6, 5'd8, 5'd3, 5'd5, 3'b101, 7'b0001001,
              32'h00000123, 32'h00000125, 32'h00000924, 32'h12345000, 32'h00045922);

    // LUI, bit 31 set: lui x5,0xFFFFF -> Uimm = 0xFFFFF000.
    // Immediate bits all ones: rs1 = rs2 = 31, funct3 = 7, funct7 = 127.
    check_vec(32'hFFFFF2B7, 6, 5'd31, 5'd31, 5'd5, 3'b111, 7'b1111111,
              32'hFFFFFFFF, 32'hFFFFFFE5, 32'hFFFFFFE4, 32'hFFFFF000, 32'hFFFFFFFE);

    // SYSTEM: ebreak = 000000000001_00000_000_00000_1110011
    // rs2 field overlaps the imm12 low bits = 1.
    check_vec(32'h00100073, 9, 5'd0, 5'd1, 5'd0, 3'b000, 7'b0000000,
              32'h00000001, 32'h00000000, 32'h00000000, 32'h00100000, 32'h00000800);

    // ---- Assembler round trip: build with the lib, decode, compare ----
    // First tie each generated word to the independently hand-encoded word
    // used above (same instruction), then run the full check_vec on it.
    memPC = 0;
    RType (7'b0110011, 5'd3, 5'd1, 5'd2, 3'b000, 7'b0000000);  // add  x3,x1,x2
    IType (7'b0010011, 5'd1, 5'd0, 32'hFFFFFFFF, 3'b000);      // addi x1,x0,-1
    SType (7'b0100011, 5'd1, 5'd2, 32'hFFFFFFFC, 3'b010);      // sw   x2,-4(x1)
    BType (7'b1100011, 5'd1, 5'd2, 32'hFFFFFFF8, 3'b001);      // bne  x1,x2,-8
    UType (7'b0110111, 5'd5, 32'hFFFFF000);                    // lui  x5,0xFFFFF
    JType (7'b1101111, 5'd0, 32'hFFFFFFF8);                    // jal  x0,-8
    `CHECK_EQ(MEM[0], 32'h002081B3, "asm RType add x3,x1,x2")
    `CHECK_EQ(MEM[1], 32'hFFF00093, "asm IType addi x1,x0,-1")
    `CHECK_EQ(MEM[2], 32'hFE20AE23, "asm SType sw x2,-4(x1)")
    `CHECK_EQ(MEM[3], 32'hFE209CE3, "asm BType bne x1,x2,-8")
    `CHECK_EQ(MEM[4], 32'hFFFFF2B7, "asm UType lui x5,0xFFFFF")
    `CHECK_EQ(MEM[5], 32'hFF9FF06F, "asm JType jal x0,-8")
    check_vec(MEM[0], 0, 5'd1,  5'd2,  5'd3,  3'b000, 7'b0000000,
              32'h00000002, 32'h00000003, 32'h00000802, 32'h00208000, 32'h00008002);
    check_vec(MEM[1], 1, 5'd0,  5'd31, 5'd1,  3'b000, 7'b1111111,
              32'hFFFFFFFF, 32'hFFFFFFE1, 32'hFFFFFFE0, 32'hFFF00000, 32'hFFF00FFE);
    check_vec(MEM[2], 8, 5'd1,  5'd2,  5'd28, 3'b010, 7'b1111111,
              32'hFFFFFFE2, 32'hFFFFFFFC, 32'hFFFFF7FC, 32'hFE20A000, 32'hFFF0A7E2);
    check_vec(MEM[3], 2, 5'd1,  5'd2,  5'd25, 3'b001, 7'b1111111,
              32'hFFFFFFE2, 32'hFFFFFFF9, 32'hFFFFFFF8, 32'hFE209000, 32'hFFF097E2);
    check_vec(MEM[4], 6, 5'd31, 5'd31, 5'd5,  3'b111, 7'b1111111,
              32'hFFFFFFFF, 32'hFFFFFFE5, 32'hFFFFFFE4, 32'hFFFFF000, 32'hFFFFFFFE);
    check_vec(MEM[5], 4, 5'd31, 5'd25, 5'd0,  3'b111, 7'b1111111,
              32'hFFFFFFF9, 32'hFFFFFFE0, 32'hFFFFF7E0, 32'hFF9FF000, 32'hFFFFFFF8);

    // Not a class: opcode 1111111 must light no flag at all.
    instr = 32'hFFFFFFFF; #1;
    `CHECK(!isALUreg && !isALUimm && !isBranch && !isJALR && !isJAL &&
           !isAUIPC && !isLUI && !isLoad && !isStore && !isSYSTEM,
           "opcode 1111111 asserts no class flag")

    `DONE
  end
endmodule
`default_nettype wire
