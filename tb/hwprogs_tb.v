`timescale 1ns/1ps
`default_nettype none
// Exportable hardware test programs. A set of self-contained RV32I test
// programs is assembled here with the lib macros, uploaded to the resident
// monitor over the serial models (W), run (G), and the result block read
// back (R) and checked against independently computed expectations. Each
// program is loaded at 0x400 and ends by writing a result block at 0x800:
// word 0 is the signature 0x600D0000 | index, words 1..n are the results —
// then it returns with RET (the G caller in the monitor replies 'K').
// Per program the bench also $writememh's the program words and the
// expected result block to build/hwprogs-<name>.prog.hex / .expect.hex ($system
// is unavailable in this iverilog, so the files land directly in build/)
//
// Programs (index: name — what it covers):
//   0: alu    — ALU sweep over 5 fixed vector pairs: ADD SUB SLL SLT SLTU
//               XOR SRL OR AND SRA (50 results; pairs include 0, +1/-1
//               edges, 0x7FFFFFFF/0x80000000, shift amounts 0 and 31).
//   1: ldst   — every load/store width at every ALIGNED offset: LB LBU
//               LH LHU LW over a two-word pattern, SB/SH/SW store-and-
//               readback at every lane (27 results; T2: misaligned or
//               out-of-range accesses halt the CPU, so hardware programs
//               must stay halt-free).
//   2: fibgcd — iterative fib(15) and subtract-Euclid gcd on two pairs
//               (3 results: 610, 21, 6).
//   3: jumpbr — branch torture: taken AND not-taken BEQ/BNE/BLT/BGE/BLTU/
//               BGEU on edge operands, JAL/JALR forward jumps, JALR bit-0
//               clearing, the JAL link value (16 results).
//
// Position-independence: the code is assembled at 0 here but runs at
// 0x400, so only relative branches/jumps (LabelRef) and runtime-computed
// data addresses are used. Data words inside a program are addressed via
// AUIPC(x,0) + ADDI(x, x, LabelRef(L) + 4) — LabelRef is relative to the
// ADDI's own address, hence the +4. Absolute addresses (0x800 results,
// 0x1000 scratch) are fixed RAM addresses, fine under relocation.
module hwprogs_tb;
  `include "check.vh"
  `WATCHDOG(400_000_000)

  reg        CLK = 0;
  reg        RXD = 1;
  wire       TXD;
  wire [4:0] LEDS;

  SOC #(.SLOW(0)) dut (.CLK(CLK), .RXD(RXD), .TXD(TXD), .LEDS(LEDS));

  always #41.667 CLK = ~CLK;   // 12 MHz

  // The emitter's data register has no power-on value (X in RTL sim would
  // stall o_ready forever); one hierarchical write kicks it into idle.
  initial dut.uart.data = 10'd0;

  // ---- serial models (same shape as monitor_tb) ---------------------------
  localparam real BITNS = 1000000000.0 / 115200.0;   // 8680.6 ns per bit

  task recv_byte;
    output [7:0] b;
    integer k;
    begin
      @(negedge TXD);          // start bit edge
      #(BITNS * 1.5);          // centre of data bit 0
      for (k = 0; k < 8; k = k + 1) begin
        b[k] = TXD;            // LSB first
        #(BITNS);
      end
      `CHECK_EQ(TXD, 1'b1, "stop bit is high")
    end
  endtask

  task send_byte;
    input [7:0] b;
    integer k;
    begin
      RXD = 1'b0;              // start bit
      #(BITNS);
      for (k = 0; k < 8; k = k + 1) begin
        RXD = b[k];            // data bits, LSB first
        #(BITNS);
      end
      RXD = 1'b1;              // stop bit
      #(BITNS);
    end
  endtask

  // ---- protocol buffers and exchanges ------------------------------------
  reg [7:0] txbuf [0:1023];    // programs are up to ~500 bytes
  reg [7:0] rxbuf [0:255];

  // Send txlen bytes from txbuf while receiving rxlen bytes into rxbuf.
  // ONE forked pair: the reply's first start bit can land in the mid-stop
  // of the last command byte (a sequential recv would miss the edge).
  task exchange;
    input integer txlen;
    input integer rxlen;
    begin
      fork
        begin : snd
          integer i;
          for (i = 0; i < txlen; i = i + 1) send_byte(txbuf[i]);
        end
        begin : rcv
          integer j;
          for (j = 0; j < rxlen; j = j + 1) recv_byte(rxbuf[j]);
        end
      join
    end
  endtask

  // Fill txbuf[1..4] / txbuf[5..8] with addr / len, little-endian.
  task put_addr_len;
    input [31:0] addr;
    input [31:0] len;
    begin
      txbuf[1] = addr[ 7: 0]; txbuf[2] = addr[15: 8];
      txbuf[3] = addr[23:16]; txbuf[4] = addr[31:24];
      txbuf[5] = len[ 7: 0];  txbuf[6] = len[15: 8];
      txbuf[7] = len[23:16];  txbuf[8] = len[31:24];
    end
  endtask

  task cmd_W;                  // data bytes must already sit in txbuf[9..]
    input [31:0] addr;
    input [31:0] len;
    begin
      txbuf[0] = "W";
      put_addr_len(addr, len);
      exchange(9 + len, 1);
      `CHECK_EQ(rxbuf[0], 8'h4B, "W replies K")
    end
  endtask

  task cmd_R;
    input [31:0] addr;
    input [31:0] len;
    begin
      txbuf[0] = "R";
      put_addr_len(addr, len);
      exchange(9, len);
    end
  endtask

  task cmd_G;
    input [31:0] addr;
    begin
      txbuf[0] = "G";
      put_addr_len(addr, 32'd0);
      exchange(5, 1);
      `CHECK_EQ(rxbuf[0], 8'h4B, "G replies K after the routine returns")
    end
  endtask

  // ---- the programs, assembled with the lib ------------------------------
  // The lib assembles into a module-level array named MEM, one program at
  // a time (memPC reset to 0 between programs); each finished program is
  // copied to prog[] and exported. Labels are discovered on the first run
  // (the lib prints every Label's memPC), then hardcoded below.
  reg [31:0] MEM [0:255];
  `include "../lib/riscv_assembly.v"

  reg [31:0] prog [0:255];     // current program's words
  integer    proglen;          // words in the current program
  reg [31:0] expblk [0:63];    // expected result block (signature + results)
  integer    explen;
  integer    i, j;
  reg [31:0] w;

  // label variables (word/byte offsets from each program's assembly start)
  integer P0LOOP = 32, P0VEC = 176;
  integer LFIB = 36, LFIBD = 60, LG1 = 76, LG1S = 92, LG1D = 100,
          LG2 = 116, LG2S = 132, LG2D = 140;

  // fixed ALU vector pairs (program 0) — the assembly reads the same pairs
  // from DATAW words at the end of the program
  reg [31:0] va [0:4];
  reg [31:0] vb [0:4];

  // upload the current prog[] and run it at 0x400, then read the result
  // block and compare every word against expblk[]
  task run_and_check;
    input [8*32-1:0] name;     // for messages
    input integer    idx;
    begin
      for (i = 0; i < proglen; i = i + 1) begin
        txbuf[9 + 4*i + 0] = prog[i][ 7: 0];
        txbuf[9 + 4*i + 1] = prog[i][15: 8];
        txbuf[9 + 4*i + 2] = prog[i][23:16];
        txbuf[9 + 4*i + 3] = prog[i][31:24];
      end
      cmd_W(32'h00000400, proglen * 4);
      cmd_G(32'h00000400);
      cmd_R(32'h00000800, explen * 4);
      for (i = 0; i < explen; i = i + 1) begin
        w = {rxbuf[4*i+3], rxbuf[4*i+2], rxbuf[4*i+1], rxbuf[4*i]};
        `CHECK_EQ(w, expblk[i], {"result block word ", name})
      end
    end
  endtask

  // ---- test sequence ------------------------------------------------------
  reg [95:0] BANNER_STR = "Loop RISC-V\n";  // first char in the MSBs
  reg  [7:0] banner [0:11];
  reg  [7:0] b;
  reg [31:0] e;                // expectation scratch
  reg [31:0] p0, p1;           // load/store pattern words (program 1)
  reg [31:0] fib_ref, gcd1_ref, gcd2_ref;   // program 2 reference models
  reg [31:0] bop [0:12];       // program 3 branch-test table: 0 BEQ, 1 BNE,
  reg [31:0] ba  [0:12];       // 2 BLT, 3 BGE, 4 BLTU, 5 BGEU
  reg [31:0] bb  [0:12];

  initial begin
    for (i = 0; i < 12; i = i + 1)
      banner[i] = BANNER_STR[(11-i)*8 +: 8];

    // ($system is unavailable in this iverilog — the hex files land directly in build/)

    `CHECK_EQ(TXD, 1'b1, "TXD idles high before the first byte")

    // Banner: 12 bytes, in order, clean framing.
    for (i = 0; i < 12; i = i + 1) begin
      recv_byte(b);
      `CHECK_EQ(b, banner[i], "banner byte received in order")
    end

    // ===== program 0: alu — ALU sweep over fixed vectors ==================
    va[0] = 32'h00000000; vb[0] = 32'h00000000;
    va[1] = 32'h7FFFFFFF; vb[1] = 32'h00000001;
    va[2] = 32'h80000000; vb[2] = 32'h80000000;
    va[3] = 32'hDEADBEEF; vb[3] = 32'h0000FFFF;
    va[4] = 32'h00000001; vb[4] = 32'h0000001F;

    memPC = 0;
    LI(x9, 32'h800);              // result block base
    LI(x10, 32'h600D0000);        // signature, index 0
    SW(x10, x9, 0);
    ADDI(x9, x9, 4);
    AUIPC(x10, 0);                // x10 = PC here; +LabelRef+4 -> vector base
    ADDI(x10, x10, LabelRef(P0VEC) + 4);
    LI(x11, 5);                   // 5 pairs
    Label(P0LOOP);
    LW(x12, x10, 0);              // a
    LW(x13, x10, 4);              // b
    ADDI(x10, x10, 8);
    ADD(x14, x12, x13); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SUB(x14, x12, x13); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SLL(x14, x12, x13); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SLT(x14, x12, x13); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SLTU(x14, x12, x13); SW(x14, x9, 0); ADDI(x9, x9, 4);
    XOR(x14, x12, x13); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SRL(x14, x12, x13); SW(x14, x9, 0); ADDI(x9, x9, 4);
    OR(x14, x12, x13); SW(x14, x9, 0); ADDI(x9, x9, 4);
    AND(x14, x12, x13); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SRA(x14, x12, x13); SW(x14, x9, 0); ADDI(x9, x9, 4);
    ADDI(x11, x11, -1);
    BNE(x11, x0, LabelRef(P0LOOP));
    JALR(x0, x1, 0);              // RET (leaf: no internal ra-using call)
    Label(P0VEC);
    DATAW(32'h00000000); DATAW(32'h00000000);   // pair 0
    DATAW(32'h7FFFFFFF); DATAW(32'h00000001);   // pair 1
    DATAW(32'h80000000); DATAW(32'h80000000);   // pair 2
    DATAW(32'hDEADBEEF); DATAW(32'h0000FFFF);   // pair 3
    DATAW(32'h00000001); DATAW(32'h0000001F);   // pair 4
    proglen = memPC >> 2;
    for (i = 0; i < proglen; i = i + 1) prog[i] = MEM[i];

    // Label discovery: with the label variables not yet hardcoded the lib
    // raises ASMerror; stop before any UART traffic (the program's branch
    // offsets are garbage until the labels are filled in).
    if (ASMerror != 0) begin
      $display("LABELS: not initialized yet — see the Label: lines above");
      $finish;
    end

    // encoding cross-checks against hand-assembled hex (python encoder,
    // one per instruction class this program introduces; word indices
    // hand-counted, the Label checks above pin the layout):
    // SW x10,0(x9): imm=0 rs2=01010(base x9... data x10) rs1=01001 f3=010 op=0100011
    `CHECK_EQ(MEM[3], 32'h00A4A023, "SW x10,0(x9) hand encoding")
    // AUIPC x10,0: imm20=0 rd=01010 op=0010111
    `CHECK_EQ(MEM[5], 32'h00000517, "AUIPC x10,0 hand encoding")
    // SUB x14,x12,x13: f7=0100000 rs2=01101 rs1=01100 f3=000 rd=01110 op=0110011
    `CHECK_EQ(MEM[14], 32'h40D60733, "SUB x14,x12,x13 hand encoding")
    // SLL: f7=0 f3=001
    `CHECK_EQ(MEM[17], 32'h00D61733, "SLL x14,x12,x13 hand encoding")
    // SLT: f3=010
    `CHECK_EQ(MEM[20], 32'h00D62733, "SLT x14,x12,x13 hand encoding")
    // SLTU: f3=011
    `CHECK_EQ(MEM[23], 32'h00D63733, "SLTU x14,x12,x13 hand encoding")
    // XOR: f3=100
    `CHECK_EQ(MEM[26], 32'h00D64733, "XOR x14,x12,x13 hand encoding")
    // SRL: f3=101
    `CHECK_EQ(MEM[29], 32'h00D65733, "SRL x14,x12,x13 hand encoding")
    // OR: f3=110
    `CHECK_EQ(MEM[32], 32'h00D66733, "OR x14,x12,x13 hand encoding")
    // AND: f3=111
    `CHECK_EQ(MEM[35], 32'h00D67733, "AND x14,x12,x13 hand encoding")
    // SRA: f7=0100000 f3=101
    `CHECK_EQ(MEM[38], 32'h40D65733, "SRA x14,x12,x13 hand encoding")

    // expected result block, computed independently with Verilog operators
    explen = 1 + 5 * 10;
    expblk[0] = 32'h600D0000;
    for (i = 0; i < 5; i = i + 1) begin
      expblk[1 + 10*i + 0] = va[i] + vb[i];
      expblk[1 + 10*i + 1] = va[i] - vb[i];
      expblk[1 + 10*i + 2] = va[i] << vb[i][4:0];
      expblk[1 + 10*i + 3] = ($signed(va[i]) < $signed(vb[i])) ? 32'd1 : 32'd0;
      expblk[1 + 10*i + 4] = (va[i] < vb[i]) ? 32'd1 : 32'd0;
      expblk[1 + 10*i + 5] = va[i] ^ vb[i];
      expblk[1 + 10*i + 6] = va[i] >> vb[i][4:0];
      expblk[1 + 10*i + 7] = va[i] | vb[i];
      expblk[1 + 10*i + 8] = va[i] & vb[i];
      expblk[1 + 10*i + 9] = $signed(va[i]) >>> vb[i][4:0];
    end
    // spot hand-checks of the model itself (comment arithmetic):
    // 0x7FFFFFFF + 1 = 0x80000000; 0x80000000 + 0x80000000 wraps to 0;
    // 0x80000000 - 0x80000000 = 0; 0x7FFFFFFF - 1 = 0x7FFFFFFE;
    // 1 << 31 = 0x80000000; 0xDEADBEEF >>> 31 = sign fill = 0xFFFFFFFF;
    // 0x80000000 >>> 0 = 0x80000000; SLT(0x80000000, 0x80000000) = 0;
    // SLTU(0x7FFFFFFF, 1) = 0; SLT(-1 as 0xFFFFFFFF? not a vector here)...
    `CHECK_EQ(expblk[1 + 10*1 + 0], 32'h80000000, "model: 0x7FFFFFFF+1")
    `CHECK_EQ(expblk[1 + 10*2 + 0], 32'h00000000, "model: 0x80000000+0x80000000 wraps")
    `CHECK_EQ(expblk[1 + 10*4 + 2], 32'h80000000, "model: 1<<31")
    `CHECK_EQ(expblk[1 + 10*3 + 9], 32'hFFFFFFFF, "model: 0xDEADBEEF>>>31 sign-fills")
    `CHECK_EQ(expblk[1 + 10*1 + 4], 32'h00000000, "model: 0x7FFFFFFF <u 1 is false")
    `CHECK_EQ(expblk[1 + 10*2 + 3], 32'h00000000, "model: SLT equal operands")
    $writememh("build/hwprogs-alu.prog.hex", prog, 0, proglen - 1);
    $writememh("build/hwprogs-alu.expect.hex", expblk, 0, explen - 1);

    run_and_check("alu", 0);

    // ===== program 1: ldst — every load/store width and aligned offset ====
    // Pattern: 0x8899AABB at buf+0, 0xCCDDEEFF at buf+4 (buf = 0x1000).
    // Little-endian bytes of word 0: +0:BB +1:AA +2:99 +3:88.
    // Loads: LB/LBU at offsets 0..3, LH/LHU at 0/2 (word 0) and 4/6 (word 1),
    // LW at 0/4 — every access aligned (T2: misaligned or out-of-range
    // accesses halt the CPU, so hardware programs must stay halt-free).
    // Stores: a zeroed word, then SB per lane, SH per halfword lane pair on
    // two words (two values), then LW readback per lane.
    memPC = 0;
    LI(x9, 32'h800);              // result block base
    LI(x10, 32'h600D0001);        // signature, index 1
    SW(x10, x9, 0);
    ADDI(x9, x9, 4);
    LI(x15, 32'h1000);            // buffer base
    LI(x16, 32'h8899AABB);        // pattern word 0
    SW(x16, x15, 0);
    LI(x16, 32'hCCDDEEFF);        // pattern word 1
    SW(x16, x15, 4);
    LB(x14, x15, 0); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LB(x14, x15, 1); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LB(x14, x15, 2); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LB(x14, x15, 3); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LBU(x14, x15, 0); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LBU(x14, x15, 1); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LBU(x14, x15, 2); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LBU(x14, x15, 3); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LH(x14, x15, 0); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LH(x14, x15, 2); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LH(x14, x15, 4); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LH(x14, x15, 6); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LHU(x14, x15, 0); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LHU(x14, x15, 2); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LHU(x14, x15, 4); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LHU(x14, x15, 6); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LW(x14, x15, 0); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LW(x14, x15, 4); SW(x14, x9, 0); ADDI(x9, x9, 4);
    LI(x16, 32'h0000005A);        // store byte value
    LI(x17, 32'h00001234);        // store halfword value 1
    LI(x18, 32'hA5A5A5A5);        // store word value
    LI(x19, 32'h00008765);        // store halfword value 2 (sign bit set)
    SW(x0, x15, 8);  SB(x16, x15,  8); LW(x14, x15,  8); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SW(x0, x15, 8);  SB(x16, x15,  9); LW(x14, x15,  8); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SW(x0, x15, 8);  SB(x16, x15, 10); LW(x14, x15,  8); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SW(x0, x15, 8);  SB(x16, x15, 11); LW(x14, x15,  8); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SW(x0, x15, 12); SH(x17, x15, 12); LW(x14, x15, 12); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SW(x0, x15, 12); SH(x17, x15, 14); LW(x14, x15, 12); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SW(x0, x15, 20); SH(x19, x15, 20); LW(x14, x15, 20); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SW(x0, x15, 20); SH(x19, x15, 22); LW(x14, x15, 20); SW(x14, x9, 0); ADDI(x9, x9, 4);
    SW(x0, x15, 16); SW(x18, x15, 16); LW(x14, x15, 16); SW(x14, x9, 0); ADDI(x9, x9, 4);
    JALR(x0, x1, 0);              // RET (leaf)
    proglen = memPC >> 2;
    for (i = 0; i < proglen; i = i + 1) prog[i] = MEM[i];

    // encoding cross-checks (python encoder; word indices hand-counted:
    // prologue 13 words, 18 load results x3, 4 LIs (1+2+2+2), 9 store tests
    // x5, RET):
    // LB x14,0(x15): imm=0 rs1=01111 f3=000 rd=01110 op=0000011
    `CHECK_EQ(MEM[13], 32'h00078703, "LB x14,0(x15) hand encoding")
    // LBU x14,0(x15): f3=100
    `CHECK_EQ(MEM[25], 32'h0007C703, "LBU x14,0(x15) hand encoding")
    // LH x14,0(x15): f3=001
    `CHECK_EQ(MEM[37], 32'h00079703, "LH x14,0(x15) hand encoding")
    // LHU x14,0(x15): f3=101
    `CHECK_EQ(MEM[49], 32'h0007D703, "LHU x14,0(x15) hand encoding")
    // SB x16,8(x15): imm=8 rs2=10000(data) rs1=01111(base) f3=000 op=0100011
    `CHECK_EQ(MEM[75], 32'h01078423, "SB x16,8(x15) hand encoding")
    // SH x17,12(x15): imm=12 f3=001
    `CHECK_EQ(MEM[95], 32'h01179623, "SH x17,12(x15) hand encoding")

    // expected result block — loads from the fixed pattern via Verilog
    // byte-lane slicing (independent of the DUT), stores hand-computed
    p0 = 32'h8899AABB; p1 = 32'hCCDDEEFF;
    explen = 28;
    expblk[0] = 32'h600D0001;
    for (j = 0; j < 4; j = j + 1) begin
      expblk[1 + j] = {{24{p0[8*j+7]}}, p0[8*j +: 8]};   // LB, sign-extended
      expblk[5 + j] = {24'd0, p0[8*j +: 8]};             // LBU
    end
    // LH/LHU at 0/2 (word 0 halves) and 4/6 (word 1 halves)
    expblk[9]  = {{16{p0[15]}}, p0[15:0]};   // LH  +0: 0xAABB sign-extends
    expblk[10] = {{16{p0[31]}}, p0[31:16]};  // LH  +2: 0x8899 sign-extends
    expblk[11] = {{16{p1[15]}}, p1[15:0]};   // LH  +4: 0xEEFF sign-extends
    expblk[12] = {{16{p1[31]}}, p1[31:16]};  // LH  +6: 0xCCDD sign-extends
    expblk[13] = {16'd0, p0[15:0]};          // LHU +0
    expblk[14] = {16'd0, p0[31:16]};         // LHU +2
    expblk[15] = {16'd0, p1[15:0]};          // LHU +4
    expblk[16] = {16'd0, p1[31:16]};         // LHU +6
    expblk[17] = p0;                                     // LW +0
    expblk[18] = p1;                                     // LW +4
    expblk[19] = 32'h0000005A;    // SB lane 0
    expblk[20] = 32'h00005A00;    // SB lane 1
    expblk[21] = 32'h005A0000;    // SB lane 2
    expblk[22] = 32'h5A000000;    // SB lane 3
    expblk[23] = 32'h00001234;    // SH +12: lanes 0,1
    expblk[24] = 32'h12340000;    // SH +14: lanes 2,3
    expblk[25] = 32'h00008765;    // SH +20: lanes 0,1, second value
    expblk[26] = 32'h87650000;    // SH +22: lanes 2,3, second value
    expblk[27] = 32'hA5A5A5A5;    // SW
    $writememh("build/hwprogs-ldst.prog.hex", prog, 0, proglen - 1);
    $writememh("build/hwprogs-ldst.expect.hex", expblk, 0, explen - 1);

    run_and_check("ldst", 1);

    // ===== program 2: fibgcd — loops, signed compares, subtraction ========
    // fib(15) iteratively (f0/f1 walk), then subtract-Euclid gcd on two
    // pairs. Only JAL x0 (plain relative jump) inside, so ra is untouched:
    // a leaf routine, plain RET.
    memPC = 0;
    LI(x9, 32'h800);              // result block base
    LI(x10, 32'h600D0002);        // signature, index 2
    SW(x10, x9, 0);
    ADDI(x9, x9, 4);
    LI(x10, 15);                  // n
    LI(x11, 0);                   // f0 (LI 0 -> ADD x11,x0,x0)
    LI(x12, 1);                   // f1
    Label(LFIB);
    BEQ(x10, x0, LabelRef(LFIBD));
    ADD(x13, x11, x12);           // t = f0 + f1
    ADD(x11, x12, x0);            // f0 = f1
    ADD(x12, x13, x0);            // f1 = t
    ADDI(x10, x10, -1);
    JAL(x0, LabelRef(LFIB));      // backward jump
    Label(LFIBD);
    SW(x11, x9, 0);               // fib(15) = 610
    ADDI(x9, x9, 4);
    LI(x10, 1071);                // gcd(1071, 462) = 21
    LI(x11, 462);
    Label(LG1);
    BEQ(x10, x11, LabelRef(LG1D));
    BLT(x10, x11, LabelRef(LG1S));
    SUB(x10, x10, x11);
    JAL(x0, LabelRef(LG1));
    Label(LG1S);
    SUB(x11, x11, x10);
    JAL(x0, LabelRef(LG1));
    Label(LG1D);
    SW(x10, x9, 0);               // 21
    ADDI(x9, x9, 4);
    LI(x10, 48);                  // gcd(48, 18) = 6
    LI(x11, 18);
    Label(LG2);
    BEQ(x10, x11, LabelRef(LG2D));
    BLT(x10, x11, LabelRef(LG2S));
    SUB(x10, x10, x11);
    JAL(x0, LabelRef(LG2));
    Label(LG2S);
    SUB(x11, x11, x10);
    JAL(x0, LabelRef(LG2));
    Label(LG2D);
    SW(x10, x9, 0);               // 6
    ADDI(x9, x9, 4);
    JALR(x0, x1, 0);              // RET
    proglen = memPC >> 2;
    for (i = 0; i < proglen; i = i + 1) prog[i] = MEM[i];

    // encoding cross-checks (python encoder; layout hand-counted, the
    // Label checks pin it):
    // BEQ x10,x0,+24 (loop exit at LFIBD): imm=24 rs2=0 rs1=01010 f3=000
    `CHECK_EQ(MEM[9], 32'h00050C63, "BEQ x10,x0,+24 hand encoding")
    // JAL x0,-20 (backward to LFIB): imm=-20 rd=0 op=1101111
    `CHECK_EQ(MEM[14], 32'hFEDFF06F, "JAL x0,-20 hand encoding")
    // BLT x10,x11,+12 (to LG1S at byte 92, from the BLT's own byte 80):
    // imm=12 rs2=01011 rs1=01010 f3=100
    `CHECK_EQ(MEM[20], 32'h00B54663, "BLT x10,x11,+12 hand encoding")

    // expected results: independent Verilog reference models, pinned to
    // hand-computed constants (fib: 0 1 1 2 3 5 8 13 21 34 55 89 144 233
    // 377 610; gcd(1071,462): 1071-462=609,609-462=147,462-147=315,
    // 315-147=168,168-147=21, then 147=7*21 down to 21; gcd(48,18)=6)
    begin : refmodels
      integer n, f0, f1, t, ga, gb;
      n = 15; f0 = 0; f1 = 1;
      while (n > 0) begin t = f0 + f1; f0 = f1; f1 = t; n = n - 1; end
      fib_ref = f0;
      ga = 1071; gb = 462;
      while (ga != gb) begin
        if (ga > gb) ga = ga - gb; else gb = gb - ga;
      end
      gcd1_ref = ga;
      ga = 48; gb = 18;
      while (ga != gb) begin
        if (ga > gb) ga = ga - gb; else gb = gb - ga;
      end
      gcd2_ref = ga;
    end
    `CHECK_EQ(fib_ref, 32'd610, "hand: fib(15) = 610")
    `CHECK_EQ(gcd1_ref, 32'd21, "hand: gcd(1071,462) = 21")
    `CHECK_EQ(gcd2_ref, 32'd6, "hand: gcd(48,18) = 6")
    explen = 4;
    expblk[0] = 32'h600D0002;
    expblk[1] = fib_ref;
    expblk[2] = gcd1_ref;
    expblk[3] = gcd2_ref;
    $writememh("build/hwprogs-fibgcd.prog.hex", prog, 0, proglen - 1);
    $writememh("build/hwprogs-fibgcd.expect.hex", expblk, 0, explen - 1);

    run_and_check("fibgcd", 2);

    // ===== program 3: jumpbr — branch/jump torture ========================
    // 13 branch tests with a uniform layout (no labels needed — literal
    // relative offsets): LI a; LI b; BR(a,b,+12); ADDI x12,0,0 (not-taken
    // marker); JAL x0,+8 (over the taken marker); ADDI x12,0,1 (taken
    // marker); SW. The recorded word is 1 iff the branch was TAKEN, so the
    // expected value is just the comparison itself, computed independently
    // below with Verilog operators. Operands cover 0/1/2, -1, signed min/
    // max 0x80000000/0x7FFFFFFF, and both outcomes for all six branch
    // types. Then: the JAL link value (8), a JALR through a register, and
    // a JALR with target|1 to prove bit-0 clearing. Uses JAL x1, so ra is
    // pushed/popped per the monitor convention (sp untouched net).
    memPC = 0;
    LI(x9, 32'h800);              // result block base
    LI(x10, 32'h600D0003);        // signature, index 3
    SW(x10, x9, 0);
    ADDI(x9, x9, 4);
    ADDI(x2, x2, -4);             // push ra (tests below use JAL x1)
    SW(x1, x2, 0);
    LI(x10, 1); LI(x11, 1);       // 1: BEQ 1,1 -> taken
    BEQ(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LI(x10, 1); LI(x11, 2);       // 2: BEQ 1,2 -> not taken
    BEQ(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LI(x10, 1); LI(x11, 2);       // 3: BNE 1,2 -> taken
    BNE(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LI(x10, 1); LI(x11, 1);       // 4: BNE 1,1 -> not taken
    BNE(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LI(x10, 32'hFFFFFFFF); LI(x11, 0);   // 5: BLT -1,0 -> taken
    BLT(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LI(x10, 32'h7FFFFFFF); LI(x11, 32'hFFFFFFFF);  // 6: BLT max,-1 -> not taken
    BLT(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LI(x10, 32'hFFFFFFFF); LI(x11, 32'h80000000);  // 7: BGE -1,min -> taken
    BGE(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LI(x10, 32'h80000000); LI(x11, 32'h7FFFFFFF);  // 8: BGE min,max -> not taken
    BGE(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LI(x10, 32'h7FFFFFFF); LI(x11, 32'h80000000);  // 9: BLTU max,min -> taken
    BLTU(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LI(x10, 32'hFFFFFFFF); LI(x11, 1);             // 10: BLTU -1,1 -> not taken
    BLTU(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LI(x10, 32'h80000000); LI(x11, 32'h7FFFFFFF);  // 11: BGEU min,max -> taken
    BGEU(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LI(x10, 1); LI(x11, 32'hFFFFFFFF);             // 12: BGEU 1,-1 -> not taken
    BGEU(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LI(x10, 32'h80000000); LI(x11, 32'h7FFFFFFF);  // 13: BLT min,max -> taken
    BLT(x10, x11, 12);
    ADDI(x12, x0, 0); JAL(x0, 8); ADDI(x12, x0, 1);
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    AUIPC(x10, 0);                // 14: JAL link = 8 (x1 - AUIPC's PC)
    JAL(x1, 8);                   // link = here+4, target skips one word
    ADDI(x12, x0, 0);             // skipped
    SUB(x12, x1, x10);            // (JAL's PC + 4) - AUIPC's PC = 8
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    AUIPC(x14, 0);                // 15: JALR through a register
    ADDI(x14, x14, 16);           // x14 = addr of the taken marker below
    JALR(x1, x14, 0);
    ADDI(x12, x0, 0);             // skipped
    ADDI(x12, x0, 1);             // landed here
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    AUIPC(x14, 0);                // 16: JALR clears the target's bit 0
    ADDI(x14, x14, 17);           // taken-marker addr | 1
    JALR(x1, x14, 0);
    ADDI(x12, x0, 0);             // skipped
    ADDI(x12, x0, 1);             // landed here (bit 0 was cleared)
    SW(x12, x9, 0); ADDI(x9, x9, 4);
    LW(x1, x2, 0);                // pop ra
    ADDI(x2, x2, 4);
    JALR(x0, x1, 0);              // RET
    proglen = memPC >> 2;
    for (i = 0; i < proglen; i = i + 1) prog[i] = MEM[i];

    // encoding probe (not uploaded): all six branch types with the same
    // operands and offset, checked against hand-assembled hex
    memPC = 0;
    BEQ(x10, x11, -8);
    BNE(x10, x11, -8);
    BLT(x10, x11, -8);
    BGE(x10, x11, -8);
    BLTU(x10, x11, -8);
    BGEU(x10, x11, -8);
    // imm=-8 rs2=01011 rs1=01010, f3 per type, op=1100011
    `CHECK_EQ(MEM[0], 32'hFEB50CE3, "BEQ x10,x11,-8 hand encoding")
    `CHECK_EQ(MEM[1], 32'hFEB51CE3, "BNE x10,x11,-8 hand encoding")
    `CHECK_EQ(MEM[2], 32'hFEB54CE3, "BLT x10,x11,-8 hand encoding")
    `CHECK_EQ(MEM[3], 32'hFEB55CE3, "BGE x10,x11,-8 hand encoding")
    `CHECK_EQ(MEM[4], 32'hFEB56CE3, "BLTU x10,x11,-8 hand encoding")
    `CHECK_EQ(MEM[5], 32'hFEB57CE3, "BGEU x10,x11,-8 hand encoding")

    // expected results: the comparison itself, per test, in Verilog ops
    bop[0] = 0; ba[0] = 32'd1; bb[0] = 32'd1;
    bop[1] = 0; ba[1] = 32'd1; bb[1] = 32'd2;
    bop[2] = 1; ba[2] = 32'd1; bb[2] = 32'd2;
    bop[3] = 1; ba[3] = 32'd1; bb[3] = 32'd1;
    bop[4] = 2; ba[4] = 32'hFFFFFFFF; bb[4] = 32'h00000000;
    bop[5] = 2; ba[5] = 32'h7FFFFFFF; bb[5] = 32'hFFFFFFFF;
    bop[6] = 3; ba[6] = 32'hFFFFFFFF; bb[6] = 32'h80000000;
    bop[7] = 3; ba[7] = 32'h80000000; bb[7] = 32'h7FFFFFFF;
    bop[8] = 4; ba[8] = 32'h7FFFFFFF; bb[8] = 32'h80000000;
    bop[9] = 4; ba[9] = 32'hFFFFFFFF; bb[9] = 32'h00000001;
    bop[10] = 5; ba[10] = 32'h80000000; bb[10] = 32'h7FFFFFFF;
    bop[11] = 5; ba[11] = 32'h00000001; bb[11] = 32'hFFFFFFFF;
    bop[12] = 2; ba[12] = 32'h80000000; bb[12] = 32'h7FFFFFFF;
    explen = 17;
    expblk[0] = 32'h600D0003;
    for (j = 0; j < 13; j = j + 1) begin
      case (bop[j])
        0: e = (ba[j] == bb[j]);
        1: e = (ba[j] != bb[j]);
        2: e = ($signed(ba[j]) < $signed(bb[j]));
        3: e = ($signed(ba[j]) >= $signed(bb[j]));
        4: e = (ba[j] < bb[j]);
        default: e = (ba[j] >= bb[j]);
      endcase
      expblk[1 + j] = e[0] ? 32'd1 : 32'd0;
    end
    expblk[14] = 32'd8;           // JAL link distance from AUIPC's PC
    expblk[15] = 32'd1;           // JALR reached the marker
    expblk[16] = 32'd1;           // JALR bit-0 clear reached the marker
    $writememh("build/hwprogs-jumpbr.prog.hex", prog, 0, proglen - 1);
    $writememh("build/hwprogs-jumpbr.expect.hex", expblk, 0, explen - 1);

    run_and_check("jumpbr", 3);

    `DONE
  end
endmodule
`default_nettype wire
