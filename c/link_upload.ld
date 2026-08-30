/* Uploadable variant: the program is loaded by the monitor at 0x400 and CALLED
   (JALR) — so it is a returning subroutine, not a boot image. It runs on the
   monitor's stack (sp = 0x1800, already set), must preserve sp, and returns
   with `ret`. Code+rodata+data+bss live from 0x400 up to below the stack. */
MEMORY { RAM (rwx) : ORIGIN = 0x400, LENGTH = 0x1400 }   /* 0x400 .. 0x1800 */
ENTRY(_start)
SECTIONS {
  . = 0x400;
  .text   : { *(.text.start) *(.text*) } > RAM
  .rodata : { *(.rodata*) *(.srodata*) } > RAM
  .data   : { *(.data*) *(.sdata*) }     > RAM
  .bss    : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) ; __bss_end = .; } > RAM
}
