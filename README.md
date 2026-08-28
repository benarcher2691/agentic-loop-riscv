# Loop RISC-V — an agentic loop builds an RV32I CPU for the iCEstick

Second experiment after `../opencode-agentic-loop` (a React todo app). Same loop, harder
domain: a cheap model (`glm-5.3-flash` via opencode) implements a small RISC-V CPU in Verilog,
one step at a time, for a real board — the Lattice iCEstick (iCE40HX1K, 1280 logic cells,
12 MHz) — using only FOSS tools. The step sequence follows the shape of Bruno Levy's
["From Blinker to RISC-V"](https://github.com/BrunoLevy/learn-fpga/tree/master/FemtoRV/TUTORIALS/FROM_BLINKER_TO_RISCV)
tutorial, but the tutorial text (which contains full solutions) is deliberately **not** in the
repo: `TASKS.md` specifies each step with acceptance criteria and the agent implements from that.
Two support files from the tutorial are included as library code (`lib/riscv_assembly.v`, a
RISC-V assembler written as Verilog macros, and `rtl/emitter_uart.v`; BSD-3, see `lib/LICENSE-learn-fpga`).

## The verifier — what makes this loop meticulous

`make check` runs, in order, and fails on the first problem:

1. **Simulation** — every `tb/*_tb.v` with Icarus Verilog. Benches are self-checking via
   `tb/check.vh` (`CHECK`, `CHECK_EQ` with 4-state compare so an `X` fails, `WATCHDOG` so a hung
   design fails, `DONE` prints `CHECKS: n passed`). The bench must print `PASS`. The total
   check count is tracked by `loop.sh`; an iteration that lowers it is flagged `SUSPECT`.
2. **Lint** — yosys `hierarchy -check` + `check -assert`: undriven/multiply-driven nets fail.
3. **Synthesis** — yosys `synth_ice40`; any inferred latch fails.
4. **Place & route** — nextpnr on the real `hx1k-tq144` part with the board's pin constraints at
   12 MHz: fails if the design does not fit or misses timing. `icepack` then produces the bitstream.
5. **Stat** — logic-cell utilisation and Fmax, so bloat is visible in the log.

Skeleton baseline: 2 checks, 1 bench, 0.7 s.

Flashing is **not** in the loop. The agent cannot see LEDs, so hardware stays a human checkpoint,
and `iceprog` / `make prog` / `make uart` are denied in `opencode.json`.

## Hardware

iCEstick on USB shows up as two FTDI channels: `/dev/cu.usbserial-*0` (channel A, SPI flash
programming, used by `iceprog`) and `/dev/cu.usbserial-*1` (channel B, the UART on pins 8/9).
`iceprog -t` reads the flash ID to confirm the link.

## Run

```sh
make check                      # green baseline
git log --oneline | head -1     # scaffold commit exists (loop.sh needs it)

opencode                        # TUI: /next runs one iteration by hand
./loop.sh 30                    # unattended; 13 tasks, expect some retries
tail -f loop.log
```

Human checkpoints — after task 1 (blinker) and task 13 (demo):

```sh
make prog                       # flash build/SOC.bin; LEDs should do something visible
make uart                       # read the UART (Ctrl-C to stop); task 13 prints a banner
```

`loop.sh` knobs are the same as the todo project (`MODEL`, `RUN`, `ITER_TIMEOUT`, `STUCK_LIMIT`,
`MIN_SECONDS`/`DUD_LIMIT`, `ON_RED`) plus `CHECK_CMD` (default `make -s check`) and
`TEST_COUNT_RE` (default `CHECKS TOTAL: [0-9]+`), which is what made it project-agnostic.

## Layout

| Path | What |
|---|---|
| `rtl/` | Synthesizable Verilog: `soc.v` (top), later `clockworks.v`, `memory.v`, `decoder.v`, `alu.v`, `processor.v` |
| `tb/` | Self-checking benches, one per module/feature; `check.vh` macros |
| `lib/riscv_assembly.v` | Verilog-macro assembler: programs for benches are written as `ADDI(x1,x0,5);` etc. |
| `boards/icestick.pcf` | Pin constraints; `SOC` port names are fixed by it |
| `tools/uart.py` | Stdlib-only serial reader for `make uart` |
| `TASKS.md` / `PROMPT.md` / `AGENTS.md` / `PROGRESS.md` / `loop.sh` | The loop, as in the todo project |

## What is missing on this machine

No RISC-V compiler (no GCC, and Apple clang has no riscv target), so the tutorial's steps 19–24
(C programs, running from SPI flash) are out of scope for now. Steps 1–18 need only the Verilog
assembler. To go further later: `brew tap riscv-software-src/riscv && brew install riscv-gnu-toolchain`.
No Verilator either; Icarus is fast enough at this size.

## Expectations

Verilog and small RISC-V cores are well represented in training data, and every task here has a
deterministic verifier, so the loop should get a good way in. The likely failure points are the
state-machine steps (task 5) and load/store byte handling (tasks 10–11), where a cheap model tends
to write a bench that mirrors its own misunderstanding. The rules in `AGENTS.md` push against that
(independent expectations, edge values, 4-state compares), and `STUCK_LIMIT` bounds the damage.
Results and a review go in `docs/` after each run, as in the todo project.
