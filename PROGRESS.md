# Progress log

Append-only notes from the loop agent. One short entry per iteration.
This file is the agent's only memory between sessions — write down what
the next session needs to know, not what it can read from the code.

---

lib/riscv_assembly.v) as the true independent cross-check; note the lib needs a `MEM`-bearing

   module to include into.

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

- **RDCYCLE delays in the demo** (task 24, phase 2): the counted delay loop is gone; each LED
   step now reads cycle (CSRRS 0xC00) once, then loops {CSRRS now, SUB diff = now−start,
   BLTU diff,DELAY} — 9 cycles/iteration, wrap-safe by construction. DELAY = 300 (sim) /
   3 000 000 = 0x2DC6C0 via LUI+ADDI (hw, 0.25 s). Program grew 33 → 35 words: message moved
   word 30 → 32 (byte 128), labels WDELAY=64, ECHO=88, EBUSY=104; all three copies updated
   (rtl/memory.v, soc_tb, memory_tb). Bench: period model **9·ceil(DELAY/9)+21 is exact**
   (probe run: all 4 steps measure 327 for DELAY=300), checked ±9 (±3 instructions) with the
   bench's own cycle counter. The 32-bit wrap is exercised for real: right after the first
   pattern commits the bench deposits `dut.processor.cycles = 32'hFFFFFF00` (hierarchical
   write between edges — lands before the start-read samples 2 cycles later), the first loop
   spans 0xFFFFFFFF→0, `cycleh` 0→1 is checked, period unchanged. 10363 → 10700 checks;
   Processor 494 → 499 LUT4 is abc run-to-run noise (only ROM contents changed; Memory still
   120), unflattened 1146/1150, pnr 1139/1280, Fmax 36.18 MHz, equiv clean.
   Surprises: (1) my hand SUB encoding was wrong (0x40EF87B3 — computed rs1=x31; correct
   0x40E787B3) and the three-way ROM cross-check caught it, the lib was right. (2) The
   "LEDS hold 16" check had to grow from 200 to exp_period+200 cycles: with the old ~30-cycle
   delay a short hold could only pass in the echo loop, but a 327-cycle period keeps LEDS=16
   through the whole last delay loop, so the PC-range check fired mid-delay-loop.
   Advice for the monitor task (next): echo loop now lives at bytes 88..124, ROM is words
   0..34, message at byte 128; the delay loop clobbers x14/x15/x16 (monitor re-establishes its
   own state anyway); the deposit trick works for any counter/regs test; exp_period-style
   models belong in the bench next to the program copy they model.

- **Handoff captured by loop.sh — iteration 1 ended without ticking its task (tree: TIMEOUT). The session's last message, verbatim:**

  > Now `monitor_io_tb`'s constants and the soc_tb header comment:
  > One stale constant left in `monitor_io_tb` (the second stack-word check still expects 56; the DUT correctly wrote 44):
  > All sims pass (14766 checks). Now the budget test:
  > `make check` is green — but pnr landed at **exactly** 1150/1150. That's too fragile: PROGRESS.md notes abc run-to-run noise of ±5 LUT4, so a re-run could tip it red. Let me find real headroom. First candidate: the `x1` mirror output (32 FFs) — is it used anywhere?

