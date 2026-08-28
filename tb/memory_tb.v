`timescale 1ns/1ps
`default_nettype none
// Memory: synchronous read, word addressing via mem_addr[9:2], read strobe
// with hold while low. The ROM program constants are duplicated here as an
// independent copy; the cross-check against dut.MEM catches the two copies
// drifting apart.
module memory_tb;
  `include "check.vh"
  `WATCHDOG(100_000)

  reg         clk = 0;
  reg  [31:0] mem_addr = 32'd0;
  wire [31:0] mem_rdata;
  reg         mem_rstrb = 0;

  Memory dut (.clk(clk), .mem_addr(mem_addr), .mem_rdata(mem_rdata), .mem_rstrb(mem_rstrb));

  always #10 clk = ~clk;

  // Independent copy of the ROM program (must match rtl/memory.v).
  reg [31:0] EXP [0:15];
  initial begin
    EXP[0]  = 32'h00000001;
    EXP[1]  = 32'h00000002;
    EXP[2]  = 32'h00000004;
    EXP[3]  = 32'h00000008;
    EXP[4]  = 32'h00000010;
    EXP[5]  = 32'h00000015;
    EXP[6]  = 32'h0000000A;
    EXP[7]  = 32'hDEADBEEF;
    EXP[8]  = 32'h0000001F;
    EXP[9]  = 32'h00000000;
    EXP[10] = 32'h80000015;
    EXP[11] = 32'h7FFFFFFF;
    EXP[12] = 32'h0000000C;
    EXP[13] = 32'h00000003;
    EXP[14] = 32'h00000018;
    EXP[15] = 32'hCAFEBABE;
  end

  integer i, k, off;

  initial begin
    // Settle: t=0 initial blocks in other modules must have run before we
    // look at dut.MEM.
    repeat (2) @(posedge clk); #1;

    // The bench copy and the ROM must agree.
    for (i = 0; i < 16; i = i + 1)
      `CHECK_EQ(dut.MEM[i], EXP[i], "ROM word matches the bench's independent copy")

    // Word addressing: byte address 4*w selects word w.
    for (i = 0; i < 16; i = i + 1) begin
      mem_rstrb = 1;
      mem_addr  = i*4;
      @(posedge clk); #1;
      `CHECK_EQ(mem_rdata, EXP[i], "word read at byte address 4*w")
    end

    // Unaligned byte offsets are ignored: 4*w+1..3 read the same word.
    for (i = 0; i < 16; i = i + 1)
      for (off = 1; off <= 3; off = off + 1) begin
        mem_addr = i*4 + off;
        @(posedge clk); #1;
        `CHECK_EQ(mem_rdata, EXP[i], "byte offset within the word is ignored")
      end

    // Address bits above [9:2] are ignored (0x4000000C is word 3 again).
    mem_addr = 32'h4000_000C;
    @(posedge clk); #1;
    `CHECK_EQ(mem_rdata, EXP[3], "address bits above [9:2] are ignored")

    // Synchronous read: a new address does nothing until the next clock edge.
    // (Last read above was word 3; the edge for word 7 has not happened yet.)
    mem_addr = 32'd28;   // word 7
    #1;                  // no clock edge since the last read
    `CHECK_EQ(mem_rdata, EXP[3], "no read without a clock edge")
    @(posedge clk); #1;
    `CHECK_EQ(mem_rdata, EXP[7], "read completes on the clock edge")

    // Strobe low: rdata holds across edges while the address keeps moving.
    mem_rstrb = 0;
    for (k = 0; k < 4; k = k + 1) begin
      mem_addr = k*4;
      @(posedge clk); #1;
      `CHECK_EQ(mem_rdata, EXP[7], "rdata holds when strobe is low")
    end

    // Strobe high again: the addressed word appears.
    mem_rstrb = 1;
    mem_addr  = 32'd40;  // word 10
    @(posedge clk); #1;
    `CHECK_EQ(mem_rdata, EXP[10], "read resumes when strobe goes high")

    `DONE
  end
endmodule
`default_nettype wire
