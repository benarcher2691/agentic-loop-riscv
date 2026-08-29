`timescale 1ns/1ps
`default_nettype none
// Jumps: JAL and JALR. The program exercises every acceptance criterion:
//
//   addr 0  word 0:  JAL  (x0,  24)     forward JAL with rd=x0 -> word 6; the two
//                                       poison words 1-2 behind it must be skipped
//                                       and no link may appear in x0
//   addr 4  word 1:  ADDI (x9,  x0, 99) poison: only reached if the JAL fails
//   addr 8  word 2:  ADDI (x9,  x0, 99) poison
//   addr 12 word 3:  ADDI (x11, x0, 7)  subroutine entry: x11 = 7
//   addr 16 word 4:  ADDI (x11, x11, 1) subroutine: x11 = 8 (proves the sub ran)
//   addr 20 word 5:  JALR (x0,  x1,  0) subroutine return through the link (imm 0)
//   addr 24 word 6:  JAL  (x1, -12)     backward JAL call #1: 24 -> 12, x1 = 28
//   addr 28 word 7:  ADDI (x12, x0, 5)  main continues after return #1
//   addr 32 word 8:  JAL  (x1, -20)     backward JAL call #2: 32 -> 12, x1 = 36
//   addr 36 word 9:  ADDI (x10, x0, 0)  loop counter = 0
//   addr 40 word 10: ADDI (x7,  x0, 42) loop seed (odd after body +4: 46-1 = 45)
//   addr 44 word 11: JAL  (x5,   8)     forward JAL over the EBREAK: 44 -> 52, x5 = 48
//   addr 48 word 12: EBREAK()           halt, reached only by the 2nd loop return
//   addr 52 word 13: ADDI (x10, x10, 1) loop body: counter++
//   addr 56 word 14: ADDI (x7,  x7,  4) loop body: retarget the return
//   addr 60 word 15: JALR (x0,  x7, -1) loop return: (x7 - 1) & ~1
//
// The loop runs exactly twice: pass 1 returns (46-1)&~1 = 44 to the loop JAL,
// pass 2 returns (50-1)&~1 = 48 to the EBREAK. Both JALR sums (45, 49) are odd,
// so the &~1 masking is required to land on the right word, and the -1 immediate
// covers rs1 + Iimm with a nonzero offset. Expected final registers:
//   x0 = 0 (never written), x1 = 36, x5 = 48 (hand-computed links),
//   x7 = 50, x9 = 0 (poison skipped), x10 = 2 (two iterations),
//   x11 = 8 (sub ran twice), x12 = 5. PC frozen at 48.
module jumps_tb;
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

  `include "riscv_assembly.v"
  initial begin
    JAL(x0, 24);
    ADDI(x9, x0, 99);
    ADDI(x9, x0, 99);
    ADDI(x11, x0, 7);
    ADDI(x11, x11, 1);
    JALR(x0, x1, 0);
    JAL(x1, -12);
    ADDI(x12, x0, 5);
    JAL(x1, -20);
    ADDI(x10, x0, 0);
    ADDI(x7, x0, 42);
    JAL(x5, 8);
    EBREAK();
    ADDI(x10, x10, 1);
    ADDI(x7, x7, 4);
    JALR(x0, x7, -1);
    endASM();
  end

  // Hand-assembled words the macros must produce (spec formulas:
  // J-type imm[20]|imm[10:1]|imm[11]|imm[19:12]|rd|0x6F,
  // I-type imm|rs1|f3|rd|op with op 0x67 for JALR).
  function [31:0] expWord(input integer w);
    case (w)
      0:  expWord = 32'h0180006F;  // jal x0,24    (imm[10:1] = 12)
      1:  expWord = 32'h06300493;  // addi x9,x0,99
      2:  expWord = 32'h06300493;  // addi x9,x0,99
      3:  expWord = 32'h00700593;  // addi x11,x0,7
      4:  expWord = 32'h00158593;  // addi x11,x11,1
      5:  expWord = 32'h00008067;  // jalr x0,x1,0 (canonical ret)
      6:  expWord = 32'hFF5FF0EF;  // jal x1,-12
      7:  expWord = 32'h00500613;  // addi x12,x0,5
      8:  expWord = 32'hFEDFF0EF;  // jal x1,-20
      9:  expWord = 32'h00000513;  // addi x10,x0,0
      10: expWord = 32'h02A00393;  // addi x7,x0,42
      11: expWord = 32'h008002EF;  // jal x5,8     (imm[10:1] = 4)
      12: expWord = 32'h00100073;  // ebreak
      13: expWord = 32'h00150513;  // addi x10,x10,1
      14: expWord = 32'h00438393;  // addi x7,x7,4
      15: expWord = 32'hFFF38067;  // jalr x0,x7,-1
      default: expWord = 32'h00000013;
    endcase
  endfunction

  integer i, w, guard;

  // Wait until the FSM is in EXECUTE with the PC at `pc` (bounded poll).
  task pollExecute(input [31:0] pc);
    begin
      guard = 0;
      while ((dut.state !== 2'd2 || dut.PC !== pc) && guard < 1000) begin
        @(posedge clk); #1;
        guard = guard + 1;
      end
      `CHECK_EQ(dut.PC, pc, "pollExecute reached the target instruction")
      `CHECK_EQ(dut.state, 2'd2, "pollExecute stopped in EXECUTE")
    end
  endtask

  initial begin
    // Reset: PC held at 0.
    repeat (3) begin
      @(posedge clk); #1;
      `CHECK_EQ(dut.PC, 32'd0, "PC held at 0 during reset")
    end
    resetn = 1;

    // Walk instruction 0 (JAL x0,+24) cycle by cycle.
    @(posedge clk); #1;                       // -> FETCH_REGS
    `CHECK_EQ(dut.state, 2'd1, "word 0 in FETCH_REGS")
    @(posedge clk); #1;                       // -> EXECUTE
    `CHECK_EQ(dut.state, 2'd2, "word 0 in EXECUTE")
    `CHECK_EQ(dut.PC, 32'd0, "PC still at the JAL during EXECUTE")
    `CHECK_EQ(dut.jumpTarget, 32'd24, "JAL target = PC + Jimm = 0 + 24")
    @(posedge clk); #1;                       // PC <= 24
    `CHECK_EQ(dut.PC, 32'd24, "forward JAL taken: PC = 24, not 4")
    `CHECK_EQ(dut.RegisterBank[0], 32'd0, "JAL x0 wrote no link into x0")

    // Subroutine return #1: JALR x0,x1,0 with x1 = 28 (link of call #1).
    pollExecute(32'd20);
    `CHECK_EQ(dut.RegisterBank[1], 32'd28, "link of call #1 = 24 + 4")
    `CHECK_EQ(dut.jumpTarget, 32'd28, "JALR target = (x1 + 0) & ~1 = 28")
    @(posedge clk); #1;
    `CHECK_EQ(dut.PC, 32'd28, "JALR returned to the instruction after call #1")

    // Loop return pass 1: JALR x0,x7,-1 with x7 = 46 -> (46-1)&~1 = 44.
    pollExecute(32'd60);
    `CHECK_EQ(dut.RegisterBank[7], 32'd46, "x7 = 42 + 4 before loop return #1")
    `CHECK_EQ(dut.RegisterBank[10], 32'd1, "counter = 1 after the first iteration")
    `CHECK_EQ(dut.jumpTarget, 32'd44, "JALR target = (46 - 1) & ~1 = 44 (bit 0 cleared)")
    @(posedge clk); #1;
    `CHECK_EQ(dut.PC, 32'd44, "loop return #1 landed on the loop JAL")

    // Loop return pass 2: x7 = 50 -> (50-1)&~1 = 48 = the EBREAK.
    pollExecute(32'd60);
    `CHECK_EQ(dut.RegisterBank[7], 32'd50, "x7 = 46 + 4 before loop return #2")
    `CHECK_EQ(dut.jumpTarget, 32'd48, "JALR target = (50 - 1) & ~1 = 48")
    @(posedge clk); #1;
    `CHECK_EQ(dut.PC, 32'd48, "loop return #2 landed on the EBREAK")

    // Run into the halt and confirm it stays put.
    repeat (10) @(posedge clk); #1;
    `CHECK_EQ(dut.PC, 32'd48, "halted at the EBREAK address 48")
    `CHECK_EQ(dut.state, 2'd2, "halted in EXECUTE")
    `CHECK_EQ(mem_rstrb, 1'b0, "no fetch strobe while halted")
    for (i = 0; i < 5; i = i + 1) begin
      @(posedge clk); #1;
      `CHECK_EQ(dut.PC, 32'd48, "PC frozen after EBREAK")
    end

    // Register file results, by hierarchical reference. All hand-computed.
    `CHECK_EQ(dut.RegisterBank[0],  32'd0, "x0 never written (JAL/JALR with rd=x0)")
    `CHECK_EQ(dut.RegisterBank[1],  32'd36, "x1 = link of call #2 = 32 + 4")
    `CHECK_EQ(dut.RegisterBank[5],  32'd48, "x5 = link of the loop JAL = 44 + 4")
    `CHECK_EQ(dut.RegisterBank[7],  32'd50, "x7 = 42 + 4 + 4")
    `CHECK_EQ(dut.RegisterBank[9],  32'd0,  "poison skipped: forward JAL x0 worked")
    `CHECK_EQ(dut.RegisterBank[10], 32'd2,  "two-iteration loop: counter = 2")
    `CHECK_EQ(dut.RegisterBank[11], 32'd8,  "subroutine ran twice: (7+1) twice")
    `CHECK_EQ(dut.RegisterBank[12], 32'd5,  "main continued after return #1")
    `CHECK_EQ(x1_out, 32'd36, "x1 output mirrors RegisterBank[1]")

    // The assembler macros produced exactly the hand-assembled words.
    for (w = 0; w < 16; w = w + 1)
      `CHECK_EQ(MEM[w], expWord(w), "assembler word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
