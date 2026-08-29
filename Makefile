# Loop RISC-V — build and verification flow. All FOSS: iverilog, yosys, nextpnr-ice40, icestorm.
#
#   make check   sim + lint + synth + pnr + stat   <- what the loop verifies
#   make prog    flash build/SOC.bin to the iCEstick (human only)
#   make uart    read the board's UART on FTDI channel B (human only)
TOP      ?= SOC
DEVICE   ?= hx1k
PACKAGE  ?= tq144
PCF      ?= boards/icestick.pcf
FREQ_MHZ ?= 12
LC_BUDGET?= 1150
BUILD    := build
RTL      := $(sort $(wildcard rtl/*.v))
TBS      := $(sort $(wildcard tb/*_tb.v))
SIMOK    := $(patsubst tb/%_tb.v,$(BUILD)/%.simok,$(TBS))
IVFLAGS  := -g2012 -Wall -Wno-timescale -DBENCH -I tb -I lib -I rtl

.PHONY: check sim lint synth pnr equiv stat prog uart clean

check: sim lint synth pnr equiv stat
	@echo "CHECK: OK"

# --- simulation: every tb/*_tb.v is a self-checking bench that must print PASS
sim: $(SIMOK)
	@total=0; for l in $(patsubst %.simok,%.log,$(SIMOK)); do \
	  n=$$(grep -oE 'CHECKS: [0-9]+ passed' $$l | grep -oE '[0-9]+'); total=$$((total + $${n:-0})); done; \
	echo "CHECKS TOTAL: $$total passed in $(words $(TBS)) benches"

$(BUILD)/%.simok: tb/%_tb.v $(RTL) tb/check.vh lib/riscv_assembly.v | $(BUILD)
	@echo "=== sim: $*_tb"
	iverilog $(IVFLAGS) -s $*_tb -o $(BUILD)/$*.vvp $< $(RTL)
	@vvp -N $(BUILD)/$*.vvp > $(BUILD)/$*.log 2>&1; s=$$?; cat $(BUILD)/$*.log; test $$s -eq 0
	@grep -q '^PASS' $(BUILD)/$*.log || { echo "FAIL: $*_tb did not print PASS"; exit 1; }
	@! grep -q '^FAIL' $(BUILD)/$*.log
	@touch $@

# --- lint: structural checks (undriven / multiply-driven / unused), fails on problems
lint: | $(BUILD)
	@echo "=== lint"
	yosys -q -l $(BUILD)/lint.log -p "read_verilog -sv $(RTL); hierarchy -check -top $(TOP); proc; check -assert" >/dev/null

# --- synthesis for iCE40; a latch is always a bug here
synth: $(BUILD)/$(TOP).json
$(BUILD)/$(TOP).json: $(RTL) | $(BUILD)
	@echo "=== synth"
	yosys -q -l $(BUILD)/synth.log -p "read_verilog -sv $(RTL); synth_ice40 -top $(TOP) -json $@" >/dev/null
	@! grep -q 'Latch inferred' $(BUILD)/synth.log || { echo "FAIL: latch inferred, see $(BUILD)/synth.log"; exit 1; }

# --- place & route on the real part: fails if it does not fit or misses $(FREQ_MHZ) MHz
pnr: $(BUILD)/$(TOP).bin
$(BUILD)/$(TOP).asc: $(BUILD)/$(TOP).json $(PCF)
	@echo "=== pnr ($(DEVICE)-$(PACKAGE), $(FREQ_MHZ) MHz)"
	nextpnr-ice40 --$(DEVICE) --package $(PACKAGE) --pcf $(PCF) --json $< --asc $@ --freq $(FREQ_MHZ) -q -l $(BUILD)/pnr.log
$(BUILD)/$(TOP).bin: $(BUILD)/$(TOP).asc
	icepack $< $@

# --- gate-level check: RTL and the synthesized netlist must agree on every port, every cycle
equiv: $(BUILD)/$(TOP).json tools/equiv_tb.v
	@echo "=== equiv (RTL vs post-synthesis netlist)"
	@yosys -q -p "read_verilog -sv $(RTL); synth_ice40 -top $(TOP); rename $(TOP) $(TOP)_synth; write_verilog -noattr $(BUILD)/$(TOP)_synth.v" >/dev/null
	@iverilog $(IVFLAGS) -s equiv_tb -o $(BUILD)/equiv.vvp tools/equiv_tb.v $(RTL) $(BUILD)/$(TOP)_synth.v "$$(yosys-config --datdir)/ice40/cells_sim.v"
	@vvp -N $(BUILD)/equiv.vvp > $(BUILD)/equiv.log 2>&1; cat $(BUILD)/equiv.log | grep -E "MISMATCH|cycles=|PASS|FAIL"; grep -q '^PASS' $(BUILD)/equiv.log

# --- stat: utilisation, Fmax, and the logic budget. The budget is checked on the UNFLATTENED
#     synthesis as well: with a constant ROM program, flattening lets yosys prune every
#     instruction path the program does not use, which hides the real core size.
stat: $(BUILD)/$(TOP).asc
	@echo "=== stat"
	@yosys -q -l $(BUILD)/synth_noflat.log -p "read_verilog -sv $(RTL); synth_ice40 -top $(TOP) -noflatten; stat" >/dev/null
	@awk '/^=== /{m=$$2} /^ +[0-9]+ +SB_LUT4/{ if (m != "design") print "  " m ": " $$1 " LUT4"}' $(BUILD)/synth_noflat.log | sort -u
	@luts=$$(awk '/^=== design/{f=1} f && /^ +[0-9]+ +SB_LUT4/{v=$$1} END{print v}' $(BUILD)/synth_noflat.log); echo "  unflattened total: $${luts:-?} LUT4 (budget $(LC_BUDGET))"; \
	  test "$${luts:-0}" -le $(LC_BUDGET) || { echo "FAIL: $$luts LUT4 unflattened exceeds LC_BUDGET=$(LC_BUDGET) (see TASKS.md 'Shrink the core')"; exit 1; }
	@grep -E 'ICESTORM_(LC|RAM):\s+[0-9]+/' $(BUILD)/pnr.log | tail -2 | sed 's/^.*Info: *//'
	@grep -E 'Max frequency' $(BUILD)/pnr.log | tail -1 | sed 's/^.*Info: *//'
	@lc=$$(grep -oE 'ICESTORM_LC: +[0-9]+/' $(BUILD)/pnr.log | tail -1 | grep -oE '[0-9]+'); \
	  test "$${lc:-0}" -le $(LC_BUDGET) || { echo "FAIL: $$lc logic cells exceeds LC_BUDGET=$(LC_BUDGET) (see TASKS.md 'Shrink the core')"; exit 1; }

# --- hardware (human only; denied to the loop agent in opencode.json)
prog: $(BUILD)/$(TOP).bin
	iceprog $<
uart:
	python3 tools/uart.py

$(BUILD):
	mkdir -p $(BUILD)
clean:
	rm -rf $(BUILD)
