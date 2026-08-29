`timescale 1ns/1ps
`default_nettype none
// Stores: SB, SH, SW with byte-enable write masks. The program stores bytes
// 0x11/0x22/0x33/0x44 at offsets 0..3 of a poisoned data word, then loads the
// word back: only the addressed byte may change each time. SH at offsets 0/2,
// SW, a SW over a previous SB (must clear the byte the SB set), sign-bit
// values (0xFF/0x80 bytes, 0xFFFF halfwords) read back through LB/LBU/LH/LHU,
// and a store through a negative offset. A per-cycle walk of the first SB
// shows the store contract: no read strobe, wmask = the one addressed byte
// lane, wdata carrying the byte, write committed on the edge that leaves
// EXECUTE (stores take 3 cycles, no wait state).
module stores_tb;
  `include "check.vh"
  `WATCHDOG(200_000)

  reg clk = 0;
  reg resetn = 0;
  always #5 clk = ~clk;

  wire [31:0] mem_addr;
  wire        mem_rstrb;
  wire [31:0] mem_wdata;
  wire [3:0]  mem_wmask;

  // Bench memory model, same contract as rtl/Memory: synchronous read of
  // MEM[addr[9:2]] while the strobe is high, synchronous byte-enabled write.
  reg [31:0] MEM [0:255];
  reg [31:0] mem_rdata;
  always @(posedge clk) begin
    if (mem_rstrb)    mem_rdata <= MEM[mem_addr[9:2]];
    if (mem_wmask[0]) MEM[mem_addr[9:2]][ 7: 0] <= mem_wdata[ 7: 0];
    if (mem_wmask[1]) MEM[mem_addr[9:2]][15: 8] <= mem_wdata[15: 8];
    if (mem_wmask[2]) MEM[mem_addr[9:2]][23:16] <= mem_wdata[23:16];
    if (mem_wmask[3]) MEM[mem_addr[9:2]][31:24] <= mem_wdata[31:24];
  end

  Processor dut (.clk(clk), .resetn(resetn), .mem_addr(mem_addr),
                 .mem_rdata(mem_rdata), .mem_rstrb(mem_rstrb),
                 .mem_wdata(mem_wdata), .mem_wmask(mem_wmask));

  // Program (word index = addr/4). Data base x1 = 0xA0 = word 40 (past the 39-word program), poisoned
  // with 0xA5A5A5A5 like every other word: a stray write fails its check.
  //    0: ADDI (x1,  x0, 128)    x1 = 0xA0
  //    1: ADDI (x2,  x0, 0x11)
  //    2: SB    (x2,  x1,  0)    MEM[40] = A5A5A511      <- walked below
  //    3: ADDI (x2,  x0, 0x22)
  //    4: SB    (x2,  x1,  1)    MEM[40] = A5A52211
  //    5: ADDI (x2,  x0, 0x33)
  //    6: SB    (x2,  x1,  2)    MEM[40] = A5332211
  //    7: ADDI (x2,  x0, 0x44)
  //    8: SB    (x2,  x1,  3)    MEM[40] = 44332211
  //    9: LW    (x3,  x1,  0)    x3 = 0x44332211
  //   10: ADDI (x4,  x0, 0x55)
  //   11: SW    (x4,  x1,  4)    MEM[41] = 0x00000055
  //   12: ADDI (x5,  x0, 0x66)
  //   13: SH    (x5,  x1,  8)    MEM[42] = A5A50066
  //   14: SH    (x5,  x1, 10)    MEM[42] = 00660066
  //   15: SW    (x4,  x1, 12)    MEM[35] = 0x00000055
  //   16: SB    (x2,  x1, 15)    MEM[35] = 0x11000055 (byte 3)
  //   17: SW    (x4,  x1, 12)    MEM[43] = 0x00000055 (SW over SB)
  //   18: LW    (x6,  x1,  4)    x6 = 0x00000055
  //   19: LHU  (x7,  x1,  8)    x7 = 0x00000066
  //   20: LHU  (x8,  x1, 10)    x8 = 0x00000066
  //   21: LW    (x9,  x1, 12)    x9 = 0x00000055
  //   22: ADDI (x10, x0,  -1)   x10 = 0xFFFFFFFF
  //   23: SB    (x10, x1, 16)    MEM[44] = A5A5A5FF
  //   24: LBU  (x11, x1, 16)    x11 = 0x000000FF
  //   25: LB   (x12, x1, 16)    x12 = 0xFFFFFFFF (sign)
  //   26: ADDI (x13, x0,-128)   x13 = 0xFFFFFF80
  //   27: SB    (x13, x1, 17)    MEM[44] = A580A5FF (byte 1)
  //   28: LBU  (x14, x1, 17)    x14 = 0x00000080
  //   29: LB   (x15, x1, 17)    x15 = 0xFFFFFF80 (sign)
  //   30: SH    (x10, x1, 20)    MEM[45] = A5A5FFFF
  //   31: LH   (x16, x1, 20)    x16 = 0xFFFFFFFF (sign)
  //   32: LHU  (x17, x1, 20)    x17 = 0x0000FFFF
  //   33: SH    (x10, x1, 22)    MEM[45] = FFFFA5A5 (upper half)
  //   34: LH   (x18, x1, 22)    x18 = 0xFFFFFFFF (sign)
  //   35: ADDI (x19, x0, 169)   x19 = 0xA9
  //   36: SB    (x2,  x19, -8)   MEM[40] = 44334411 (0xA9-8 = 0xA1, byte 1)
  //   37: LBU  (x20, x1,  1)    x20 = 0x00000022
  //   38: EBREAK()              halt, PC frozen at 152
  `include "riscv_assembly.v"
  integer i;
  initial begin
    for (i = 0; i < 256; i = i + 1) MEM[i] = 32'hA5A5A5A5;
    memPC = 0;
    ADDI(x1, x0, 160);
    ADDI(x2, x0, 8'h11);
    SB  (x2, x1, 0);
    ADDI(x2, x0, 8'h22);
    SB  (x2, x1, 1);
    ADDI(x2, x0, 8'h33);
    SB  (x2, x1, 2);
    ADDI(x2, x0, 8'h44);
    SB  (x2, x1, 3);
    LW  (x3, x1, 0);
    ADDI(x4, x0, 8'h55);
    SW  (x4, x1, 4);
    ADDI(x5, x0, 8'h66);
    SH  (x5, x1, 8);
    SH  (x5, x1, 10);
    SW  (x4, x1, 12);
    SB  (x2, x1, 15);
    SW  (x4, x1, 12);
    LW  (x6, x1, 4);
    LHU (x7, x1, 8);
    LHU (x8, x1, 10);
    LW  (x9, x1, 12);
    ADDI(x10, x0, -1);
    SB  (x10, x1, 16);
    LBU (x11, x1, 16);
    LB  (x12, x1, 16);
    ADDI(x13, x0, -128);
    SB  (x13, x1, 17);
    LBU (x14, x1, 17);
    LB  (x15, x1, 17);
    SH  (x10, x1, 20);
    LH  (x16, x1, 20);
    LHU (x17, x1, 20);
    SH  (x10, x1, 22);
    LH  (x18, x1, 22);
    ADDI(x19, x0, 169);
    SB  (x2, x19, -8);
    LBU (x20, x1, 1);
    EBREAK();
    endASM();
  end

  // Hand-assembled words the macros must produce. S-type store encoding:
  // {imm[11:5], rs2, rs1, funct3, imm[4:0], 0100011}; the I-type loads are
  // {imm[11:0], rs1, funct3, rd, 0000011}. Values pre-computed from the
  // spec bit formulas (python slicer) — independent of the assembler.
  function [31:0] expWord(input integer w);
    case (w)
      0:  expWord = 32'h0A000093;  // addi x1,x0,160
      1:  expWord = 32'h01100113;  // addi x2,x0,17
      2:  expWord = 32'h00208023;  // sb   x2,0(x1)
      3:  expWord = 32'h02200113;  // addi x2,x0,34
      4:  expWord = 32'h002080A3;  // sb   x2,1(x1)
      5:  expWord = 32'h03300113;  // addi x2,x0,51
      6:  expWord = 32'h00208123;  // sb   x2,2(x1)
      7:  expWord = 32'h04400113;  // addi x2,x0,68
      8:  expWord = 32'h002081A3;  // sb   x2,3(x1)
      9:  expWord = 32'h0000A183;  // lw   x3,0(x1)
      10: expWord = 32'h05500213;  // addi x4,x0,85
      11: expWord = 32'h0040A223;  // sw   x4,4(x1)
      12: expWord = 32'h06600293;  // addi x5,x0,102
      13: expWord = 32'h00509423;  // sh   x5,8(x1)
      14: expWord = 32'h00509523;  // sh   x5,10(x1)
      15: expWord = 32'h0040A623;  // sw   x4,12(x1)
      16: expWord = 32'h002087A3;  // sb   x2,15(x1)
      17: expWord = 32'h0040A623;  // sw   x4,12(x1)
      18: expWord = 32'h0040A303;  // lw   x6,4(x1)
      19: expWord = 32'h0080D383;  // lhu  x7,8(x1)
      20: expWord = 32'h00A0D403;  // lhu  x8,10(x1)
      21: expWord = 32'h00C0A483;  // lw   x9,12(x1)
      22: expWord = 32'hFFF00513;  // addi x10,x0,-1
      23: expWord = 32'h00A08823;  // sb   x10,16(x1)
      24: expWord = 32'h0100C583;  // lbu  x11,16(x1)
      25: expWord = 32'h01008603;  // lb   x12,16(x1)
      26: expWord = 32'hF8000693;  // addi x13,x0,-128
      27: expWord = 32'h00D088A3;  // sb   x13,17(x1)
      28: expWord = 32'h0110C703;  // lbu  x14,17(x1)
      29: expWord = 32'h01108783;  // lb   x15,17(x1)
      30: expWord = 32'h00A09A23;  // sh   x10,20(x1)
      31: expWord = 32'h01409803;  // lh   x16,20(x1)
      32: expWord = 32'h0140D883;  // lhu  x17,20(x1)
      33: expWord = 32'h00A09B23;  // sh   x10,22(x1)
      34: expWord = 32'h01609903;  // lh   x18,22(x1)
      35: expWord = 32'h0A900993;  // addi x19,x0,169
      36: expWord = 32'hFE298C23;  // sb   x2,-8(x19)
      37: expWord = 32'h0010CA03;  // lbu  x20,1(x1)
      38: expWord = 32'h00100073;  // ebreak
      default: expWord = 32'h00000013;
    endcase
  endfunction

  integer w;

  initial begin
    // Reset: PC held at 0.
    repeat (3) begin
      @(posedge clk); #1;
      `CHECK_EQ(dut.PC, 32'd0, "PC held at 0 during reset")
    end
    resetn = 1;

    // Six cycles: both ADDIs commit, PC = 8, about to fetch the first SB.
    repeat (6) begin @(posedge clk); #1; end
    `CHECK_EQ(dut.PC, 32'd8, "PC = 8 before the first store")
    `CHECK_EQ(dut.state, 2'd0, "FETCH_INSTR before the first store")
    `CHECK_EQ(dut.RegisterBank[1], 32'd160, "x1 = 0xA0 data base")

    // Per-cycle walk of SB x2,0(x1): stores take the plain 3 cycles.
    @(posedge clk); #1;                       // -> FETCH_REGS
    `CHECK_EQ(dut.state, 2'd1, "SB: FETCH_REGS")
    `CHECK_EQ(mem_wmask, 4'b0000, "SB: no write in FETCH_REGS")
    `CHECK_EQ(mem_rstrb, 1'b0, "SB: no read strobe in FETCH_REGS")
    @(posedge clk); #1;                       // -> EXECUTE
    `CHECK_EQ(dut.state, 2'd2, "SB: EXECUTE")
    `CHECK_EQ(mem_rstrb, 1'b0, "SB: store must not assert the read strobe")
    `CHECK_EQ(mem_addr, 32'h000000A0, "SB: mem_addr = rs1 + Simm = 0xA0")
    `CHECK_EQ(mem_wmask, 4'b0001, "SB: byte lane 0 enabled")
    `CHECK_EQ(mem_wdata[7:0], 8'h11, "SB: store data byte on lane 0")
    @(posedge clk); #1;                       // write commits, -> FETCH_INSTR
    `CHECK_EQ(dut.state, 2'd0, "SB: back to FETCH_INSTR (no wait state)")
    `CHECK_EQ(dut.PC, 32'd12, "SB: PC advanced by 4")
    `CHECK_EQ(MEM[40], 32'hA5A5A511, "SB wrote byte 0, poison intact above")

    // Free-run the remaining stores/loads into the EBREAK halt at word 38.
    repeat (200) @(posedge clk);
    #1;
    `CHECK_EQ(dut.PC, 32'd152, "halted at the EBREAK address 38*4")
    `CHECK_EQ(dut.state, 2'd2, "halted in EXECUTE")
    `CHECK_EQ(mem_wmask, 4'b0000, "no write strobe while halted")
    `CHECK_EQ(mem_rstrb, 1'b0, "no fetch strobe while halted")

    // Load-backs: every store width/offset read back through the loads.
    `CHECK_EQ(dut.RegisterBank[3],  32'h44332211, "LW read the four SBs back")
    `CHECK_EQ(dut.RegisterBank[6],  32'h00000055, "LW read the SW back")
    `CHECK_EQ(dut.RegisterBank[7],  32'h00000066, "LHU read SH offset 0")
    `CHECK_EQ(dut.RegisterBank[8],  32'h00000066, "LHU read SH offset 2")
    `CHECK_EQ(dut.RegisterBank[9],  32'h00000055, "LW read SW over SB")
    `CHECK_EQ(dut.RegisterBank[11], 32'h000000FF, "LBU read SB 0xFF")
    `CHECK_EQ(dut.RegisterBank[12], 32'hFFFFFFFF, "LB sign-extends SB 0xFF")
    `CHECK_EQ(dut.RegisterBank[14], 32'h00000080, "LBU read SB 0x80")
    `CHECK_EQ(dut.RegisterBank[15], 32'hFFFFFF80, "LB sign-extends SB 0x80")
    `CHECK_EQ(dut.RegisterBank[16], 32'hFFFFFFFF, "LH sign-extends SH 0xFFFF")
    `CHECK_EQ(dut.RegisterBank[17], 32'h0000FFFF, "LHU zero-extends SH 0xFFFF")
    `CHECK_EQ(dut.RegisterBank[18], 32'hFFFFFFFF, "LH sign-extends SH offset 2")
    `CHECK_EQ(dut.RegisterBank[20], 32'h00000044, "LBU read the -8 offset SB")

    // The memory words themselves: byte stores changed only their lane,
    // SW over SB cleared the byte the SB had set, poison survived next door.
    `CHECK_EQ(MEM[40], 32'h44334411, "SB 0..3 then -8-offset SB sets byte 1 to 0x44")
    `CHECK_EQ(MEM[41], 32'h00000055, "SW wrote the whole word")
    `CHECK_EQ(MEM[42], 32'h00660066, "SH offset 0 then offset 2")
    `CHECK_EQ(MEM[43], 32'h00000055, "SW over SB cleared the SB's byte 3")
    `CHECK_EQ(MEM[44], 32'hA5A580FF, "SB 0xFF lane 0, SB 0x80 lane 1")
    `CHECK_EQ(MEM[45], 32'hFFFFFFFF, "SH 0xFFFF lane 0/1 then lane 2/3")
    `CHECK_EQ(MEM[46], 32'hA5A5A5A5, "word above the data area untouched")
    `CHECK_EQ(MEM[39], 32'hA5A5A5A5, "word below the data area untouched")

    // The assembler produced the hand-assembled words.
    for (w = 0; w < 39; w = w + 1)
      `CHECK_EQ(MEM[w], expWord(w), "assembler word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
