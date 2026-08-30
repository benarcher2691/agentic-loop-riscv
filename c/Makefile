# Build a C program for the Loop RISC-V core and run it in simulation.
#   make PROG=hello run      # compile c/examples/hello.c, run it, print UART output
#   make PROG=fib   run
# Requires: riscv64-elf-gcc (brew install riscv64-elf-gcc), iverilog.
PROG    ?= hello
RTL     := ../rtl/processor.v ../rtl/decoder.v ../rtl/alu.v
BUILD   := ../build
CC      := riscv64-elf-gcc
OBJCOPY := riscv64-elf-objcopy
CFLAGS  := -march=rv32i -mabi=ilp32 -Os -ffreestanding -nostdlib -fno-builtin -Wall -Wextra
# libgcc supplies the soft __udivsi3/__umodsi3 (RV32I has no hardware divide) —
# pure integer routines, safe bare-metal.
LIBGCC  := $(shell $(CC) $(CFLAGS) -print-libgcc-file-name)

.PHONY: run build hw clean
run: build
	@iverilog -g2012 -Wall -Wno-timescale -o $(BUILD)/csim.vvp -s csim csim.v $(RTL)
	@echo "=== $(PROG) output ==="
	@vvp -N $(BUILD)/csim.vvp

build: $(BUILD)
	$(CC) $(CFLAGS) -T link.ld -o $(BUILD)/$(PROG).elf start.S rvc.c examples/$(PROG).c $(LIBGCC)
	@$(OBJCOPY) -O binary $(BUILD)/$(PROG).elf $(BUILD)/$(PROG).bin
	@python3 tobin2hex.py $(BUILD)/$(PROG).bin $(BUILD)/cprog.hex 1536
	@sz=$$(wc -c < $(BUILD)/$(PROG).bin); echo "$(PROG): $$sz bytes / 6144"; test $$sz -le 6144
	@echo "disasm: $(BUILD)/$(PROG).lst"; $(CC:gcc=objdump) -d $(BUILD)/$(PROG).elf > $(BUILD)/$(PROG).lst

# hardware: build a returning, 0x400-linked variant and upload+run it via the monitor
hw: $(BUILD)
	$(CC) $(CFLAGS) -T link_upload.ld -o $(BUILD)/$(PROG)_hw.elf start_upload.S rvc.c examples/$(PROG).c $(LIBGCC)
	@$(OBJCOPY) -O binary $(BUILD)/$(PROG)_hw.elf $(BUILD)/$(PROG)_hw.bin
	@python3 tobin2hex.py $(BUILD)/$(PROG)_hw.bin $(BUILD)/$(PROG)_hw.hex
	@sz=$$(wc -c < $(BUILD)/$(PROG)_hw.bin); echo "$(PROG)_hw: $$sz bytes (loads at 0x400)"; test $$sz -le 5120
	@echo "=== $(PROG) on hardware (via the UART monitor) ==="
	python3 ../tools/hw.py runc $(BUILD)/$(PROG)_hw.hex

$(BUILD):
	@mkdir -p $(BUILD)
clean:
	@rm -f $(BUILD)/cprog.hex $(BUILD)/*.elf $(BUILD)/*.bin $(BUILD)/csim.vvp

# --- inputtest: the PROTECTED verifier for Phase 6 (UART input). Builds count.c,
#     runs it in csim feeding canned input via +instr, and checks the program
#     actually read the count and limited its output. Do not weaken this.
inputtest: $(BUILD)
	$(CC) $(CFLAGS) -T link.ld -o $(BUILD)/count.elf start.S rvc.c examples/count.c $(LIBGCC)
	@$(OBJCOPY) -O binary $(BUILD)/count.elf $(BUILD)/count.bin
	@python3 tobin2hex.py $(BUILD)/count.bin $(BUILD)/cprog.hex 1536
	@iverilog -g2012 -Wall -Wno-timescale -o $(BUILD)/csim.vvp -s csim csim.v $(RTL)
	@o6=$$(vvp -N $(BUILD)/csim.vvp +instr=6 2>/dev/null); \
	 o3=$$(vvp -N $(BUILD)/csim.vvp +instr=3 2>/dev/null); p=0; \
	 if echo "$$o6" | grep -q 'primes' && echo "$$o6" | grep -qw 13 && ! echo "$$o6" | grep -qw 17; \
	   then p=$$((p+2)); else echo "FAIL N=6: want prompt + 13 present + 17 absent; got: [$$o6]"; fi; \
	 if echo "$$o3" | grep -qw 5 && ! echo "$$o3" | grep -qw 7; \
	   then p=$$((p+2)); else echo "FAIL N=3: want 5 present + 7 absent; got: [$$o3]"; fi; \
	 echo "CHECKS TOTAL: $$p passed"; \
	 test $$p -eq 4 && echo "INPUTTEST: PASS" || { echo "INPUTTEST: FAIL"; exit 1; }
