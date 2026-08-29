# Progress log

Append-only notes from the loop agent. One short entry per iteration.
This file is the agent's only memory between sessions — write down what
the next session needs to know, not what it can read from the code.

---

lib/riscv_assembly.v) as the true independent cross-check; note the lib needs a `MEM`-bearing

   module to include into.

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

- **Handoff captured by loop.sh — iteration 4 ended without ticking its task (tree: green). The session's last message, verbatim:**

  > "Read AGENTS.md and follow its workflow for exactly ONE task.
  > 
  > Steps:
  > 1. `make check` — if red, fix first.
  > 2. Open TASKS.md. Take the first `- [ ]` task. Read PROGRESS.md for notes from earlier sessions.
  > 3. **Act, do not plan.** Right after reading the task, your very next tool call creates the bench file with its first two or three checks and a `make sim` run. Do not design the whole task in your head first; grow the bench and the RTL in small steps, running `make sim` after each (it takes seconds). Think in files, not in thoughts.
  > 4. Keep going until `make check` is green. Read build/*.log on failure.
  > 5. Tick the task in TASKS.md, append to PROGRESS.md, commit.
  > 6. Stop.
  > 
  > If every task in TASKS.md is already checked, reply with the single line
  > `ALL TASKS DONE` and do nothing else."
  > `make check` is green (15059 checks, pnr fits). First unchecked task: **Exportable hardware test programs** (`tb/hwprogs_tb.v`). Let me read PROGRESS.md and the existing monitor bench to reuse its models.
  > Now let me check the Makefile and check.vh to understand bench integration.


- **Exportable hardware test programs** (phase 3, task 3): bench-only, as advised — budget untouched
   (1149/1150). `tb/hwprogs_tb.v` assembles 4 programs (alu/ldst/fibgcd/jumpbr) into one shared `MEM`
   sequentially (memPC reset between), uploads each at 0x400 with W, runs with G, reads the 0x800
   result block (signature 0x600D0000|idx + results) with R, checks every word against independent
   expectations (Verilog ops for alu/jumpbr, byte-lane slicing of a fixed pattern for ldst, reference
   loops pinned to hand constants 610/21/6 for fibgcd). Exports build/hwprogs-<name>.prog.hex /
   .expect.hex — $system is NOT available in this iverilog, so per the task's fallback the files land
   directly in build/; iverilog's $writememh writes `// 0xNNNNNNNN` address comments every 16 words,
   the host tool must skip them. Surprises/advice: (1) lib store operand order is ASSEMBLY order —
   SW/SB/SH(data, base, imm), loads LW(rd, base, imm); (2) label discovery: gate the UART sequence on
   the lib's ASMerror, else the bench executes garbage-offset code, G never returns, and the sim
   burns the whole watchdog (>120 s wall); (3) for data addresses inside a relocated program use
   AUIPC(x,0) + ADDI(x, x, LabelRef(L) + 4) — LabelRef is relative to the ADDI's own address — and
   NEVER feed LI a label-dependent value (its 1-vs-2-word expansion differs between the X-label
   discovery run and the final run, shifting every later label); (4) the jumpbr tests use a uniform
   literal-offset pattern (BR +12 skips the not-taken marker, JAL x0,+8 skips the taken marker) so
   the whole program needs zero labels, and B-type encodings are checked via a 6-word "probe"
   assembly (never uploaded) at fixed MEM[0..5]; (5) odd-offset LH/LHU read the LOW half and SH
   writes lanes {addr[1], addr[1]+1} (lane from addr[1] only) — now pinned by the exported ldst
   program too; (6) my BLT hand constant was wrong once (branch offset is from the branch's own
   address, not the label's) — the three-way check caught it. 15059 → 15635 checks in 18 benches;
   pnr 1136/1280, 37.72 MHz, equiv clean.
