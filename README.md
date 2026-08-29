# Loop RISC-V — an agentic loop builds an RV32I CPU for the iCEstick

A small RISC-V CPU and SoC, written in Verilog **by a cheap language model inside an agentic loop**,
running on a Lattice iCEstick (iCE40HX1K: 1,280 logic cells, 12 MHz). Built with FOSS tools only.
Total model cost: **$0.91**. It prints a banner over the UART and walks the LEDs.

This is the second project of the [agentic-loop kit](https://github.com/benarcher2691/opencode-agentic-loop)
(read that README first if the words "outer loop" and "verifier" are new). Same kit, same script,
different verifier: instead of `tsc` + `vitest`, "green" here means every self-checking testbench
passes, yosys synthesizes it without latches, nextpnr fits it on the real part at 12 MHz, and the
synthesized netlist behaves exactly like the RTL in a gate-level co-simulation.

```
$ make hwtest
listening on /dev/cu.usbserial-12201; programming build/SOC.bin ...
PASS: received 'Loop RISC-V' within 5.0s
```

## What was built

| Module | Lines | What |
|---|---|---|
| `rtl/clockworks.v` | 48 | Clock divider + power-on reset (2¹⁶ cycles on hardware — see [the one bug](#the-one-bug-no-test-could-see)) |
| `rtl/memory.v` | 72 | 1 KB byte-addressable RAM in block RAM, byte-write enables; holds the demo program |
| `rtl/decoder.v` | 61 | Combinational RV32I decoder: 10 one-hot instruction classes, register fields, all five immediates |
| `rtl/alu.v` | 70 | Shared 33-bit subtractor (SUB/EQ/LT/LTU), one right shifter (SLL by bit reversal), ADD, logic |
| `rtl/processor.v` | 322 | 4-state FSM (FETCH_INSTR → FETCH_REGS → EXECUTE [→ LOAD]), 32×32 register file in BRAM, every RV32I integer instruction, EBREAK halts |
| `rtl/soc.v` | 116 | CPU + RAM; IO space at address bit 22: LED register, UART TX (115200 8N1), UART status |
| `tb/*_tb.v` | 2,400 | 13 self-checking benches, 4,897 checks: random ALU sweep, every load/store width and offset, fib/gcd/call-ret programs, a serial receiver model that decodes `TXD` |

RV32I minus CSR/FENCE (ECALL/EBREAK halt; FENCE is a NOP). Three clocks per instruction, four for a
load → ~4 MIPS. 986 of 1,280 logic cells, Fmax 43 MHz. `git log` is one commit per task.

## Hardware and tools

- **Board:** Lattice iCEstick (iCE40HX1K-TQ144, 12 MHz oscillator, five LEDs, FT2232H). On USB it shows
  two serial devices: `…usbserial-*0` is channel A (SPI flash programming, used by `iceprog`),
  `…usbserial-*1` is channel B, the UART on FPGA pins 8/9. `iceprog -t` reads the flash ID to confirm the link.
- **Toolchain (all FOSS, `brew install yosys nextpnr-ice40 icestorm icarus-verilog`):**
  [Icarus Verilog](https://steveicarus.github.io/iverilog/) for simulation,
  [Yosys](https://yosyshq.net/yosys/) for synthesis, [nextpnr](https://github.com/YosysHQ/nextpnr) for
  place & route, [Project IceStorm](https://clifford.at/icestorm/) (`icepack`, `iceprog`) for the bitstream
  and programming. No vendor tools anywhere.
- **Not needed:** a RISC-V compiler. Programs are written with a RISC-V assembler implemented as
  Verilog macros (`lib/riscv_assembly.v`), so `ADDI(x1, x0, 5);` in an `initial` block assembles into
  the program memory. C support would need `riscv-gnu-toolchain` and is on the list for later.

## The verifier — `make check`

Every loop iteration ends with this, and the loop trusts nothing else:

| Stage | Tool | Fails when |
|---|---|---|
| `sim` | Icarus | Any `tb/*_tb.v` fails a check, hangs (each bench arms a watchdog), or produces an `X` on a compared signal. Prints `CHECKS TOTAL: N` for the loop's test-count guard |
| `lint` | Yosys `check -assert` | Undriven or multiply-driven nets |
| `synth` | Yosys `synth_ice40` | A latch is inferred |
| `pnr` | nextpnr, `hx1k-tq144`, board pins, 12 MHz | Does not fit or misses timing. Then `icepack` → `build/SOC.bin` |
| `equiv` | Yosys netlist + Icarus | RTL and the synthesized netlist disagree on any output on any of 40,000 cycles (catches synthesis/simulation mismatches) |
| `stat` | nextpnr log + unflattened Yosys | Logic cells over `LC_BUDGET` (measured unflattened too — see below) |

The bench helpers are in `tb/check.vh`: `CHECK`, `CHECK_EQ` (4-state compare), `WATCHDOG`, `DONE`.
Expectations are hand-computed constants or behavioural references written in the bench, never the
DUT's own output. Two verifier lessons worth stealing:

1. **A constant ROM lies about size.** While the program memory was read-only, flattened synthesis
   constant-folded away every instruction path the demo program did not use and reported a 66-cell CPU.
   The budget is now also checked on the *unflattened* netlist.
2. **The co-sim must run the same program on both sides.** Simulation-only constants live under
   `` `ifdef FAST_SIM ``, defined for every simulation *and* for the `equiv` netlist, never for the bitstream.

## Run it

```sh
make check                 # ~60 s: the whole flow above; build/SOC.bin is the bitstream
make prog                  # flash it (human step — the agent is denied iceprog)
make uart                  # read the UART; Ctrl-C to stop
make hwtest                # flash and expect the banner: PASS/FAIL
```

To run the loop itself: `opencode` then `/next` for one supervised iteration, `./loop.sh 30` for the rest;
see the kit's README for the knobs. Flash-safe snapshots of milestone bitstreams are kept in `bitstreams/`
(git-ignored) because `build/` is rewritten by the agent every few minutes.

## How the loop built it

Nineteen tasks in `TASKS.md`, ordered like a course: blinker → LED patterns from ROM → decoder (three
parts) → ALU → processor (two parts) → jumps → branches → LUI/AUIPC → program suite → *shrink the core*
→ loads → stores → *shrink again* → memory-mapped IO → demo program → hardware reset fix. The two shrink
tasks and the reset fix were inserted during the run by the human supervisor; everything else was
planned up front. 32 sessions of `glm-5.3-flash`, 5.7 hours, one commit per task.

What the supervisor did — and it is all in [`docs/run-1-review.md`](docs/run-1-review.md) — was never
Verilog: splitting specs the model could not plan in one thought, adding the logic-cell budget when the
design grew to 92 % of the part, adding the gate-level co-simulation, and carrying a step-capped
session's handoff note forward. Each intervention then became a rule in the kit.

### The one bug no test could see

The first bitstream did nothing on the board: dark LEDs, no banner, with 4,814 passing checks and a
green co-simulation. The power-on reset lasted 16 cycles; **iCE40 block RAM is not readable that soon
after configuration**, so the CPU fetched garbage. Simulated BRAM is ready at time zero, so no bench
could have caught it. Handed to the loop as a task with that explanation, it was fixed in one
iteration ($0.018): reset now lasts 2¹⁶ cycles on hardware and 16 under `FAST_SIM`. The verifier
encodes the physics you told it about; the person holding the board is still part of the loop.

## Layout

| Path | What |
|---|---|
| `rtl/` | Synthesizable Verilog-2005, one module per file |
| `tb/` | Self-checking benches; `check.vh` macros |
| `lib/riscv_assembly.v` | The Verilog-macro assembler (Bruno Levy, BSD-3) |
| `rtl/emitter_uart.v` | UART transmitter (from the same tutorial, BSD-3) |
| `boards/icestick.pcf` | Pin constraints; the `SOC` port names are fixed by it |
| `tools/` | `uart.py` (serial reader), `hwtest.py` (flash + banner check), `equiv_tb.v` (co-sim bench) |
| `Makefile` | The verifier flow; `LC_BUDGET` |
| `TASKS.md`, `PROMPT.md`, `AGENTS.md`, `PROGRESS.md`, `loop.sh`, `opencode.json`, `.opencode/` | The loop — identical in shape to the kit |
| `docs/run-1-review.md` | Cost per iteration, code quality, robustness, the supervisor's log, lessons |
| `docs/decisions.md` | Architecture-decision log (e.g. why the cycle counter is 32-bit, not the ISA's 64-bit) |

## References and attribution

- **Bruno Levy, [learn-fpga — "From Blinker to RISC-V"](https://github.com/BrunoLevy/learn-fpga/tree/master/FemtoRV/TUTORIALS/FROM_BLINKER_TO_RISCV).**
  The task sequence follows the shape of this tutorial, and the board pin constraints and two files
  (`lib/riscv_assembly.v`, `rtl/emitter_uart.v`) come from it unmodified, under the BSD 3-Clause
  license reproduced in `lib/LICENSE-learn-fpga`. The tutorial *text* — which contains a complete
  solution for every step — was deliberately kept out of the repo and away from the model: `TASKS.md`
  specifies each step with acceptance criteria, and the agent implemented from those. If you want to
  understand a RISC-V core rather than watch one get built, read the tutorial; it is excellent.
- **The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA** — the RV32I base integer
  instruction set, chapter 2 (encodings, immediates, the `x0` rule).
  [riscv.org/specifications](https://riscv.org/specifications/ratified/).
- **iCE40 block-RAM initialisation delay:** Lattice application notes; the reference design above
  holds reset for 2¹⁶ clocks for the same reason.
- **Tools:** Yosys, nextpnr and Project IceStorm by YosysHQ / Claire Wolf; Icarus Verilog by Stephen
  Williams.
- **The loop:** [opencode-agentic-loop](https://github.com/benarcher2691/opencode-agentic-loop) —
  concept, kit, and the three React runs that calibrated it.

## License

MIT for everything in this repository except the two learn-fpga files, which keep their BSD 3-Clause
license (`lib/LICENSE-learn-fpga`).
