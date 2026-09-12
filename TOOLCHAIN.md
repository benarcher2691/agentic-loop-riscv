# TOOLCHAIN.md — the exact software stack `make check` is proven green on

**Read this before you conclude that a red `make check` on a new machine is a
project fault.** The cell count that `make stat` checks against `LC_BUDGET` is an
*output of synthesis*: the same RTL gives a different number under a different
yosys. Compare `bash tools/toolchain.sh` with the reference below first.

## Reference stack — proven green on the M4 Mac mini, 2026-09-12

(First proven on the previous machine 2026-09-10, same numbers to the cell; the
M4 re-recorded it after pinning yosys.) Full `make clean && make check`, 09:38–09:39 CEST, 88 s:

```
CHECKS TOTAL: 16105 passed in 23 benches
  unflattened total: 1165 LUT4 (budget 1180)
  ICESTORM_LC:    1175/   1280    91%
  ICESTORM_RAM:     16/     16   100%
Max frequency for clock 'CLK$SB_IO_IN_$glb_clk': 33.20 MHz (PASS at 12.00 MHz)
CHECK: OK
```

Output of `bash tools/toolchain.sh` on the M4:

```
host                   m4 arm64 macOS 26.6.2 (25G83)
yosys                  Yosys 0.68+post (git sha1 c12172fbae8af5e20f6fb52e3d4e92d56ed587b6, Release, AppleClang clang++ 21.0.0.21000334)
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
cc                     Apple clang version 21.0.0 (clang-2100.3.34.2)
timeout                timeout (GNU coreutils) 9.11
git                    git version 2.55.0
bash                   GNU bash, version 5.3.15(1)-release (aarch64-apple-darwin25.4.0)
paths                  yosys=/opt/homebrew/bin/yosys nextpnr-ice40=/opt/homebrew/bin/nextpnr-ice40 iverilog=/opt/homebrew/bin/iverilog python3=/opt/homebrew/bin/python3
```

All of it from Homebrew (`brew install nextpnr-ice40 icestorm icarus-verilog
riscv64-elf-gcc coreutils`) **except `yosys`**, which is **pinned at 0.68+post** and
built from a carried formula through a local tap (`m4-mac-mini-install` stage 4b;
Homebrew 6 needs `brew trust` for it). Do *not* `brew install yosys`: that is 0.69 and
`stat` fails by 10 cells. Apple Command Line Tools 26.6 for `cc`/`make`, Homebrew
`python@3.14`. `tools/hw.py` uses `termios` + `os.open` on `/dev/cu.usbserial-*`, no
pyserial. Everything but yosys is unpinned: `brew upgrade` moves those.

**Hardware, same day:** `make hwtest` → `PASS: received 'Loop RISC-V'`; `make hwcheck` →
`HWCHECKS: 4 passed, 0 failed` (alu 51 words, fibgcd 4, jumpbr 17, ldst 28) on the iCEstick
at `/dev/cu.usbserial-212201`, bitstream `bitstreams/monitor-cf0551c.bin`
(sha256 `3cd18342…7ab6b`). Simulation and silicon agree.

## What each tool is used for

| Tool | Where | Sensitivity |
|---|---|---|
| `iverilog` / `vvp` | `sim`, `equiv`, `hwreset`, `c/` | Low — 13.0 has been stable across machines |
| `yosys` | `lint`, `synth`, `equiv`, `stat` | **High — the LUT/LC counts come from here** |
| `nextpnr-ice40` | `pnr` (hx1k, tq144, 12 MHz) | Medium — Fmax and placed LC count vary run to run and version to version |
| `icepack` / `iceprog` | bitstream / flashing (human only) | Low |
| `riscv64-elf-gcc` + binutils | `c/` examples only, not `make check` | Low |
| `python3` | `tools/*.py`, `c/tobin2hex.py` | Low — stdlib only |

## Known drift — why yosys is pinned

**Homebrew's Yosys 0.69+post (git 143eb14f), seen 2026-09-10 before the pin:** identical
RTL, fresh clone, everything green except `stat`:

```
FAIL: 1185 logic cells exceeds LC_BUDGET=1180 (see TASKS.md 'Shrink the core')
```

That is **1185 on 0.69 vs 1175 on 0.68** — a 10-cell swing from the synthesiser
alone, 0.8 % of the part, against a budget with 5 cells of headroom. The RTL did
not change. So on any machine with a newer yosys than the reference, a `stat`
failure by a handful of cells is **toolchain drift until proven otherwise**.

Resolved by pinning yosys (next section). The standing rule: do not "fix" a
version-drift failure by editing RTL in a loop session. Escalate it.

## DECIDED 2026-09-11 — yosys pinned at 0.68 (option B)

**Decided by the human; the alternatives were A (raise `LC_BUDGET`) and C (shrink
the core). B keeps the numbers comparable across machines.**
Done on the M4 the same morning: `yosys@0.68` built from source (the 0.68 bottle
is gone from ghcr.io) from homebrew-core's formula at `a9f2bc5e7b`, `brew pin`,
Homebrew's `yosys` 0.69 removed. Result on the M4, same commit as the reference:

```
CHECKS TOTAL: 16105 passed in 23 benches
  unflattened total: 1165 LUT4 (budget 1180)
  ICESTORM_LC:    1175/   1280    91%
  ICESTORM_RAM:     16/     16   100%
Max frequency for clock 'CLK$SB_IO_IN_$glb_clk': 33.20 MHz (PASS at 12.00 MHz)
CHECK: OK
```

Identical to the previous reference block, to the cell. *The pin was applied on both machines the same day
(2026-09-11): the M4 through install stage 4b, the previous machine by hand from the same
`yosys@0.68` formula; both re-verified at 16,105 checks, 1165 LUT4, 1175 LC. `brew upgrade`
can no longer move yosys on either.* `LC_BUDGET` stays 1180. The pin
lives in the install repo (`m4-mac-mini-install`: stage 4b, `formula/yosys@0.68.rb`,
and stage 14 refuses a machine whose `yosys -V` is not 0.68). Every future machine
built from that repo inherits it, as the table warned. Moving the reference to a
newer yosys is a deliberate act: re-record this file *and* change the pin there.

Before the decision (2026-09-10) the same commit was red on Homebrew's 0.69
(1185 LC) and green on 0.68 (1175 LC). The recommendation at the time was A, on the
grounds that a budget which breaks on every `brew upgrade` is a budget nobody will
trust; B was chosen instead, and the pin in the install repo is what makes it hold.

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
