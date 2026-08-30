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

## Running C on the actual hardware (next step, not yet automated)
These examples run in **simulation** on the real core. To run one on the iCEstick it must become
the resident program: point `rtl/memory.v` at the compiled hex (a `$readmemh` init instead of the
assembler-macro monitor), then `make prog`. That swap — and a linker variant that returns to the
monitor so C can be uploaded over UART with `hw.py` instead of reflashed — is a clean future task.
