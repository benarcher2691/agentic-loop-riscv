/* Bare-metal RV32I layout for the Loop RISC-V core: 6 KB RAM at 0, PC boots at 0.
   Everything (code, rodata, data, bss) lives in RAM; VMA==LMA so initialised data
   is simply part of the loaded image. Stack grows down from the top of RAM. */
MEMORY { RAM (rwx) : ORIGIN = 0x0, LENGTH = 6K }
ENTRY(_start)
SECTIONS {
  . = 0x0;
  .text   : { *(.text.start) *(.text*) } > RAM
  .rodata : { *(.rodata*) *(.srodata*) } > RAM
  .data   : { *(.data*) *(.sdata*) }     > RAM
  .bss    : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) ; __bss_end = .; } > RAM
  . = ALIGN(4);
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);   /* 0x1800 */
}
