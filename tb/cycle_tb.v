`timescale 1ns/1ps
`default_nettype none
// Cycle counter, part 1: a 32-bit free-running counter in Processor and its
// CSR read. csrrs rd, cycle, x0 (0xC00) returns the counter, csrrs rd, cycleh,
// x0 (0xC80) returns 0; every other SYSTEM encoding still halts.
//
//   C1  two cycle reads around a known sequence differ by exactly
//       3 + 3*k + j cycles, where k = instructions strictly between the reads
//       (3 clk each: FETCH_INSTR/FETCH_REGS/EXECUTE) and j = loads among them
//       (+1: the LOAD wait state). Derivation: from the EXECUTE cycle of read 1,
//       its own EXECUTE tail is 1 cycle, each in-between instruction 3 (+1 per
//       load), then read 2's fetch is 2 more before its own EXECUTE samples the
//       counter. Also checks the absolute value: reset clears the counter, so
//       the first instruction's EXECUTE (3rd cycle after reset release) sees 2.
//   C2  back-to-back reads differ by exactly 3; a cycleh read returns 0.
//   C3  x0 as destination writes nothing and the CPU still advances.
//   C4  EBREAK still halts, and the counter keeps free-running through the
//       halt (+1 every clk regardless of the FSM).
//   C5  other SYSTEM encodings still halt: CSRRS with rs1 != 0, CSRRS with a
//       CSR address that is neither 0xC00 nor 0xC80, CSRRW (funct3 001).
//
// Encodings (hand-assembled, spec bit layout {imm[11:0], rs1, funct3, rd, opcode}):
//   csrrs rd, cycle,  x0 = 32'hC0002073 | (rd << 7)   RDCYCLE(rd)
//   csrrs rd, cycleh, x0 = 32'hC8002073 | (rd << 7)   RDCYCLEH(rd)
// cross-checked below against the words the helper tasks emit.
module cycle_tb;
  `include "check.vh"
  `WATCHDOG(400_000)

  reg clk = 0;
  reg resetn = 0;
  always #5 clk = ~clk;   // fast sim clock; the CPU is purely synchronous

  wire [31:0] mem_addr;
  wire        mem_rstrb;
  wire [31:0] mem_wdata;
  wire [3:0]  mem_wmask;
  wire [31:0] x1_out;   // not "x1": the assembler lib localparams x0..x31

  // Bench memory model, same contract as rtl/Memory (6 KB, synchronous read
  // while the strobe is high, byte-enabled writes).
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
                 .mem_wdata(mem_wdata), .mem_wmask(mem_wmask), .x1(x1_out));

  `include "riscv_assembly.v"

  // CSR-read helper tasks (task text: live in the bench, not lib/).
  // Same emission convention as the lib macros: MEM[memPC[31:2]], memPC += 4.
  task RDCYCLE(input [4:0] rd);
    begin
      MEM[memPC[31:2]] = 32'hC0002073 | (rd << 7);
      memPC = memPC + 4;
    end
  endtask
  task RDCYCLEH(input [4:0] rd);
    begin
      MEM[memPC[31:2]] = 32'hC8002073 | (rd << 7);
      memPC = memPC + 4;
    end
  endtask
  // Raw word (halt-case encodings that no macro produces).
  task RAW(input [31:0] w);
    begin
      MEM[memPC[31:2]] = w;
      memPC = memPC + 4;
    end
  endtask

  integer i;

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

  initial begin
    // ================= C1: read -> known sequence -> read =================
    //        word 0:  RDCYCLE(x5)          sampled at its EXECUTE cycle
    //        word 4:  ADDI x6,x0,0   \  k = 3 in-between instructions,
    //        word 8:  ADDI x7,x0,0   /  none of them a jump
    //        word 12: LW x8,0(x0)       j = 1 load (+1 cycle)
    //        word 16: RDCYCLE(x6)
    //        word 20: EBREAK
    // Expected difference: 3 + 3*3 + 1 = 13. Absolute values: the counter is
    // reset-cleared, so read 1 (EXECUTE = 3rd cycle after release) sees 2 and
    // read 2 sees 15.
    memPC = 0;
    RDCYCLE(x5);
    ADDI(x6, x0, 0);
    ADDI(x7, x0, 0);
    LW(x8, x0, 0);        // address 0: reads the program's own word 0, harmless
    RDCYCLE(x6);
    EBREAK();
    endASM();
    fillEbreak;

    `CHECK_EQ(MEM[0],  32'hC00022F3, "RDCYCLE(x5) matches the hand encoding C0002073|(5<<7)")
    `CHECK_EQ(MEM[4],  32'hC0002373, "RDCYCLE(x6) matches the hand encoding C0002073|(6<<7)")

    startRun;
    waitHalt;
    `CHECK_EQ(dut.PC, 32'd20, "halted at C1's EBREAK")
    `CHECK_EQ(dut.RegisterBank[5], 32'd2,  "read 1: counter cleared by reset, EXECUTE is cycle 2")
    `CHECK_EQ(dut.RegisterBank[6], 32'd15, "read 2: 2 + 3 + 3 + 4 + 2 = 15")
    `CHECK_EQ(dut.RegisterBank[6] - dut.RegisterBank[5], 32'd13,
              "two reads around 3 instrs (1 load) differ by 3 + 3*3 + 1 = 13")

    // ============ C2: back-to-back reads, cycleh returns 0 ============
    //        word 0: RDCYCLE(x5)   no instruction between the reads:
    //        word 4: RDCYCLE(x6)   difference = 3 + 3*0 + 0 = 3
    //        word 8: RDCYCLEH(x7)  cycleh has no high half: returns exactly 0
    //        word 12: EBREAK
    memPC = 0;
    RDCYCLE(x5);
    RDCYCLE(x6);
    RDCYCLEH(x7);
    EBREAK();
    endASM();
    fillEbreak;

    `CHECK_EQ(MEM[2], 32'hC80023F3, "RDCYCLEH(x7) matches the hand encoding C8002073|(7<<7)")

    startRun;
    waitHalt;
    `CHECK_EQ(dut.PC, 32'd12, "halted at C2's EBREAK")
    `CHECK_EQ(dut.RegisterBank[6] - dut.RegisterBank[5], 32'd3,
              "back-to-back cycle reads differ by exactly 3 (no in-between instructions)")
    `CHECK_EQ(dut.RegisterBank[7], 32'd0, "cycleh read returns 0 (no high half)")

    // ============ C3: x0 as destination writes nothing ============
    //        word 0:  RDCYCLE(x0)    must advance like any CSR read...
    //        word 4:  ADDI x9,x0,42  ...prove it by running past it
    //        word 8:  RDCYCLE(x10)   pipeline still healthy after the x0 read
    //        word 12: EBREAK
    // x10's EXECUTE samples the counter at 2 (read 1's EXECUTE) + 3 (ADDI)
    // + 3 (read 2's own fetch) = 8; the first read's value is discarded by x0.
    memPC = 0;
    RDCYCLE(x0);
    ADDI(x9, x0, 42);
    RDCYCLE(x10);
    EBREAK();
    endASM();
    fillEbreak;

    startRun;
    waitHalt;
    `CHECK_EQ(dut.PC, 32'd12, "halted at C3's EBREAK (x0 reads do not halt the CPU)")
    `CHECK_EQ(dut.RegisterBank[0], 32'd0, "x0 destination writes nothing")
    `CHECK_EQ(dut.RegisterBank[9], 32'd42, "instruction after the x0 read executed")
    `CHECK_EQ(dut.RegisterBank[10], 32'd8,
              "read 2 samples the counter at 2 + 3 + 3 = 8")

    // ==== C4: EBREAK still halts; the counter free-runs through the halt ====
    memPC = 0;
    ADDI(x11, x0, 1);
    EBREAK();
    endASM();
    fillEbreak;

    startRun;
    waitHalt;
    `CHECK_EQ(dut.PC, 32'd4, "halted at C4's EBREAK")
    `CHECK_EQ(dut.state, 2'd2, "halted in EXECUTE")
    `CHECK_EQ(mem_rstrb, 1'b0, "no fetch strobe while halted")
    i = dut.cycles;
    repeat (10) begin @(posedge clk); #1; end
    `CHECK_EQ(dut.cycles - i, 32'd10, "counter free-runs through the halt: +10 in 10 cycles")
    `CHECK_EQ(dut.PC, 32'd4, "PC still frozen after 10 more cycles")

    // ==== C5: every other SYSTEM encoding still halts ====
    //  a) csrrs x5, cycle, x1 — rs1 != 0: not a read, must halt at itself.
    //     {12'hC00, 5'd1, 3'b010, 5'd5, 7'b1110011} = 0xC0002073|1<<15|5<<7
    //  b) csrrs x5, 0xC01, x0 — instret: address not 0xC00/0xC80, must halt.
    //     {12'hC01, 5'd0, 3'b010, 5'd5, 7'b1110011} = 0xC0102073|5<<7
    //  c) csrrw x5, cycle, x0 — funct3 001 (CSRRW), must halt.
    //     {12'hC00, 5'd0, 3'b001, 5'd5, 7'b1110011} = 0xC0001073|5<<7
    // x5 is pre-set before each halting instruction: it must come out unchanged.
    memPC = 0;
    ADDI(x5, x0, 7);
    RAW(32'hC0002073 | 32'h00008000 | 32'h00000280);  // a) = 0xC000A2F3, at byte 4
    EBREAK();
    endASM();
    fillEbreak;
    `CHECK_EQ(MEM[1], 32'hC000A2F3, "csrrs x5,cycle,x1 matches the hand encoding")
    startRun;
    waitHalt;
    `CHECK_EQ(dut.PC, 32'd4, "CSRRS with rs1 != 0 halts at itself")
    `CHECK_EQ(dut.RegisterBank[5], 32'd7, "no write happened for the halting encoding")

    memPC = 0;
    RAW(32'hC0102073 | 32'h00000280);                 // b) = 0xC01022F3
    EBREAK();
    endASM();
    fillEbreak;
    `CHECK_EQ(MEM[0], 32'hC01022F3, "csrrs x5,instret,x0 matches the hand encoding")
    startRun;
    waitHalt;
    `CHECK_EQ(dut.PC, 32'd0, "CSRRS with a non-cycle CSR address halts at itself")

    memPC = 0;
    RAW(32'hC0001073 | 32'h00000280);                 // c) = 0xC00012F3
    EBREAK();
    endASM();
    fillEbreak;
    `CHECK_EQ(MEM[0], 32'hC00012F3, "csrrw x5,cycle,x0 matches the hand encoding")
    startRun;
    waitHalt;
    `CHECK_EQ(dut.PC, 32'd0, "CSRRW (funct3 001) halts at itself")

    `DONE
  end
endmodule
`default_nettype wire
