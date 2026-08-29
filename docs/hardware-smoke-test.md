# Hardware smoke test — driving the RISC-V monitor on the iCEstick

Everything below runs on the real board. The bitstream is a UART **monitor**: after a
one-line banner it listens for binary commands (V/W/R/G) on FTDI channel B @115200.
Nothing here is run by the agentic loop — these are the human checkpoints.

## 0. Flash it
```sh
cd ~/sandbox/agentic-loop-riscv
iceprog bitstreams/monitor-fa5210a.bin      # or: make prog   (builds+flashes build/SOC.bin)
```
`bitstreams/monitor-fa5210a.bin` is the exact committed design (safe from the loop's build dir).

## 1. Banner (open the port first, then flash — the banner prints once at reset)
```sh
# terminal 1:
make uart
# terminal 2:
iceprog bitstreams/monitor-fa5210a.bin
```
Expect terminal 1 to print `Loop RISC-V` a few ms after `cdone: high`. Ctrl-C to stop.
(After this the monitor is waiting for commands; the plain `make uart` reader can't send, so stop it.)

## 2. Automated suite — the payoff
```sh
make hwcheck
```
Flashes if needed, then drives the monitor over the UART: uploads each program in
`build/hwprogs-*.prog.hex` to 0x400 (`W`), runs it (`G`), reads the result block at 0x800
(`R`), and compares to `*.expect.hex`. Expect:
```
ok   alu: 55 words
ok   fibgcd: 5 words
ok   jumpbr: ... words
ok   ldst: ... words
HWCHECKS: 4 passed, 0 failed
```
This is the same suite the simulation `tb/hwprogs_tb.v` checks, now proven on silicon. If sim
and hardware ever disagree, that is the one bug class no testbench can catch (as the block-RAM
reset bug was — see `docs/decisions.md`).

## 3. Poke around by hand (optional)
```sh
python3 tools/hw.py id                       # -> RV32
python3 tools/hw.py poke 0x400004 0x15       # write 0b10101 to the LED register (D1,D3,D5 on)
python3 tools/hw.py peek 0x400004            # read it back
python3 tools/hw.py poke 0x500 11 22 33      # write 3 words to RAM at 0x500
python3 tools/hw.py peek 0x500 3             # read them back
```
`0x400004` is the LED IO word; watch the board's LEDs change as you poke it.

## If something is wrong
- No banner: replug (forces a reload from flash); confirm `iceprog -t` reads the flash ID.
- `hw.py` timeout / identity != RV32: the monitor bitstream isn't running — re-`make prog`.
- One program fails but others pass: a real RTL/hardware discrepancy for that instruction class
  — capture the `FAIL <name>: word N got X expected Y` line; it maps to a specific test in
  `tb/hwprogs_tb.v`.
