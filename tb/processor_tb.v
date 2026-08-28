`timescale 1ns/1ps
`default_nettype none
// Processor part 2: all register-register and register-immediate ALU
// instructions. Part 1's per-cycle fetch walk (strobe/address/PC) is kept
// for the first nine instructions; the rest of the program free-runs until
// the EBREAK halt. Every ALU-reg and ALU-imm op appears at least once with
// a hand-computed result, including the task's edge cases: SRAI of a
// negative value, SLTIU with -1 (unsigned compare), SUB producing a negative
// result, SLLI by 31, shift amount taken from bits [4:0] (shift by 33), and
// ADDI with immediate bit 30 set (must NOT turn into SUB). The program is
// built with the assembler macros and cross-checked word by word against
// hand-assembled hex derived from the spec formulas.
module processor_tb;
  `include "check.vh"
  `WATCHDOG(100_000)

  reg clk = 0;
  reg resetn = 0;
  always #5 clk = ~clk;   // fast sim clock; the CPU is purely synchronous

  wire [31:0] mem_addr;
  wire        mem_rstrb;
  wire [31:0] x1_out;   // not "x1": the assembler lib localparams x0..x31

  // Bench memory model, same contract as rtl/Memory: synchronous read of
  // MEM[addr[9:2]] on the clock edge while the strobe is high.
  reg [31:0] MEM [0:255];
  reg [31:0] mem_rdata;
  always @(posedge clk) if (mem_rstrb) mem_rdata <= MEM[mem_addr[9:2]];

  Processor dut (.clk(clk), .resetn(resetn), .mem_addr(mem_addr),
                 .mem_rdata(mem_rdata), .mem_rstrb(mem_rstrb), .x1(x1_out));

  // Program (word index = address/4), x1=5 and x2=12 are the operands:
  //    0: ADDI (x1,  x0,    5)  x1  = 5
  //    1: ADDI (x2,  x1,    7)  x2  = 12
  //    2: ADDI (x3,  x2,   -3)  x3  = 9     (negative immediate)
  //    3: ADDI (x0,  x0,    5)  x0 stays 0
  //    4: ADD  (x4,  x1,  x2)   x4  = 17
  //    5: SUB  (x5,  x1,  x2)   x5  = -7    (negative result)
  //    6: SLL  (x6,  x1,  x2)   x6  = 5<<12 = 0x5000
  //    7: SLT  (x7,  x5,  x1)   x7  = 1     (-7 < 5 signed)
  //    8: SLTU (x8,  x5,  x1)   x8  = 0     (0xFFFFFFF9 < 5 unsigned is false)
  //    9: XOR  (x9,  x1,  x2)   x9  = 9
  //   10: SRL  (x10, x2,  x1)   x10 = 12>>5 = 0
  //   11: SRA  (x11, x5,  x1)   x11 = -7>>>5 = -1
  //   12: OR   (x12, x1,  x2)   x12 = 13
  //   13: AND  (x13, x1,  x2)   x13 = 4
  //   14: ADDI (x14, x0, 1024)  x14 = 1024  (imm[30]=1: no SUBI!)
  //   15: SLLI (x15, x1,   31)  x15 = 0xA0000000
  //   16: SRLI (x16, x5,    4)  x16 = 0x0FFFFFFF
  //   17: SRAI (x17, x5,    4)  x17 = 0xFFFFFFFF
  //   18: SLTI (x18, x5,    0)  x18 = 1
  //   19: SLTIU(x19, x5,   -1)  x19 = 1     (0xFFFFFFF9 < 0xFFFFFFFF unsigned)
  //   20: XORI (x20, x1,   -1)  x20 = 0xFFFFFFFA
  //   21: ORI  (x21, x1,    8)  x21 = 13
  //   22: ANDI (x22, x1,    6)  x22 = 4
  //   23: ADDI (x23, x0,   33)  x23 = 33
  //   24: SRL  (x24, x1,  x23)  x24 = 5>>(33&31) = 5>>1 = 2
  //   25: LUI  (x25, 0x12345)   still a NOP in part 2: x25 stays 0
  //   26: EBREAK()              halt, PC frozen at 104
  `include "riscv_assembly.v"
  initial begin
    ADDI(x1, x0, 5);
    ADDI(x2, x1, 7);
    ADDI(x3, x2, -3);
    ADDI(x0, x0, 5);
    ADD(x4, x1, x2);
    SUB(x5, x1, x2);
    SLL(x6, x1, x2);
    SLT(x7, x5, x1);
    SLTU(x8, x5, x1);
    XOR(x9, x1, x2);
    SRL(x10, x2, x1);
    SRA(x11, x5, x1);
    OR(x12, x1, x2);
    AND(x13, x1, x2);
    ADDI(x14, x0, 1024);
    SLLI(x15, x1, 31);
    SRLI(x16, x5, 4);
    SRAI(x17, x5, 4);
    SLTI(x18, x5, 0);
    SLTIU(x19, x5, -1);
    XORI(x20, x1, -1);
    ORI(x21, x1, 8);
    ANDI(x22, x1, 6);
    ADDI(x23, x0, 33);
    SRL(x24, x1, x23);
    LUI(x25, 32'h12345000);  // lib LUI takes the final rd value -> lui x25,0x12345
    EBREAK();
    endASM();
  end

  // Hand-assembled words the macros must produce (spec formulas: R-type
  // f7|rs2|rs1|f3|rd|0x33, I-type imm|rs1|f3|rd|0x13, shifts imm={f7,shamt}).
  function [31:0] expWord(input integer w);
    case (w)
      0: expWord = 32'h00500093;  // addi x1,x0,5
      1: expWord = 32'h00708113;  // addi x2,x1,7
      2: expWord = 32'hFFD10193;  // addi x3,x2,-3
      3: expWord = 32'h00500013;  // addi x0,x0,5
      4: expWord = 32'h00208233;  // add  x4,x1,x2
      5: expWord = 32'h402082B3;  // sub  x5,x1,x2
      6: expWord = 32'h00209333;  // sll  x6,x1,x2
      7: expWord = 32'h0012A3B3;  // slt  x7,x5,x1
      8: expWord = 32'h0012B433;  // sltu x8,x5,x1
      9: expWord = 32'h0020C4B3;  // xor  x9,x1,x2
      10: expWord = 32'h00115533; // srl  x10,x2,x1
      11: expWord = 32'h4012D5B3; // sra  x11,x5,x1
      12: expWord = 32'h0020E633; // or   x12,x1,x2
      13: expWord = 32'h0020F6B3; // and  x13,x1,x2
      14: expWord = 32'h40000713; // addi x14,x0,1024
      15: expWord = 32'h01F09793; // slli x15,x1,31
      16: expWord = 32'h0042D813; // srli x16,x5,4
      17: expWord = 32'h4042D893; // srai x17,x5,4 (funct7 0100000)
      18: expWord = 32'h0002A913; // slti x18,x5,0
      19: expWord = 32'hFFF2B993; // sltiu x19,x5,-1
      20: expWord = 32'hFFF0CA13; // xori x20,x1,-1
      21: expWord = 32'h0080EA93; // ori  x21,x1,8
      22: expWord = 32'h0060FB13; // andi x22,x1,6
      23: expWord = 32'h02100B93; // addi x23,x0,33
      24: expWord = 32'h0170DC33; // srl  x24,x1,x23
      25: expWord = 32'h12345CB7; // lui  x25,0x12345
      26: expWord = 32'h00100073; // ebreak
      default: expWord = 32'h00000013;
    endcase
  endfunction

  integer i, w;
  reg [31:0] pc0;
  reg [1:0]  state0;

  initial begin
    // Reset: PC held at 0, fetch strobe already presenting word 0.
    repeat (3) begin
      @(posedge clk); #1;
      `CHECK_EQ(dut.PC, 32'd0, "PC held at 0 during reset")
    end
    `CHECK_EQ(mem_rstrb, 1'b1, "strobe high while reset holds the FSM in FETCH_INSTR")
    `CHECK_EQ(mem_addr, 32'd0, "fetch address is PC = 0")
    resetn = 1;

    // Walk the first nine instructions, three cycles each, checking the
    // fetch strobe and the PC every step of the way.
    for (i = 0; i < 9; i = i + 1) begin
      `CHECK_EQ(mem_rstrb, 1'b1, "FETCH_INSTR: strobe high")
      `CHECK_EQ(mem_addr,  4*i,  "FETCH_INSTR: address = PC")
      @(posedge clk); #1;                       // -> FETCH_REGS
      `CHECK_EQ(mem_rstrb, 1'b0, "FETCH_REGS: strobe low")
      @(posedge clk); #1;                       // -> EXECUTE
      `CHECK_EQ(mem_rstrb, 1'b0, "EXECUTE: strobe low")
      `CHECK_EQ(dut.PC, 4*i, "PC still at the instruction during EXECUTE")
      @(posedge clk); #1;                       // write back, PC + 4
      `CHECK_EQ(dut.PC, 4*(i+1), "PC advanced by 4 out of EXECUTE")
    end

    // Free-run the remaining instructions (words 9..26, 3 cycles each) into
    // the EBREAK halt at word 26.
    repeat (60) @(posedge clk);
    #1;
    `CHECK_EQ(mem_rstrb, 1'b0, "no fetch strobe while halted")
    `CHECK_EQ(dut.PC, 32'd104, "halted at the EBREAK address 26*4")
    `CHECK_EQ(dut.state, 2'd2, "halted in EXECUTE")

    pc0    = dut.PC;
    state0 = dut.state;
    repeat (5) begin
      @(posedge clk); #1;
      `CHECK_EQ(dut.PC, pc0, "PC frozen after EBREAK")
      `CHECK_EQ(dut.state, state0, "state stays put after EBREAK")
      `CHECK_EQ(mem_rstrb, 1'b0, "no fetch strobe while halted")
    end

    // Register file results, by hierarchical reference. Expected values are
    // hand-computed from x1 = 5, x2 = 12, x5 = -7 = 0xFFFFFFF9.
    `CHECK_EQ(dut.RegisterBank[0],  32'd0,          "x0 still 0 after ADDI x0,x0,5")
    `CHECK_EQ(dut.RegisterBank[1],  32'd5,          "x1 = 5")
    `CHECK_EQ(dut.RegisterBank[2],  32'd12,         "x2 = 5 + 7 = 12")
    `CHECK_EQ(dut.RegisterBank[3],  32'd9,          "x3 = 12 - 3 = 9 (negative imm)")
    `CHECK_EQ(dut.RegisterBank[4],  32'd17,         "ADD: 5 + 12 = 17")
    `CHECK_EQ(dut.RegisterBank[5],  32'hFFFFFFF9,   "SUB: 5 - 12 = -7")
    `CHECK_EQ(dut.RegisterBank[6],  32'h00005000,   "SLL: 5 << 12 = 0x5000")
    `CHECK_EQ(dut.RegisterBank[7],  32'd1,          "SLT: -7 < 5 signed")
    `CHECK_EQ(dut.RegisterBank[8],  32'd0,          "SLTU: 0xFFFFFFF9 < 5 unsigned false")
    `CHECK_EQ(dut.RegisterBank[9],  32'd9,          "XOR: 5^12 = 9")
    `CHECK_EQ(dut.RegisterBank[10], 32'd0,          "SRL: 12 >> 5 = 0")
    `CHECK_EQ(dut.RegisterBank[11], 32'hFFFFFFFF,   "SRA: -7 >>> 5 = -1")
    `CHECK_EQ(dut.RegisterBank[12], 32'd13,         "OR: 5|12 = 13")
    `CHECK_EQ(dut.RegisterBank[13], 32'd4,          "AND: 5&12 = 4")
    `CHECK_EQ(dut.RegisterBank[14], 32'd1024,       "ADDI imm[30]=1: 0+1024, NOT 0-1024")
    `CHECK_EQ(dut.RegisterBank[15], 32'h80000000,   "SLLI by 31: 5<<31, only bit 0 survives")
    `CHECK_EQ(dut.RegisterBank[16], 32'h0FFFFFFF,   "SRLI: 0xFFFFFFF9 >> 4 logical")
    `CHECK_EQ(dut.RegisterBank[17], 32'hFFFFFFFF,   "SRAI: 0xFFFFFFF9 >>> 4 = -1")
    `CHECK_EQ(dut.RegisterBank[18], 32'd1,          "SLTI: -7 < 0 signed")
    `CHECK_EQ(dut.RegisterBank[19], 32'd1,          "SLTIU -1: 0xFFFFFFF9 < 0xFFFFFFFF")
    `CHECK_EQ(dut.RegisterBank[20], 32'hFFFFFFFA,   "XORI -1: 5 ^ 0xFFFFFFFF = ~5")
    `CHECK_EQ(dut.RegisterBank[21], 32'd13,         "ORI: 5|8 = 13")
    `CHECK_EQ(dut.RegisterBank[22], 32'd4,          "ANDI: 5&6 = 4")
    `CHECK_EQ(dut.RegisterBank[23], 32'd33,         "x23 = 33 (shift amount source)")
    `CHECK_EQ(dut.RegisterBank[24], 32'd2,          "SRL amount 33: uses bits[4:0] = 1")
    `CHECK_EQ(dut.RegisterBank[25], 32'd0,          "LUI still a NOP in part 2")
    `CHECK_EQ(x1_out, 32'd5, "x1 output mirrors RegisterBank[1]")

    // The assembler macros produced exactly the hand-assembled words.
    for (w = 0; w < 27; w = w + 1)
      `CHECK_EQ(MEM[w], expWord(w), "assembler word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
