# Progress log

Append-only notes from the loop agent. One short entry per iteration.
This file is the agent's only memory between sessions — write down what
the next session needs to know, not what it can read from the code.

---

lib/riscv_assembly.v) as the true independent cross-check; note the lib needs a `MEM`-bearing

   module to include into.

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

- **Handoff captured by loop.sh — iteration 3 ended without ticking its task (tree: TIMEOUT). The session's last message, verbatim:**

  > Fetch drives `mem_rstrb`/`mem_addr` too, so forced strobes can corrupt a fetch — but a halted CPU (EBREAK → permanent EXECUTE freeze, no strobes) makes every forced cycle fully deterministic. Let me check the state encoding, then write the first bench:
  > Now the first bench — `tb/rxoverrun_tb.v` with the overrun last-writer-wins scenario:
  > The forced read sampled one cycle too late — `ioSelR` is a one-cycle registered pulse, and my `release` executed in the active region *before* the NBA update at the strobe edge. The fix: hold the force past the edge, sample at `+1ns`, then release:

- **Handoff captured by loop.sh — iteration 4 ended without ticking its task (tree: TIMEOUT). The session's last message, verbatim:**

  > Now remove the debug instrumentation:
  > Part (b) passes — 39 checks, 15931 total in 23 benches. Now part (c): the comment fixes. First the `rxAvail` policy documentation (part a) and the `uartValid` rationale correction (A12) in `rtl/soc.v`:
  > Now the stale SRLI claim in `tb/io_tb.v` (A16) — the lib's SRLI macro builds `RType(0010011, rd, rs1, imm[4:0], 101, 0000000)`, which is exactly the correct SRLI encoding (imm[11:5]=0, imm[4:0]=shamt), so the "buggy" claim is false:
   > `make check` is fully green. Let me verify all stages passed and confirm the check count:

- **T4: UART contracts** (phase 5, T4): the iteration-4 handoff had finished all three parts and
   died at the verification step; this session verified every acceptance line and did the
   tick/commit. (a) `rxoverrun_tb.v` (18): overrun is last-writer-wins, the set-vs-clear race is
   pinned on the exact `uartRxValid` cycle with a `sawRace` witness — the racing read returns the
   pre-race avail=0 but the completing byte is preserved (set wins); policy + host-throttle
   documented at the `rxAvail` block. (b) `txbusy_tb.v` (39): the M4 kill re-specced per T3 —
   full-word SW 'A'/'B' back-to-back from an uploaded G routine, `sawSw2Busy` witness (PC=0x610,
   uartReady=0) makes it non-vacuous, TXD is exactly banner+K+'A'+K+"RV32" and 'B' never appears.
   (c) A12/A16 comment fixes. RTL comments-only: budgets identical to T3 (1165 unflattened,
   1175 pnr, 33.20 MHz), equiv clean; 15874 → 15931 checks in 23 benches.
   Advice for T5 (coverage batch, next): (1) the rxoverrun race technique (arm the force on the
   edge AFTER the event pulse rises, hold past the strobe edge, sample at +1 ns) is the reusable
   pattern for any set-vs-clear race; (2) txbusy_tb's hierarchical PC+strobe witnesses are the
   template for proving a CPU-side event really happened; (3) T5(a) needs `tb/cycle_tb.v` —
   cycle_tb already exists from the cycle-counter task, so EXTEND it rather than create it, and
   check how its CSR reads are driven first; (4) 15 LUT4 unflattened headroom, 105 pnr LCs.

- **T5: coverage batch** (phase 5, T5): all six parts landed in one session. (a) cycle_tb C8/C9/C10 —
   the mutant-kill deposit (0x7FFFFFFE) and the wrap-cycle CSR read both exploit the same fact: a
   CSR read returns the counter value live DURING its EXECUTE cycle, i.e. the value latched at the
   edge ENTERING EXECUTE; deposit one short of the target right after reset release to place any
   counter value on any instruction's EXECUTE. (b) uart_rx count → `$clog2(BIT_CLKS)`, width-identical.
   (c) monitor_tb: zero-len R/W, split W, and the register-wrecking G. (d) ADD/AUIPC-to-x0 one-liners.
   (e) jumps_tb phase 2 with MEM grown to 2048 words — a bench memory may exceed the 6 KB RAM so the
   13-bit PC-wrap region (0x1800-0x1FFF) is fetchable in sim. (f) stores_tb phase 2: self-modifying
   store to PC+4 with a stale-word trap.
   Surprises: (1) POST-RETURN register checks after a monitor G are meaningless — the monitor's own
   K-reply code re-trashes registers by design (x1 becomes its PUTBYTE link, x5/x9/x10 its helpers);
   the reusable pattern is a watcher process FORKED beside the exchange that samples the regfile
   while the routine's last instruction is in flight (hierarchical `dut.processor.RegisterBank[i]`
   with a variable index works fine in iverilog). (2) The clobber-G trick: x1's clobber value
   LUI(x1,1)=0x1000 doubles as the scratch address holding the saved RA, so `LW x1,0(x1)` restores
   the return address through the clobbered register itself. (3) Hand-encoding J-type failed twice —
   imm[10:1] sits at word bits [30:21], NOT [21:12]; `jal x0,-8` = 0xFF9FF06F. Use a python slicer
   for every new encoding (stores_tb's expWord comment already warned this). (4) The lib declares
   `ra` (ABI name) — don't reuse it as a bench variable.
   Budgets unchanged (1165 unflattened, 1175 pnr, 33.20 MHz), equiv clean; 15931 → 16105 checks in
   23 benches (cycle_tb 87, monitor_tb 228, jumps_tb 70, stores_tb 90).
   Advice for T6 (equiv drives the SoC, next): (1) copy monitor_tb's send_byte/recv_byte pair into
   tools/equiv_tb.v — the recv must be forked with the send (reply start bit lands in the mid-stop);
   (2) the banner is 12 frames — wait for 12 before commanding; (3) the clobber-G routine from T5(c)
   is a ready-made "small G" (or use the 10-word sum routine already in monitor_tb); (4) keep the
   equiv run ~150-200k cycles: the W+R+G sequence above costs ~2 ms of UART time ≈ 24k cycles at
   12 MHz, well inside budget; (5) FAST_SIM is defined for equiv — check what that changes in
   Clockworks before trusting cycle counts.

