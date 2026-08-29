`timescale 1ns/1ps
`default_nettype none
// LUI and AUIPC: rd <= Uimm and rd <= PC + Uimm.
//
//   word 0 (0):  LUI   x5, 0x80000000  x5 = 0x80000000 (bit 31 set)
//   word 1 (4):  LUI   x6, 0x12345000  x6 = 0x12345000
//   word 2 (8):  ADDI  x6, x6, 0x678   x6 = 0x12345678 (full 32-bit constant)
//   word 3 (12): AUIPC x7, 0x00001000  x7 = 12 + 0x1000      = 0x0000100C
//   word 4 (16): AUIPC x8, 0xFFFFF000  x8 = 16 + 0xFFFFF000  = 0xFFFFF010
//   word 5 (20): AUIPC x9, 0x00001000  x9 = 20 + 0x1000      = 0x00001014
//   word 6 (24): LUI   x0, 0xFFFFF000  x0 stays 0 (rd = x0 dropped)
//   word 7 (28): EBREAK
//
// x7 and x9 use the SAME Uimm at PCs 12 and 20: the results differ by
// exactly the PC difference (0x101C - 0x1014 = 8), which isolates the
// PC + Uimm behaviour from the immediate itself.
module lui_auipc_tb;
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
    LUI(x5, 32'h80000000);     // word 0: bit 31 set
    LUI(x6, 32'h12345000);     // word 1: upper half of a full constant
    ADDI(x6, x6, 32'h678);     // word 2: + 0x678 -> 0x12345678
    AUIPC(x7, 32'h00001000);   // word 3: at PC 12
    AUIPC(x8, 32'hFFFFF000);   // word 4: at PC 16, Uimm bit 31 set
    AUIPC(x9, 32'h00001000);   // word 5: same Uimm as word 3, at PC 20
    LUI(x0, 32'hFFFFF000);     // word 6: write to x0 must be dropped
    EBREAK();                  // word 7
    endASM();
  end

  integer g;

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

  // Hand-assembled words the macros must produce (U-type spec formula:
  // imm[31:12] | rd | opcode).
  function [31:0] expWord(input integer w);
    case (w)
      0: expWord = 32'h800002B7;  // lui   x5,0x80000  (rd=5<<7 = 0x280)
      1: expWord = 32'h12345337;  // lui   x6,0x12345  (rd=6<<7 = 0x300)
      2: expWord = 32'h67830313;  // addi  x6,x6,0x678
      3: expWord = 32'h00001397;  // auipc x7,0x1      (rd=7<<7 = 0x380)
      4: expWord = 32'hFFFFF417;  // auipc x8,0xFFFFF  (rd=8<<7 = 0x400)
      5: expWord = 32'h00001497;  // auipc x9,0x1      (rd=9<<7 = 0x480)
      6: expWord = 32'hFFFFF037;  // lui   x0,0xFFFFF  (rd=0)
      7: expWord = 32'h00100073;  // ebreak
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

    // Walk 1: LUI x5 at PC 0 — write data is the immediate itself.
    pollExecute(32'd0);
    `CHECK_EQ(dut.isLUI,   1'b1,        "LUI decoded")
    `CHECK_EQ(dut.Uimm,    32'h80000000, "Uimm = 0x80000000 (bit 31 set)")
    `CHECK_EQ(dut.wrEn,    1'b1,        "LUI writes rd")
    `CHECK_EQ(dut.wrData,  32'h80000000, "LUI write data = Uimm, not the ALU output")
    @(posedge clk); #1;
    `CHECK_EQ(dut.PC, 32'd4, "LUI: PC advanced by 4")

    // Walk 2: AUIPC x7 at PC 12 — write data is PC + Uimm.
    pollExecute(32'd12);
    `CHECK_EQ(dut.isAUIPC, 1'b1,         "AUIPC decoded")
    `CHECK_EQ(dut.Uimm,    32'h00001000, "AUIPC Uimm = 0x1000")
    `CHECK_EQ(dut.wrData,  32'd12 + 32'h1000, "AUIPC write data = PC (12) + Uimm")
    @(posedge clk); #1;
    `CHECK_EQ(dut.PC, 32'd16, "AUIPC: PC advanced by 4")

    // Free-run into the final EBREAK at 28.
    waitHalt(32'd28);
    repeat (5) begin
      @(posedge clk); #1;
      `CHECK_EQ(dut.PC, 32'd28, "PC frozen at the EBREAK")
    end
    `CHECK_EQ(mem_rstrb, 1'b0, "no fetch strobe while halted")

    // Register file results, by hierarchical reference. All hand-computed.
    `CHECK_EQ(dut.RegisterBank[5], 32'h80000000, "LUI bit 31 set: x5 = 0x80000000")
    `CHECK_EQ(dut.RegisterBank[6], 32'h12345678, "LUI 0x12345000 + ADDI 0x678 = full constant 0x12345678")
    `CHECK_EQ(dut.RegisterBank[7], 32'h0000100C, "AUIPC at PC 12: 12 + 0x1000 = 0x100C")
    `CHECK_EQ(dut.RegisterBank[8], 32'hFFFFF010, "AUIPC at PC 16 with Uimm bit 31 set: 16 + 0xFFFFF000 = 0xFFFFF010")
    `CHECK_EQ(dut.RegisterBank[9], 32'h00001014, "AUIPC at PC 20, same Uimm: 20 + 0x1000 = 0x1014")
    `CHECK_EQ(dut.RegisterBank[9] - dut.RegisterBank[7], 32'd8,
              "same Uimm at PCs 12 and 20: results differ by exactly the PC difference")
    `CHECK_EQ(dut.RegisterBank[0], 32'd0, "LUI to x0 dropped: x0 still 0")

    // The assembler macros produced exactly the hand-assembled words.
    for (w = 0; w < 8; w = w + 1)
      `CHECK_EQ(MEM[w], expWord(w), "assembler word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire