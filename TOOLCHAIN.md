# TOOLCHAIN.md — the exact software stack `make check` is proven green on

**Read this before you conclude that a red `make check` on a new machine is a
project fault.** The cell count that `make stat` checks against `LC_BUDGET` is an
*output of synthesis*: the same RTL gives a different number under a different
yosys. Compare `bash tools/toolchain.sh` with the reference below first.

## Reference machine — M2 Mac mini, proven green 2026-09-10

Full `make clean && make check`, 17:07–17:08 CEST, 51 s:

```
CHECKS TOTAL: 16105 passed in 23 benches
  unflattened total: 1165 LUT4 (budget 1180)
  ICESTORM_LC:    1175/   1280    91%
  ICESTORM_RAM:     16/     16   100%
Max frequency for clock 'CLK$SB_IO_IN_$glb_clk': 33.20 MHz (PASS at 12.00 MHz)
CHECK: OK
```

Output of `bash tools/toolchain.sh` on that machine:

```
host                   M2 arm64 macOS 26.6.2 (25G83)
yosys                  Yosys 0.68+post (git sha1 c12172fbae8af5e20f6fb52e3d4e92d56ed587b6, Release, AppleClang clang++ 21.0.0.21000101)
nextpnr-ice40          nextpnr-ice40 0.11.1_1
icestorm               icestorm 1.1
icepack                present
iceprog                present (human only)
iverilog               Icarus Verilog version 13.0 (stable) (v13_0)
vvp                    Icarus Verilog runtime version 13.0 (stable) (v13_0)
riscv64-elf-gcc        riscv64-elf-gcc (GCC) 16.2.0
riscv64-elf-objcopy    GNU objcopy (GNU Binutils) 2.47.20260726
python3                Python 3.14.7
make                   GNU Make 3.81
cc                     Apple clang version 21.0.0 (clang-2100.1.1.101)
timeout                timeout (GNU coreutils) 9.11
git                    git version 2.55.0
bash                   GNU bash, version 5.3.15(1)-release (aarch64-apple-darwin25.4.0)
paths                  yosys=/opt/homebrew/bin/yosys nextpnr-ice40=/opt/homebrew/bin/nextpnr-ice40 iverilog=/opt/homebrew/bin/iverilog python3=/opt/homebrew/bin/python3
```

All of it from Homebrew (`brew install yosys nextpnr-ice40 icestorm icarus-verilog
riscv64-elf-gcc coreutils`), Apple Command Line Tools 26.6 for `cc`/`make`, Homebrew
`python@3.14`. `tools/hw.py` uses `termios` + `os.open` on `/dev/cu.usbserial-*`, no
pyserial. Nothing is pinned: `brew upgrade` moves these.

## What each tool is used for

| Tool | Where | Sensitivity |
|---|---|---|
| `iverilog` / `vvp` | `sim`, `equiv`, `hwreset`, `c/` | Low — 13.0 has been stable across machines |
| `yosys` | `lint`, `synth`, `equiv`, `stat` | **High — the LUT/LC counts come from here** |
| `nextpnr-ice40` | `pnr` (hx1k, tq144, 12 MHz) | Medium — Fmax and placed LC count vary run to run and version to version |
| `icepack` / `iceprog` | bitstream / flashing (human only) | Low |
| `riscv64-elf-gcc` + binutils | `c/` examples only, not `make check` | Low |
| `python3` | `tools/*.py`, `c/tobin2hex.py` | Low — stdlib only |

## Known drift — recorded, not fixed

**M4 Mac mini, 2026-09-10, Yosys 0.69+post (git 143eb14f):** identical RTL, fresh
clone, everything green except `stat`:

```
FAIL: 1185 logic cells exceeds LC_BUDGET=1180 (see TASKS.md 'Shrink the core')
```

That is **1185 on 0.69 vs 1175 on 0.68** — a 10-cell swing from the synthesiser
alone, 0.8 % of the part, against a budget with 5 cells of headroom. The RTL did
not change. So on any machine with a newer yosys than the reference, a `stat`
failure by a handful of cells is **toolchain drift until proven otherwise**.

What to do about it is a project decision, not a machine one. The choices are:

1. Raise `LC_BUDGET` in the `Makefile` to match the new yosys (and record the new
   yosys here as the reference), or
2. Pin yosys to the reference (`brew pin yosys` after installing the matching
   version — Homebrew does not ship old bottles, so this means building from
   source at the recorded git sha), or
3. Actually shrink the core (`TASKS.md`, "Shrink the core").

Do not "fix" a version-drift failure by editing RTL in a loop session. Escalate it.

## Checking a new machine

```sh
bash tools/toolchain.sh                 # compare with the block above
make clean && make check                # must print CHECK: OK
```

`CHECKS TOTAL` must be 16105 in 23 benches. If it is lower with every bench "ok",
a bench was skipped — find out why before going on.

## Keeping this file honest

When the reference machine or a tool version changes and `make check` is green
afterwards, paste the new `tools/toolchain.sh` output over the block above and
update the date and the numbers. A stale reference is worse than none.
