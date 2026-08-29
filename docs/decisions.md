# Design decisions

Short architecture-decision log for the Loop RISC-V SoC. Newest first. Each entry: the choice,
why, what it costs, and when to revisit — so a future session (human or agent) does not re-litigate
it blindly, and knows exactly what would change the answer.

---

## D1 — Cycle counter is 32-bit, not the RISC-V-standard 64-bit (2026-08-29)

**Decision.** Implement `RDCYCLE` as a 32-bit free-running counter. `RDCYCLEH` (the high half) reads
as constant `0` rather than counting. This deviates from the RV32I `cycle`/`cycleh` CSRs, which are
defined as a single 64-bit counter.

**Why.** The 64-bit version was built and *works* (10,367 checks pass) and *physically fits*
(1,211 / 1,280 logic cells, timing met). It failed nothing but our conservative `LC_BUDGET` proxy —
`Processor` grew ~110 LUT4 for 64 flip-flops, a 64-bit increment carry chain, and two 32-bit read
arms into an already-crowded write-back mux. The real issue is headroom, not fit:

- At 12 MHz a 32-bit counter wraps every 2³²/12e6 ≈ **357 seconds**.
- The only consumer (part 2's real-time delay) compares the **difference** between two reads, so a
  wrap between them is harmless. Nothing in this project needs an un-wrapping 64-bit count.
- Keeping the 64-bit counter would have left ~69 free cells, and the next feature — the phase-3 UART
  monitor — needs ~100. So 64-bit here forces a later shrink or a smaller RAM regardless.

**The flip side we rejected (raising `LC_BUDGET` to keep 64-bit).** The budget is the loop's only
guard against the cheap model bloating the design; it is what turned "92 % full" into scheduled shrink
tasks instead of a surprise at place-and-route. Raising it to ~1,250 to fit a 95 %-full design would
set the early-warning line *above* where the monitor lands, converting a clean, early budget failure
into a late, confusing "does not fit" at nextpnr — and the proxy only ever ratchets up. We chose to
keep the guard meaningful and spend the cells elsewhere.

**Cost.** Software cannot read a cycle count above 2³². A program that must measure a >357 s interval
would have to poll and accumulate wraps itself. No current or planned program does.

**Revisit if:** (a) the board changes to a larger part (e.g. iCE40HX8K / UP5K) with spare logic;
(b) we drop to 4 KB RAM or land a deeper ALU shrink, freeing enough cells that 64-bit fits under a
*meaningful* budget (not a raised one); or (c) a real program needs an interval longer than ~6 minutes
measured in cycles. The 64-bit implementation is recoverable from git history around this date
(the flash and glm-5.3 attempts on the `Cycle counter, part 1` task).

**Escalation footnote.** Both glm-5.3-flash (three attempts) and glm-5.3 (one, $2.13) built a working,
fitting 64-bit counter and neither could bring it under the 1,150 proxy — because it is not reducible
that far, which is *information*, not failure. That confirmed the constraint was real and made this a
policy decision for the human, not a modelling problem.
