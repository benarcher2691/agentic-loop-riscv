`timescale 1ns/1ps
`default_nettype none
// T2 regression (audit A1 major / A2): a load or store whose effective
// address is misaligned for its width, or points outside the machine, must
// halt the CPU exactly like EBREAK: state frozen in EXECUTE, PC frozen,
// rd not written — and, unlike the SYSTEM halt, no read strobe and no write
// mask (they are asserted combinationally during EXECUTE; an ungated read
// of the RX word would clear rxAvail, an ungated store would commit).
//
// Bad cases (each a small program reached through a JAL trampoline, because
// the halt is permanent and only a reset recovers):
//   LW/SW at addr[1:0] = 1/2/3, LH/LHU/SH at addr[0] = 1 (in-range RAM),
//   aligned and byte accesses at 0x1800 (first address past the 6 KB RAM),
//   0x2000/0x4000 (alias region: bits [21:13] set), 0x80000000 (bit 31),
//   and misaligned accesses in IO space (bit 22 set).
// Boundary-good cases: LW/LH/LHU/LB/LBU at the top of RAM (0x17FC..0x17FF),
// LW at 0x0000, SW at 0x17F8, and ALIGNED IO-space accesses (bit 22 set)
// which must NOT halt. A poison marker after the access proves the CPU
// never continued past a bad access.
module badaddr_tb;
  `include "check.vh"
  `WATCHDOG(2_000_000)

  reg clk = 0;
  reg resetn = 0;
  always #5 clk = ~clk;

  wire [31:0] mem_addr;
  wire        mem_rstrb;
  wire [31:0] mem_wdata;
  wire [3:0]  mem_wmask;

  // Bench memory, same contract as rtl/Memory: 6 KB, synchronous read of
  // MEM[addr[12:2]] while the strobe is high, per-byte writes. Like the
  // real thing, a word index >= 1536 reads X and its writes vanish, so the
  // pre-fix symptoms (X loads, vanishing stores) are reproduced exactly.
  reg [31:0] MEM [0:1535];
  reg [31:0] mem_rdata;
  always @(posedge clk) if (mem_rstrb) mem_rdata <= MEM[mem_addr[12:2]];
  always @(posedge clk) begin
    if (mem_wmask[0]) MEM[mem_addr[12:2]][ 7: 0] <= mem_wdata[ 7: 0];
    if (mem_wmask[1]) MEM[mem_addr[12:2]][15: 8] <= mem_wdata[15: 8];
    if (mem_wmask[2]) MEM[mem_addr[12:2]][23:16] <= mem_wdata[23:16];
    if (mem_wmask[3]) MEM[mem_addr[12:2]][31:24] <= mem_wdata[31:24];
  end

  Processor dut (.clk(clk), .resetn(resetn), .mem_addr(mem_addr),
                 .mem_rdata(mem_rdata), .mem_rstrb(mem_rstrb),
                 .mem_wdata(mem_wdata), .mem_wmask(mem_wmask));

  // Independent J-type encoder (cross-checks the trampolines the lib emits:
  // JAL = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 1101111}).
  function [31:0] encJ(input integer off, input [4:0] rd);
    encJ = {off[20], off[10:1], off[11], off[19:12], rd, 7'b1101111};
  endfunction

  `include "riscv_assembly.v"
  integer i, k;
  integer nCases;
  integer caseBase [0:31];   // byte address of each case routine
  integer accPC    [0:31];   // byte address of the access instruction
  reg [31:0] pcHold;

  // Run one case: point the word-0 trampoline at the case (PC resets to 0,
  // so MEM[0] selects the routine), reset (registers persist), then free-run
  // through the trampoline, the setup and the access, and let it settle.
  task tRun(input integer idx);
    begin
      MEM[0] = encJ(caseBase[idx], 5'd0);
      resetn = 0;
      @(posedge clk); #1;
      resetn = 1;
      repeat (90) @(posedge clk);
      #1;
    end
  endtask

  // The six universal halt checks, run right after tRun on a bad case.
  task tHaltCheck(input integer atPC);
    begin
      `CHECK_EQ(dut.state, 2'd2, "halted in EXECUTE")
      `CHECK_EQ(dut.PC, atPC, "PC frozen at the bad access")
      pcHold = dut.PC;
      repeat (25) @(posedge clk); #1;
      `CHECK_EQ(dut.PC, pcHold, "PC still frozen 25 cycles later (>=20)")
      `CHECK_EQ(dut.state, 2'd2, "still EXECUTE: halt is permanent")
      `CHECK_EQ(mem_rstrb, 1'b0, "no read strobe while halted")
      `CHECK_EQ(mem_wmask, 4'b0000, "no write strobe while halted")
    end
  endtask

  initial begin
    for (i = 0; i < 1536; i = i + 1) MEM[i] = 32'hA5A5A5A5;  // poison
    MEM[64]   = 32'hA5A5A5A5;   // canary: a store at 0x101 would hit word 0x40
    MEM[272]  = 32'h5E5E5E5E;   // canary: a store at 0x2440 aliases to word 272
    MEM[288]  = 32'hC0FFEE01;   // read by the aligned IO-space load (0x400480)
    MEM[304]  = 32'hA5A5A5A5;   // written by the aligned IO-space store (0x4004C0)
    MEM[1534] = 32'hA5A5A5A5;   // boundary-good SW target (0x17F8)
    MEM[1535] = 32'hFF839E7F;   // boundary-good loads: bytes 7F 9E 83 FF
    nCases = 0;
    memPC = 1280;               // cases start at word 320: clear of the canary
                                // words (64, 272, 288, 304) dictated by the
                                // test addresses, and of 1534/1535

    // ---- bad loads (rd = x10, sentinel 0x123) ----
    // 0: LW at 0x101 — word misaligned (addr[1:0] = 01), in range
    caseBase[0] = memPC;
    ADDI(x1, x0, 256);
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[0] = memPC;
    LW(x10, x1, 1);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 1: LW at 0x102 — word misaligned (addr[1:0] = 10)
    caseBase[1] = memPC;
    ADDI(x1, x0, 256);
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[1] = memPC;
    LW(x10, x1, 2);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 2: LW at 0x103 — word misaligned (addr[1:0] = 11)
    caseBase[2] = memPC;
    ADDI(x1, x0, 256);
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[2] = memPC;
    LW(x10, x1, 3);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 3: LH at 0x101 — halfword misaligned (addr[0] = 1)
    caseBase[3] = memPC;
    ADDI(x1, x0, 256);
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[3] = memPC;
    LH(x10, x1, 1);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 4: LHU at 0x101 — halfword misaligned, unsigned form
    caseBase[4] = memPC;
    ADDI(x1, x0, 256);
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[4] = memPC;
    LHU(x10, x1, 1);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 5: LW at 0x1800 — first word past the 6 KB RAM (aligned, out of range)
    caseBase[5] = memPC;
    LUI(x1, 32'h00002000);
    ADDI(x1, x1, -32'h800);   // 0x2000-0x800 = 0x1800
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[5] = memPC;
    LW(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 6: LH at 0x1800 — aligned halfword, out of range
    caseBase[6] = memPC;
    LUI(x1, 32'h00002000);
    ADDI(x1, x1, -32'h800);   // 0x2000-0x800 = 0x1800
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[6] = memPC;
    LH(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 7: LB at 0x1800 — byte accesses are always aligned but can be out of range
    caseBase[7] = memPC;
    LUI(x1, 32'h00002000);
    ADDI(x1, x1, -32'h800);   // 0x2000-0x800 = 0x1800
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[7] = memPC;
    LB(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 8: LBU at 0x1800 — unsigned byte, out of range
    caseBase[8] = memPC;
    LUI(x1, 32'h00002000);
    ADDI(x1, x1, -32'h800);   // 0x2000-0x800 = 0x1800
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[8] = memPC;
    LBU(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 9: LW at 0x2000 — alias region (bit 13 set, bit 22 clear): today this
    //    silently aliases to RAM word 0 instead of halting
    caseBase[9] = memPC;
    LUI(x1, 32'h00002000);
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[9] = memPC;
    LW(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 10: LW at 0x4000 — bit 14 set, bit 22 clear
    caseBase[10] = memPC;
    LUI(x1, 32'h00004000);
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[10] = memPC;
    LW(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 11: LW at 0x80000000 — bit 31 set, bit 22 clear
    caseBase[11] = memPC;
    LUI(x1, 32'h80000000);
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[11] = memPC;
    LW(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 12: LW at 0x400002 — IO space (bit 22 set) but word misaligned
    caseBase[12] = memPC;
    LUI(x1, 32'h00400000);
    ADDI(x1, x1, 2);
    ADDI(x10, x0, 32'h123);
    ADDI(x9, x0, 0);
    accPC[12] = memPC;
    LW(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;

    // ---- bad stores (rs2 = x11, sentinel 0xFFFFFF00) ----
    // 13: SW at 0x101 — word misaligned; would clobber the canary at 0x100
    caseBase[13] = memPC;
    ADDI(x1, x0, 256);
    ADDI(x11, x0, -256);
    ADDI(x9, x0, 0);
    accPC[13] = memPC;
    SW(x11, x1, 1);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 14: SH at 0x101 — halfword misaligned; would clobber canary lanes 1-2
    caseBase[14] = memPC;
    ADDI(x1, x0, 256);
    ADDI(x11, x0, -256);
    ADDI(x9, x0, 0);
    accPC[14] = memPC;
    SH(x11, x1, 1);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 15: SW at 0x1800 — aligned store past the RAM (today it vanishes)
    caseBase[15] = memPC;
    LUI(x1, 32'h00002000);
    ADDI(x1, x1, -32'h800);   // 0x2000-0x800 = 0x1800
    ADDI(x11, x0, -256);
    ADDI(x9, x0, 0);
    accPC[15] = memPC;
    SW(x11, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 16: SB at 0x1800 — byte store, out of range
    caseBase[16] = memPC;
    LUI(x1, 32'h00002000);
    ADDI(x1, x1, -32'h800);   // 0x2000-0x800 = 0x1800
    ADDI(x11, x0, -256);
    ADDI(x9, x0, 0);
    accPC[16] = memPC;
    SB(x11, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 17: SW at 0x2440 — alias region store: today it lands on RAM word 272
    caseBase[17] = memPC;
    LUI(x1, 32'h00002000);
    ADDI(x1, x1, 32'h440);   // 0x2000+0x440 = 0x2440
    ADDI(x11, x0, -256);
    ADDI(x9, x0, 0);
    accPC[17] = memPC;
    SW(x11, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 18: SH at 0x400001 — IO space but halfword misaligned
    caseBase[18] = memPC;
    LUI(x1, 32'h00400000);
    ADDI(x1, x1, 1);
    ADDI(x11, x0, -256);
    ADDI(x9, x0, 0);
    accPC[18] = memPC;
    SH(x11, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;

    // ---- boundary-good cases (must NOT halt) ----
    // 19: LW at 0x17FC — the last word of RAM
    caseBase[19] = memPC;
    LUI(x1, 32'h00001000);
    ADDI(x1, x1, 32'h7FC);   // 0x1000+0x7FC = 0x17FC
    ADDI(x9, x0, 0);
    accPC[19] = memPC;
    LW(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 20: LH at 0x17FE — the last halfword (top half of the last word)
    caseBase[20] = memPC;
    LUI(x1, 32'h00001000);
    ADDI(x1, x1, 32'h7FE);   // 0x1000+0x7FE = 0x17FE
    ADDI(x9, x0, 0);
    accPC[20] = memPC;
    LH(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 21: LHU at 0x17FE — unsigned form
    caseBase[21] = memPC;
    LUI(x1, 32'h00001000);
    ADDI(x1, x1, 32'h7FE);   // 0x1000+0x7FE = 0x17FE
    ADDI(x9, x0, 0);
    accPC[21] = memPC;
    LHU(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 22: LB at 0x17FF — the last byte (0xFF, sign-extends)
    caseBase[22] = memPC;
    LUI(x1, 32'h00001000);
    ADDI(x1, x1, 32'h7FF);   // 0x1000+0x7FF = 0x17FF
    ADDI(x9, x0, 0);
    accPC[22] = memPC;
    LB(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 23: LBU at 0x17FF — unsigned form
    caseBase[23] = memPC;
    LUI(x1, 32'h00001000);
    ADDI(x1, x1, 32'h7FF);   // 0x1000+0x7FF = 0x17FF
    ADDI(x9, x0, 0);
    accPC[23] = memPC;
    LBU(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 24: LW at 0x0000 — the first word (trampoline 0, a JAL)
    caseBase[24] = memPC;
    ADDI(x1, x0, 0);
    ADDI(x9, x0, 0);
    accPC[24] = memPC;
    LW(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 25: SW at 0x17F8 — aligned store below the top word
    caseBase[25] = memPC;
    LUI(x1, 32'h00001000);
    ADDI(x1, x1, 32'h7F8);   // 0x1000+0x7F8 = 0x17F8
    ADDI(x11, x0, -256);
    ADDI(x9, x0, 0);
    accPC[25] = memPC;
    SW(x11, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 26: LW at 0x400480 — ALIGNED IO-space load must not halt
    caseBase[26] = memPC;
    LUI(x1, 32'h00400000);
    ADDI(x1, x1, 32'h480);
    ADDI(x9, x0, 0);
    accPC[26] = memPC;
    LW(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 27: SW at 0x4004C0 — ALIGNED IO-space store must not halt
    caseBase[27] = memPC;
    LUI(x1, 32'h00400000);
    ADDI(x1, x1, 32'h4C0);
    ADDI(x11, x0, -256);
    ADDI(x9, x0, 0);
    accPC[27] = memPC;
    SW(x11, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;
    // 28: LW at 0x402000 — bit 22 SET (IO space) and bit 17 set (which
    //     would be out of range if bit 22 were clear): no halt. The bench
    //     model serves the aliased word 0, i.e. the case's own trampoline.
    caseBase[28] = memPC;
    LUI(x1, 32'h00402000);
    ADDI(x9, x0, 0);
    accPC[28] = memPC;
    LW(x10, x1, 0);
    ADDI(x9, x0, 32'h5AA);
    EBREAK();
    nCases = nCases + 1;

    endASM();

    // ================= bad loads =================
    tRun(0); tHaltCheck(accPC[0]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LW 0x101: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LW 0x101: poison marker not executed")

    tRun(1); tHaltCheck(accPC[1]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LW 0x102: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LW 0x102: poison marker not executed")

    tRun(2); tHaltCheck(accPC[2]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LW 0x103: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LW 0x103: poison marker not executed")

    tRun(3); tHaltCheck(accPC[3]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LH 0x101: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LH 0x101: poison marker not executed")

    tRun(4); tHaltCheck(accPC[4]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LHU 0x101: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LHU 0x101: poison marker not executed")

    tRun(5); tHaltCheck(accPC[5]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LW 0x1800: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LW 0x1800: poison marker not executed")

    tRun(6); tHaltCheck(accPC[6]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LH 0x1800: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LH 0x1800: poison marker not executed")

    tRun(7); tHaltCheck(accPC[7]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LB 0x1800: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LB 0x1800: poison marker not executed")

    tRun(8); tHaltCheck(accPC[8]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LBU 0x1800: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LBU 0x1800: poison marker not executed")

    tRun(9); tHaltCheck(accPC[9]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LW 0x2000: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LW 0x2000: poison marker not executed")

    tRun(10); tHaltCheck(accPC[10]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LW 0x4000: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LW 0x4000: poison marker not executed")

    tRun(11); tHaltCheck(accPC[11]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LW 0x80000000: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LW 0x80000000: poison marker not executed")

    tRun(12); tHaltCheck(accPC[12]);
    `CHECK_EQ(dut.RegisterBank[10], 32'h123, "LW 0x400002: rd sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "LW 0x400002: poison marker not executed")

    // ================= bad stores =================
    tRun(13); tHaltCheck(accPC[13]);
    `CHECK_EQ(dut.RegisterBank[11], 32'hFFFFFF00, "SW 0x101: rs2 sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "SW 0x101: poison marker not executed")
    `CHECK_EQ(MEM[64], 32'hA5A5A5A5, "SW 0x101: canary word at 0x100 untouched")

    tRun(14); tHaltCheck(accPC[14]);
    `CHECK_EQ(dut.RegisterBank[11], 32'hFFFFFF00, "SH 0x101: rs2 sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "SH 0x101: poison marker not executed")
    `CHECK_EQ(MEM[64], 32'hA5A5A5A5, "SH 0x101: canary word at 0x100 untouched")

    tRun(15); tHaltCheck(accPC[15]);
    `CHECK_EQ(dut.RegisterBank[11], 32'hFFFFFF00, "SW 0x1800: rs2 sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "SW 0x1800: poison marker not executed")

    tRun(16); tHaltCheck(accPC[16]);
    `CHECK_EQ(dut.RegisterBank[11], 32'hFFFFFF00, "SB 0x1800: rs2 sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "SB 0x1800: poison marker not executed")

    tRun(17); tHaltCheck(accPC[17]);
    `CHECK_EQ(dut.RegisterBank[11], 32'hFFFFFF00, "SW 0x2440: rs2 sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "SW 0x2440: poison marker not executed")
    `CHECK_EQ(MEM[272], 32'h5E5E5E5E, "SW 0x2440: aliased canary word 272 untouched")

    tRun(18); tHaltCheck(accPC[18]);
    `CHECK_EQ(dut.RegisterBank[11], 32'hFFFFFF00, "SH 0x400001: rs2 sentinel preserved")
    `CHECK_EQ(dut.RegisterBank[9], 32'd0, "SH 0x400001: poison marker not executed")
    `CHECK_EQ(MEM[0], encJ(caseBase[18], 5'd0), "SH 0x400001: trampoline not clobbered")

    // ================= boundary-good cases =================
    tRun(19);
    `CHECK_EQ(dut.state, 2'd2, "LW 0x17FC: halted at EBREAK, not before")
    `CHECK_EQ(dut.PC, accPC[19] + 8, "LW 0x17FC: PC reached the EBREAK")
    pcHold = dut.PC;
    repeat (25) @(posedge clk); #1;
    `CHECK_EQ(dut.PC, pcHold, "LW 0x17FC: EBREAK halt is permanent")
    `CHECK_EQ(dut.RegisterBank[9], 32'h5AA, "LW 0x17FC: marker executed")
    `CHECK_EQ(dut.RegisterBank[10], 32'hFF839E7F, "LW 0x17FC: last word loads")

    tRun(20);
    `CHECK_EQ(dut.PC, accPC[20] + 8, "LH 0x17FE: PC reached the EBREAK")
    `CHECK_EQ(dut.RegisterBank[9], 32'h5AA, "LH 0x17FE: marker executed")
    `CHECK_EQ(dut.RegisterBank[10], 32'hFFFFFF83, "LH 0x17FE: top half sign-extends")

    tRun(21);
    `CHECK_EQ(dut.PC, accPC[21] + 8, "LHU 0x17FE: PC reached the EBREAK")
    `CHECK_EQ(dut.RegisterBank[9], 32'h5AA, "LHU 0x17FE: marker executed")
    `CHECK_EQ(dut.RegisterBank[10], 32'h0000FF83, "LHU 0x17FE: top half zero-extends")

    tRun(22);
    `CHECK_EQ(dut.PC, accPC[22] + 8, "LB 0x17FF: PC reached the EBREAK")
    `CHECK_EQ(dut.RegisterBank[9], 32'h5AA, "LB 0x17FF: marker executed")
    `CHECK_EQ(dut.RegisterBank[10], 32'hFFFFFFFF, "LB 0x17FF: last byte 0xFF sign-extends")

    tRun(23);
    `CHECK_EQ(dut.PC, accPC[23] + 8, "LBU 0x17FF: PC reached the EBREAK")
    `CHECK_EQ(dut.RegisterBank[9], 32'h5AA, "LBU 0x17FF: marker executed")
    `CHECK_EQ(dut.RegisterBank[10], 32'h000000FF, "LBU 0x17FF: last byte zero-extends")

    tRun(24);
    `CHECK_EQ(dut.PC, accPC[24] + 8, "LW 0x0000: PC reached the EBREAK")
    `CHECK_EQ(dut.RegisterBank[9], 32'h5AA, "LW 0x0000: marker executed")
    `CHECK_EQ(dut.RegisterBank[10], encJ(caseBase[24], 5'd0), "LW 0x0000: first word (the case's own trampoline JAL) loads")

    tRun(25);
    `CHECK_EQ(dut.PC, accPC[25] + 8, "SW 0x17F8: PC reached the EBREAK")
    `CHECK_EQ(dut.RegisterBank[9], 32'h5AA, "SW 0x17F8: marker executed")
    `CHECK_EQ(MEM[1534], 32'hFFFFFF00, "SW 0x17F8: store landed at 0x17F8")

    tRun(26);
    `CHECK_EQ(dut.PC, accPC[26] + 8, "LW 0x400480: PC reached the EBREAK")
    `CHECK_EQ(dut.RegisterBank[9], 32'h5AA, "LW 0x400480: marker executed")
    `CHECK_EQ(dut.RegisterBank[10], 32'hC0FFEE01, "LW 0x400480: aligned IO load works")

    tRun(27);
    `CHECK_EQ(dut.PC, accPC[27] + 8, "SW 0x4004C0: PC reached the EBREAK")
    `CHECK_EQ(dut.RegisterBank[9], 32'h5AA, "SW 0x4004C0: marker executed")
    `CHECK_EQ(MEM[304], 32'hFFFFFF00, "SW 0x4004C0: aligned IO store works")

    tRun(28);
    `CHECK_EQ(dut.PC, accPC[28] + 8, "LW 0x402000: PC reached the EBREAK")
    `CHECK_EQ(dut.RegisterBank[9], 32'h5AA, "LW 0x402000: marker executed")
    `CHECK_EQ(dut.RegisterBank[10], encJ(caseBase[28], 5'd0), "LW 0x402000: bit 22 set is IO space, not a halt")

    `DONE
  end
endmodule
`default_nettype wire
