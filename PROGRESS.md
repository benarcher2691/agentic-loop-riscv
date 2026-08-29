# Progress log

Append-only notes from the loop agent. One short entry per iteration.
This file is the agent's only memory between sessions — write down what
the next session needs to know, not what it can read from the code.

---

lib/riscv_assembly.v) as the true independent cross-check; note the lib needs a `MEM`-bearing

   module to include into.

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

- **T1: x1 debug mirror removed** (phase 5, T1): port + 32-bit shadow + both duplicated write arms
   deleted (processor.v port list, EXECUTE and LOAD arms; soc.v wire + connection); 8 benches rewired
   from `.x1(x1_out)` to hierarchical `RegisterBank[1]` reads (4 CHECKs re-targeted, count held at
   15635). All green: 18 benches, lint, equiv, hwreset, pnr 1141/1280, Fmax 38.45 MHz.
   **The ≥25 LUT4 acceptance line was a wrong premise, now measured twice**: the mirror is 32 FFs,
   and iCE40 FFs pack into LCs beside their LUTs — real saving is 2 LUT4 unflattened (1149→1147,
   Processor 497→495) + 5 pnr LCs. The audit's "~30 LUT" was a grep estimate counting FFs as LUTs.
   Advice for T2 (next): you inherit only 3 LUT4 unflattened headroom (1147/1150) — run a scratch
   yosys ablation before editing, and remember the halt logic can share the existing ALU comparator
   rather than adding one. Also in this commit: the previous session's uncommitted file-rotation
   housekeeping (TASKS/TASKS-done/PROGRESS-archive).

- **Handoff captured by loop.sh — iteration 2 ended without ticking its task (tree: TIMEOUT). The session's last message, verbatim:**

  > The ldst program's misaligned cases (LH/LHU at offsets 1/3, SH at 13/15) now halt mid-`G`. Per the task I'll remove them and replace with aligned coverage of equal strength (LH/LHU from the second pattern word, SH pairs on a second word with a different value). First let me check the `LI` macro's expansion rule (word counts feed the hand-encoding cross-check indices) and scan `stores_tb` for misaligned stores:
  > `LI` confirmed: 1 word when the value fits signed 12 bits, else LUI (+ADDI only if low 12 bits ≠ 0) — so `LI(x19, 32'h8765)` = 2 words. The stores_tb grep came back empty — checking its actual formatting:
  > `stores_tb` uses `SB  (` spacing — its SH offsets are all even (8/10/20/22) and bytes are never misaligned, so it's safe. Now the hwprogs ldst edits:
   > Now the expectation block for the new aligned coverage:

- **T2: halt on bad data addresses** (phase 5, T2): the iteration-2 handoff had already finished
   the engineering (RTL halt logic, badaddr_tb, hwprogs ldst rework) and the tree was green —
   this session verified every acceptance line and did the tick/commit. RTL: `badAddr` gates
   `mem_rstrb`/`mem_wmask` AND halts in EXECUTE (arm ordered after SYSTEM, before isLoad, so
   `ldOff` is never latched on a bad access). The halt comparators cost +11 LUT4 unflattened
   (1147 → 1158) and +22 pnr LCs (1141 → 1163); Ben raised LC_BUDGET 1150 → 1180 for exactly
   this (99e5ede), so the budget question is settled — T3 inherits ~22 LUT4 headroom.
   Fmax 38.45 → 34.63 MHz, still 2.9× margin. 15635 → 15823 checks in 19 benches (badaddr_tb
   = 188), equiv clean. Also in this commit: another round of file rotation (hwprogs entry →
   TASKS-done, two old PROGRESS entries → PROGRESS-archive).
   Advice    for T3 (exact-match IO decode, next): (1) the misalign term deliberately ignores
   bit 22 — IO-space misaligned accesses halt via misalign (badaddr cases 12/18), while
   unmapped ALIGNED IO offsets are T3's job; (2) the SOC's LED-word read is currently the
   ioRdata *default* arm — exact-match decode replaces that default with 32'd0, so the edit
   may be roughly LUT-neutral, but ablate first and remember ledReg's declaration must stay
   above the read-path always block (iverilog bind order); (3) the badaddr bench's memory
   model (poison fill + canaries + X/vanish semantics matching rtl/Memory) is a good template
   for fault-injection benches; (4) `tRun`'s reset-preserves-registers trick lets one bench
   cover many permanent-halt cases without re-elaboration.

- **T3: exact-match IO decode** (phase 5, T3): `rtl/soc.v` decodes the four IO words by
   equality on `mem_addr[5:2]`; read default is now `32'd0` (LEDS read is an explicit
   `ioLeds` arm); `storeNow` wire deleted. **The load-bearing contract decision: the UART
   data port (0x400008) accepts FULL-WORD stores only (`mem_wmask == 4'b1111`)** — the
   audit calls the monitor's ≥5-byte W at 0x400004 "walking into the UART" a bug, and
   T4(b) pins `W 0x400008 1 <byte>` as must-NOT-transmit, while PUTBYTE sends with SW —
   byte-lane gating alone cannot satisfy all three. T4 should bench-pin this (iowalk_tb
   already does) rather than re-litigate the RTL. Bench tricks worth reusing: (1) to get
   `rxAvail` pending across arbitrary CPU instructions WITHOUT the CPU polling RX (a poll
   read consumes the byte), time the RX byte to complete inside the TX-busy window of two
   back-to-back frames (~174 µs) — the CPU polls the side-effect-free status word instead;
   (2) event-driven TXD recorder (log frames on negedge, flag strays past a threshold,
   bounded wait on `txdN` before checking) cannot miss a start bit and cannot hang, unlike
   a `recv_byte` that arms after the frame started; (3) the lib's `endASM` $finishes with
   "Missing label initialization" unless label integers are pre-initialized with their
   byte addresses (`integer S1 = 36, S2 = 52;`); (4) the monitor banner is 12 frames —
   wait `txdN == 12` before sending commands. My hand LUI constant was wrong once again
   (imm20 0x00400 → 0x004002B7, not 0x400002B7) — the EXP cross-check caught it pre-sim.
   Budgets: unflattened 1158 → 1165 (SOC 57 → 65, +7 for the four 4-bit comparators and
   the fourth read-mux arm), pnr 1163 → 1175, Fmax 33.20 MHz. 15823 → 15874 checks in
   21 benches (ioexact_tb 47, iowalk_tb 4), equiv clean.
   Advice for T4 (UART contracts, next): mostly bench/comment work — (a) RX overrun
   last-writer-wins and the set-vs-clear race via bus forcing (uart_rx_tb technique);
   document the policy at the `rxAvail` block; (b) the M4 kill is ALREADY in (wmask==1111
   gate) — add the monitor `W 0x400008 1 <byte>` mid-PUTBYTE bench; (c) comment fixes:
   `rtl/soc.v` uartValid hold rationale (A12) and the stale SRLI claim in `tb/io_tb.v`
   (A16). Headroom: 15 LUT4 unflattened, 105 pnr LCs.

