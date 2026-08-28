`timescale 1ns/1ps
`default_nettype none
// Decoder part 1: opcode classes and register/funct fields.
// Hand-encoded instructions, one per RV32I opcode class. Every vector checks
// all ten class flags (exactly one high) and rs1/rs2/rd/funct3/funct7.
// Note the field overlaps: in I/S/B/U/J formats the rs2/rd/funct7 fields sit
// where immediate bits live, so their "expected" values here are the raw
// instruction bits at those positions, worked out by hand per vector.
// Immediates get their own checks in parts 2 and 3.
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

  // Drive one word, then check the one-hot class flags (exactly flag `c` is
  // high, c = 0..9 in the order below), the register ids and funct fields.
  task check_vec(input [31:0] w, input integer c,
                 input [4:0] ers1, input [4:0] ers2, input [4:0] erd,
                 input [2:0] ef3, input [6:0] ef7);
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
    end
  endtask

  initial begin
    // R-type: add x3,x1,x2 = 0000000_00010_00001_000_00011_0110011
    check_vec(32'h002081B3, 0, 5'd1, 5'd2, 5'd3, 3'b000, 7'b0000000);

    // I-type: addi x1,x0,5 = 000000000101_00000_000_00001_0010011
    // rs2 field overlaps imm[4:0] = 5.
    check_vec(32'h00500093, 1, 5'd0, 5'd5, 5'd1, 3'b000, 7'b0000000);

    // LOAD: lw x2,4(x1) = 000000000100_00001_010_00010_0000011
    // rs2 field overlaps imm[4:0] = 4.
    check_vec(32'h0040A103, 7, 5'd1, 5'd4, 5'd2, 3'b010, 7'b0000000);

    // STORE: sw x2,-4(x1) = 1111111_00010_00001_010_11100_0100011
    // rd field overlaps imm[4:0] = 11100 = 28; funct7 overlaps imm[11:5].
    check_vec(32'hFE20AE23, 8, 5'd1, 5'd2, 5'd28, 3'b010, 7'b1111111);

    // BRANCH: beq x1,x2,8 = 0000000_00010_00001_000_01000_1100011
    // rd field overlaps imm[4:1|11] = 01000 = 8.
    check_vec(32'h00208463, 2, 5'd1, 5'd2, 5'd8, 3'b000, 7'b0000000);

    // JALR: jalr x5,x6,64 = 000001000000_00110_000_00101_1100111
    // rs2 = imm[4:0] = 0, funct7 = imm[11:5] = 0000010 = 2.
    check_vec(32'h040302E7, 3, 5'd6, 5'd0, 5'd5, 3'b000, 7'b0000010);

    // JAL: jal x1,16 = 0_0000001000_0_00000000_00001_1101111
    // rs1 = 0; rs2 overlaps imm bits = 10000 = 16; funct7 = imm[19:12] high bit = 0.
    check_vec(32'h010000EF, 4, 5'd0, 5'd16, 5'd1, 3'b000, 7'b0000000);

    // AUIPC: auipc x5,0x12345 = 0x12345<<12 | 5<<7 | 0010111 = 0x12345297
    // U-type: rs1/rs2/funct3/funct7 are raw immediate bits, not registers.
    check_vec(32'h12345297, 5, 5'd8, 5'd3, 5'd5, 3'b101, 7'b0001001);

    // LUI: lui x5,0xFFFFF = 0xFFFFF<<12 | 5<<7 | 0110111 = 0xFFFFF2B7
    // Immediate bits all ones: rs1 = rs2 = 31, funct3 = 7, funct7 = 127.
    check_vec(32'hFFFFF2B7, 6, 5'd31, 5'd31, 5'd5, 3'b111, 7'b1111111);

    // SYSTEM: ebreak = 000000000001_00000_000_00000_1110011
    // rs2 field overlaps the imm12 low bits = 1.
    check_vec(32'h00100073, 9, 5'd0, 5'd1, 5'd0, 3'b000, 7'b0000000);

    // Not a class: opcode 1111111 must light no flag at all.
    instr = 32'hFFFFFFFF; #1;
    `CHECK(!isALUreg && !isALUimm && !isBranch && !isJALR && !isJAL &&
           !isAUIPC && !isLUI && !isLoad && !isStore && !isSYSTEM,
           "opcode 1111111 asserts no class flag")

    `DONE
  end
endmodule
`default_nettype wire
