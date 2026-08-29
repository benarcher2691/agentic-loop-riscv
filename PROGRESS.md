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
- **Branches** (task 10): processor.v — `aluIn2` now feeds rs2Val for branches too
   (`(isALUreg|isBranch) ? rs2Val : Iimm`; Iimm would corrupt the compare), `branchCond`
   is a funct3 mux over EQ/LT/LTU and their complements, `doBranch = isBranch & branchCond`
   joins the EXECUTE PC mux (`doJump ? jumpTarget : doBranch ? PC+Bimm : PC+4`), isBranch
   stays out of wrEn. New tb/branches_tb.v (87 checks): 4 per-cycle EXECUTE walks (BEQ
   not-taken/taken, BLT taken, BLTU not-taken on the SAME −1 vs 0xFFFFFFFF operands —
   checks aluLT/aluLTU/branchCond/branchTarget wires and the PC after the edge), free-run
   to halt, 15 register checks (markers=1, poisons=0, backward BNE 2→1→0, loop sum 55),
   37-word hand-encoding cross-check. 4416 total. LCs 979 → 1121 (87%), Fmax 44.68 MHz.
   Surprises: two more hand-encoding slips, both caught by the lib cross-check, both MINE:
   (1) add x21,x21,x20 — first put rs2 at rs1's shift (20<<15), then dropped bit 15 when
   re-summing (0x014A0AB3 vs correct 0x014A8AB3); (2) addi x19,x19,-1 rd nibble (…913 vs
   …993). The DUT/lib were right both times. Advice for LUI/AUIPC (next): add a wrData arm
   (`isLUI ? Uimm : isAUIPC ? PC + Uimm : …`) and put isLUI|isAUIPC into wrEn — same shape
   as the jump path. Resource warning: 87% of the part is used; if the next tasks squeeze,
   share the ALU's three barrel shifters first (task-8 note) before touching anything else.
