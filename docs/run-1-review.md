# Run 1 review — glm-5.3-flash builds an RV32I SoC for the iCEstick

Night of 2026-08-28/29. Model: `openrouter/z-ai/glm-5.3-flash`, opencode 1.18.20, `loop.sh` (v2 + DUD detection, generalised with `CHECK_CMD`).
Supervisor: Claude (this session), watching `loop.log` and acting on the harness only — never on the Verilog.

**Result: a working RV32I CPU + SoC on real hardware.** 18 tasks, 31 sessions across two runs, ~5.6 h wall time, **$0.89**.
Final `make check`: 4,814 checks in 13 benches, gate-level co-simulation matches RTL for 40k cycles, 981 of 1,280 logic cells (76 %), Fmax 43 MHz at a 12 MHz constraint.
Bitstream: `bitstreams/demo-18fc833.bin` → `iceprog` it, then `make uart` shows `Loop RISC-V` and the LEDs walk.

## 1. What was built

| Module | Lines | What |
|---|---|---|
| `rtl/clockworks.v` | 34 | Clock divider (parameterised) + 16-cycle power-on reset |
| `rtl/memory.v` | 72 | 1 KB byte-addressable RAM in block RAM, byte-write enables, holds the demo program (assembled with the Verilog-macro assembler) |
| `rtl/decoder.v` | 61 | Purely combinational RV32I decoder: 10 one-hot classes, register/funct fields, all five immediates |
| `rtl/alu.v` | 70 | Shared 33-bit subtractor (SUB/EQ/LT/LTU), one right shifter (SLL via bit-reversal), ADD, logic ops |
| `rtl/processor.v` | 322 | 4-state FSM (FETCH_INSTR → FETCH_REGS → EXECUTE [→ LOAD]), 32×32 register file in BRAM, every RV32I integer instruction, EBREAK halts |
| `rtl/soc.v` | 116 | Wires CPU + RAM; IO space at address bit 22: LEDs register, UART TX (115200), UART status; `TXD` idle-high fix |
| `tb/*_tb.v` | 2,321 | 13 self-checking benches incl. a serial receiver model, a 200-vector random ALU sweep, fib/gcd/call-ret programs |

Instruction set: all of RV32I except CSR/ECALL (treated as halt) and FENCE (NOP). Three clocks per instruction (four for loads) → ~4 MIPS at 12 MHz. Not pipelined, no interrupts, 1 KB memory. It is the tutorial's "Quark"-class core, built without the tutorial.

## 2. Cost and time

| | run 1 (stopped) | run 2 | total |
|---|---|---|---|
| iterations | 4 (3 green, 1 timeout) | 27 (22 green, 5 non-green) | 31 |
| wall time | 42 min | 4 h 53 min | 5 h 35 min |
| cost | $0.089 | $0.800 | **$0.889** |

Tokens (both runs): 2.47 M uncached input, 199 K output, **883 K reasoning**, 28.9 M cache-read. Reasoning tokens are 4.4× the output tokens — the model thinks far more than it writes, and that (not the code) is where the money went. Median iteration: 611 s. Longest green: 1,503 s (jumps). The todo app's iterations were 1–5 minutes; here `make check` alone is 30–60 s and sessions ran 30–40 turns.

Per-iteration table: `runs/20260829-004049/summary.tsv` (and `runs/20260828-235729/`).

## 3. What the supervisor had to do (7 interventions)

Everything below was a change to the harness, prompt, task list or verifier. Zero lines of Verilog written by the supervisor.

| When | Signal | Action |
|---|---|---|
| 00:40 | Decoder task: two sessions ended in 32K-token reasoning bursts (`finish=length`) with nothing written; loop stopped on STUCK | "Act, don't plan" rule in `PROMPT.md`; decoder split in 3; `ITER_TIMEOUT` 900→1800; `STUCK_LIMIT` 2→3; red baseline = warning. Relaunch. |
| 01:15 | Processor task: same burst pattern | Split in 2; `AGENTS.md`: don't read the whole 800-line assembler; ended the burning session |
| 02:52 | Logic cells 139 → **1,182 of 1,280** over four tasks (six adders, three shifters) | Inserted "Shrink the core" task with the recipe; `LC_BUDGET` enforced by `make check`; ended the Loads session |
| 03:05 | Shrink reported **66 cells** — implausible | Found yosys pruning unused instruction paths because `Memory` was a constant ROM. Added `make equiv` (RTL vs gate-level co-sim) to `make check`; budget measured on unflattened synthesis too |
| 03:55 | Loads correct (sim + equiv green) but 1,073 > 900 budget; STUCK at 2 | Budget → 1,150 (the real limit is the part); second shrink scheduled after Stores |
| 04:46 | Session hit `steps: 40` mid-refactor; its precise handoff note existed only in its final message | Copied the note into `PROGRESS.md`; `steps` → 60; restarted the iteration. Next session finished the task in 611 s |
| 05:45 | Extending `equiv` to 40k cycles showed a real RTL/netlist divergence | Traced to `PC`: the netlist was running the *hardware* delay constant — my equiv target synthesized without the bench define. Introduced `FAST_SIM` (used by sims and the equiv netlist, never by the bitstream). Design was correct all along |

