# Tasks

Ordered. The loop agent takes the **first unchecked** task each iteration. Every task ends with
`make check` green (all benches PASS, synth without latches, fits the hx1k at 12 MHz) and a commit.
Architecture target, so no task requires rewriting an earlier one: `SOC` (clock, reset, IO) →
`Processor` (CPU) + `Memory` (RAM/ROM), plus small pure modules `Decoder`, `ALU`, `Clockworks`.

# Phase 2 — a computer, not just a core



Same rules. The SoC currently has 1 KB RAM, UART transmit only, and no way to read time.

- [x] **6 KB of RAM.** *(Done at 16 BRAMs, not the estimated 14 — the regfile floor is 4, not 2: RAM4K's widest mode is 256×16, so each 32-bit sync read port needs 2 blocks and 2 read ports + 1 write need 2 copies. 12 (MEM) + 4 = 16 fits the part exactly; see PROGRESS.md.)* `Memory`: 1536 words (6 KB). The hx1k has sixteen 4 Kbit block RAMs: the register file uses 2 and 6 KB needs 12, so 14 of 16. `Processor`: PC arithmetic and the fetch/load/store address path grow from 10 to 13 bits (`PC[12:0]`); everything about IO decode (bit 22) is unchanged. Benches: `tb/memory_tb.v` reads/writes words above 1 KB and at the last word; `tb/programs_tb.v` gets one program placed at address 4096 (assembled with `memPC` moved) and a data area at 5120; `make stat` reports 14 BRAMs and stays under the LUT budget (the wider adders cost some).

- [x] **Cycle counter, part 1: the counter and its CSR read (built 64-bit — see below).** *(Done 2026-08-29 by an Opus 4.8 investigation, verified independently. Decision D2 (docs/decisions.md) REVERSED D1: the counter is the RISC-V-spec 64-bit RDCYCLE/RDCYCLEH after the ALU was refactored to a single shared add/sub, which freed enough logic — final 1139/1280 cells, 141 free, all 10363 checks + gate-level equiv green.)*

- [x] **Cycle counter, part 2: real-time delays in the demo.** *(Done 2026-08-29. Per-step loop: `CSRRS` start → `CSRRS`/`SUB`/`BLTU` diff loop (9 cycles/iter); DELAY 300 sim / 3 000 000 hw. Period model `9·ceil(DELAY/9)+21` is exact — measured 327 on all 4 steps; wrap exercised by a bench deposit of 0xFFFFFF00, cycleh 0→1 checked.)* Replace the counted delay loop in the resident program with `RDCYCLE`-based waiting: read the counter, then loop until it has advanced by `DELAY` cycles (3 000 000 on hardware = 0.25 s; a small value under `` `ifdef FAST_SIM ``). Handle the 32-bit wrap by comparing the *difference*. Bench: `tb/soc_tb.v` checks the LED period equals `DELAY` (± 3 instructions) using the bench's own cycle count.

# Phase 3 — hardware in the loop







The board becomes a test fixture the loop can drive over the UART. The monitor and the test programs



are built and proven in simulation by the loop (the serial models in the benches already speak both



directions); the host-side tool and `make hwcheck` are supervisor work (they need the board to test).







- [ ] **Stack + UART byte primitives.** The monitor (next task) needs nested subroutines, so first give the resident program a real memory stack — do NOT hand-juggle link registers across nested calls (that path is fragile and has burned sessions). In `Memory`'s resident program: reserve a scratch/stack region high in RAM (e.g. sp = x2 = 0x1800, growing down; the monitor's code lives low). Convention: a subroutine that itself calls another must, on entry, `ADDI sp,sp,-4; SW(ra,sp,0)` and on exit `LW(ra,sp,0); ADDI sp,sp,4; RET` — leaf routines may skip it. Write two helpers used by everything after: **GETBYTE** (blocking: poll the UART RX status word at 0x400020 until bit 8 set, read the byte from bits[7:0] into a0, clearing avail) and **PUTBYTE** (blocking: poll the UART TX status at 0x400010 until not busy, then write a0's low byte to 0x400008). Prove the machinery with a small resident program: print the banner "Loop RISC-V\n", then a routine `ECHO2` that reads one byte with GETBYTE and calls PUTBYTE **twice** through the stack (echoing it, then echoing it+1), demonstrating a 2-deep nested call whose `ra` is correctly saved/restored. Bench `tb/monitor_io_tb.v` (reuse the serial TX/RX bench models from `tb/uart_rx_tb.v` / `tb/io_tb.v`): send one byte, check both echoed bytes come back on TXD in order, and that execution continues correctly after the nested return (e.g. a sentinel byte sent last is also echoed — proving `ra` was not clobbered). **Reconcile `tb/soc_tb.v`**: the resident program no longer does the old LED walk, so update its expectations — keep the banner check; replace the LED-walk-forever checks with the new behavior (banner, then the echo loop; LEDS may be left at a known value). `make check` under budget.

- [ ] **Monitor command protocol.** Build on the stack + GETBYTE/PUTBYTE from the previous task. Replace `ECHO2` with the monitor command loop: read a command byte with GETBYTE, dispatch, repeat forever. Commands (all multi-byte values little-endian 32-bit, sent/received via GETBYTE/PUTBYTE, using GET32/PUT32 helpers that call GETBYTE/PUTBYTE four times through the stack): `V` (0x56) → PUT32 the 4 bytes "RV32"; `W` addr len data… → GET32 addr, GET32 len, then `len` bytes written to memory starting at addr (RAM or the IO space at 0x400000+), reply byte `K` (0x4B); `R` addr len → GET32 addr, GET32 len, PUT the `len` bytes read from addr; `G` addr → GET32 addr, `JALR ra,addr,0` (call it; the routine returns with RET, may clobber everything but sp), then reply `K`; any other byte → reply `?` (0x3F). Make the LED IO word at 0x400004 readable so `R` can read it back. Bench `tb/monitor_tb.v` (serial models, driving the protocol): `V`→"RV32"; `W` 8 words at 0x400 then `R` them back; `G` a small uploaded routine (loaded via `W`) that sums those 8 words into 0x420 and returns, then `R` the sum; write 5'b10101 to the LED word via `W` and `R` it back; an unknown command → `?`. Bytes handled at full 115200 with no inter-byte gaps required. `make check` under budget.

- [ ] **Exportable hardware test programs.** `tb/hwprogs_tb.v` assembles a set of self-contained test programs with the macros — at least: the ALU sweep with fixed vectors, every load/store width and offset, fib/gcd, a jump/branch torture — each loaded at 0x400, ending by writing a result block (a signature word `0x600D0000 | index` followed by its result words) at 0x800 and returning with `ret`. The bench runs each program through the RTL via the monitor (upload with `W`, run with `G`, read the block with `R`) and checks the results against hand-computed expectations. Then it `$writememh`s, per program, the program words and the expected result block to `build/hwprogs/<name>.prog.hex` and `<name>.expect.hex` for the host tool. Add `hwprogs` to `make sim` outputs (the Makefile rule for benches already runs it; just make sure `build/hwprogs/` exists — create it from the bench with `$system` if needed, or write into `build/` directly with fixed names).

# Phase 4 — visual verification (parked; not needed until the SoC has a visual peripheral)







Idea, not yet a task: a fixed webcam over the board as a verifier for outputs that have no register to



read back (OLED, LED matrix, VGA). Capture a frame (`imagesnap`/`ffmpeg` — one extra tool), then either



pixel-compare fixed regions against an image rendered by the simulation (deterministic, alignment-



sensitive) or hand the frame to a vision-capable model with a yes/no question (robust, fuzzy). For the



five LEDs the UART monitor (phase 3) is the better sensor; revisit this when the first visual peripheral



lands. Not a `- [ ]` item on purpose — the loop must not pick it up.









