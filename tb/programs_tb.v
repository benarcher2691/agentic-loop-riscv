`timescale 1ns/1ps
`default_nettype none
// Program suite: four complete programs with hand-verifiable results, run one
// after another on the single Processor. Each program is assembled into MEM at
// word 0 (mid-simulation, while the previous program sits halted on its
// EBREAK), then the CPU is reset and free-runs to its own EBREAK.
//
//   P1  fibonacci(10) = 55 by loop.  x5=f0, x6=f1, x7=n, x28=tmp.
//       10 iterations of {tmp=f1; f1=f0+f1; f0=tmp; n--}; final x5=55, x6=89.
//
//   P2  gcd(48,18) = 6 by subtraction loop.  x8=a, x9=b.
//       while a!=b: if b<a then a-=b else b-=a.  Path: (48,18)->(30,18)->
//       (12,18)->(12,6)->(6,6).  Final x8=x9=6.
//
//   P3  CALL/RET subroutine (ra=x1) called twice with different a0 (x10);
//       result a1 (x11) = 2*a0+1.  Calls: a0=5 -> 11, a0=20 -> 41.
//       addr  0: addi x10,x0,5        addr 20 (Ld): add  x11,x10,x10
//       addr  4: jal  x1,+16  x1=8    addr 24:      addi x11,x11,1
//       addr  8: addi x10,x0,20       addr 28:      jalr x0,x1,0  (ret)
//       addr 12: jal  x1,+16  x1=16   addr 16:      ebreak
//
//   P4  Nested calls: main -> f1 -> f2.  No loads/stores yet, so f1 saves its
//       return address (ra=x1) into callee-saved x20 with ADDI and marks the
//       frame with ADDI sp(x2),-4 / +4.  acc x12 = 1 (f1) + 10 (f2) + 100
//       (f1 after f2 returns) = 111; sp balanced back to 0; ra restored to 12.
//       addr  0: addi x2,x0,0   sp=0     addr 32: addi x12,x12,100
//       addr  4: addi x12,x0,0  acc=0    addr 36: addi x1,x20,0   restore ra
//       addr  8: jal  x1,+8 -> f1        addr 40: addi x2,x2,4    pop frame
//       addr 12: ebreak                  addr 44: jalr x0,x1,0    ret main
//       addr 16 (Lf1): addi x2,x2,-4     addr 48 (Lf2): addi x12,x12,10
//       addr 20: addi x20,x1,0 save ra   addr 52: jalr x0,x1,0    ret f1
//       addr 24: addi x12,x12,1
//       addr 28: jal  x1,+20 -> f2  (x1=32)
//
//   P5  13-bit addressing: a program placed at byte 4096 (entered through a
//       JAL trampoline at 0 — the old 10-bit PC path would wrap to 0) sums
//       eight data words from the data area at 5120 (0x1400, built with
//       LUI 4096 + ADDI 1024) into x3, stores the sum at 5152 and loads it
//       back.  Data 100,200,...,800 -> sum 3600.
//
// Each run: reset (PC held 0), free-run until the fetch strobe has been quiet
// 8 cycles (EBREAK halt), check PC frozen at the program's EBREAK address,
// check mid-run state at unique PCs (proves call/return order), check final
// registers by hierarchical reference, and cross-check every assembled word
// against hand-encoded expWord constants (spec bit formulas).
module programs_tb;
  `include "check.vh"
  `WATCHDOG(400_000)

  reg clk = 0;
  reg resetn = 0;
  always #5 clk = ~clk;   // fast sim clock; the CPU is purely synchronous

  wire [31:0] mem_addr;
  wire        mem_rstrb;
  wire [31:0] mem_wdata;
  wire [3:0]  mem_wmask;

  // Bench memory model, same contract as rtl/Memory: synchronous read of
  // MEM[addr[12:2]] on the clock edge while the strobe is high (6 KB),
  // synchronous byte-enabled writes (P5 stores through this path).
  reg [31:0] MEM [0:1535];
  reg [31:0] mem_rdata;
  always @(posedge clk) begin
    if (mem_rstrb)    mem_rdata <= MEM[mem_addr[12:2]];
    if (mem_wmask[0]) MEM[mem_addr[12:2]][ 7: 0] <= mem_wdata[ 7: 0];
    if (mem_wmask[1]) MEM[mem_addr[12:2]][15: 8] <= mem_wdata[15: 8];
    if (mem_wmask[2]) MEM[mem_addr[12:2]][23:16] <= mem_wdata[23:16];
    if (mem_wmask[3]) MEM[mem_addr[12:2]][31:24] <= mem_wdata[31:24];
  end

  Processor dut (.clk(clk), .resetn(resetn), .mem_addr(mem_addr),
                 .mem_rdata(mem_rdata), .mem_rstrb(mem_rstrb),
                 .mem_wdata(mem_wdata), .mem_wmask(mem_wmask));

  `include "riscv_assembly.v"

  // Label byte addresses, hand-computed from the layouts above.
  // Label() verifies each against memPC at assembly time; a mismatch sets
  // ASMerror and endASM() finishes the bench without PASS.
  integer Lfib   = 12;   // P1 loop head
  integer Lfdone = 36;   // P1 exit
  integer Lg      = 8;   // P2 loop head
  integer Lgsubab = 24;  // P2 a-=b arm
  integer Lgdone  = 32;  // P2 exit
  integer Ld  = 20;      // P3 subroutine
  integer Lf1 = 16;      // P4 outer subroutine
  integer Lf2 = 48;      // P4 inner subroutine
  integer Lp5 = 4112;    // P5 loop head (program base 4096 + 16)

  integer i, w;

  // Fill the rest of MEM with EBREAK so a runaway PC halts instead of
  // executing a previous program's stale words.
  task fillEbreak;
    integer j;
    begin
      for (j = memPC >> 2; j < 1536; j = j + 1) MEM[j] = 32'h00100073;
    end
  endtask

  // Wait until the fetch strobe has been low for 8 consecutive cycles: the
  // FSM asserts it 1 cycle in 3 while running, so only a halt stays quiet.
  task waitHalt;
    integer g, quiet;
    begin
      quiet = 0;
      for (g = 0; g < 2000 && quiet < 8; g = g + 1) begin
        @(posedge clk); #1;
        if (mem_rstrb !== 1'b1) quiet = quiet + 1;
        else quiet = 0;
      end
      `CHECK(quiet == 8, "fetch strobe quiet 8 cycles: EBREAK halt reached")
    end
  endtask

  task startRun;
    begin
      resetn = 0;
      repeat (3) begin @(posedge clk); #1; end
      `CHECK_EQ(dut.PC, 32'd0, "PC held at 0 during reset")
      resetn = 1;
    end
  endtask

  task finishHalt(input [31:0] ebreakAddr);
    begin
      waitHalt;
      repeat (3) begin @(posedge clk); #1; end
      `CHECK_EQ(dut.PC, ebreakAddr, "halted at the program's EBREAK address")
      `CHECK_EQ(dut.state, 2'd2, "halted in EXECUTE")
      `CHECK_EQ(mem_rstrb, 1'b0, "no fetch strobe while halted")
    end
  endtask

  // Advance at least one edge, then wait for the next EXECUTE of the
  // instruction at pc (bounded poll). Used for unique mid-run PCs.
  task pollPC(input [31:0] pc);
    integer g;
    begin
      @(posedge clk); #1;
      g = 0;
      while ((dut.PC !== pc || dut.state !== 2'd2) && g < 1000) begin
        @(posedge clk); #1;
        g = g + 1;
      end
      `CHECK_EQ(dut.PC, pc, "pollPC reached the target PC in EXECUTE")
    end
  endtask

  // Hand-assembled words the macros must produce, per program (spec formulas:
  // R {f7,rs2,rs1,f3,rd,0x33} / I {imm,rs1,f3,rd,op} / S-B {imm12,imm10:5,rs2,
  // rs1,f3,imm4:1,imm11,op} / U-J {imm20,imm10:1,imm11,imm19:12,rd,0x6F}).
  function [31:0] expWord(input integer p, input integer k);
    begin
      case (p)
        1: begin
          case (k)
            0: expWord = 32'h00000293;  // addi x5,x0,0
            1: expWord = 32'h00100313;  // addi x6,x0,1
            2: expWord = 32'h00A00393;  // addi x7,x0,10
            3: expWord = 32'h00038C63;  // beq x7,x0,+24  (12 -> 36)
            4: expWord = 32'h00030E13;  // addi x28,x6,0
            5: expWord = 32'h00530333;  // add  x6,x6,x5
            6: expWord = 32'h000E0293;  // addi x5,x28,0
            7: expWord = 32'hFFF38393;  // addi x7,x7,-1
            8: expWord = 32'hFEDFF06F;  // jal  x0,-20    (32 -> 12)
            9: expWord = 32'h00100073;  // ebreak
            default: expWord = 32'h00000013;
          endcase
        end
        2: begin
          case (k)
            0: expWord = 32'h03000413;  // addi x8,x0,48
            1: expWord = 32'h01200493;  // addi x9,x0,18
            2: expWord = 32'h00940C63;  // beq x8,x9,+24  (8 -> 32)
            3: expWord = 32'h0084C663;  // blt x9,x8,+12  (12 -> 24)
            4: expWord = 32'h408484B3;  // sub x9,x9,x8
            5: expWord = 32'hFF5FF06F;  // jal x0,-12     (20 -> 8)
            6: expWord = 32'h40940433;  // sub x8,x8,x9
            7: expWord = 32'hFEDFF06F;  // jal x0,-20     (28 -> 8)
            8: expWord = 32'h00100073;  // ebreak
            default: expWord = 32'h00000013;
          endcase
        end
        3: begin
          case (k)
            0: expWord = 32'h00500513;  // addi x10,x0,5
            1: expWord = 32'h010000EF;  // jal  x1,+16    (4 -> 20)
            2: expWord = 32'h01400513;  // addi x10,x0,20
            3: expWord = 32'h008000EF;  // jal  x1,+8     (12 -> 20)
            4: expWord = 32'h00100073;  // ebreak
            5: expWord = 32'h00A505B3;  // add  x11,x10,x10
            6: expWord = 32'h00158593;  // addi x11,x11,1
            7: expWord = 32'h00008067;  // jalr x0,x1,0   (canonical ret)
            default: expWord = 32'h00000013;
          endcase
        end
        4: begin
          case (k)
            0:  expWord = 32'h00000113;  // addi x2,x0,0
            1:  expWord = 32'h00000613;  // addi x12,x0,0
            2:  expWord = 32'h008000EF;  // jal  x1,+8     (8 -> 16)
            3:  expWord = 32'h00100073;  // ebreak
            4:  expWord = 32'hFFC10113;  // addi x2,x2,-4  (I-imm field = imm[11:0] = 0xFFC)
            5:  expWord = 32'h00008A13;  // addi x20,x1,0
            6:  expWord = 32'h00160613;  // addi x12,x12,1
            7:  expWord = 32'h014000EF;  // jal  x1,+20    (28 -> 48)
            8:  expWord = 32'h06460613;  // addi x12,x12,100
            9:  expWord = 32'h000A0093;  // addi x1,x20,0
            10: expWord = 32'h00410113;  // addi x2,x2,4
            11: expWord = 32'h00008067;  // jalr x0,x1,0
            12: expWord = 32'h00A60613;  // addi x12,x12,10
            13: expWord = 32'h00008067;  // jalr x0,x1,0
            default: expWord = 32'h00000013;
          endcase
        end
        5: begin
          case (k)
            0:  expWord = 32'h00000193;  // addi x3,x0,0    (4096)
            1:  expWord = 32'h00001237;  // lui  x4,0x1000  (4100) x4 = 4096
            2:  expWord = 32'h40020213;  // addi x4,x4,1024 (4104) x4 = 5120
            3:  expWord = 32'h00800313;  // addi x6,x0,8    (4108)
            4:  expWord = 32'h00022283;  // lw   x5,0(x4)   (4112 = Lp5)
            5:  expWord = 32'h005181B3;  // add  x3,x3,x5   (4116)
            6:  expWord = 32'h00420213;  // addi x4,x4,4    (4120)
            7:  expWord = 32'hFFF30313;  // addi x6,x6,-1   (4124)
            8:  expWord = 32'hFE0318E3;  // bne  x6,x0,-16  (4128 -> 4112)
            9:  expWord = 32'h00322023;  // sw   x3,0(x4)   (4132)
            10: expWord = 32'h00022383;  // lw   x7,0(x4)   (4136)
            11: expWord = 32'h00100073;  // ebreak          (4140)
            default: expWord = 32'h00000013;
          endcase
        end
        default: expWord = 32'h00000013;
      endcase
    end
  endfunction

  initial begin
    // ================= P1: fibonacci(10) = 55 =================
    memPC = 0;
    ADDI(x5, x0, 0);      // f0 = 0
    ADDI(x6, x0, 1);      // f1 = 1
    ADDI(x7, x0, 10);     // n = 10
    Label(Lfib);
    BEQ(x7, x0, LabelRef(Lfdone));
    ADDI(x28, x6, 0);     // tmp = f1
    ADD(x6, x6, x5);      // f1 = f1 + f0
    ADDI(x5, x28, 0);     // f0 = tmp
    ADDI(x7, x7, -1);     // n--
    JAL(x0, LabelRef(Lfib));
    Label(Lfdone);
    EBREAK();
    endASM();
    fillEbreak;

    startRun;
    finishHalt(32'd36);
    `CHECK_EQ(dut.RegisterBank[5],  32'd55, "fib(10) = 55 in x5")
    `CHECK_EQ(dut.RegisterBank[6],  32'd89, "fib(11) = 89 in x6")
    `CHECK_EQ(dut.RegisterBank[7],  32'd0,  "loop counter drained to 0")
    `CHECK_EQ(dut.RegisterBank[28], 32'd55, "tmp holds fib(10) from the last iteration")
    for (w = 0; w < 10; w = w + 1)
      `CHECK_EQ(MEM[w], expWord(1, w), "P1 assembler word matches the hand encoding")

    // ================= P2: gcd(48,18) = 6 =================
    memPC = 0;
    ADDI(x8, x0, 48);     // a = 48
    ADDI(x9, x0, 18);     // b = 18
    Label(Lg);
    BEQ(x8, x9, LabelRef(Lgdone));
    BLT(x9, x8, LabelRef(Lgsubab));  // b < a -> a -= b
    SUB(x9, x9, x8);                 // else b -= a
    JAL(x0, LabelRef(Lg));
    Label(Lgsubab);
    SUB(x8, x8, x9);
    JAL(x0, LabelRef(Lg));
    Label(Lgdone);
    EBREAK();
    endASM();
    fillEbreak;

    startRun;
    finishHalt(32'd32);
    `CHECK_EQ(dut.RegisterBank[8], 32'd6, "gcd(48,18) = 6 in x8")
    `CHECK_EQ(dut.RegisterBank[9], 32'd6, "loop exits with a == b == 6")
    for (w = 0; w < 9; w = w + 1)
      `CHECK_EQ(MEM[w], expWord(2, w), "P2 assembler word matches the hand encoding")

    // ============ P3: CALL/RET twice, arg in a0 ============
    memPC = 0;
    ADDI(x10, x0, 5);     // a0 = 5
    JAL(x1, LabelRef(Ld));           // call #1, x1 = 8
    ADDI(x10, x0, 20);    // a0 = 20
    JAL(x1, LabelRef(Ld));           // call #2, x1 = 16
    EBREAK();
    Label(Ld);
    ADD(x11, x10, x10);   // a1 = 2*a0
    ADDI(x11, x11, 1);    // a1 = 2*a0 + 1
    JALR(x0, x1, 0);      // ret
    endASM();
    fillEbreak;

    startRun;
    // Unique PC 8 = the addi x10,x0,20 after call #1 returned. (PC 24 is the
    // subroutine's own ADDI: polling there would sample x11 pre-commit.)
    pollPC(32'd8);
    `CHECK_EQ(dut.RegisterBank[11], 32'd11, "call #1 result: 2*5+1 = 11")
    `CHECK_EQ(dut.RegisterBank[1],  32'd8,  "link of call #1 = 4 + 4")
    `CHECK_EQ(dut.RegisterBank[10], 32'd5,  "a0 still 5 at the return site")
    // Next EXECUTE at 20 = entry of call #2.
    pollPC(32'd20);
    `CHECK_EQ(dut.RegisterBank[1],  32'd16, "link of call #2 = 12 + 4")
    `CHECK_EQ(dut.RegisterBank[10], 32'd20, "a0 = 20 for call #2")
    finishHalt(32'd16);
    `CHECK_EQ(dut.RegisterBank[10], 32'd20, "a0 = 20 at the end")
    `CHECK_EQ(dut.RegisterBank[11], 32'd41, "call #2 result: 2*20+1 = 41")
    `CHECK_EQ(dut.RegisterBank[1],  32'd16, "ra = link of call #2")
    for (w = 0; w < 8; w = w + 1)
      `CHECK_EQ(MEM[w], expWord(3, w), "P3 assembler word matches the hand encoding")

    // ========= P4: nested calls, ra saved via ADDI + reg =========
    memPC = 0;
    ADDI(x2, x0, 0);      // sp = 0
    ADDI(x12, x0, 0);     // acc = 0
    JAL(x1, LabelRef(Lf1));          // call f1, x1 = 12
    EBREAK();
    Label(Lf1);
    ADDI(x2, x2, -4);     // push frame (no stores yet)
    ADDI(x20, x1, 0);     // save ra (12) in callee-saved x20
    ADDI(x12, x12, 1);    // f1 work: acc += 1
    JAL(x1, LabelRef(Lf2));          // nested call f2, x1 = 32
    ADDI(x12, x12, 100);  // f1 work after f2 returns: acc += 100
    ADDI(x1, x20, 0);     // restore ra
    ADDI(x2, x2, 4);      // pop frame
    JALR(x0, x1, 0);      // ret to main
    Label(Lf2);
    ADDI(x12, x12, 10);   // f2 work: acc += 10
    JALR(x0, x1, 0);      // ret to f1
    endASM();
    fillEbreak;

    startRun;
    // Unique PC 48 = f2 entry, reached only through the nested call.
    pollPC(32'd48);
    `CHECK_EQ(dut.RegisterBank[1],  32'd32,         "f2 entered with x1 = 28 + 4")
    `CHECK_EQ(dut.RegisterBank[20], 32'd12,         "f1 saved its return address 12")
    `CHECK_EQ(dut.RegisterBank[2],  32'hFFFFFFFC,   "sp pushed: 0 - 4")
    `CHECK_EQ(dut.RegisterBank[12], 32'd1,          "f1 work done before the nested call")
    // Unique PC 32 = f1 resumed after f2 returned.
    pollPC(32'd32);
    `CHECK_EQ(dut.RegisterBank[12], 32'd11, "f2 work done: 1 + 10")
    `CHECK_EQ(dut.RegisterBank[1],  32'd32, "x1 still f1's continuation")
    finishHalt(32'd12);
    `CHECK_EQ(dut.RegisterBank[12], 32'd111, "acc = 1 + 10 + 100")
    `CHECK_EQ(dut.RegisterBank[1],  32'd12,  "ra restored to main's link 8 + 4")
    `CHECK_EQ(dut.RegisterBank[2],  32'd0,   "sp balanced back to 0")
    `CHECK_EQ(dut.RegisterBank[20], 32'd12,  "callee-saved x20 still holds 12")
    `CHECK_EQ(dut.RegisterBank[1],  32'd12,  "ra = 12 read hierarchically (x1 mirror port removed)")
    for (w = 0; w < 14; w = w + 1)
      `CHECK_EQ(MEM[w], expWord(4, w), "P4 assembler word matches the hand encoding")

    // ===== P5: program at 4096, data at 5120 (13-bit addressing) =====
    // Trampoline at 0: the old 10-bit PC path would wrap 4096 & 0x3FF = 0
    // and spin here forever, so reaching the program at all proves the
    // 13-bit JAL target.
    memPC = 0;
    JAL(x0, 4096);        // x0 link (dropped), PC -> 4096
    EBREAK();
    endASM();
    fillEbreak;           // words 2..1535 = EBREAK

    memPC = 4096;
    ADDI(x3, x0, 0);      // sum = 0
    LUI(x4, 32'h00001000);  // x4 = 4096
    ADDI(x4, x4, 1024);   // x4 = 5120 = data base (0x1400)
    ADDI(x6, x0, 8);      // count = 8
    Label(Lp5);
    LW(x5, x4, 0);        // x5 = data[i]
    ADD(x3, x3, x5);      // sum += data[i]
    ADDI(x4, x4, 4);      // p++
    ADDI(x6, x6, -1);     // count--
    BNE(x6, x0, LabelRef(Lp5));
    SW(x3, x4, 0);        // MEM[5152] = sum (x4 = 5120 + 32 here)
    LW(x7, x4, 0);        // read the stored sum back
    EBREAK();
    endASM();
    fillEbreak;           // words 1036..1535 = EBREAK

    // Data area at 5120 (words 1280..1287), written after both EBREAK fills
    // so neither can clobber it.
    for (i = 0; i < 8; i = i + 1) MEM[1280 + i] = 100 * (i + 1);

    startRun;
    `CHECK_EQ(MEM[0], 32'h0000106F, "trampoline jal x0,+4096 matches the hand encoding")
    // Loop head, first iteration: the prologue has committed.
    pollPC(32'd4112);
    `CHECK_EQ(dut.RegisterBank[4], 32'd5120, "x4 = data base 5120 (LUI+ADDI 13-bit constant)")
    `CHECK_EQ(dut.RegisterBank[6], 32'd8,    "count = 8 at the first load")
    `CHECK_EQ(dut.RegisterBank[3], 32'd0,    "sum still 0 at the first load")
    finishHalt(32'd4140);
    `CHECK_EQ(dut.RegisterBank[3], 32'd3600, "sum of 100..800 = 3600")
    `CHECK_EQ(dut.RegisterBank[4], 32'd5152, "x4 = 5120 + 8*4 after the loop")
    `CHECK_EQ(dut.RegisterBank[7], 32'd3600, "stored sum loaded back into x7")
    `CHECK_EQ(MEM[1288], 32'd3600, "SW landed at byte 5152 = word 1288")
    for (i = 0; i < 8; i = i + 1)
      `CHECK_EQ(MEM[1280 + i], 100 * (i + 1), "data word intact after the run")
    for (w = 0; w < 12; w = w + 1)
      `CHECK_EQ(MEM[1024 + w], expWord(5, w), "P5 assembler word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
