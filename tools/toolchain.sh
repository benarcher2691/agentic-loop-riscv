#!/usr/bin/env bash
# Print the exact versions of every tool `make check` (and the human-only
# hardware targets) invoke. Compare against TOOLCHAIN.md before trusting a
# red check on a new machine: a different yosys gives a different cell count.
#   bash tools/toolchain.sh            # print
#   bash tools/toolchain.sh > /tmp/now; diff <(sed -n '/^## Reference/,/^## /p' TOOLCHAIN.md) /tmp/now
set -u
v() { # v <label> <command...>: first line of output, or "MISSING"
  local label=$1; shift
  local out
  if out=$("$@" 2>&1 </dev/null); then :; else :; fi
  out=$(printf '%s' "$out" | grep -v '^\s*$' | head -1)
  printf '%-22s %s\n' "$label" "${out:-MISSING}"
}
echo "host                   $(hostname -s) $(uname -m) macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
v "yosys"          yosys -V
v "yosys pin"      bash -c 'brew list --pinned 2>/dev/null | grep -qx "yosys@0.68" && echo "yosys@0.68 pinned (brew upgrade cannot move it)" || echo "NOT PINNED - see TOOLCHAIN.md"'
v "nextpnr-ice40"  bash -c 'brew list --versions nextpnr-ice40 2>/dev/null || echo MISSING'
v "icestorm"       bash -c 'brew list --versions icestorm 2>/dev/null || echo MISSING'
v "icepack"        bash -c 'command -v icepack >/dev/null && echo present || echo MISSING'
v "iceprog"        bash -c 'command -v iceprog >/dev/null && echo present "(human only)" || echo MISSING'
v "iverilog"       bash -c 'iverilog -V 2>&1 | head -1'
v "vvp"            bash -c 'vvp -V 2>&1 | head -1'
v "riscv64-elf-gcc" riscv64-elf-gcc --version
v "riscv64-elf-objcopy" riscv64-elf-objcopy --version
v "python3"        python3 --version
v "make"           bash -c 'make --version | head -1'
v "cc"             bash -c '/usr/bin/cc --version | head -1'
v "timeout"        bash -c 'timeout --version 2>&1 | head -1'
v "git"            git --version
v "bash"           bash -c 'bash --version | head -1'
echo "paths                  yosys=$(command -v yosys) nextpnr-ice40=$(command -v nextpnr-ice40) iverilog=$(command -v iverilog) python3=$(command -v python3)"
