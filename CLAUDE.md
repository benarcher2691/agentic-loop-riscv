# CLAUDE.md — orientation for an agent taking over

**What this is.** A complete, hardware-verified RV32I CPU + SoC for the Lattice iCEstick
(iCE40HX1K), written in Verilog almost entirely by a cheap model (`glm-5.3-flash` via opencode)
driven task-by-task in an agentic loop, and supervised by a stronger model that reviewed/tested/
audited but wrote almost no RTL. It boots, blinks, runs a UART monitor, runs compiled C on
silicon, and passes a four-reviewer audit. Read `README.md` first, then this.

**Current status (2026-09-12): DONE and hardware-verified, on the M4 Mac mini.** All of Phase 2 (CPU),
Phase 3 (UART monitor, hardware-in-the-loop), Phase 5 (audit fixes) and Phase 6 (UART input) are complete; `TASKS.md` has zero
unchecked tasks. `make check` is green (16,105 checks / 23 benches, gate-level equiv, ~50 s).
`make hwcheck` passes on the board; C examples run on silicon (`cd c && make PROG=hello hw`).

**How the loop works.** `./loop.sh [N]` runs the cheap model one `TASKS.md` task per fresh
session; state lives on disk (`TASKS.md` = backlog, `PROGRESS.md` = the agent's cross-session
memory, git = history). Rules the worker follows: `AGENTS.md`. The prompt each session gets:
`PROMPT.md`. The worker never touches hardware or the load-bearing files (enforced in
`opencode.json`). Supervise by watching `loop.log` / `runs/<id>/summary.tsv`; act on the harness
(prompt, task split, budget), not the code. Escalate a single hard *question* to a stronger model
via a `<!-- model: provider/model -->` tag on a task line.

**The verifier (`make check`), authoritative — supersedes AGENTS.md's older list.** In order:
`sim` (23 self-checking benches) → `lint` (yosys + guards: RXD 2-flop synchroniser depth,
FAST_SIM confined to clockworks.v, vendored-file SHA-256) → `synth` (no latch) → `pnr` (fits
hx1k @12 MHz) → `equiv` (RTL vs synthesized netlist, 150k-cycle driven monitor session, byte-level
compare) → `hwreset` (the ONLY stage without FAST_SIM: pins the 65,536-cycle BRAM-readiness reset)
→ `stat` (unflattened + flattened LUT budgets, `LC_BUDGET=1180`). Human-only, denied to the loop:
`make prog|uart|hwtest|hwcheck|hw`, `iceprog`, `tools/hw.py`.

**Toolchain versions (`TOOLCHAIN.md`).** `make check` is proven green on the exact versions
recorded there; `bash tools/toolchain.sh` prints this machine's. yosys is **pinned at 0.68+post**
so the counts are stable; a `stat` failure by a few cells means the pin slipped (Homebrew's 0.69 gives
1185 LC vs 1175) — check `yosys -V` before touching RTL, and never shrink RTL to chase it.

**Where to look.** `docs/decisions.md` (D1/D2: the 32-vs-64-bit cycle-counter saga and the ALU
refactor that resolved it). `docs/audit-2026-08-29.md` (four-reviewer audit A1–A23 + the S-series
security findings, all fixed/guarded/documented, with mutation results and Contracts & limits).
`docs/hardware-smoke-test.md` (driving the board). `c/README.md` (the C toolchain flow). The
sibling repo `../opencode-agentic-loop` is the reusable loop kit and its own tutorial.

**Gotchas.** Misaligned/out-of-range data accesses HALT the CPU (recovery = reflash). UART TX is
word-store-only. The monitor's `W`/`R`/`G` give a trusted serial peer arbitrary memory access by
design. `bitstreams/` (git-ignored) holds flash-safe snapshots; the current design is
`monitor-cf0551c.bin` (rebuilt clean on the M4 2026-09-12; rebuild with `make prog` after any RTL change).

**Parked / possible next.** Peripherals (needs the owner's parts list) → unparks the phase-4
camera-verification idea (prose in `TASKS.md`). Running C from SPI flash / a bigger board. Note:
security-review tasks get auto-escalated off Fable 5 by the harness (observed).
