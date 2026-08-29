# Progress log

Append-only notes from the loop agent. One short entry per iteration.
This file is the agent's only memory between sessions — write down what
the next session needs to know, not what it can read from the code.

---

lib/riscv_assembly.v) as the true independent cross-check; note the lib needs a `MEM`-bearing

   module to include into.

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

- **Handoff captured by loop.sh — iteration 1 ended without ticking its task (tree: TIMEOUT). The session's last message, verbatim:**

  > Hard numbers: Processor +109 LUT4 and **+62 SB_CARRY** — the 64-bit ripple counter's carry chain is the real cost. Let me see what pnr does with it:
  > pnr is 1203/1280 — fits the part but over the Makefile's 1150 line, and the unflattened count is 1217. The naive 4-arm writeback mux is the first thing to fix: during a CSR read the ALU output is provably 0 (`SLT(0, negative Iimm)`), so the CSR value can be **OR-ed** into the existing tree instead of added as a fourth arm — one LUT/bit instead of two mux levels. Let me restructure:
  > The OR-trick got Processor to 439 (+36) and the unflattened total to **1144 — under budget**. But sim now fails on the read values. Let me see the full failure list:

- **Handoff captured by loop.sh — iteration 2 ended without ticking its task (tree: TIMEOUT). The session's last message, verbatim:**

  > Odd — same command gives Processor 492 in scratch vs 530 in `make stat`. Let me check if yosys/abc is non-deterministic run-to-run:
  > The scratch copies were stale (pre-fix) — that explains 492 vs 530: the correct 32-bit read path costs +38. So the read path is already tight. The suspect is now the counter itself (~175 LUT4 for a 64-bit +1 is way over the ~64 expected). Let me see the Processor cell breakdown:
  > Processor local: 530 LUT4 + 83 SB_CARRY (the counter's carry chain) and the regfile mapped to 4 BRAMs with `rs1Val/rs2Val` absorbed into BRAM output registers. Let me quantify each piece with ablation variants in the SOC context:
  > vA got the stale scratch copy — let me redo it from the repo's current file and apply the ablation edits:

- **Handoff captured by loop.sh — iteration 1 ended without ticking its task (tree: RED). The session's last message, verbatim:**

  > HEAD flat = 1032 LUT4/110 carry (pnr 1100); old486 flat = 1101/140 (pnr ≤1150); v6 flat = 1115/140 (pnr 1187). My slicing helped unflattened but hurt the flattened cone. Let me isolate which change hurt flat: measure v3c (original aluIn2) and v5 (ternary slice)flattened.
  > v3c flat = 1106, v5 = 1109, v6 = 1115 — the slicing costs a little flat but saved huge unflat. Critical realization: the old486 pnr LC was likely >1150 all along (the stat rule checks unflattened FIRST, so the pnr LC grep never ran). I need **both** gates ≤1150. Let me measure the real pnr LC for v3c, and flat-ablate the big blocks to find flatfat.
  > v3c pnr = 1178 — even the original aluIn2 fails pnr; the feature costs ~78 pnr LCs (1100→1178) but pnr headroom is only 50. I need ~28-37 more LCs from the flat netlist. Flat ablations on the v6 base to find theslop.
  > **MAXIMUM STEPS REACHED — session must stop here. `make check` is RED (pnr gate), work is uncommitted. Below is the full state and handoff.**
  > 
  > ## What this session accomplished
  > 
  > **Task:** "Cycle counter, part 1: a 32-bit counter and its CSR read" (first unchecked in TASKS.md). The previous session left the RTL functionally complete but `make stat` red (1191 unflattened > 1150). All 15 benches already passed (10357 checks), including `tb/cycle_tb.v` (C1–C5: read-diff = 3×instr+1/load, cycleh→0, x0 dest, EBREAK halt + free-run, other SYSTEM encodings halt).
  > 
  > **This session's work was pure area optimization.** Measurements (yosys `synth_ice40 -top SOC -noflatten` per module, plus flattened + nextpnr):
  > 
  > | variant | unflat total | flat LUT4 | pnr LC |
  > |---|---|---|---|
  > | HEAD (pre-task) | 1108 (Proc 406) | 1032 | 1100 |
  > | session start (old tree) | 1191 (Proc 486) | 1101 | ~1178 (never checked!) |
  > | v3c: cheap decode + wrData hi/lo split | 1182 (Proc 477) | 1106 | 1178 |
  > | **v6 (now in repo): + aluIn2 2-bit-case slice** | **1145 (Proc 440)** | 1115 | **1187** |
  > 
  > Key findings:
  > 1. **The counter itself is 33 LUT4 + 30 SB_CARRY + 32 SB_DFFSR** (floor; measured in isolation). Decode+control = +13. The wrData OR arm = +25 as written by the previous session.
  > 2. **The old `aluIn2` 4-way priority mux cost 98 LUT4 unflattened (abc maps 7-input muxes at 3 LUT4/bit)**. Since `Simm[31:5] == Iimm[31:5]` and `Uimm[11:0] == 0`, it slices into a 2-bit `case` at 1–2 LUT4/bit → saved 37 unflattened (486→440... combined with the other edits).
  > 3. **The stat rule checks unflattened FIRST, then pnr LC — so the pnr LC gate was never reached before.** The feature costs ~78 pnr LCs (1100→1178) but pnr headroom is only 50. **Both gates must be ≤1150; the task's "~50 LUT" estimate is ~25 too optimistic.**
  > 
  > ## Current repo state (uncommitted)
  > 
  > `rtl/processor.v` has three semantics-preserving edits (all benches pass, `make sim` = 10357 checks in 15 benches, equiv clean, timing 37.25 MHz):
  > - Cheap CSR decode: `isCSRaddr = (Iimm[11:8]==4'hC) & (Iimm[6:0]==0)`, `isC00 = isCSRread & ~Iimm[7]`
  > - `aluIn2` sliced into a 2-bit case (in2Hi/in2Mid/in2LoS)
  > - `wrData` split at bit 13 so the CSR OR absorbs into the `~doJump` gate above the link's top bit
  > 
  > `make check` result: **unflattened 1145 ≤ 1150 PASSES; pnr ICESTORM_LC 1187 > 1150 FAILS.**
  > 
  > ## Remaining work (next session)
  > 
  > Need **−37 pnr LCs** from the flattened netlist (1115 LUT4 + ~72 unshared carries). Recommended path, in order:
  > 1. **Run the flat ablations I had just set up** (dirs `fa1/fa3/fa4` in the scratch dir, copies of v6 with one block killed each: `mem_wdata=0`, `ldExt=0`, `aluIn2=Iimm`) to find where the *flattened* netlist has slop vs floor. Unflat floors already measured: stData 32 (at floor), ldExt ~66, PCmux ~26.
  > 2. Try `v7`: keep the aluIn2 case slice for [31:5] but leave [4:0] as the original 4-way ternary (the `in2Lo` pre-mux is the likely flat-carry-packing culprit; costs +5 unflat → 1150 exactly, still passes).
  > 3. If still over: the honest conclusion per the task text ("if it goes over, that is a real problem, not a proxy one — stop and note it") is that **the feature fundamentally costs ~70 LUT4 against ~42-50 headroom**; either the budget must rise or a "shrink round 4" (flat-context) must precede this task. Document in PROGRESS.md and leave unchecked.
  > 4. Do NOT commit as-is: `make check` is red. Either fix pnr or revert `rtl/processor.v` to HEAD (git checkout) and leave a PROGRESS note with this table.
  > 
  > Scratch dir with all variants/logs: `/var/folders/6m/bgvxvyjs0zv6g9fcgvcclzyh0000gn/T/opencode/cyc1a/` (v1–v6, a1/a4, fa1/fa3/fa4, f0, ctr.v, *.log).

