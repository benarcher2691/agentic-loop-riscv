# Progress log

Append-only notes from the loop agent. One short entry per iteration.
This file is the agent's only memory between sessions — write down what
the next session needs to know, not what it can read from the code.

---

lib/riscv_assembly.v) as the true independent cross-check; note the lib needs a `MEM`-bearing

   module to include into.

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

- **Handoff captured by loop.sh — iteration 1 ended without ticking its task (tree: TIMEOUT). The session's last message, verbatim:**

  > Hard numbers: Processor +109 LUT4 and **+62 SB_CARRY** — the 64-bit ripple counter's carry chain is the real cost. Let me see what pnr does with it:
  > pnr is 1203/1280 — fits the part but over the Makefile's 1150 line, and the unflattened count is 1217. The naive 4-arm writeback mux is the first thing to fix: during a CSR read the ALU output is provably 0 (`SLT(0, negative Iimm)`), so the CSR value can be **OR-ed** into the existing tree instead of added as a fourth arm — one LUT/bit instead of two mux levels. Let me restructure:
  > The OR-trick got Processor to 439 (+36) and the unflattened total to **1144 — under budget**. But sim now fails on the read values. Let me see the full failure list:

- **Handoff captured by loop.sh — iteration 2 ended without ticking its task (tree: TIMEOUT). The session's last message, verbatim:**

  > Odd — same command gives Processor 492 in scratch vs 530 in `make stat`. Let me check if yosys/abc is non-deterministic run-to-run:
  > The scratch copies were stale (pre-fix) — that explains 492 vs 530: the correct 32-bit read path costs +38. So the read path is already tight. The suspect is now the counter itself (~175 LUT4 for a 64-bit +1 is way over the ~64 expected). Let me see the Processor cell breakdown:
  > Processor local: 530 LUT4 + 83 SB_CARRY (the counter's carry chain) and the regfile mapped to 4 BRAMs with `rs1Val/rs2Val` absorbed into BRAM output registers. Let me quantify each piece with ablation variants in the SOC context:
  > vA got the stale scratch copy — let me redo it from the repo's current file and apply the ablation edits:

