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
