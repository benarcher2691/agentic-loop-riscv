# Progress log

Append-only notes from the loop agent. One short entry per iteration.
This file is the agent's only memory between sessions — write down what
the next session needs to know, not what it can read from the code.

---

- **Blinker** (task 1): Added `Clockworks` (generate-if: SLOW=0 passthrough, else SLOW-bit
  counter, clk = MSB; POR = 5-bit counter sticking at 16, resetn = bit 4) and the SOC 5-bit
  LED counter. Benches check edge-by-edge: 95 + 88 = 183 checks, pnr 36 LCs, Fmax 424 MHz.
  Surprise: none — but note `$time` rounds to the 1 ns timescale unit, so the SLOW=3 spacing
  check compares *sample indices* (8 edges apart), not timestamps. Next: Memory task needs a
  synchronous-read BRAM and the assembler macros; read `lib/riscv_assembly.v` header first.

- **LED patterns from ROM** (task 2): Added `Memory` (256x32, sync read gated by `mem_rstrb`,
  16-word LED pattern in `initial`) and reworked `SOC` into a fetch machine: `PC` walks
  0..60 by 4 (wrap via `PROG_WORDS` localparam = 16, must match `rtl/memory.v`), LEDS =
  `mem_rdata[4:0]`. 254 checks total (95+88+71), 91 LCs, 1 BRAM, Fmax 221 MHz.
  Surprises: (1) iverilog needs `reg PC` declared *before* the `Memory` instance that uses
  it ("declaration after use" is a hard elaboration error); (2) yosys narrows `mem_rdata`
  to the 5 bits LEDS uses, so the ROM maps to ONE 256x16 RAM4K (INIT_0 only) — expect 2
  BRAMs once the Processor reads full 32-bit words; (3) word 0 displays for 17 edges
  (16 reset + 1) because PC is held at 0 through POR while the strobe is tied high — the
  soc_tb pass loop starts sampling after edge 17. Benches keep independent copies of the
  16 ROM constants, cross-checked against `dut.memory.MEM[i]` (note the instance path).
- **Decoder, part 1** (task 3): `rtl/decoder.v` already existed complete from the interrupted
  session (all 10 class flags, fields, AND all five immediates already implemented) — verified
  it, did not rewrite it. New `tb/decoder_tb.v`: table-driven `check_vec` task, 10 hand-encoded
  vectors (one per class) × 15 checks + 1 illegal-opcode check = 151 checks, 405 total.
  Surprise: in I/S/B/U/J formats rs2/rd/funct7 overlap immediate bits, so expected values are
  raw instruction bits (addi x1,x0,5 → rs2Id=5; ebreak → rs2Id=1; jal x1,16 → rs2Id=16;
  lui → rs1=rs2=31, funct7=127). Next (part 2): immediates are already driven — bench-only
  work; extend `check_vec` with the five expected immediates per vector and add the task's
  positive/negative I/S/U vectors.
- **Decoder, part 2** (task 4): bench-only again (decoder already drove all five immediates).
  `check_vec` now takes eI/eS/eB/eU/eJ and checks all five immediate outputs on every vector;
  14 vectors (added addi -1, lw -8, sw +16, lui 0x12345 for bit-31-clear U) × 20 checks + 1
  illegal = 281, total 535. New hand encodings: lw x3,-8(x2) = 0xFF812183, sw x2,16(x1) =
  0x0020A823. Surprise: hand bit-slicing kept misaligning (nibble→bit-index slips), so the
  expected constants were computed by applying the spec formulas to the hand-encoded words
  with a throwaway python bit-slicer, anchored against the task text's own named values
  (Iimm=-1, Simm=-4, Uimm=0xFFFFF000, Jimm=16, Bimm=8, Iimm=64) and part-1's field checks —
  all matched, and sim passed first run. Advice: for part 3, reuse the same python slicer to
  pre-compute B/J immediate expectations, then do the assembler round-trip (RType..JType from
lib/riscv_assembly.v) as the true independent cross-check; note the lib needs a `MEM`-bearing
   module to include into.
- **Decoder, part 3** (task 5): bench-only again. Added 5 hand vectors (fwd bne +16, back bne -8
  and beq -8 = 0xFE209CE3/0xFE208CE3, back jal x0,-8 = 0xFF9FF06F, edge jal x1,4094 = 0x7FF000EF
  with imm[11]=1/imm[20]=0) + assembler round trip: `reg [31:0] MEM[0:15]` + lib include at
  module level, six RType..JType calls, each word first CHECK_EQ'd against the hand encoding,
  then run through check_vec. 761 checks total, pnr unchanged (91 LCs).
  Surprises: (1) the "jal x1,2046" word I first built was really jal x1,4094 — 0x7FF000EF has
  imm[11]=1; kept it as the swap-edge test; (2) two FAILs from transcribing funct3=000 for
  0xFF9FF06F where bits[14:12]=111 — the python slicer had it right, I overrode it by eye.
   Advice: trust the slicer output verbatim, never re-derive fields by hand. The lib include
   resolves via the Makefile's `-I lib`; it needs `MEM` + brings its own `memPC` (assign it
   before generating). Next task is the ALU (rtl/alu.v) — first new RTL module since Memory.
