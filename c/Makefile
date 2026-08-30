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

.PHONY: run build clean
run: build
	@iverilog -g2012 -Wall -Wno-timescale -o $(BUILD)/csim.vvp -s csim csim.v $(RTL)
	@echo "=== $(PROG) output ==="
	@vvp -N $(BUILD)/csim.vvp

build: $(BUILD)
	$(CC) $(CFLAGS) -T link.ld -o $(BUILD)/$(PROG).elf start.S rvc.c examples/$(PROG).c $(LIBGCC)
	@$(OBJCOPY) -O binary $(BUILD)/$(PROG).elf $(BUILD)/$(PROG).bin
	@python3 tobin2hex.py $(BUILD)/$(PROG).bin $(BUILD)/cprog.hex
	@sz=$$(wc -c < $(BUILD)/$(PROG).bin); echo "$(PROG): $$sz bytes / 6144"; test $$sz -le 6144
	@echo "disasm: $(BUILD)/$(PROG).lst"; $(CC:gcc=objdump) -d $(BUILD)/$(PROG).elf > $(BUILD)/$(PROG).lst

$(BUILD):
	@mkdir -p $(BUILD)
clean:
	@rm -f $(BUILD)/cprog.hex $(BUILD)/*.elf $(BUILD)/*.bin $(BUILD)/csim.vvp
