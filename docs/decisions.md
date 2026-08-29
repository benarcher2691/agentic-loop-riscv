# Design decisions

Short architecture-decision log for the Loop RISC-V SoC. Newest first. Each entry: the choice,
why, what it costs, and when to revisit — so a future session (human or agent) does not re-litigate
it blindly, and knows exactly what would change the answer.

---

## D2 — Cycle counter is now the RISC-V-standard 64-bit; D1 reversed (2026-08-29)

**Decision.** Implement `RDCYCLE`/`RDCYCLEH` as a true 64-bit free-running counter
(`{cycleh, cycles}` +1 every clk; 0xC00 reads the low word, 0xC80 the high word). This
reverses D1. Both budget guards still pass at `LC_BUDGET=1150`: **1141 unflattened / 1139
flattened**, ~141 logic cells free (> the ~100 the phase-3 UART monitor needs), Fmax ~35 MHz.

**Why it now fits (D1's blocker removed).** D1 was right that a 64-bit counter cannot fit
*on top of the old ALU*. The fix was the ALU, not the counter. The old ALU carried a hard
"two-adder floor": it exposed EQ/LT/LTU from an always-on 33-bit compare subtractor that
`tb/alu_tb.v` checked on *every* vector, so it could never merge with the ADD adder — 434 LUT4.
That floor was an artifact of *where* the compare was tested, not a real requirement: the
compare outputs are only ever consumed when the ALU subtracts (SUB, SLT/SLTU, and branches).
Merging ADD and SUB/compare into **one** add/sub unit (operand-2 invert + carry-in, compare
valid only while subtracting; branches assert a new `cmp` input to force the subtract) cut the
ALU to **376 LUT4** and — because the single carry chain and pruned second adder pack far
better — dropped the *flattened* SoC from 1187 to 1077 even before the counter. `tb/alu_tb.v`
was adapted to drive `cmp` and validate EQ/LT/LTU in a forced-subtract phase, still against an
independent `$signed`/`==`/`<` reference (never the DUT's own output).

**Counter cost kept minimal.** The low word is a plain +1; the high word increments only on the
clk where the low word rolls over (`&cycles`), so the carry into the high half is one AND-reduce,
not a 64-bit ripple. The CSR read folds into the existing writeback OR (the ALU output is provably
0 during a CSR read) with a single 32-bit half-select mux — no new writeback mux arm.

**Revisit if:** a future feature needs those freed cells back and the 64-bit count is unused —
but the split-carry counter and merged ALU are the cheap forms, so the first place to look would
be the barrel shifter or the 6 KB RAM, not the counter.

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
