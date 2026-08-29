# Loop RISC-V — rules for agents working in this repo

A small RV32I CPU for the Lattice iCEstick (iCE40HX1K, 1280 logic cells, 12 MHz), written in
Verilog and built with FOSS tools only (iverilog, yosys, nextpnr-ice40, icestorm). An outer
loop drives you one task at a time; read this file fully before doing anything.

## The one rule that matters

**Never finish a session with `make check` red.** `check` = simulate every `tb/*_tb.v`
(self-checking, must print PASS) → yosys lint → yosys synth (no latches) → nextpnr place & route
on the real part at 12 MHz (must fit, must meet timing). Run it before you start and after every
meaningful change. If it is red when you start, fixing it is your first task.

## Workflow for a task from TASKS.md

1. `make check`. If red, fix first.
2. Take the **first** unchecked task (`- [ ]`) in `TASKS.md`. One task per session. Read `PROGRESS.md`.
3. Write or extend the testbench for the acceptance criteria **first**, then implement.
4. `make check` until green. Read `build/*.log` when something fails; do not guess.
5. Tick the task in `TASKS.md`, append 1–3 lines to `PROGRESS.md` (what, surprises, advice for the next session), commit: `git add -A && git commit -m "task: <short title>"`.
6. Stop. Do not start the next task.

## Layout

| Path | Contents |
|---|---|
| `rtl/*.v` | Synthesizable Verilog. One module per file; file name = module name in lower case (`rtl/processor.v` ↔ `module Processor`). |
| `rtl/soc.v` | Top level `SOC(CLK, RXD, TXD, LEDS)`. Port names are fixed by `boards/icestick.pcf`. |
| `rtl/emitter_uart.v` | Provided UART transmitter `corescore_emitter_uart` (do not edit). |
| `tb/*_tb.v` | Testbenches. Module name = file stem (`tb/alu_tb.v` ↔ `module alu_tb`). Compiled with `-g2012 -DBENCH`. |
| `tb/check.vh` | `CHECK`, `CHECK_EQ`, `DONE`, `WATCHDOG` macros. Include it inside the bench module. |
| `lib/riscv_assembly.v` | Provided Verilog-macro RISC-V assembler (do not edit). `include` it **inside** a module that declares `reg [31:0] MEM [0:N]`. Do not read the whole file (800 lines): `head -60 lib/riscv_assembly.v` shows the usage; macros are the instruction names with RISC-V operand order (`ADD(rd,rs1,rs2)`, `ADDI(rd,rs1,imm)`, `LW(rd,rs1,imm)`, `SW(rs2,rs1,imm)`, `BEQ(rs1,rs2,imm)`, `JAL(rd,imm)`, `LUI(rd,imm)`, `EBREAK()`), registers are `x0`..`x31`, `Label(L)`/`LabelRef(L)` need `integer L;`, finish with `endASM();`. |
| `build/` | Generated. Logs: `build/<bench>.log`, `build/lint.log`, `build/synth.log`, `build/pnr.log`. |

## Verilog rules (synthesizable code in `rtl/`)

- Verilog-2005 only in `rtl/` (yosys reads it as `-sv`, but keep to `reg`/`wire`/`always @(posedge clk)`; no SystemVerilog types, interfaces, or `always_ff`). Start every file with `` `default_nettype none `` and end with `` `default_nettype wire ``.
- Sequential logic: `always @(posedge clk)` with non-blocking `<=`. Combinational: `always @(*)` with blocking `=` and **every output assigned on every path** (or a default at the top) — a latch fails the build.
- No `#` delays, no `initial` blocks in `rtl/` except register initial values (`reg [4:0] x = 0;`) and memory initialisation (`initial begin MEM[0] = …; end` / the assembler).
- Reset: synchronous, active-low `resetn`, generated inside `SOC` (the board has no reset button).
- Memories: `reg [31:0] MEM [0:N-1]` with a **synchronous** read (`always @(posedge clk) rdata <= MEM[addr]`) so yosys maps them to block RAM. The part has 8 KB of BRAM total.
- Anything slow for the human (LED blink rates, delay loops) must be a `parameter` or under `` `ifdef BENCH `` so simulations stay fast.
- Names testbenches rely on (keep them): `Processor` has `reg [31:0] RegisterBank [0:31]`, `reg [31:0] PC`, and `state`; `Memory` has `reg [31:0] MEM [...]`. Benches read these with hierarchical references (`dut.RegisterBank[3]`).

## Testbench rules — be meticulous

- Every bench: `` `timescale 1ns/1ps ``, `` `include "check.vh" `` inside the module, `` `WATCHDOG(<ns>) `` armed, ends with `` `DONE ``. A bench without at least one `CHECK` is not a test.
- Compare with **independently computed expectations**: hand-encoded constants, values worked out in the comment next to the check, or a behavioural reference written in the bench (e.g. `$signed(a) < $signed(b)` for the ALU). Never derive the expected value from the DUT's own output.
- Cover edges, not just the happy path: 0, 1, −1, `0x7FFFFFFF`, `0x80000000`, shift amounts 0/1/31, unaligned byte offsets, taken *and* not-taken branches, `x0` writes.
- Use `CHECK_EQ` (4-state): an `X` is a failure, not a pass.
- Programs for the CPU are written with the macros in `lib/riscv_assembly.v` inside the bench (or inside `Memory` for the hardware program). Cross-check encodings against hand-assembled hex at least once per instruction class.
- Run `make sim` while iterating (seconds) and `make check` before declaring done (adds synth + pnr, ~30 s).
- The `CHECKS TOTAL` count in `make sim` must not go down between sessions.

## Constraints

- **No new dependencies, no downloads.** Everything is installed. No pip, brew, npm, curl, git clone.
- Do not edit `Makefile`, `loop.sh`, `PROMPT.md`, `AGENTS.md`, `boards/`, `lib/`, `rtl/emitter_uart.v`, or anything under `.opencode/`.
- **Never run `iceprog`, `make prog`, or `make uart`.** Hardware is a human step. You cannot see LEDs; trust the benches and the pnr report.
- Do not rewrite files that already work. Make focused edits. Keep earlier benches passing.
- Resource budget: `make stat` prints logic-cell usage and Fmax and **fails above `LC_BUDGET` (900)** — the part has 1280 and the UART/IO need headroom. Share adders and shifters; do not add a comparator or adder where an existing one can be muxed.
