`timescale 1ns/1ps
`default_nettype none
// Processor part 1: fetch machine (FETCH_INSTR -> FETCH_REGS -> EXECUTE),
// register bank with x0 hardwired to 0, ADDI as the only rd-writing
// instruction, every other class a NOP that still advances PC, EBREAK halt.
// The bench brings its own memory model (sync read, strobe-gated) and its own
// program, built with the assembler macros and cross-checked word by word
// against hand-assembled hex. Registers are checked by hierarchical reference.
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

  // Program (word index = address/4):
  //   0: ADDI(x1, x0,  5)   x1  = 5
  //   1: ADDI(x2, x1,  7)   x2  = 12
  //   2: ADDI(x3, x2, -3)   x3  = 9    (negative immediate)
  //   3: ADDI(x0, x0,  5)   x0 must stay 0
  //   4: ADD (x5, x1, x2)   not ADDI: NOP, PC still advances
  //   5: LUI (x6, 0x12345000)  not ADDI: NOP, PC still advances
  //   6: EBREAK()           halt, PC frozen at 24
  `include "riscv_assembly.v"
  initial begin
    ADDI(x1, x0, 5);
    ADDI(x2, x1, 7);
    ADDI(x3, x2, -3);
    ADDI(x0, x0, 5);
    ADD(x5, x1, x2);
    LUI(x6, 32'h12345000);   // lib LUI takes the final rd value -> lui x6,0x12345
    EBREAK();
    endASM();
  end

  // Hand-assembled words the macros must produce.
  function [31:0] expWord(input integer w);
    case (w)
      0: expWord = 32'h00500093;  // addi x1,x0,5
      1: expWord = 32'h00708113;  // addi x2,x1,7
      2: expWord = 32'hFFD10193;  // addi x3,x2,-3
      3: expWord = 32'h00500013;  // addi x0,x0,5
      4: expWord = 32'h002082B3;  // add  x5,x1,x2
      5: expWord = 32'h12345337;  // lui  x6,0x12345
      6: expWord = 32'h00100073;  // ebreak
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

    // Walk the six executed instructions, three cycles each, checking the
    // fetch strobe and the PC every step of the way.
    for (i = 0; i < 6; i = i + 1) begin
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

    // EBREAK: fetched like any instruction at PC = 24, then the machine halts.
    `CHECK_EQ(mem_rstrb, 1'b1, "EBREAK is fetched like any instruction")
    `CHECK_EQ(mem_addr, 32'd24, "EBREAK sits at address 24")
    @(posedge clk); #1;
    @(posedge clk); #1;
    pc0    = dut.PC;
    state0 = dut.state;
    repeat (20) begin
      @(posedge clk); #1;
      `CHECK_EQ(dut.PC, pc0, "PC frozen after EBREAK")
      `CHECK_EQ(dut.state, state0, "state stays put after EBREAK")
      `CHECK_EQ(mem_rstrb, 1'b0, "no fetch strobe while halted")
    end

    // Register file results, by hierarchical reference.
    `CHECK_EQ(dut.RegisterBank[1], 32'd5,  "x1 = 5")
    `CHECK_EQ(dut.RegisterBank[2], 32'd12, "x2 = 5 + 7 = 12")
    `CHECK_EQ(dut.RegisterBank[3], 32'd9,  "x3 = 12 - 3 = 9 (negative immediate)")
    `CHECK_EQ(dut.RegisterBank[0], 32'd0,  "x0 still 0 after ADDI x0,x0,5")
    `CHECK_EQ(dut.RegisterBank[5], 32'd0,  "ADD is a NOP: x5 untouched")
    `CHECK_EQ(dut.RegisterBank[6], 32'd0,  "LUI is a NOP: x6 untouched")
    `CHECK_EQ(x1_out, 32'd5, "x1 output mirrors RegisterBank[1]")

    // The assembler macros produced exactly the hand-assembled words.
    for (w = 0; w < 7; w = w + 1)
      `CHECK_EQ(MEM[w], expWord(w), "assembler word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