- **ALU** (task 6): `rtl/alu.v` (full funct3/funct7_5 decode, shift amount in2[4:0], SLT/SLTU
  reuse the EQ/LT/LTU output wires so the two paths cannot disagree) + `tb/alu_tb.v`:
  hand-anchored literal checks (overflow wrap, SRA sign fill, signed-vs-unsigned on
  0x80000000), 5×5 edge-value sweep × all 10 op variants, explicit shift amounts
  0/1/2/4/16/31 × SLL/SRL/SRA × 5 edge values, 256 seeded `$random` vectors — 2438 checks,
  3199 total, pnr unchanged (91 LCs).
   Surprise: iverilog evaluates `$signed(a) >>> sh` *inside an unsigned ternary* as a logical
   shift (the ?: context wins over the operand's signedness) — both initial FAILs were my
   reference doing SRL where the DUT was correct. Fix: compute the reference SRA in a
   standalone assignment. Advice: the Processor should drive ALU.funct7_5 from
   `instr[30]`/funct7 bit 5 and take branch operands straight from EQ/LT/LTU; expect the LC
   count to jump next session since yosys currently discards the unused ALU.
- **Processor, part 1** (task 7): `rtl/processor.v` — 3-state FSM, 3 cycles/instr; Decoder
   input muxes `mem_rdata` in during FETCH_REGS (that is how "read rs1/rs2 in FETCH_REGS"
   works with a sync memory); register reads are synchronous (latched into rs1Val/rs2Val) so
   RegisterBank maps to BRAM (synth log: "mapping memory SOC.processor.RegisterBank via
   $__ICE40_RAM4K_"). The `x1` output is a same-edge mirror register, NOT
   `assign x1 = RegisterBank[1]` — an async read would drag the regfile back to ~1000 LCs of
   FFs+muxes. SOC = Processor+Memory at SLOW=0, LEDS = x1[4:0]; Memory's ROM is now a 6-word
   ADDI program via the assembler tasks (yosys resolves `../lib/riscv_assembly.v` from rtl/).
   Benches: new processor_tb (117: per-cycle strobe/PC walk, halt freeze, reg checks,
   hand-encoding cross-check), memory_tb rewritten (ROM copy + bench-filled words 6..255,
   full 256-word addressing, 1038 checks), soc_tb rewritten (62). 4257 total, 139 LCs,
   2 BRAMs, Fmax 118 MHz.
   Surprises: (1) lib LUI/AUIPC take the FINAL rd value — UType stores imm[31:12]; the lib
   header's "pre-shifted constant" note is stale; (2) my addi x3,x2,-3 hand word was ...193,
   not ...793 (3<<7 = 0x180) — the assembler cross-check caught both of my hand-encoding
   slips, DUT was right both times; (3) bench signals must not be named x0..x31 (lib
   localparam clash); (4) forgot x1's init value → LEDS was X during reset, soc_tb's
   4-state CHECK_EQ caught it. Advice for part 2: keep register reads sync, keep the x1
   mirror's write condition general (`wrEn && rdId == 1`), and expect LCs to grow as the
   SOC program starts writing more registers (each written reg ≈ +5 observable FFs).
- **Processor, part 2** (task 8): ALU wired into EXECUTE — `aluIn2 = isALUreg ? rs2Val : Iimm`,
   `aluF75 = isALUreg ? funct7[5] : (isALUimm && funct3==101) ? funct7[5] : 0` (ADDI with
   imm[30]=1 must stay ADDI; regression: `ADDI x14,x0,1024`), `wrEn = isALUreg|isALUimm`,
   `wrData = aluOut`. Bench: 27-word program covering every ALU-reg/ALU-imm op once with
   hand-computed results (SRAI of -7, SLTIU -1, SUB negative, SLLI 31, SRL by 33 → amount
   [4:0]), part-1's per-cycle FSM walk kept for the first 9 instructions then free-run to
   the EBREAK halt; 131 checks, 4271 total. LCs 139 → 771 (60%), BRAMs 2 → 5 (regfile now
   3 RAM4K: 2 sync read ports + write), Fmax 56.76 MHz.
   Surprises: (1) my python encoder passed `hi=1 << 25` for SRAI instead of funct7 0x20 —
   the lib's 0x4042D893 was right; "trust the script" cuts both ways, check the script
   against the spec formula too; (2) 5<<31 = 0x80000000, not 0xA0000000 (that's 5<<29) —
   DUT right, my mental math wrong, the check caught it; (3) the ALU's three separate
   barrel shifters (SLL/SRL/SRA arms) are likely the bulk of the 771 LCs — if later tasks
   squeeze the part, share one shift core before touching anything else. Advice for JAL/
   JALR: the wrEn/wrData path is ready for `rd <= PC+4`; add a PC-source mux in EXECUTE
   and remember rs1Val is already latched for JALR's target.
- **Jumps: JAL and JALR** (task 9): iteration 9 had already put the jump path in
   processor.v (doJump/jumpTarget, wrData = PC+4) and left a WIP bench that an auto-commit
   captured; I replaced that bench with tb/jumps_tb.v (58 checks) — same acceptance
   criteria plus `jumpTarget` wire checks and a per-cycle walk of the first JAL. Program:
   forward JAL x0 over two poison words, a subroutine at addr 12 called twice by backward
   JALs (x1 = 28/36) returning through JALR x0,x1,0, and a two-iteration loop whose JALR
   return self-retargets (x7 seed 42, +4 per pass, return (x7-1)&~1 → 44 then 48 = EBREAK);
   both JALR sums (45, 49) are odd so the &~1 masking is load-bearing. 4329 total, pnr
   unchanged (979 LCs, 5 BRAMs, 52 MHz).
   Surprises: (1) my hand encoding of jal x5,8 dropped the opcode byte (0x00800280 vs
   0x008002EF) — third hand-encoding slip in a row, the lib cross-check caught it again;
   (2) the old bench's comment claims an expWord loop "misbehaved" in iverilog — a
   `for` loop calling a case-function works fine here, that note was about something else.
   Advice for Branches (next): EQ/LT/LTU already leave the ALU instance; extend the
   EXECUTE PC mux to `branch taken ? PC + Bimm` with taken = decoded per funct3 from
   those wires, and keep isBranch OUT of wrEn (branches write no rd).
