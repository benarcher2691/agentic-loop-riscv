# Tasks

Ordered. The loop agent takes the **first unchecked** task each iteration. Every task ends with
`make check` green (all benches PASS, synth without latches, fits the hx1k at 12 MHz) and a commit.
Architecture target, so no task requires rewriting an earlier one: `SOC` (clock, reset, IO) →
`Processor` (CPU) + `Memory` (RAM/ROM), plus small pure modules `Decoder`, `ALU`, `Clockworks`.

# Phase 2 — a computer, not just a core



Same rules. The SoC currently has 1 KB RAM, UART transmit only, and no way to read time.



- [x] **Shrink the core, round 3 — the ALU.** *(Outcome: 485 → 434 LUT4, total 1,031; the ≤ 320 target was shown unreachable without changing the ALU's compare interface — see the glm-5.3 session's note in PROGRESS.md. Accepted as done by the supervisor.)* `make stat` reports `ALU: 485 LUT4`; a resource-shared RV32I ALU on iCE40 is ~250. Bring **`ALU` to ≤ 320 LUT4 and the unflattened total to ≤ 980** with no functional change — `tb/alu_tb.v` (2,438 checks against a behavioural reference), every other bench and `equiv` are the regression and must pass unchanged. The previous session measured where the cells are (its note is in `PROGRESS.md`): shifter + the two `flip32` reversals ≈ 244, logic ops 94, subtractor/compares 92, ADD 52. Approaches, try in order and keep what `make stat` proves: (1) one shifter, no reversal muxes in the *data* path: compute `shRight` once from `in1` (or its reversal) and put the SLL reversal on the *output* only, so the shifter input mux disappears; or implement all three shifts as one 5-stage log shifter written explicitly (five `always @(*)` stages of 2:1 muxes, direction by conditional reversal at stage 0 only). (2) Merge the ADD and SUB into the single 33-bit adder (`in1 + (funct7_5 ? ~in2 : in2) + funct7_5`) and take EQ/LT/LTU from *that* result — one adder in the whole ALU instead of two. (3) Fold XOR/OR/AND into one `case` after the adder, and make the final `out` mux a single `case (funct3)` with no nested ternaries — abc maps nested ternaries badly. Record per-step before/after numbers in `PROGRESS.md`. Do not touch `Processor` or `Memory` in this task.

