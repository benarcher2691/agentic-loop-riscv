# Uploadable crt0: entered via the monitor's `G 0x400` (JALR ra, 0x400).
# It is a proper subroutine — save ra, zero .bss, call main, restore ra, ret.
# Uses the monitor's already-set sp (0x1800); must not clobber sp.
  .section .text.start
  .globl _start
_start:
  addi  sp, sp, -16
  sw    ra, 12(sp)
  la    t0, __bss_start
  la    t1, __bss_end
1:
  bgeu  t0, t1, 2f
  sw    zero, 0(t0)
  addi  t0, t0, 4
  j     1b
2:
  call  main
  lw    ra, 12(sp)
  addi  sp, sp, 16
  ret               # back to the monitor, which replies 'K'
