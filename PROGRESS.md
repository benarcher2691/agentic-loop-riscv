# Progress log

Append-only notes from the loop agent. One short entry per iteration.
This file is the agent's only memory between sessions — write down what
the next session needs to know, not what it can read from the code.

---

lib/riscv_assembly.v) as the true independent cross-check; note the lib needs a `MEM`-bearing

   module to include into.

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

- **Handoff captured by loop.sh — iteration 7 ended without ticking its task (tree: TIMEOUT). The session's last message, verbatim:**

  > The netlist receiver fires on a spurious negedge ~10 µs before each real start bit. Let me log every value event on both TXD lines around the first occurrence:
  > Event flood — let me window and cap the logging:
  > Time-literal bug — literals are in ns, I wrote ms. Fixing:
  > **Root cause found.** Probe 3 nails it:
  > 
  > ```
  > t=92626000 TXD_r=1 TXD_s=0   <- netlist TXD glitches low for ONE DELTA
  > t=92626000 TXD_r=1 TXD_s=1   <- ...and back, same time step
  > t=102792000 TXD_r=0 TXD_s=1  <- real start bit: netlist lags one delta
  > ```
  > 
   > The provided emitter's combinational TXD (`data[0] | !(|data)`, re-factored by yosys into a multi-level LUT tree) produces a **sub-clock hazard glitch at frame end in the gate-level netlist only** — invisible to the clock-sampled port check (`mismatches=0`), but a real falling edge to a negedge-triggered receiver, which then samples one bit-time early and decodes garbage. The RTL is clean (atomic 10-bit reg update). The emitter is do-not-edit, and this transient can't corrupt a real 115200-baud link — so the correct fix is in the bench: the serial receivers must model a real UART's **start-bit validation** (re-sample half a bit into the "start" edge; if the line is back high, it was noise). That keeps every assertion intact while making the receivers faithful hardware models:

- **T6: equiv drives the SoC** (phase 5, T6): the iteration-7 handoff had finished the engineering
   (full `tools/equiv_tb.v` rewrite, +283 lines, plus the file rotation) and died before
   verification; this session verified every acceptance line and did the tick/commit. The driven
   session (banner, V, W 0x15→0x400004, R, 3-instruction G at 0x500 with code+data readbacks, live
   V) feeds the SAME RXD into both dies; one serial receiver per DUT, start-bit-validated, and
   every reply byte-compared RTL vs netlist. The start-bit validation is the load-bearing idea:
   the netlist TXD glitches low for one delta at frame end (emitter's combinational output
   re-factored by yosys; the RTL's atomic 10-bit reg update never glitches) — a bare `@(negedge)`
   receiver decodes the frame one bit-time early, so the receiver must re-sample half a bit into
   every falling edge like a real UART. Assertions: mism=0 over 150000 cycles, txd_edges 241>200,
   led_changes 1, final LEDS 5'b10101 on both, 84 checks in build/equiv.log. `make equiv` = 45 s
   (budget 90 s). Budgets unchanged (1165 unflattened, 1175 pnr, 33.20 MHz); sim total unchanged
   16105 in 23 benches (equiv_tb lives in tools/, its checks count in the equiv log only).
   **That was the last unchecked task in TASKS.md** — the next session should reply `ALL TASKS
   DONE` unless new tasks are added.


- **UART input: getch/get_uint + csim input model + count.c** (phase 6): all three edits under `c/`,
   no RTL/tb changes. `getch` polls 0x400020 bit 8; `get_uint` echoes digits and stops at the first
   non-digit; csim's `+instr=%s` queue (chars + one 0x0A) feeds reads of the RX word, popping on each
   read, avail=0 when empty. inputtest PASS 4/4, hello run unchanged, make check green (budgets
   untouched: 1165/1175 LCs, 33.20 MHz). Surprise: iverilog `$value$plusargs %s` stores the string
   right-justified (last char in the LOWEST byte) — scan from the highest non-zero byte down to
   rebuild it; also, regs used by an always block must be declared textually before it or iverilog
   fails to bind. Advice: the no-plusarg run of an input-reading program blocks forever on avail=0
   (csim TIMEOUT) — that is correct hardware behaviour, not a hang to fix.