- [x] **6 KB of RAM.** *(Done at 16 BRAMs, not the estimated 14 — the regfile floor is 4, not 2: RAM4K's widest mode is 256×16, so each 32-bit sync read port needs 2 blocks and 2 read ports + 1 write need 2 copies. 12 (MEM) + 4 = 16 fits the part exactly; see PROGRESS.md.)* `Memory`: 1536 words (6 KB). The hx1k has sixteen 4 Kbit block RAMs: the register file uses 2 and 6 KB needs 12, so 14 of 16. `Processor`: PC arithmetic and the fetch/load/store address path grow from 10 to 13 bits (`PC[12:0]`); everything about IO decode (bit 22) is unchanged. Benches: `tb/memory_tb.v` reads/writes words above 1 KB and at the last word; `tb/programs_tb.v` gets one program placed at address 4096 (assembled with `memPC` moved) and a data area at 5120; `make stat` reports 14 BRAMs and stays under the LUT budget (the wider adders cost some).

- [ ] **Cycle counter, part 1: a 32-bit counter and its CSR read.** *(Design decision 2026-08-29: 32-bit, not the ISA's 64-bit — see docs/decisions.md. At 12 MHz a 32-bit counter wraps every 357 s, the only consumer compares differences so wrap is harmless, and the 64-bit version cost ~100 LUT on a 95%-full part. Revisit if the part changes.)* In `Processor`: a **32-bit** free-running cycle counter (`reg [31:0] cycles`, +1 every `clk`, cleared by `!resetn`). Decode `isSYSTEM` with `funct3 == 3'b010` (CSRRS) and `rs1Id == 0` as a CSR read: `Iimm[11:0] == 12'hC00` (cycle) returns `cycles`; `12'hC80` (cycleh) returns `32'd0` (the high half does not exist — spec-visible as always-zero); the value is written to `rd` and PC advances like any other instruction. Every other `isSYSTEM` encoding still halts. Encodings for the bench: `csrrs rd, cycle, x0` = `32'hC0002073 | (rd << 7)`, `csrrs rd, cycleh, x0` = `32'hC8002073 | (rd << 7)` — add `RDCYCLE(rd)` / `RDCYCLEH(rd)` helper tasks *in the bench* (do not edit `lib/`). Bench `tb/cycle_tb.v`: two `cycle` reads separated by a known instruction sequence differ by exactly 3 × instructions (+1 per load); a `cycleh` read returns 0; `x0` as destination writes nothing; `EBREAK` still halts. `make check` must stay under budget (the 32-bit counter adds ~50 LUT; if it goes over, that is a real problem, not a proxy one — stop and note it). <!-- model: openrouter/z-ai/glm-5.3 -->

- [ ] **Cycle counter, part 2: real-time delays in the demo.** Replace the counted delay loop in the resident program with `RDCYCLE`-based waiting: read the counter, then loop until it has advanced by `DELAY` cycles (3 000 000 on hardware = 0.25 s; a small value under `` `ifdef FAST_SIM ``). Handle the 32-bit wrap by comparing the *difference*. Bench: `tb/soc_tb.v` checks the LED period equals `DELAY` (± 3 instructions) using the bench's own cycle count.

# Phase 3 — hardware in the loop



The board becomes a test fixture the loop can drive over the UART. The monitor and the test programs

are built and proven in simulation by the loop (the serial models in the benches already speak both

directions); the host-side tool and `make hwcheck` are supervisor work (they need the board to test).



- [ ] **Monitor program.** The resident program becomes a monitor: banner, one LED walk, then a command loop over the UART. Binary protocol, all multi-byte values little-endian 32-bit: `V` → reply the 4 bytes `"RV32"`; `W addr len data…` → write `len` bytes starting at `addr` (any address: RAM or IO), reply `K`; `R addr len` → reply `len` bytes read from `addr`; `G addr` → call `addr` (`JALR ra`) and, when the routine returns with `ret`, reply `K` — the routine may clobber every register except `sp`, and the monitor re-establishes its own state after the return; any other command byte → reply `?`. Reading the LED IO word must return the current LED value (make the register readable). Memory map: monitor code and stack in the first 1 KB; user programs are loaded at 0x400 and up. Bench `tb/monitor_tb.v`: through the bench's serial TX/RX models, check `V`, write 8 words at 0x400 and read them back, `G` a small uploaded routine that sums them into a fixed address and returns, read the sum back, write the LED word and read it back, and an unknown command. Bytes must be handled at full 115200 rate with no gaps required between them.

- [ ] **Exportable hardware test programs.** `tb/hwprogs_tb.v` assembles a set of self-contained test programs with the macros — at least: the ALU sweep with fixed vectors, every load/store width and offset, fib/gcd, a jump/branch torture — each loaded at 0x400, ending by writing a result block (a signature word `0x600D0000 | index` followed by its result words) at 0x800 and returning with `ret`. The bench runs each program through the RTL via the monitor (upload with `W`, run with `G`, read the block with `R`) and checks the results against hand-computed expectations. Then it `$writememh`s, per program, the program words and the expected result block to `build/hwprogs/<name>.prog.hex` and `<name>.expect.hex` for the host tool. Add `hwprogs` to `make sim` outputs (the Makefile rule for benches already runs it; just make sure `build/hwprogs/` exists — create it from the bench with `$system` if needed, or write into `build/` directly with fixed names).

# Phase 4 — visual verification (parked; not needed until the SoC has a visual peripheral)



Idea, not yet a task: a fixed webcam over the board as a verifier for outputs that have no register to

read back (OLED, LED matrix, VGA). Capture a frame (`imagesnap`/`ffmpeg` — one extra tool), then either

pixel-compare fixed regions against an image rendered by the simulation (deterministic, alignment-

sensitive) or hand the frame to a vision-capable model with a yes/no question (robust, fuzzy). For the

five LEDs the UART monitor (phase 3) is the better sensor; revisit this when the first visual peripheral

lands. Not a `- [ ]` item on purpose — the loop must not pick it up.



