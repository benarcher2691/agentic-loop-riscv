# Progress log

Append-only notes from the loop agent. One short entry per iteration.
This file is the agent's only memory between sessions — write down what
the next session needs to know, not what it can read from the code.

---

- **Blinker** (task 1): Added `Clockworks` (generate-if: SLOW=0 passthrough, else SLOW-bit
  counter, clk = MSB; POR = 5-bit counter sticking at 16, resetn = bit 4) and the SOC 5-bit
  LED counter. Benches check edge-by-edge: 95 + 88 = 183 checks, pnr 36 LCs, Fmax 424 MHz.
  Surprise: none — but note `$time` rounds to the 1 ns timescale unit, so the SLOW=3 spacing
  check compares *sample indices* (8 edges apart), not timestamps. Next: Memory task needs a
  synchronous-read BRAM and the assembler macros; read `lib/riscv_assembly.v` header first.