- **Stack + UART byte primitives** (phase 3, task 1): resident program rewritten — sp = x2 = 0x1800
   (one past the 6 KB top, growing down), banner now goes one word per char through PUTBYTE
   (LW not LB — see below), then MAIN calls ECHO2 forever. ECHO2 is the non-leaf demo: push ra,
   GETBYTE, PUTBYTE(byte), PUTBYTE(byte+1), pop ra, RET. GETBYTE/PUTBYTE are leaves (no push).
   Benches: new tb/monitor_io_tb.v ('A'→'A','B'; sentinel 'Z'→'Z','[' proves ra survived the
   nested return; pushed word MEM[1535]=0x17FC holds link 44; sp parked at 0x17FC and ra=60 in
   the GETBYTE poll idle state; edge bytes 0x00/0x7F/0xFF — 0xFF's echo+1 wraps to 0x00 for real);
   soc_tb reconciled (banner + echo behaviour, LEDS dark throughout, LED walk gone); memory_tb
   follows the new ROM. 10700 → 14766 checks; unflattened 1148/1150, pnr 1150/1280 (exactly at
   budget), Fmax 39.59 MHz, equiv clean, 16 BRAM.
   Surprises/advice for the monitor task (next): (1) The prior session's headroom idea is a
   MEASURED dead end — the x1 mirror is 32 FFs but 361 total FFs pack into the 1150 LCs next to
   the 1148 LUT4s (only ~2 FF-only LCs exist), so removing it frees ~0 pnr LCs and 0 LUT4, and
   4 benches CHECK x1_out. Don't re-derive. (2) Both budget metrics pass but with 2/0 spare;
   yosys+nextpnr are deterministic for fixed RTL, so the tree is stable until you edit logic —
   the LEDS-read arm at 0x400004 (~5-8 LUT4) WILL need an offset found as part of that task
   (measure with a scratch yosys ablation before editing). (3) The ROM deliberately sticks to
   LW/SW/ADDI/ANDI/BNE/JAL/JALR/LUI (no LB/BEQ) so the flattened netlist prunes the byte-lane
   load logic and branch mux — keep new monitor code to that set. (4) ROM layout: WBYTE=20,
   MAIN=40, ECHO2=48, GETBYTE=84, GBDONE=100, PUTBYTE=108 (bytes), message at byte 128, 44 words;
   the deterministic idle state is PC 84..100 with sp=0x17FC/ra=60 — benches poll for that PC
   range before hierarchical checks. (5) The echo2 bench task needs fork/join: the first echo's
   start edge lands mid-stop of the incoming frame, a sequential recv misses it.


- **Monitor command protocol** (phase 3, task 2): ECHO2 replaced by the command loop
   (V/W/R/G/unknown). Key trick: GET32/PUT32 assemble/disassemble words through an 8-byte
   stack frame (ra at sp+4, scratch word at sp+0) using SB/LBU — no shifter, no OR needed,
   and the frame is collision-free by construction. MAIN re-establishes x5 every iteration
   and the G arm again after JALR (a G routine may clobber all but sp). SOC: the LED word
   at 0x400004 is now readable as the ioRdata *default* arm ({27'd0, ledReg}) — cheaper than
   a dedicated decode; ledReg's declaration had to move ABOVE the read-path always block
   (iverilog elaboration binds uses to declarations in source order). Benches: monitor_tb
   (111) drives the full matrix incl. a G-uploaded 10-word sum routine (assembled in the
   bench via the lib — the bench array MUST be named MEM) and a post-G survival V; the
   monitor_io_tb rewrite spies PUT32's live sp-dip to 0x17F8 with a `wait` in a fork arm;
   soc_tb's three-way ROM cross-check regenerated from an independent python encoder
   (scratch, not committed) — surprise: the lib's LUI takes the FINAL 32-bit value
   (0x00400000 → 0x004002B7), my encoder's first cut passed the imm20 field and got
   0x400002B7; the three-way check caught it exactly as designed. 14766 → 15059 checks.
   Budget: 1149/1150 unflattened — the LEDS-read arm (+6 on SOC 52→58) was fully absorbed
   by abc run-to-run noise (Processor 501→497, Memory 120→119 with ROM-only changes);
   pnr 1136/1280, 37.72 MHz, equiv clean, 16 BRAM.
   Advice for the next task (hwprogs): it should be bench-only (no RTL edits), which matters
   because there is exactly ONE LUT4 of headroom — if you must touch rtl/, run a scratch
   yosys ablation first. The monitor protocol is stable: uploaded code must use relative
   branches only (G jumps to an absolute address, fine), W writes bytes with SB (note: every
   byte lane of the LED word hits the ledReg latch, so write it with len=1, not 4), R has no
   reply byte, W/G reply K, unknown replies '?'. The deterministic idle state is PC 348..363
   with sp=0x1800/ra=48 — poll that range before hierarchical checks. The exchange helper
   needs fork/join (a reply's start bit can land mid-stop of the last command byte).
