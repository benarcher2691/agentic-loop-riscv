`timescale 1ns/1ps
`default_nettype none
// Processor part 3: JAL and JALR. rd <= PC + 4; JAL: PC <= PC + Jimm;
// JALR: PC <= (rs1 + Iimm) & ~1. The program exercises: a two-iteration
// loop counted in a register (the loop-back is a JALR whose target register
// counts down, since there are no branches yet), forward JAL with link over
// poison words, JALR through a register with rd != x0, a backward JAL, and
// rd = x0 jumps that must not write a link. Link values are checked against
// hand-computed addresses, and the JAL/JALR words are cross-checked against
// hand-assembled hex derived from the spec formulas.
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

  // Program (word index = address/4):
  //    0 (0x00): ADDI  (x11, x0,  12)  countdown = 12
  //    1 (0x04): ADDI  (x10, x0,   0)  loop counter i = 0
  //    2 (0x08): JAL   (x0,    8)      entry: hop over the exit word -> w4 (forward JAL, rd = x0)
  //    3 (0x0C): JAL   (x0,   16)      loop exit: hop over the body -> w7 (forward JAL, rd = x0)
  //    4 (0x10): ADDI  (x10, x10,  1)  body: i++                (loop head)
  //    5 (0x14): ADDI  (x11, x11, -4)  countdown -= 4
  //    6 (0x18): JALR  (x0, x11,   8)  PC = (x11+8)&~1: x11=8 -> w4 (loop), x11=4 -> w3 (exit)
  //    7 (0x1C): JAL   (x1,   12)      forward jump over poison -> w10; x1 = 0x20 (link)
  //    8 (0x20): ADDI  (x30, x0, 100)  POISON: skipped by w7's JAL
  //    9 (0x24): ADDI  (x31, x0, 200)  POISON: skipped by w7's JAL
  //   10 (0x28): ADDI  (x13, x0,  53)  JALR target 53: bit 0 must be cleared (-> 52 = w13)
  //   11 (0x2C): JALR  (x4, x13,   0)  jump through register -> w13; x4 = 0x30 (link)
  //   12 (0x30): ADDI  (x30, x0, 100)  POISON: skipped by w11's JALR
  //   13 (0x34): ADDI  (x12, x0,   7)  marker: x12 = 7
  //   14 (0x38): ADDI  (x16, x0,  72)  escape target = 0x48 = w18
  //   15 (0x3C): JAL   (x0,    8)      hop over the escape JALR -> w17
  //   16 (0x40): JALR  (x0, x16,   0)  escape (reached only via the backward JAL) -> w18
  //   17 (0x44): JAL   (x3,   -4)      BACKWARD JAL -> w16; x3 = 0x48 (link)
  //   18 (0x48): ADDI  (x12, x12,  1)  x12 = 8: proves the whole chain ran
  //   19 (0x4C): EBREAK()             halt, PC frozen at 0x4C
  `include "riscv_assembly.v"
  initial begin
    ADDI(x11, x0, 12);
    ADDI(x10, x0, 0);
    JAL(x0, 8);
    JAL(x0, 16);
    ADDI(x10, x10, 1);
    ADDI(x11, x11, -4);
    JALR(x0, x11, 8);
    JAL(x1, 12);
    ADDI(x30, x0, 100);
    ADDI(x31, x0, 200);
    ADDI(x13, x0, 53);
    JALR(x4, x13, 0);
    ADDI(x30, x0, 100);
    ADDI(x12, x0, 7);
    ADDI(x16, x0, 72);
    JAL(x0, 8);
    JALR(x0, x16, 0);
    JAL(x3, -4);
    ADDI(x12, x12, 1);
    EBREAK();
    endASM();
  end

  // Hand-assembled words the macros must produce (spec formulas:
  // J-type {imm[20]|imm[10:1]|imm[11]|imm[19:12]|rd|0x6F},
  // I-type {imm|rs1|f3|rd|0x67}). Straight-line literal checks: a
  // CHECK_EQ loop over MEM[i] with an expWord(i) function call misbehaved
  // under iverilog in this bench (reads came out compressed / the function
  // always returned its default) — see PROGRESS.md.
  reg [31:0] pc0;
  reg [1:0]  state0;

  initial begin
    // Reset: PC held at 0, fetch strobe already presenting word 0.
    repeat (3) begin
      @(posedge clk); #1;
      `CHECK_EQ(dut.PC, 32'd0, "PC held at 0 during reset")
    end
    `CHECK_EQ(mem_rstrb, 1'b1, "strobe high while reset holds the FSM in FETCH_INSTR")
    resetn = 1;

    // Free-run the whole program (20 executed instructions x 3 cycles) into
    // the EBREAK halt at word 19 (0x4C).
    repeat (120) @(posedge clk);
    #1;
    `CHECK_EQ(mem_rstrb, 1'b0, "no fetch strobe while halted")
    `CHECK_EQ(dut.PC, 32'h4C, "halted at the EBREAK address 19*4")
    `CHECK_EQ(dut.state, 2'd2, "halted in EXECUTE")

    pc0    = dut.PC;
    state0 = dut.state;
    repeat (5) begin
      @(posedge clk); #1;
      `CHECK_EQ(dut.PC, pc0, "PC frozen after EBREAK")
      `CHECK_EQ(dut.state, state0, "state stays put after EBREAK")
      `CHECK_EQ(mem_rstrb, 1'b0, "no fetch strobe while halted")
    end

    // Register file results, by hierarchical reference. Link values are
    // hand-computed: JAL/JALR at byte address A leave rd = A + 4.
    `CHECK_EQ(dut.RegisterBank[0],  32'd0,        "x0: JAL/JALR with rd=x0 wrote no link")
    `CHECK_EQ(dut.RegisterBank[1],  32'h20,       "x1 = 0x20: link of the forward JAL at 0x1C")
    `CHECK_EQ(dut.RegisterBank[3],  32'h48,       "x3 = 0x48: link of the backward JAL at 0x44")
    `CHECK_EQ(dut.RegisterBank[4],  32'h30,       "x4 = 0x30: link of the JALR at 0x2C")
    `CHECK_EQ(dut.RegisterBank[10], 32'd2,        "x10 = 2: the JALR loop ran exactly two iterations")
    `CHECK_EQ(dut.RegisterBank[11], 32'd4,        "x11 = 4: countdown 12 - 4 - 4 at loop exit")
    `CHECK_EQ(dut.RegisterBank[12], 32'd8,        "x12 = 8: marker 7 then +1, whole jump chain ran")
    `CHECK_EQ(dut.RegisterBank[13], 32'd53,       "x13 = 53: JALR target reg (bit 0 cleared internally)")
    `CHECK_EQ(dut.RegisterBank[16], 32'd72,       "x16 = 72: escape target for the backward-JAL cycle")
    `CHECK_EQ(dut.RegisterBank[30], 32'd0,        "x30 poison: skipped by the forward JAL and the JALR")
    `CHECK_EQ(dut.RegisterBank[31], 32'd0,        "x31 poison: skipped by the forward JAL")
    `CHECK_EQ(x1_out, 32'h20, "x1 output mirror follows the JAL link write")

    // The assembler macros produced exactly the hand-assembled words
    // (every word checked; jump words are the interesting ones).
    `CHECK_EQ(MEM[0],  32'h00C00593, "addi x11,x0,12")
    `CHECK_EQ(MEM[1],  32'h00000513, "addi x10,x0,0")
    `CHECK_EQ(MEM[2],  32'h0080006F, "jal x0,8 (imm[10:1]=4 -> 4<<21)")
    `CHECK_EQ(MEM[3],  32'h0100006F, "jal x0,16")
    `CHECK_EQ(MEM[4],  32'h00150513, "addi x10,x10,1")
    `CHECK_EQ(MEM[5],  32'hFFC58593, "addi x11,x11,-4")
    `CHECK_EQ(MEM[6],  32'h00858067, "jalr x0,8(x11)")
    `CHECK_EQ(MEM[7],  32'h00C000EF, "jal x1,12 (imm[10:1]=6 -> 6<<21 | 1<<7)")
    `CHECK_EQ(MEM[8],  32'h06400F13, "addi x30,x0,100")
    `CHECK_EQ(MEM[9],  32'h0C800F93, "addi x31,x0,200")
    `CHECK_EQ(MEM[10], 32'h03500693, "addi x13,x0,53")
    `CHECK_EQ(MEM[11], 32'h00068267, "jalr x4,0(x13) (13<<15 | 4<<7 | 0x67)")
    `CHECK_EQ(MEM[12], 32'h06400F13, "addi x30,x0,100")
    `CHECK_EQ(MEM[13], 32'h00700613, "addi x12,x0,7")
    `CHECK_EQ(MEM[14], 32'h04800813, "addi x16,x0,72")
    `CHECK_EQ(MEM[15], 32'h0080006F, "jal x0,8")
    `CHECK_EQ(MEM[16], 32'h00080067, "jalr x0,0(x16) (16<<15 | 0x67)")
    `CHECK_EQ(MEM[17], 32'hFFDFF1EF, "jal x3,-4 (anchored on jal x0,-8 = 0xFF9FF06F)")
    `CHECK_EQ(MEM[18], 32'h00160613, "addi x12,x12,1")
    `CHECK_EQ(MEM[19], 32'h00100073, "ebreak")

    `DONE
  end
endmodule
`default_nettype wire
