`timescale 1ns/1ps
`default_nettype none
// Loads: LW, LH, LB, LHU, LBU. The program sets x1 = 0x80 (data base) and
// performs every load type at every required byte offset (bytes 0..3,
// halfwords 0 and 2) against a data area built with DATAB/DATAW, including
// bytes/halfwords with the sign bit set (0xFF/0x80/0x80FF/0xDEAD) and clear
// (0x01/0x7F/0x7F01). Also: a load through a negative offset, a load into
// x0 (dropped), a load into x1 (mirror path), and a per-cycle walk of the
// first LW showing the LOAD wait state: FETCH_INSTR -> FETCH_REGS ->
// EXECUTE (strobe high, mem_addr = rs1+Iimm) -> LOAD (strobe low, memory
// holds the word) -> FETCH_INSTR with rd written and PC + 4.
module loads_tb;
  `include "check.vh"
  `WATCHDOG(100_000)

  reg clk = 0;
  reg resetn = 0;
  always #5 clk = ~clk;

  wire [31:0] mem_addr;
  wire        mem_rstrb;
  wire [31:0] x1_out;

  // Bench memory model, same contract as rtl/Memory: synchronous read of
  // MEM[addr[9:2]] on the clock edge while the strobe is high.
  reg [31:0] MEM [0:255];
  reg [31:0] mem_rdata;
  always @(posedge clk) if (mem_rstrb) mem_rdata <= MEM[mem_addr[9:2]];

  Processor dut (.clk(clk), .resetn(resetn), .mem_addr(mem_addr),
                 .mem_rdata(mem_rdata), .mem_rstrb(mem_rstrb), .x1(x1_out));

  // Program (word index = addr/4). Data base x1 = 0x80 = word 32.
  //    0: ADDI (x1,  x0, 128)   x1  = 0x80
  //    1: LW   (x2,  x1,   0)   x2  = 0x80FF7F01        <- walked below
  //    2: LB   (x3,  x1,   0)   x3  = 0x00000001
  //    3: LB   (x4,  x1,   1)   x4  = 0x0000007F
  //    4: LB   (x5,  x1,   2)   x5  = 0xFFFFFFFF (sign)
  //    5: LB   (x6,  x1,   3)   x6  = 0xFFFFFF80 (sign)
  //    6: LBU  (x7,  x1,   0)   x7  = 0x00000001
  //    7: LBU  (x8,  x1,   1)   x8  = 0x0000007F
  //    8: LBU  (x9,  x1,   2)   x9  = 0x000000FF
  //    9: LBU  (x10, x1,   3)   x10 = 0x00000080
  //   10: LH   (x11, x1,   0)   x11 = 0x00007F01
  //   11: LH   (x12, x1,   2)   x12 = 0xFFFF80FF (sign)
  //   12: LHU  (x13, x1,   0)   x13 = 0x00007F01
  //   13: LHU  (x14, x1,   2)   x14 = 0x000080FF
  //   14: LW   (x15, x1,   4)   x15 = 0xDEADBEEF (second data word)
  //   15: LB   (x16, x1,   4)   x16 = 0xFFFFFFEF (sign)
  //   16: LBU  (x17, x1,   7)   x17 = 0x000000DE
  //   17: LH   (x18, x1,   6)   x18 = 0xFFFFDEAD (sign)
  //   18: ADDI (x19, x0, 136)   x19 = 0x88
  //   19: LW   (x20, x19, -8)   x20 = 0x80FF7F01 (negative offset)
  //   20: LW   (x0,  x1,   0)   x0 stays 0
  //   21: LBU  (x1,  x1,   0)   x1  = 1 (mirror path)
  //   22: EBREAK()              halt, PC frozen at 88
  //  Data (memPC jumped to 128):
  //   32: DATAB(01,7F,FF,80) -> 0x80FF7F01
  //   33: DATAW(0xDEADBEEF)
  `include "riscv_assembly.v"
  integer i;
  initial begin
    for (i = 0; i < 256; i = i + 1) MEM[i] = 32'hA5A5A5A5;  // poison: a stray load fails its check
    memPC = 0;
    ADDI(x1, x0, 128);
    LW  (x2,  x1, 0);
    LB  (x3,  x1, 0);
    LB  (x4,  x1, 1);
    LB  (x5,  x1, 2);
    LB  (x6,  x1, 3);
    LBU (x7,  x1, 0);
    LBU (x8,  x1, 1);
    LBU (x9,  x1, 2);
    LBU (x10, x1, 3);
    LH  (x11, x1, 0);
    LH  (x12, x1, 2);
    LHU (x13, x1, 0);
    LHU (x14, x1, 2);
    LW  (x15, x1, 4);
    LB  (x16, x1, 4);
    LBU (x17, x1, 7);
    LH  (x18, x1, 6);
    ADDI(x19, x0, 136);
    LW  (x20, x19, -8);
    LW  (x0,  x1, 0);
    LBU (x1,  x1, 0);
    EBREAK();
    memPC = 128;
    DATAB(8'h01, 8'h7F, 8'hFF, 8'h80);   // little-endian: byte0=01 .. byte3=80
    DATAW(32'hDEADBEEF);
    endASM();
  end

  // Hand-assembled words the macros must produce (I-type load encoding:
  // {imm[11:0], rs1[4:0], funct3[2:0], rd[4:0], 0000011}).
  function [31:0] expWord(input integer w);
    case (w)
      0:  expWord = 32'h08000093;  // addi x1,x0,128
      1:  expWord = 32'h0000A103;  // lw   x2,0(x1)
      2:  expWord = 32'h00008183;  // lb   x3,0(x1)
      3:  expWord = 32'h00108203;  // lb   x4,1(x1)
      4:  expWord = 32'h00208283;  // lb   x5,2(x1)
      5:  expWord = 32'h00308303;  // lb   x6,3(x1)
      6:  expWord = 32'h0000C383;  // lbu  x7,0(x1)
      7:  expWord = 32'h0010C403;  // lbu  x8,1(x1)
      8:  expWord = 32'h0020C483;  // lbu  x9,2(x1)
      9:  expWord = 32'h0030C503;  // lbu  x10,3(x1)
      10: expWord = 32'h00009583;  // lh   x11,0(x1)
      11: expWord = 32'h00209603;  // lh   x12,2(x1)
      12: expWord = 32'h0000D683;  // lhu  x13,0(x1)
      13: expWord = 32'h0020D703;  // lhu  x14,2(x1)
      14: expWord = 32'h0040A783;  // lw   x15,4(x1)
      15: expWord = 32'h00408803;  // lb   x16,4(x1)
      16: expWord = 32'h0070C883;  // lbu  x17,7(x1)
      17: expWord = 32'h00609903;  // lh   x18,6(x1)
      18: expWord = 32'h08800993;  // addi x19,x0,136
      19: expWord = 32'hFF89AA03;  // lw   x20,-8(x19)
      20: expWord = 32'h0000A003;  // lw   x0,0(x1)
      21: expWord = 32'h0000C083;  // lbu  x1,0(x1)
      22: expWord = 32'h00100073;  // ebreak
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

    // Three cycles: ADDI x1,x0,128 commits, PC = 4, about to fetch the LW.
    repeat (3) begin @(posedge clk); #1; end
    `CHECK_EQ(dut.PC, 32'd4, "PC = 4 before the first load")
    `CHECK_EQ(dut.state, 2'd0, "FETCH_INSTR before the first load")
    `CHECK_EQ(dut.RegisterBank[1], 32'd128, "x1 = 0x80 data base")

    // Per-cycle walk of the LW x2,0(x1): the LOAD wait state.
    @(posedge clk); #1;                       // -> FETCH_REGS
    `CHECK_EQ(dut.state, 2'd1, "LW: FETCH_REGS")
    `CHECK_EQ(mem_rstrb, 1'b0, "LW: strobe low in FETCH_REGS")
    @(posedge clk); #1;                       // -> EXECUTE
    `CHECK_EQ(dut.state, 2'd2, "LW: EXECUTE")
    `CHECK_EQ(mem_rstrb, 1'b1, "LW: read strobe high in EXECUTE")
    `CHECK_EQ(mem_addr, 32'h00000080, "LW: mem_addr = rs1 + Iimm = 0x80")
    @(posedge clk); #1;                       // -> LOAD (wait state)
    `CHECK_EQ(dut.state, 2'd3, "LW: LOAD wait state entered")
    `CHECK_EQ(mem_rstrb, 1'b0, "LW: strobe low during LOAD (memory holds)")
    `CHECK_EQ(mem_rdata, 32'h80FF7F01, "LW: memory returned the data word")
    @(posedge clk); #1;                       // -> FETCH_INSTR, writeback
    `CHECK_EQ(dut.state, 2'd0, "LW: back to FETCH_INSTR after LOAD")
    `CHECK_EQ(dut.PC, 32'd8, "LW: PC advanced by 4")
    `CHECK_EQ(dut.RegisterBank[2], 32'h80FF7F01, "LW wrote x2 = 0x80FF7F01")

    // Free-run the remaining loads into the EBREAK halt at word 22 (addr 88).
    repeat (120) @(posedge clk);
    #1;
    `CHECK_EQ(dut.PC, 32'd88, "halted at the EBREAK address 22*4")
    `CHECK_EQ(dut.state, 2'd2, "halted in EXECUTE")
    `CHECK_EQ(mem_rstrb, 1'b0, "no fetch strobe while halted")

    // Register file results. Data word 0 = 0x80FF7F01 (bytes 01,7F,FF,80),
    // data word 1 = 0xDEADBEEF; expectations hand-computed per load type.
    `CHECK_EQ(dut.RegisterBank[2],  32'h80FF7F01, "LW  [0x80] full word")
    `CHECK_EQ(dut.RegisterBank[3],  32'h00000001, "LB  [0x80] positive byte")
    `CHECK_EQ(dut.RegisterBank[4],  32'h0000007F, "LB  [0x81] positive byte")
    `CHECK_EQ(dut.RegisterBank[5],  32'hFFFFFFFF, "LB  [0x82] 0xFF sign-extends")
    `CHECK_EQ(dut.RegisterBank[6],  32'hFFFFFF80, "LB  [0x83] 0x80 sign-extends")
    `CHECK_EQ(dut.RegisterBank[7],  32'h00000001, "LBU [0x80] zero-extends")
    `CHECK_EQ(dut.RegisterBank[8],  32'h0000007F, "LBU [0x81] zero-extends")
    `CHECK_EQ(dut.RegisterBank[9],  32'h000000FF, "LBU [0x82] 0xFF zero-extends")
    `CHECK_EQ(dut.RegisterBank[10], 32'h00000080, "LBU [0x83] 0x80 zero-extends")
    `CHECK_EQ(dut.RegisterBank[11], 32'h00007F01, "LH  [0x80] positive half")
    `CHECK_EQ(dut.RegisterBank[12], 32'hFFFF80FF, "LH  [0x82] 0x80FF sign-extends")
    `CHECK_EQ(dut.RegisterBank[13], 32'h00007F01, "LHU [0x80] zero-extends")
    `CHECK_EQ(dut.RegisterBank[14], 32'h000080FF, "LHU [0x82] 0x80FF zero-extends")
    `CHECK_EQ(dut.RegisterBank[15], 32'hDEADBEEF, "LW  [0x84] second data word")
    `CHECK_EQ(dut.RegisterBank[16], 32'hFFFFFFEF, "LB  [0x84] 0xEF sign-extends")
    `CHECK_EQ(dut.RegisterBank[17], 32'h000000DE, "LBU [0x87] byte 3 of word 1")
    `CHECK_EQ(dut.RegisterBank[18], 32'hFFFFDEAD, "LH  [0x86] 0xDEAD sign-extends")
    `CHECK_EQ(dut.RegisterBank[19], 32'h00000088, "x19 = 0x88 (negative-offset base)")
    `CHECK_EQ(dut.RegisterBank[20], 32'h80FF7F01, "LW [0x88-8] negative offset reaches 0x80")
    `CHECK_EQ(dut.RegisterBank[0],  32'd0,        "LW into x0 is dropped")
    `CHECK_EQ(dut.RegisterBank[1],  32'h00000001, "LBU into x1")
    `CHECK_EQ(x1_out,               32'h00000001, "x1 output mirrors the load writeback")

    // The data area really contains what the loads read, and the assembler
    // produced the hand-assembled words.
    `CHECK_EQ(MEM[32], 32'h80FF7F01, "DATAB laid out the bytes little-endian")
    `CHECK_EQ(MEM[33], 32'hDEADBEEF, "DATAW stored the word")
    for (w = 0; w < 23; w = w + 1)
      `CHECK_EQ(MEM[w], expWord(w), "assembler word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