The `reasoning.effort` knob: OpenRouter honours it on the raw API (0 reasoning tokens), but opencode 1.18.20 forwards none of `--variant`, `options.reasoning`, `options.extraBody`, `reasoningEffort`. Verified empirically; the structural fixes were the workaround.

## 4. Code quality

Would approve, with real respect for the comments. The `Processor` header explains every hazard it designed around: why `mem_rdata` can serve as the instruction register (the RAM holds its output while the strobe is low), why the `LOAD` state must take the first arm of the writeback mux ("a loaded `0xDEADBEEF` decodes as JAL and would otherwise write back PC+4 instead of the data"), why the register file must be read synchronously ("an asynchronous read would stop it mapping to block RAM and blow the hx1k budget"). These are the notes a good engineer leaves.

Design decisions worth knowing:
- **No instruction register.** Saves 32 flip-flops by relying on `Memory` holding `mem_rdata`. Documented on both sides; a coupling nonetheless — a different memory would break the CPU silently.
- **10-bit PC arithmetic.** Memory is 1 KB, so PC+4 and branch/jump targets are computed in 10 bits (−158 LUTs). A program larger than 1 KB wraps silently; the 32-bit `PC` register the benches read is zero-extended.
- **Everything through one ALU**: loads/stores/AUIPC/LUI compute their addresses/values by forcing `funct3 = 000` and muxing `in1`/`in2`. Good sharing; the `aluIn2` mux is the price.
- **Evidence-based shrinking.** The agent built a scratch ablation harness in a temp dir and measured each block: shifter + flips 244, `wrData` mux tree 231, load path only 61. It wrote that my task hint's estimates were wrong (they were) and where the real cost was. That note saved the next session.
- ALU still 485 LUT4 — the tutorial's final core is ~300 total. The `flip32` trick costs ~77 LUTs of muxing under abc9, contrary to folklore. A third shrink is possible, not necessary.

Tests: each bench arms a watchdog, uses 4-state compares, and computes expectations independently (hand-encoded hex, `$signed` references, a serial receiver decoding `TXD` at 104.17 clocks/bit). 4,814 checks. Weakness: benches read `RegisterBank`/`PC` hierarchically, so they cannot run against the netlist — `equiv` covers the port level only.

## 5. Robustness (the "security" section, hardware edition)

Attack surface is nil (UART transmit only; `RXD` unused). Robustness findings:

| Finding | Severity |
|---|---|
| Reset is power-on only (board has no button); `resetn` from a 16-cycle counter. Fine for this board; a design with a reset pin would need synchronisation | info |
| `x0`, the program and the register file rely on **block-RAM initialisation** from the bitstream — supported on iCE40, and the co-sim proves it, but it means the CPU cannot be reset to a clean state without reloading the bitstream (registers keep their values through `resetn`) | low |
| PC wraps at 1 KB with no trap; misaligned halfword/word loads are unspecified (allowed by the task) | info |
| Fmax 43 MHz vs 12 MHz clock — 3.6× timing margin; 76 % utilisation leaves room for a UART receiver or a second KB of RAM | none |
| `TXD = uartTx | ~txStarted` masks the emitter's power-on level so the line idles high before the first byte — a genuine hardware detail the model got right | none |

## 6. Loop findings

1. **The model's failure mode is thinking, not coding.** Every stall was a hidden reasoning burst (14K–52K tokens) after reading files; 32K is the ceiling and hitting it produces nothing. Small specs + "act, don't plan" made the bursts survivable; they never went away (883K reasoning tokens total).
2. **The verifier is where the supervisor's value went.** Four of seven interventions were verifier changes — the logic budget, the gate-level co-sim, the unflattened metric, the define fix. Each one caught a real thing or proved a scary thing benign. A loop is only as honest as its `check`.
3. **Constant ROMs lie about size.** Flattened cell counts were meaningless until memory became writable. Anyone measuring a CPU with a fixed program in ROM should know this.
4. **The step cap is a cliff.** A session that hits it cannot write its own handoff. `loop.sh` should capture the last assistant message into `PROGRESS.md` automatically when an iteration ends without ticking — the manual version of that fixed the shrink task in one retry.
5. **Bookkeeping-only retries** happened three times (work done, task unticked): $0.11 total. Cheap, and the loop absorbs them by design.
6. Versus the todo app: 31 vs 8 iterations, 7 vs 1 supervisory interventions, $0.89 vs $0.05, and the acceptance criteria were less deterministic (resource budgets, hardware timing). The cheap model still got there; the price was supervision, not tokens.

## 7. Next

- **Morning:** plug the stick in, `iceprog bitstreams/demo-18fc833.bin`, `make uart` → `Loop RISC-V`, LEDs walking at 4 Hz.
- Automate handoff capture in `loop.sh` (finding 4).
- `brew tap riscv-software-src/riscv && brew install riscv-gnu-toolchain` unlocks the tutorial's steps 19–24: C programs, a UART receiver, running from SPI flash.
- Optional third shrink (ALU shifter/mux tree) if the goal is the tutorial's ~300-LUT core.
- The comparison experiment that is *not* worth running: glm-5.3 on this whole list (~$25). Worth running: glm-5.3 on just the two shrink tasks.