- **LUI and AUIPC** (task 11): processor.v — `wrEn |= isLUI|isAUIPC`, `wrData` gains two
   arms (`isLUI ? Uimm : isAUIPC ? PC+Uimm : aluOut`); PC still holds the instruction's
   own address during EXECUTE, so no extra latch needed. New tb/lui_auipc_tb.v (39 checks):
   wire walks of the first LUI (wrData = Uimm, NOT the ALU's rs1+Iimm garbage) and first
   AUIPC, LUI bit-31, LUI+ADDI = 0x12345678, AUIPC with bit-31 Uimm, same-Uimm-at-two-PCs
   (x9−x7 = 8 = PC difference), LUI to x0 dropped, 8-word lib cross-check. Also flipped
   processor_tb's stale "LUI still a NOP" regression to expect 0x12345000. 4455 total,
   LCs 1121 → 1182 (92%), Fmax 47 MHz.
   Surprises: three more MY-side constant slips in one session, all caught before touching
   RTL: (1) rd=7/rd=9 U-encodings 0x13B7/0x14B7 vs correct 0x1397/0x1497 (7<<7=0x380,
   9<<7=0x480 — I keep mis-hexing rd<<7); (2) 12 + 0x1000 = 0x100C, not 0x101C. Advice:
   write expected values as *expressions* (32'd12 + 32'h1000) where possible — the walk
   checks written that way passed first try while the literal ones failed. Resource alarm:
   92% of the part; the program-suite task is bench-only, but Loads/Stores will add logic —
   share the ALU's three barrel shifters (task-8 note) BEFORE loads/stores if pnr squeezes.
- **Program suite** (task 12): bench-only, no RTL change (LCs stay 1182/92%, Fmax 47 MHz).
   tb/programs_tb.v (90 checks, 4545 total): fib(10)=55 loop, gcd(48,18)=6 subtraction loop,
   CALL/RET sub called twice (a0=5→11, a0=20→41), nested main→f1→f2 with ra saved to x20 via
   ADDI + sp(x2) frame push/pop (acc 1+10+100=111, sp balanced, ra restored). Pattern: all
   four programs assembled MID-SIM into the live MEM (memPC=0 between programs, rest filled
   with EBREAK), run sequentially on the one Processor; halt = fetch strobe quiet 8 cycles;
   mid-run state polled at unique PCs; every word cross-checked vs hand-encoded expWord.
   Label workflow: pre-init `integer Lx = <byte addr>;` — Label() verifies vs memPC and
   endASM() $finishes the bench (no PASS) on a mismatch; LabelRef(L) returns L−memPC
   (relative), so JAL/branches take LabelRef directly. 5 FAILs, all mine, DUT+lib right
   again: (1) blt nibble swap 0x008C4663→0x0084C663; (2) I-type imm field is imm[11:0] —
   addi x2,x2,-4 = 0xFFC10113, NOT 0xFFF10113 (imm[31:20] of the 32-bit value is wrong);
   (3) copy-pasted jal +16 over the +8 site; (4) stray-bit typo 0x00010113; (5) polled PC 24
   (the sub's own ADDI, x11 still pre-commit) instead of the return site PC 8 — poll PCs
   where the checked writes have already committed.    Advice for Loads (next): 92% full —
   share the ALU's three barrel shifters (task-8 note) before adding load logic if pnr
   squeezes; loads also need the LOAD wait state + byte-lane/sign-ext mux on mem_rdata.
- **Shrink the core** (task 13): the refactor itself was already sitting uncommitted from
   iteration 17 (auto-commit ac26f16) — this session verified it instead of rewriting it.
   All four techniques are in: one 33-bit subtractor (aluMinus) feeds SUB/EQ/LT/LTU and the
   branch compares; one right-shifter with flip32 bit-reversal does SRL/SRA/SLL; one
   PC+imm adder serves JAL/AUIPC/branch targets (JALR reuses the ALU ADD); branchCond
   muxes the ALU's EQ/LT/LTU (no comparator in Processor); plus the `instr` register and
   the x0 read muxes are gone (mem_rdata holds the instruction through EXECUTE;
   RegisterBank[0] can only ever read 0). Numbers: 1182 LCs / 47 MHz / 5 BRAMs →
   66 LCs flattened / 878 LUT4 unflattened / 118.76 MHz / 3 BRAMs. All 10 benches pass
   unchanged (4545 checks).
   Surprises: (1) the flattened count is PROGRAM-DEPENDENT — with the datapath cleaned up,
   yosys prunes per-bit to what the ROM exercises: netlist PC is bits [9:2] only, x1 only
   [4:0], regfile BRAMs narrowed to 16-bit, ROM to one BRAM. I verified the 66-LC netlist
   really runs (port-level smoke bench in /tmp: LEDS walk cycle-exact) — and mid-session
   the harness hardened make check with `make equiv` (RTL-vs-netlist co-sim, 4000 cycles)
   and an unflattened-LUT4 budget gate, guarding this permanently. (2) A scratch program
   exercising high bits (LUI/ADD/SRA) re-widens the flattened netlist to 681 LCs / 6 BRAMs.
   Advice for Loads (next): watch the UNFLATTENED total (878/900), not the flattened 66 —
   load/store logic (~250 cells) lands on the unflattened number, so the margin is ~22
   LUT4; if it goes red, share further inside the ALU (e.g. fold the XOR arm into the
   subtractor path) before touching module boundaries.
- **Loads** (task 14): landed the previous session's WIP (4-cycle load: EXECUTE drives the
   read strobe with the ALU-computed address rs1+Iimm, LOAD wait state writes the extended
   data; lane/width/rd latched in FETCH_REGS because mem_rdata holds load *data* during
   LOAD). Memory itself unchanged — MEM[addr[9:2]] was already byte-addressable; lane
   select + sign/zero extension live in the Processor. Budget was red (1073 > 900), so the
   session became a shrink pass: **1073 → 885 unflattened** (Processor 565 → 377, ALU 485
   and Decoder 17 unchanged), pnr 84 LCs / 3 BRAM / 106.9 MHz, checks 4545 → 4612
   (+67 loads_tb: all 5 load types × all offsets, sign bits set/clear, DATAW/DATAB,
   negative offset, x0/x1 loads, LOAD-state cycle walk, 23-word hand-encoding cross-check).
   What paid: (1) 10-bit PC arithmetic — PC is stored 32-bit (benches read it) but only
   [9:0] is architectural (1 KB memory), so the +4 adder, the next-PC mux, the JAL/JALR
   link arm and the mem_addr fetch/load mux all shrank to 10 bits (−158 LUT4); AUIPC's
   pcPlusImm adder stays 32-bit because AUIPC writes the full PC+Uimm to rd. (2) ldExt as
   one parallel `case (ldFunct3)` with `half = ldOff[1] ? mem[31:16] : mem[15:0]` and
   ldHiByte = half[15:8] as wiring (−30). Surprises: (1) mid-session the harness raised
   LC_BUDGET 900 → 1150 (eb0be53) and scheduled a "Shrink round 2" after Stores — the
   shrink still landed at 885, leaving ~265 headroom for stores. (2) Dead ends, measured
   or worked: folding ADD into the shared subtractor via an isADD-complemented input is a
   wash (SB_CARRY needs the complemented bit as a raw input → +32 LUT4 cancels −32);
   routing JAL's link through the ALU needs 32-bit in1/in2 muxes (+64) vs the −30 adder.
   Advice for Stores (next): Memory gains mem_wdata/mem_wmask[3:0]; the store path is
   cheaper than loads (no sign extension — just a lane shifter/mask from addr[1:0] and
   funct3), and mem_addr is already 10-bit; keep the store data on rs2Val (already
   latched). Watch the unflattened total after the change; round-2 shrink (ALU ~490 →
   ~250 per the harness note) comes only after Stores.
- **Stores** (task 15): Memory gained `mem_wdata`/`mem_wmask[3:0]` (four per-lane write
   guards in the same always block as the read). Processor store path: `aluIn2` picks Simm
   for stores, `aluFunct3` forced 000 for `isLoad|isStore` (shared address adder), and
   `storeWrite = isStore & (state == EXECUTE)` gates both the mem_addr mux and mem_wmask —
   the gate is load-bearing because the decoder still decodes the old store during the
   following FETCH_INSTR (mem_rdata holds) and would otherwise write to the *fetch* address.
   stData replicates the byte/halfword across all four lanes (pure wiring), stMask comes
   from funct3 + aluOut[1:0]; stores take the plain 3 cycles, no wait state. New
   tb/stores_tb.v (81 checks, 4693 total): per-cycle SB walk (no read strobe, wmask/wdata,
   write commits on the edge leaving EXECUTE), SB 0..3 lane isolation over poison, SH 0/2,
   SW, SW-over-SB clearing the SB's byte, sign-bit 0xFF/0x80/0xFFFF via LB/LBU/LH/LHU,
   negative-offset SB, poison neighbours intact, 39-word expWord cross-check.
   Numbers: 885 → 1010 unflattened LUT4 (Processor 377→451, Memory 0→51 write-merge; ALU
   485 untouched), pnr 914 LCs / 6 BRAMs / 46.5 MHz, budget 1150 OK.
   Surprises: (1) first program put the data area at 0x80 while the program had grown to
   39 words (0x98) — the stores overwrote their own program mid-run; data base moved to
   0xA0. (2) Four expectation slips, DUT right every time: MEM[44] had 0x80 in the wrong
   byte, MEM[45] forgot the first SH already wrote 0xFFFF, the -8-offset SB landed on byte
   0 (0xA8-8=0xA0) with x2=0x44 not 0x22 (rebased x19 to 0xA9), and expWord kept the old
   128/136 immediates. (3) My python slicer encoded loads with ADDI's opcode 0x13 — check
   the script against the spec formula too, it had its own bug. Advice for Shrink round 2
   (next): Memory's +51 is the byte-enable read-modify-write merge (yosys log shows how it
   mapped); Processor's +74 is the store path; ALU 485 → ~250 remains the big prize per
   the harness note.

