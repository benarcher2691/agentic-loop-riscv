`timescale 1ns/1ps
`default_nettype none
// Memory: synchronous read, word addressing via mem_addr[9:2], read strobe
// with hold while low. Words 0..5 hold the SOC's ADDI demo program, generated
// by the assembler tasks in rtl/memory.v; the bench keeps a hand-assembled
// independent copy and cross-checks it. Words 6..255 are filled by the bench
// so the whole 256-word address space can be exercised.
module memory_tb;
  `include "check.vh"
  `WATCHDOG(1_000_000)

  reg         clk = 0;
  reg  [31:0] mem_addr = 32'd0;
  wire [31:0] mem_rdata;
  reg         mem_rstrb = 0;

  Memory dut (.clk(clk), .mem_addr(mem_addr), .mem_rdata(mem_rdata), .mem_rstrb(mem_rstrb));

  always #10 clk = ~clk;

  // Hand-assembled copy of the ROM program (must match rtl/memory.v).
  reg [31:0] EXP [0:5];
  initial begin
    EXP[0] = 32'h00100093;  // addi x1,x0,1
    EXP[1] = 32'h00208093;  // addi x1,x1,2
    EXP[2] = 32'h00408093;  // addi x1,x1,4
    EXP[3] = 32'h00808093;  // addi x1,x1,8
    EXP[4] = 32'h01008093;  // addi x1,x1,16
    EXP[5] = 32'h00100073;  // ebreak
  end

  // Expected read for word w: program words 0..5, bench fill pattern above.
  function [31:0] expWord(input integer w);
    if (w < 6) expWord = EXP[w];
    else       expWord = 32'hDEAD0000 + w;
  endfunction

  integer i, k, off;

  // Fill words 6..255 so the whole address space is readable (the ROM's own
  // initial block only touches 0..5, so the two cannot collide).
  initial begin
    for (i = 6; i < 256; i = i + 1)
      dut.MEM[i] = 32'hDEAD0000 + i;
  end

  initial begin
    // Settle: t=0 initial blocks in other modules must have run before we
    // look at dut.MEM.
    repeat (2) @(posedge clk); #1;

    // The bench copy and the ROM must agree.
    for (i = 0; i < 6; i = i + 1)
      `CHECK_EQ(dut.MEM[i], EXP[i], "ROM word matches the bench's hand-assembled copy")

    // Word addressing: byte address 4*w selects word w, over the whole space.
    for (i = 0; i < 256; i = i + 1) begin
      mem_rstrb = 1;
      mem_addr  = i*4;
      @(posedge clk); #1;
      `CHECK_EQ(mem_rdata, expWord(i), "word read at byte address 4*w")
    end

    // Unaligned byte offsets are ignored: 4*w+1..3 read the same word.
    for (i = 0; i < 256; i = i + 1)
      for (off = 1; off <= 3; off = off + 1) begin
        mem_addr = i*4 + off;
        @(posedge clk); #1;
        `CHECK_EQ(mem_rdata, expWord(i), "byte offset within the word is ignored")
      end

    // Address bits above [9:2] are ignored (0x4000000C is word 3 again).
    mem_addr = 32'h4000_000C;
    @(posedge clk); #1;
    `CHECK_EQ(mem_rdata, expWord(3), "address bits above [9:2] are ignored")

    // Synchronous read: a new address does nothing until the next clock edge.
    // (Last read above was word 3; the edge for word 7 has not happened yet.)
    mem_addr = 32'd28;   // word 7
    #1;                  // no clock edge since the last read
    `CHECK_EQ(mem_rdata, expWord(3), "no read without a clock edge")
    @(posedge clk); #1;
    `CHECK_EQ(mem_rdata, expWord(7), "read completes on the clock edge")

    // Strobe low: rdata holds across edges while the address keeps moving.
    mem_rstrb = 0;
    for (k = 0; k < 4; k = k + 1) begin
      mem_addr = k*4;
      @(posedge clk); #1;
      `CHECK_EQ(mem_rdata, expWord(7), "rdata holds when strobe is low")
    end

    // Strobe high again: the addressed word appears.
    mem_rstrb = 1;
    mem_addr  = 32'd40;  // word 10
    @(posedge clk); #1;
    `CHECK_EQ(mem_rdata, expWord(10), "read resumes when strobe goes high")

    `DONE
  end
endmodule
`default_nettype wire
