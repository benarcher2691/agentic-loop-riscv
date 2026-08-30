# Compiling C for the Loop RISC-V core

The SoC is RV32I (base integer, no M/A/C extensions). With `riscv64-elf-gcc` you can
write C, compile it for this core, and watch it run on the actual `Processor` RTL in
simulation. This is the tutorial's "run C" milestone.

## Install the toolchain
```sh
brew install riscv64-elf-gcc      # bottled GCC 16 with rv32i/ilp32 multilib
```

## Run an example
```sh
cd c
make PROG=hello run       # compile c/examples/hello.c, run on the RTL, print UART output
make PROG=fib    run
make PROG=primes run
```
`run` compiles the program for `-march=rv32i -mabi=ilp32`, links it at address 0 with the
bare-metal startup (`start.S`) and the tiny UART runtime (`rvc.c`), converts the image to a
`$readmemh` word file, and simulates it with **the real `Processor`/`Decoder`/`ALU`** against a
behavioural memory + UART sink (`csim.v`). Program output appears on your terminal; the run
ends when the program returns and the core `EBREAK`-halts.

## What's here
| File | Role |
|---|---|
| `link.ld` | Memory layout: 6 KB RAM at 0, stack at the top (0x1800) |
| `start.S` | crt0: set `sp`, zero `.bss`, `call main`, `ebreak` on return |
| `rvc.h` / `rvc.c` | Freestanding runtime — `putch`/`puts_`/`put_uint`/`put_hex`/`leds` via memory-mapped UART (0x400008 data, 0x400010 status) and LEDs (0x400004). No libc. |
| `examples/*.c` | `hello`, `fib`, `primes` (division/`%` pull in libgcc's soft `__udivsi3` — RV32I has no hardware divide) |
| `csim.v` | Standalone sim harness (reuses the shipped RTL unchanged) |
| `Makefile`, `tobin2hex.py` | Build + hex conversion |

## Writing your own
Add `examples/foo.c` with an `int main(void)`, include `"../rvc.h"`, `make PROG=foo run`. Keep it
under 6 KB (the Makefile checks). Avoid `printf`/malloc/floats — there's no libc and no FPU; use
the `rvc.h` helpers. Multiply/divide work but are slow software routines.

## Running C on the actual hardware
No reflash needed — the monitor already on the board (`bitstreams/monitor-*.bin`) uploads and
runs programs over UART. The `hw` target compiles a **returning, 0x400-linked** variant
(`link_upload.ld` + `start_upload.S`: a subroutine that saves `ra`, runs `main`, and `ret`s to
the monitor), uploads it with `hw.py`, runs it (`G`), and prints its UART output:

```sh
# board flashed with the monitor and plugged in:
cd c
make PROG=hello  hw      # -> Hello from C on Loop RISC-V!
make PROG=fib    hw
make PROG=primes hw      # watch the LEDs count primes as it prints
```
Under the hood: `python3 tools/hw.py runc build/<prog>_hw.hex` writes the image to 0x400 (`W`),
calls it (`G`), and captures everything the program prints up to the monitor's `K` ack. Programs
must stay a returning subroutine (no `ebreak`), use the monitor's stack (don't touch `sp`), and
fit in 0x400–0x1800 (5 KB, checked). If a run hangs, the program didn't `ret` — reset the board
(reflash the monitor) to recover, per the monitor's contract.

The **standalone** flow above (`make PROG=x run`) still boots at 0 and `ebreak`-halts for pure
simulation; the **`hw`** flow is the returning variant for the real board.
