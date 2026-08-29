`timescale 1ns/1ps
`default_nettype none
// Branches: BEQ/BNE/BLT/BGE/BLTU/BGEU, taken and not taken, signed vs
// unsigned on -1 (0xFFFFFFFF) vs 1, a backward branch, and a countdown
// loop that sums 1..10 = 55.
//
//   word 0  (0):   ADDI x5, x0, 1     x5 = 1
//   word 1  (4):   ADDI x6, x0, 2     x6 = 2
//   word 2  (8):   ADDI x7, x0, -1    x7 = 0xFFFFFFFF (-1 unsigned max)
//   word 3  (12):  BEQ  x5, x6, +8    NOT taken (1 != 2) -> word 4
//   word 4  (16):  ADDI x10, x0, 1    marker A: not-taken BEQ fell through
//   word 5  (20):  BEQ  x5, x5, +8    taken (1 == 1) -> word 7
//   word 6  (24):  ADDI x11, x0, 99   poison A: skipped by the taken BEQ
//   word 7  (28):  BNE  x5, x5, +8    NOT taken (1 == 1) -> word 8
//   word 8  (32):  ADDI x12, x0, 1    marker B
//   word 9  (36):  BNE  x5, x6, +8    taken (1 != 2) -> word 11
//   word 10 (40):  ADDI x13, x0, 99   poison B: skipped
//   word 11 (44):  BLT  x7, x5, +8    taken SIGNED (-1 < 1) -> word 13
//   word 12 (48):  ADDI x14, x0, 99   poison C: skipped
//   word 13 (52):  BLT  x5, x7, +8    NOT taken signed (1 < -1 false) -> word 14
//   word 14 (56):  ADDI x14, x0, 1    marker C
//   word 15 (60):  BGE  x5, x7, +8    taken SIGNED (1 >= -1) -> word 17
//   word 16 (64):  ADDI x15, x0, 99   poison D: skipped
//   word 17 (68):  BGE  x7, x5, +8    NOT taken signed (-1 >= 1 false) -> word 18
//   word 18 (72):  ADDI x15, x0, 1    marker D
//   word 19 (76):  BLTU x7, x5, +8    NOT taken UNSIGNED (0xFFFFFFFF < 1 false)
//   word 20 (80):  ADDI x16, x0, 1    marker E: proves BLTU is unsigned — the
//                                     signed BLT of the SAME operands was taken
//   word 21 (84):  BLTU x5, x7, +8    taken UNSIGNED (1 < 0xFFFFFFFF) -> word 23
//   word 22 (88):  ADDI x17, x0, 99   poison F: skipped
//   word 23 (92):  BGEU x7, x5, +8    taken UNSIGNED (0xFFFFFFFF >= 1) -> word 25
//   word 24 (96):  ADDI x17, x0, 99   poison G: skipped
//   word 25 (100): BGEU x5, x7, +8    NOT taken UNSIGNED (1 >= 0xFFFFFFFF false)
//   word 26 (104): ADDI x18, x0, 1    marker F
//   word 27 (108): ADDI x19, x0, 2    backward-branch seed
//   word 28 (112): ADDI x19, x19, -1  backward target: x19--
//   word 29 (116): BNE  x19, x0, -4   taken once (x19 = 1), then NOT taken (x19 = 0)
//   word 30 (120): ADDI x20, x0, 10   countdown loop: counter = 10
//   word 31 (124): ADDI x21, x0, 0    sum = 0
//   word 32 (128): BEQ  x20, x0, +16  exit when counter == 0 -> word 36
//   word 33 (132): ADD  x21, x21, x20 sum += counter
//   word 34 (136): ADDI x20, x20, -1  counter--
//   word 35 (140): JAL  x0, -12       back to the loop head (word 32)
//   word 36 (144): EBREAK             final halt
//
// Expected final registers (all hand-computed):
//   x5 = 1, x6 = 2, x7 = 0xFFFFFFFF, x10 = x12 = x14 = x15 = x16 = x18 = 1
//   (markers reached), x11 = x13 = x17 = 0 (poisons skipped), x19 = 0,
//   x20 = 0, x21 = 55 (10+9+...+1). PC frozen at 144.
module branches_tb;
  `include "check.vh"
  `WATCHDOG(200_000)

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

  `include "riscv_assembly.v"
  initial begin
    ADDI(x5, x0, 1);      // word 0
    ADDI(x6, x0, 2);      // word 1
    ADDI(x7, x0, -1);     // word 2
    BEQ(x5, x6, 8);       // word 3:  not taken
    ADDI(x10, x0, 1);     // word 4:  marker A
    BEQ(x5, x5, 8);       // word 5:  taken
    ADDI(x11, x0, 99);    // word 6:  poison A
    BNE(x5, x5, 8);       // word 7:  not taken
    ADDI(x12, x0, 1);     // word 8:  marker B
    BNE(x5, x6, 8);       // word 9:  taken
    ADDI(x13, x0, 99);    // word 10: poison B
    BLT(x7, x5, 8);       // word 11: taken signed
    ADDI(x14, x0, 99);    // word 12: poison C
    BLT(x5, x7, 8);       // word 13: not taken signed
    ADDI(x14, x0, 1);     // word 14: marker C
    BGE(x5, x7, 8);       // word 15: taken signed
    ADDI(x15, x0, 99);    // word 16: poison D
    BGE(x7, x5, 8);       // word 17: not taken signed
    ADDI(x15, x0, 1);     // word 18: marker D
    BLTU(x7, x5, 8);      // word 19: not taken unsigned
    ADDI(x16, x0, 1);     // word 20: marker E
    BLTU(x5, x7, 8);      // word 21: taken unsigned
    ADDI(x17, x0, 99);    // word 22: poison F
    BGEU(x7, x5, 8);      // word 23: taken unsigned
    ADDI(x17, x0, 99);    // word 24: poison G
    BGEU(x5, x7, 8);      // word 25: not taken unsigned
    ADDI(x18, x0, 1);     // word 26: marker F
    ADDI(x19, x0, 2);     // word 27: backward-branch seed
    ADDI(x19, x19, -1);   // word 28: backward target
    BNE(x19, x0, -4);     // word 29: backward, taken then not taken
    ADDI(x20, x0, 10);    // word 30: counter = 10
    ADDI(x21, x0, 0);     // word 31: sum = 0
    BEQ(x20, x0, 16);     // word 32: loop exit
    ADD(x21, x21, x20);   // word 33: sum += counter
    ADDI(x20, x20, -1);   // word 34: counter--
    JAL(x0, -12);         // word 35: loop back
    EBREAK();             // word 36
    endASM();
  end

  integer i, g;

  // Wait until the FSM is in EXECUTE with the PC at `pc` (bounded poll).
  task pollExecute(input [31:0] pc);
    begin
      g = 0;
      while ((dut.state !== 2'd2 || dut.PC !== pc) && g < 2000) begin
        @(posedge clk); #1;
        g = g + 1;
      end
      `CHECK_EQ(dut.PC, pc, "pollExecute reached the target instruction")
      `CHECK_EQ(dut.state, 2'd2, "pollExecute stopped in EXECUTE")
    end
  endtask

  // Free-run until the FSM sits in EXECUTE at haltPc (the EBREAK), bounded.
  task waitHalt(input [31:0] haltPc);
    begin
      g = 0;
      while (!(dut.state == 2'd2 && dut.PC == haltPc) && g < 5000) begin
        @(posedge clk); #1;
        g = g + 1;
      end
      `CHECK_EQ(dut.PC, haltPc, "waitHalt reached the EBREAK address")
      `CHECK_EQ(dut.state, 2'd2, "waitHalt stopped in EXECUTE")
    end
  endtask

  // Hand-assembled words the macros must produce (B-type spec formula:
  // imm[12]|imm[10:5]|rs2|rs1|funct3|imm[4:1]|imm[11]|1100011).
  function [31:0] expWord(input integer w);
    case (w)
      0:  expWord = 32'h00100293;  // addi x5,x0,1
      1:  expWord = 32'h00200313;  // addi x6,x0,2
      2:  expWord = 32'hFFF00393;  // addi x7,x0,-1
      3:  expWord = 32'h00628463;  // beq x5,x6,8   (imm[4:1]=0100)
      4:  expWord = 32'h00100513;  // addi x10,x0,1
      5:  expWord = 32'h00528463;  // beq x5,x5,8
      6:  expWord = 32'h06300593;  // addi x11,x0,99
      7:  expWord = 32'h00529463;  // bne x5,x5,8   (funct3=001)
      8:  expWord = 32'h00100613;  // addi x12,x0,1
      9:  expWord = 32'h00629463;  // bne x5,x6,8
      10: expWord = 32'h06300693;  // addi x13,x0,99
      11: expWord = 32'h0053C463;  // blt x7,x5,8   (funct3=100)
      12: expWord = 32'h06300713;  // addi x14,x0,99
      13: expWord = 32'h0072C463;  // blt x5,x7,8
      14: expWord = 32'h00100713;  // addi x14,x0,1
      15: expWord = 32'h0072D463;  // bge x5,x7,8   (funct3=101)
      16: expWord = 32'h06300793;  // addi x15,x0,99
      17: expWord = 32'h0053D463;  // bge x7,x5,8
      18: expWord = 32'h00100793;  // addi x15,x0,1
      19: expWord = 32'h0053E463;  // bltu x7,x5,8  (funct3=110)
      20: expWord = 32'h00100813;  // addi x16,x0,1
      21: expWord = 32'h0072E463;  // bltu x5,x7,8
      22: expWord = 32'h06300893;  // addi x17,x0,99
      23: expWord = 32'h0053F463;  // bgeu x7,x5,8  (funct3=111)
      24: expWord = 32'h06300893;  // addi x17,x0,99
      25: expWord = 32'h0072F463;  // bgeu x5,x7,8
      26: expWord = 32'h00100913;  // addi x18,x0,1
      27: expWord = 32'h00200993;  // addi x19,x0,2
      28: expWord = 32'hFFF98993;  // addi x19,x19,-1
      29: expWord = 32'hFE099EE3;  // bne x19,x0,-4 (backward: imm[12]=imm[11]=1)
      30: expWord = 32'h00A00A13;  // addi x20,x0,10
      31: expWord = 32'h00000A93;  // addi x21,x0,0
      32: expWord = 32'h000A0863;  // beq x20,x0,16 (imm[4:1]=1000)
      33: expWord = 32'h014A8AB3;  // add x21,x21,x20 (rs2=20<<20, rs1=21<<15)
      34: expWord = 32'hFFFA0A13;  // addi x20,x20,-1
      35: expWord = 32'hFF5FF06F;  // jal x0,-12
      36: expWord = 32'h00100073;  // ebreak
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

    // Walk 1: BEQ x5,x6,+8 at 12 — operands 1 vs 2, NOT taken.
    pollExecute(32'd12);
    `CHECK_EQ(dut.aluEQ, 1'b0, "1 != 2: ALU EQ low")
    `CHECK_EQ(dut.branchCond, 1'b0, "BEQ condition not met")
    `CHECK_EQ(dut.branchTarget, 32'd20, "branch target wire = 12 + 8 (unused when not taken)")
    @(posedge clk); #1;
    `CHECK_EQ(dut.PC, 32'd16, "not-taken BEQ: PC fell through to 16, not 20")

    // Walk 2: BEQ x5,x5,+8 at 20 — operands equal, taken.
    pollExecute(32'd20);
    `CHECK_EQ(dut.aluEQ, 1'b1, "1 == 1: ALU EQ high")
    `CHECK_EQ(dut.branchCond, 1'b1, "BEQ condition met")
    `CHECK_EQ(dut.branchTarget, 32'd28, "taken BEQ target = 20 + 8")
    @(posedge clk); #1;
    `CHECK_EQ(dut.PC, 32'd28, "taken BEQ: PC = 28, not 24")

    // Walk 3: BLT x7,x5,+8 at 44 — -1 vs 1, taken SIGNED.
    pollExecute(32'd44);
    `CHECK_EQ(dut.aluLT, 1'b1, "signed: -1 < 1")
    `CHECK_EQ(dut.aluLTU, 1'b0, "unsigned: 0xFFFFFFFF < 1 is false")
    `CHECK_EQ(dut.branchCond, 1'b1, "BLT condition met (signed compare)")
    `CHECK_EQ(dut.branchTarget, 32'd52, "taken BLT target = 44 + 8")
    @(posedge clk); #1;
    `CHECK_EQ(dut.PC, 32'd52, "taken BLT: PC = 52, not 48")

    // Walk 4: BLTU x7,x5,+8 at 76 — SAME operand values, NOT taken UNSIGNED.
    pollExecute(32'd76);
    `CHECK_EQ(dut.aluLTU, 1'b0, "unsigned: 0xFFFFFFFF < 1 is false")
    `CHECK_EQ(dut.branchCond, 1'b0, "BLTU condition not met (unsigned compare)")
    @(posedge clk); #1;
    `CHECK_EQ(dut.PC, 32'd80, "not-taken BLTU: PC fell through to 80")

    // Free-run through the rest into the final EBREAK at 144.
    waitHalt(32'd144);
    repeat (5) begin
      @(posedge clk); #1;
      `CHECK_EQ(dut.PC, 32'd144, "PC frozen at the EBREAK")
    end
    `CHECK_EQ(mem_rstrb, 1'b0, "no fetch strobe while halted")

    // Register file results, by hierarchical reference. All hand-computed.
    `CHECK_EQ(dut.RegisterBank[5],  32'h00000001, "x5 = 1")
    `CHECK_EQ(dut.RegisterBank[6],  32'h00000002, "x6 = 2")
    `CHECK_EQ(dut.RegisterBank[7],  32'hFFFFFFFF, "x7 = -1 = 0xFFFFFFFF")
    `CHECK_EQ(dut.RegisterBank[10], 32'd1, "BEQ not taken (1 != 2): marker A reached")
    `CHECK_EQ(dut.RegisterBank[11], 32'd0, "BEQ taken (1 == 1): poison A skipped")
    `CHECK_EQ(dut.RegisterBank[12], 32'd1, "BNE not taken (1 == 1): marker B reached")
    `CHECK_EQ(dut.RegisterBank[13], 32'd0, "BNE taken (1 != 2): poison B skipped")
    `CHECK_EQ(dut.RegisterBank[14], 32'd1, "BLT not taken signed (1 < -1 false): marker C, poison C overwritten")
    `CHECK_EQ(dut.RegisterBank[15], 32'd1, "BGE not taken signed (-1 >= 1 false): marker D, poison D overwritten")
    `CHECK_EQ(dut.RegisterBank[16], 32'd1, "BLTU not taken unsigned (0xFFFFFFFF < 1 false): marker E — signed BLT of the same operands was taken")
    `CHECK_EQ(dut.RegisterBank[17], 32'd0, "BLTU/BGEU taken unsigned: poisons F and G skipped")
    `CHECK_EQ(dut.RegisterBank[18], 32'd1, "BGEU not taken unsigned (1 >= 0xFFFFFFFF false): marker F reached")
    `CHECK_EQ(dut.RegisterBank[19], 32'd0, "backward BNE ran twice: 2 -> 1 (taken) -> 0 (not taken)")
    `CHECK_EQ(dut.RegisterBank[20], 32'd0, "countdown loop ended at counter = 0")
    `CHECK_EQ(dut.RegisterBank[21], 32'd55, "countdown loop summed 10+9+...+1 = 55")

    // The assembler macros produced exactly the hand-assembled words.
    for (w = 0; w < 37; w = w + 1)
      `CHECK_EQ(MEM[w], expWord(w), "assembler word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