- **Handoff from an interrupted session (hit the step cap mid-edit on "Shrink the core, round 2"; tree is RED). Its own notes, verbatim:**

  > **Maximum steps for this agent have been reached.** Tools are disabled; here is the handoff state.
  > 
  > ## ⚠️ CRITICAL: The repo is currently MID-EDIT and `make check` is RED
  > 
  > `rtl/processor.v` will **not compile** right now. I restructured the AUIPC path (AUIPC now goes through the ALU) and replaced the 32-bit `pcImm`/`pcPlusImm` adder with a 10-bit `pcImm10`/`pcPlusImm10`, but three references to the old `pcPlusImm` wire still exist in the file and must be fixed before anything builds:
  > 
  > 1. **`wrData` mux** — remove the `isAUIPC ? pcPlusImm :` arm entirely (AUIPC now falls through to `aluOut`, which equals PC + Uimm; this is the whole point of the restructure).
  > 2. **EXECUTE PC update** — change `doBranch ? {22'b0, pcPlusImm[9:0]}` to `doBranch ? {22'b0, pcPlusImm10}` (numerically identical: low 10 bits of the old 32-bit sum).
  > 3. **`branchTarget` alias** — change `wire [31:0] branchTarget = pcPlusImm;` to `= {22'b0, pcPlusImm10;}` (benches only check it at small positive values 20/28/52, which agree).
  > 
  > ## What was accomplished (evidence-based ablation, all in `/var/folders/.../T/opencode/alu_exp`)
  > 
  > - `make check` was green at start: 4693 checks, 1010 unflattened LUT4 (ALU 485, Processor 451, Memory 51, Decoder 17, Clockworks 6), budget 1150. Task: reach ≤ 950.
  > - **ALU ablation (485)**: shifter+flips ≈ 244, logic ops 94, subtractor/EQ/LT/LTU 92, ADD 52. Key findings: `flip32` IS pure wiring standalone, but costs ~44 (output) + ~33 (input mux) in the ALU because the SLL flip defeats mux-arm merging — hoisting to continuous assigns did **not** help (still 485). The task hint's "~250 ALU" is not achievable with the fixed interface (EQ/LT/LTU are checked on every vector in `tb/alu_tb.v`, so the always-on compare subtractor must stay → two adders minimum). ALU floor ≈ 485; leave it.
  > - **Processor ablation (448 standalone)**: load path only 61 (already in the hint's suggested shape — hint's "~200" was wrong), store 4, branchCond 5, but the **`wrData` mux tree costs 231**, of which the AUIPC arm + its 32-bit `pcImm` mux + 32-bit adder ≈ 127.
  > - **Designed fix (partially applied)**: route AUIPC through the ALU (`aluIn1 = isAUIPC ? PC : rs1Val`, `aluIn2` gains Uimm arm, `aluFunct3` forces 000 for AUIPC too) → PC+imm adder shrinks to 10 bits, `wrData` loses an arm. Estimated net ≈ −50 to −60 LUT4. Applied so far: `aluIn1`/`aluIn2`/`aluFunct3`/ALU instantiation and the `pcImm10`/`pcPlusImm10`/`jumpTarget` block (with updated comments).
  > 
  > ## Remaining work (next session)
  > 
  > 1. Apply the three fixes above, then `make sim` (all 12 benches, 4693 checks must pass unchanged — `lui_auipc_tb`'s `wrData`/register checks still hold since AUIPC writeback value is unchanged) and `make stat`.
  > 2. If still above 950: (a) merge `ldExt`'s 5-arm case into 3 arms (LB/LBU and LH/LHU share data, `ldFunct3[2]` picks sign/zero fill; est. −10); (b) optionally move the ALU's output flip into `shRight` so SLL/SRL arms merge (est. −12).
  > 3. `make check` fully green (incl. `equiv`), tick the task in `TASKS.md`, append before/after per-module numbers to `PROGRESS.md` (include the ablation findings — they contradict the task hint's estimates and will save the next shrink session hours), commit `task: shrink round 2 — AUIPC through ALU, 10-bit branch/JAL adder`.
   > 4. Do **not** start the next task (Memory-mapped IO).

- **Shrink the core, round 2** (task 16): started from the interrupted session's RED tree —
   applied its three documented fixes (drop the `isAUIPC ? pcPlusImm` wrData arm, EXECUTE PC
   update and `branchTarget` alias onto `pcPlusImm10`) plus moved `pc10`'s declaration above
   the adder block (iverilog "declaration after use" was the actual compile error). That
   completed the AUIPC-through-ALU restructure: 1010 → 971 (Processor 451 → 412). Then two
   more moves landed: ldExt 5-arm case → 3 data arms + fill-bit mux (0 unflattened change),
   and **LUI through the ALU** (in1 = 0, in2 = Uimm, funct3 forced ADD; wrData loses its
   isLUI arm): Processor 412 → 382. Final: **941 unflattened** (ALU 485, Processor 382,
   Memory 51, Decoder 17, Clockworks 6) ≤ 950 goal; pnr 860 LCs / 6 BRAM / 47.62 MHz;
   4693 checks unchanged; equiv 4000 cycles 0 mismatches.
   Measured ablations (scratch harness in /tmp, yosys -noflatten per module): (1) ldExt
   merge saved 0 unflattened — yosys had already merged the shared data across the
   sign/zero arms (only −8 flattened LC); (2) pre-muxing the ALU's SLL output flip into one
   shOut case arm cost +1 — the two-arm case is better, abc folds the arm select for free;
   (3) LUI-through-ALU −30, the real win: a constant-0 arm in aluIn1 folds into the LUT
   while a 32-bit Uimm arm in wrData does not. Confirmed the interrupted session's ALU
   floor ≈ 485 (shifter+flips 244, logic 94, subtractor/EQ/LT/LTU 92, ADD 52) — the task
   hint's "~250 ALU" is unreachable with EQ/LT/LTU as always-on outputs; its
   ADD-into-subtractor and JAL-link-through-ALU ideas measured as washes/losses.
   Advice for Memory-mapped IO (next): 941 + ~100 for UART/IO ≈ 1041 < 1150 budget, no
   shrink needed before starting; the address decode is a bit-22 compare + word-offset
   muxes, and `mem_addr` is already 10-bit — IO space sits above bit 22 so the RAM decode
   is unchanged.

- **Memory-mapped IO** (task 17): SOC decodes `mem_addr[22]` as IO space — bit 2 → LEDS
   write reg, bit 3 → UART data write, bit 4 → status read (bit 9 = busy = ~o_ready);
   `corescore_emitter_uart` at 12 MHz/115200. RAM read strobe and write mask are gated off
   while ioSel, so IO addresses cannot alias into MEM[addr[9:2]]. Processor's load/store
   mem_addr half widened 10 → 23 bits (`{9'b0, aluOut[22:0]}`; fetch side still pc10) —
   bit 22 never left the chip before this. The read mux uses a REGISTERED ioSelR: during
   the LOAD wait state mem_addr is back at the PC, so the combinational decode is gone
   exactly when the Processor consumes mem_rdata. io_tb (62 checks, 4755 total): program
   writes 5'b10101 to LEDS (on the SOC port), sends "OK\n" waiting on busy; bench has a
   mid-bit 115200-baud receiver (nominal 8680.6 ns/bit) checking the 3 bytes + stop bits;
   19-word lib-vs-hand cross-check; RAM-intact and halt checks. Numbers: 941 → 1031
   unflattened (emitter 27, SOC 50, Processor 382→395), pnr 981 LCs / 6 BRAM / 42.48 MHz.
   Surprises: (1) the emitter's `data` reg has NO power-on value → in RTL sim `|data` is X
   forever and o_ready never resolves (hardware FFs power up 0, so it only bites sim);
   io_tb kicks `dut.uart.data = 0` at t=0, and SOC gates TXD with a sticky txStarted reg
   (`TXD = uartTx | ~txStarted`) so the X never escapes — this also keeps equiv green
   (X|1 = 1 on both sides). (2) The emitter swallows a single-cycle i_valid pulse that
   lands on its internal shift edge (~1 in 106) — SOC HOLDS i_valid until o_ready drops
   instead of pulsing. (3) The emitter's real bit period is 106 clocks (12e6/106 ≈ 113.2
   kbaud, 1.7% slow — the counter wraps 0→255 before the shift), mid-bit sampling at the
   nominal rate still has 0.35-bit margin on the last data bit. (4) The lib's SRLI macro
   is BUGGY — encodes `srl rd,rs1,x(shamt)` (funct7 0, shamt as rs2); SLLI is accidentally
   right, SRAI correct. Used ANDI(x13,x13,512) for the busy-bit test. (5) Lib LUI takes
   the FINAL value — LUI(x5,32'h00400000), not 0x400 (misread the task-7 note, one wasted
   sim round; the EXP cross-check caught it). Advice for the demo program (next): all IO
   infrastructure is done and proven — ROM program needs LUI base 0x400000, SW to
   0x400004 (LEDS) / 0x400008 (UART data), LW 0x400010 + ANDI 0x200 busy-wait (copy the
   io_tb pattern; remember the lib SRLI/LUI quirks). 119 LUT4 headroom, no shrink needed.
   Note: equiv only exercises the ROM program (LEDS/TXD ports), IO logic is covered by
   io_tb alone; soc_tb's LEDS expectations are now "dark" (same 62-check count).

- **Hardware demo program** (task 18): ROM is now the real demo — 22 code words + 3 message
   words: LB/SW banner loop ("Loop RISC-V\n", 12 bytes from word 22, busy-wait on status bit 9
   via LW+ANDI 512+BNE), then a LED walk 1,2,4,8,16→restart forever (ADD x9,x9,x9 / ANDI 31 /
   restart JAL) paced by a countdown loop: `ifdef BENCH` delay=2 (~30 cycles/step), hardware
   LUI 0x7A000+ADDI 0x120 = 500000×6 = 3.0M cycles = 0.25 s/step at 12 MHz. soc_tb rewritten
   (102 checks): 12-byte mid-bit receiver, LEDS-dark-until-banner, full cycle 1,2,4,8,16→1,
   step-gap ∈ [25,60], PC-in-loop liveness, three-way ROM check (python-verified hand words vs
   lib-assembled bench copy vs dut.memory.MEM). memory_tb re-assembles the program itself
   (fill now starts at word 25). 4755 → 4814 checks; LCs unchanged (1031 LUT4 unflattened,
   981 pnr, 43.35 MHz). equiv needed a fix: the ROM now uses the UART, so the RTL instance's
   X-poisoned emitter handshake (no power-on values; netlist FFs power up 0) diverged from the
   netlist at cycle 34 — added the same `initial rtl.uart.data = 0` kick io_tb/soc_tb already
   use to tools/equiv_tb.v (sim-only artifact, hardware unaffected).
   Surprises: (1) module-level `integer i` is shared across initial blocks — the assembly
   block's check loop at t=1ns clobbered the main block's reset-loop counter mid-iteration
   (15 checks silently skipped); the assembly block now has its own `wi`. (2) LB is funct3
   000, not 010 (that's LW) — my python encoder call was wrong, the lib was right again.
   (3) Emitter acceptance is every-clock (1-cycle latency), so the SW→busy-wait pattern has
   no race; busy lasts ~1166 clocks/byte (1060 transmit + ~106 ready delay) → banner ≈ 14k
   clocks ≈ 1.2 ms. Ready for the human: `make prog` then `make uart` shows the banner once,
   LEDs walk at 4 Hz.

- **Hardware fix: hold reset until the block RAM is ready** (task 19): Clockworks gained
   `parameter RESET_CYCLES` — 65536 default (hardware: iCE40 BRAM unreadable for several µs
   after config; 65536 cycles = 5.46 ms at 12 MHz), 16 under `ifdef FAST_SIM` so every bench
   keeps its timing. Counter width is `$clog2(RESET_CYCLES)+1`, sticks at its terminal value
   via the old MSB-tap (`resetn = por[MSB]`) — so RESET_CYCLES must be a power of two (all
   uses are: 16/64/65536); a general compare would cost ~8 LUT4 for nothing. Benches: +65 in
   clockworks_tb (RESET_CYCLES=64 instance: low through posedge 63, high after 64, stays high),
   +3 in processor_tb (`state == FETCH_INSTR` during reset, PC=0 was already checked), +15 in
   soc_tb (explicit `resetn` low + LEDS dark per cycle). 4814 → 4897 checks. Numbers:
   Clockworks 6 → 18 LUT4 unflattened (17-bit counter), total 1031 → 1043 (budget 1150),
   pnr 981 → 986 LCs, Fmax 43.35 → 45.54 MHz, equiv 0 mismatches.
   Surprises: (1) the Makefile's equiv target passes `-DFAST_SIM` to yosys (line 60) — that is
   what keeps the netlist and the RTL sim in agreement at 16 cycles; synth/pnr/lint compile
   without it, so only the bitstream sees 65536. Do not "simplify" that flag away. (2) soc_tb's
   old "16 dark cycles" loop sampled *after* the 16th posedge, where resetn is already high —
   the LEDS-only checks masked it because LEDS stays dark one cycle longer; the resetn-low
   check caught it immediately. Sampled-cycle vs counter-cycle off-by-one is the trap here
   (clockworks_tb's original 15+1 structure already encodes it). All tasks in TASKS.md are
   now checked — the design is ready for the human to run `make prog` / `make uart`.

- **UART receiver** (task 20, phase 2): `rtl/uart_rx.v` — 4-state FSM (IDLE/START/DATA/STOP),
   two-flop sync + falling-edge detect, mid-start sample rejects false starts, bits sampled
   every BIT_CLKS=104 from mid-start, `valid` pulses one clock at mid-stop. SOC: `rxAvail`
   reg (set-priority over the read-clear so a byte completing on the read cycle survives),
   IO word `0x400020` = `{23'd0, avail, data}` in the ioRdata mux. uart_rx_tb (27 checks,
   4924 total): idle silence, single byte with a mid-stop timing window (valid at 9.5 bit
   periods + 1..4 clocks after the start edge — distinguishes mid-bit from frame-end
   sampling), back-to-back bytes, byte after ~34-bit idle, 20-clock glitch ignored + FSM
   recovery, per-pulse one-clock-width check, pulse-count total; SOC section checks
   rxAvail/`{avail,data}` word/read-clears-avail. Numbers: 1043 → 1082 LUT4 unflattened
   (UartRx 37, SOC 50 → 52), pnr 986 → 1064 LCs (83%), Fmax 45.54 → 40.31 MHz, equiv clean.
   Surprises: (1) `valid` fires at mid-stop, ~4.3 µs BEFORE `send_byte` returns — a task
   that starts polling afterwards always misses the one-clock pulse (first run's 2 FAILs);
   fixed with a capture monitor (records data/timestamp of every pulse, checks the width
   inline) that `wait_valid` consumes from a queue. (2) The SOC read path is tested by
   hijacking the bus: `force soc.mem_rstrb/mem_addr` for exactly one cycle, release, sample
   `mem_rdata` the next edge (ioSelR routes the registered ioRdata) — works fine in
   iverilog; the running demo program shrugs it off (RX word 0x41 decodes as an illegal
   opcode = NOP; picked test bytes for exactly that). (3) Bench clock is 83.334 ns (1 ps
   rounding) vs the nominal 83.3333 — 0.17 clocks/bit drift, absorbed by the timing window.
   Advice for Echo (next): the RX word is a plain LW from 0x400020, avail test = ANDI 256
   (lib SRLI is buggy, task-17 note); copy uart_rx_tb's `send_soc` transmitter model into
   soc_tb for the "hi" round-trip; LEDS = byte & 31 after the walk. 68 LUT4 headroom left.

- **Echo program** (task 21, phase 2): found the whole task already sitting uncommitted in the
   working tree from an interrupted session — verified it instead of rewriting it. ROM: banner →
   LED walk exactly ONCE (the old restart JAL is gone; `ADD x9,x9,x9; ANDI x9,x9,31` wraps 16→32→0
   and `BNE x9,x0,LSTEP` falls through) → echo loop forever (LW 0x400020, ANDI 256 avail test,
   SW byte to UART data, busy-wait bit 9, LEDS <- byte & 31, JAL back). Message moved word 22 → 30
   (program now 30 code words). soc_tb 117 → 339 checks: concurrent `fork send_byte/recv_byte`
   (the DUT starts echoing at the incoming frame's mid-stop, BEFORE send_byte returns — sequential
   recv misses the echo's start edge), 'h' and 'i' echoed, LEDS == "i" & 31 = 9, LEDS hold 16 while
   polling, PC in 80..116 during the poll, 33-word three-way ROM cross-check. memory_tb 1057 → 1065
   (fill now starts at word 33). 4924 → 5154 checks; LCs unchanged (1082 LUT4 unflattened, pnr
   1063 / 41.59 MHz), equiv clean.
   Surprises: (1) the define split is deliberate — rtl/memory.v uses `ifdef FAST_SIM for the delay
   constant while the bench copies use `ifdef BENCH; both are defined for every sim (Makefile
   IVFLAGS) and both undefined for the bitstream, so they always agree, and the three-way ROM
   cross-check would catch drift if that ever changed. (2) The echo's SW lands while the emitter
   is idle by construction: each iteration's busy-wait exits only after the previous byte finished,
   so no write is ever dropped — but the RX side is one byte deep, so the bench sends the next byte
   only after the previous echo (a real host typing slowly is fine). (3) equiv's led_changes=6 with
   no RX input: banner-dark + 5 walk steps; the echo loop just polls with LEDS=16 forever.
    Ready for the human: `make prog`, then `screen /dev/cu.usbserial-*1 115200` — banner, one LED
    walk, then every typed byte echoes back with its low 5 bits on the LEDs. Advice for 6 KB RAM
    (next): Memory is 256 words / addr[9:2] everywhere; the task needs 1536 words and 13-bit
    addressing (PC[12:0], fetch/load/store addr paths) — the ROM program sits at 0 so its byte
    constants (message at 120) don't move; memory_tb's fill/expWord and the 256-word loops all
    need the new bound; watch the LUT budget (1082 + wider adders, 68 headroom).

- **Shrink the core, round 3 — the ALU** (task 22): landed the best provable structure:
  **ALU 485 → 434 LUT4** (total 1082 → 1031, pnr 1063 → 1033 LCs / 80%, Fmax 41.59 → 41.09 MHz,
  all 5154 checks + equiv unchanged). The task's targets (ALU ≤ 320, total ≤ 980) are **proven
  unreachable with the bench unchanged — task deliberately left unchecked**; the analysis below
  is the deliverable. What worked (scratch harness in /var/.../opencode/alu_exp3, yosys
  `synth_ice40 -top ALU` per variant, each also run against the real tb/alu_tb.v):
  (1) **split the output mux on funct3[2]** into two full 4-arm cases on funct3[1:0] + one final
  2:1 — the old single 8-arm `case (funct3)` was the whole problem: a logic-ops-only ablation
  costs 162 LUT4 under a 3-bit case with default but **32 LUT4 (exactly 1/bit)** under a 2-bit
  case; −49 on the full ALU. (2) mirror the shifter as a LEFT shifter (SLL shifts in1 directly,
  SRL/SRA shift bit-reversed in1 and flip the output) with the reversal mux selected by plain
  funct3[2] — SLL (001) and SRL/SRA (101) differ only in that bit and every other encoding is a
  shifter don't-care, so the isSLL decoder disappears; left-shift fill lands in the low bits,
  which after the output flip are the SRL/SRA high bits, so fill = f3[2] & f75 & in1[31]; −2.
  Dead ends, all MEASURED: explicit 5-stage log shifter == the `>>>` expansion (485 both — yosys
  was already optimal, hint approach 1a is a no-op); per-bit indexed output case +3; pre-muxing
  the shifter output into one signal fed to both cases +49 (abc merges case arms better than any
  explicit pre-mux — do not "help" it); f3[1] split +104, f3[0] split +57; nested-ternary
  two-level split +41 (hint's ternary warning is right); EQ as carry-out of `~aluMinus+1` +22
  (yosys keeps the sum-bit LUT4s, only the CARRY would have been free); add-form subtractor is
  a wash AND a polarity trap — `{1'b0,~in2}+in1+1` gives bit32 = carry = ~borrow, 1009 bench
  FAILs until LTU/LT invert it; **ADD/SUB-into-one-adder (hint approach 2) is impossible**: the
  bench checks EQ/LT/LTU against a pure in1-vs-in2 compare on EVERY vector (counterexample
  sweep_pair(1,−1) with ADD: out=0 but EQ must be 0; a merged adder says 1), so the always-on
  compare subtractor can never merge with the out-adder — two adders are a hard floor.
  Floor analysis (why 320/980 are unreachable): shifter 197 (160 = 5×32 stage muxes — a pure
  one-direction shifter measures 165 with fill — plus the 32-LUT4 reversal mux, which is
  information-theoretically necessary: SLL/SRL differ by exactly one bit-reversal of the input,
  no fixed shifter input produces both) + adders 65 (33 sub + 32 add, 63 SB_CARRY) + EQ/LT 13
  (32-input NOR tree ≈ 11 + LT sign mux 2) = 275 before ANY output mux; the output mux needs
  ≥5 LUT4/bit here (addSub pre-mux, logic-trio LUT4, shifter-arm insert, dataOut select, final
  f3[2] select — each genuinely 4-input, no folding room), ≈157 measured. Floor ≈ 430, landed
  434. Total ≤ 980 needs ALU ≤ 383 with Processor/Memory frozen by the task — below the floor.
  Options if the harness wants this closed: relax the numbers to 434/1031 (the honest floor), or
  allow the bench to check EQ/LT/LTU only where architecturally meaningful (then the merged
  adder becomes legal, est. ~380-400 — still not 320). Advice for the next session: if this task
  returns with the same numbers, do NOT re-derive — the 12-variant table above is exhaustive;
  the reusable insight is the **2-bit-case/1-LUT4-per-bit** trick, worth checking anywhere abc
  maps a wide sparse case (Decoder's one-hot flags are 17 LUT4, probably fine).


- **Handoff captured by loop.sh — iteration 1 ended without ticking its task (tree: green). The session's last message, verbatim:**

  > `make check` fully green: **ALU 485 → 434 LUT4, total 1082 → 1031, pnr 1033 LCs (80%), Fmax 41.09 MHz, equiv clean, all 5154 checks unchanged.**
  > 
  > The task's specific targets (ALU ≤ 320, total ≤ 980) are another matter — I've now measured 12 structural variants and can show they're unreachable with the bench unchanged. Per AGENTS.md, I'll leave the task unchecked, document the proof, and commit the real improvement. Writing the PROGRESS.md entry:
  > Now the commit — first inspect the repo state per the workflow:
  > Session complete. Summary of what happened:
  > 
  > **Task: "Shrink the core, round 3 — the ALU"** (first unchecked in TASKS.md)
  > 
  > **Result: ALU 485 → 434 LUT4** (−51), `make check` fully green — 5154 checks in 14 benches unchanged, equiv clean, unflattened total 1082 → 1031 (budget 1150), pnr 1033 LCs (80%), Fmax 41.09 MHz.
  > 
  > **What landed in `rtl/alu.v`:**
  > 1. **Output mux split on `funct3[2]`** into two full 4-arm cases on `funct3[1:0]` + one final 2:1 — the single 8-arm `case (funct3)` was the real problem: a logic-only ablation costs 162 LUT4 under a 3-bit case but **32 LUT4 (1/bit)** under a 2-bit case. −49.
  > 2. **Left-shifter mirror**: SLL shifts `in1` directly; SRL/SRA shift the bit-reversed operand and flip the output. The reversal mux is selected by plain `funct3[2]` (SLL=001/SRL=101 differ only in that bit; all other encodings are shifter don't-cares), so the `isSLL` decoder disappears. −2.
  > 
  > **Why the task's ≤320/≤980 targets are left unmet (task deliberately left unchecked, per AGENTS.md):** I measured 12 structural variants and the floors are provable — the bench checks `EQ/LT/LTU` against a pure `in1` vs `in2` compare on *every* vector, which makes the always-on compare subtractor non-negotiable (the task's approach (2), merging ADD/SUB into one adder, fails on `sweep_pair(1,−1)` with ADD: out=0 but EQ must be 0); the SLL/SRL reversal mux is information-theoretically necessary; the 5×32 log-shift stages measure 165 pure; and the output mux needs ≥5 LUT4/bit. Floor ≈ 430; 434 is at it. Total ≤980 would need ALU ≤383 with Processor/Memory frozen — below the floor. All of this, plus the measured dead-end table (explicit stages = no-op, pre-muxing +49, ternaries +41, carry-chain EQ +22, add-form subtractor polarity trap, etc.) and the options for the harness, is written into PROGRESS.md so the next session doesn't re-derive it.
  > 
  > Committed as `75c086f`. Stopping here — one task per session.


- **6 KB of RAM** (task 23, phase 2): found the task already merged — the WIP branch
   (ae28291, parked at 1162 LUT4 over budget) was merged as bc21d76 once shrink round 3
   freed ALU 485→434; this session verified the merge instead of rewriting it. Memory is
   1536 words indexed `mem_addr[12:2]`; Processor PC arithmetic is 13-bit (`pc13`,
   `pcPlus4`, `pcPlusImm13`, PC updates `{19'b0, …}`), fetch addr `{19'b0, pc13}`,
   load/store addr keeps bit 22 + `aluOut[12:0]` (bits [21:13] dropped — IO decode
   unchanged; soc.v diff is a comment only). Benches: memory_tb 1065 → 6194 (full
   1536-word read + unaligned-offset sweeps, SW at the last word 6140, words 256/4096,
   SB/SH lane isolation above 1 KB, read-backs), programs_tb 90 → 124 (P5: trampoline
   JAL 0→4096 — the old 10-bit PC path would wrap 4096&0x3FF=0 and spin, so reaching the
   program at all proves the 13-bit JAL target; data at 5120, sum 100..800 = 3600,
   SW/LW round-trip at 5152, hand-encoding cross-check). 5154 → 10317 checks, equiv
   clean (40000 cycles, 0 mismatches). Numbers: 1108 LUT4 unflattened (budget 1150),
   pnr 1100 LCs / 85%, Fmax 38.85 MHz.
   **BRAM: 16/16, not the task's estimated 14 — and 16 is the floor.** Measured split
   (yosys stat per module): MEM = 12 (1536×32 = 49152 bits = exactly 12 RAM4K), regfile
   = 4. The task's "register file uses 2" is impossible on this part: RAM4K's widest
   mode is 256×16, so one 32-bit sync read port needs 2 blocks, and 2 read ports + 1
   write port need 2 copies → 4. It fits the part exactly (pnr PASS) but ZERO BRAM
   headroom remains — any future BRAM need must shrink the regfile (narrow/time-mux the
   read ports) or live inside the 6 KB.
   Advice for RDCYCLE (next): decode in Processor as `isSYSTEM && funct3==010 &&
   Iimm[11:0] ∈ {0xC00, 0xC80}` — isSYSTEM currently halts unconditionally, so add the
   counter-read arm BEFORE the halt and keep every other isSYSTEM encoding halting
   (programs_tb's waitHalt and every EBREAK bench depend on it). The 64-bit counter is
   ~64 FFs (not LUTs) but the rd read mux into wrData is a 32-bit 2:1 (~32 LUT4); LUT
   headroom is 42 (1108/1150) — tight but enough. The counter must free-run through
   reset (or at least not reset with the CPU: "free-running" per the task) and benches
   will count instructions between reads: 3 cycles/instr, +1 per load (4-cycle loads).
