# crt0: set the stack, zero .bss, call main, halt on return.
  .section .text.start
  .globl _start
_start:
  lui   sp, %hi(__stack_top)
  addi  sp, sp, %lo(__stack_top)
  # zero .bss
  la    t0, __bss_start
  la    t1, __bss_end
1:
  bgeu  t0, t1, 2f
  sw    zero, 0(t0)
  addi  t0, t0, 4
  j     1b
2:
  call  main
  ebreak            # main returned -> EBREAK halts the core (the sim/monitor sees it)
