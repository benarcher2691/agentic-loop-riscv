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

- **LED patterns from ROM** (task 2): Added `Memory` (256x32, sync read gated by `mem_rstrb`,
  16-word LED pattern in `initial`) and reworked `SOC` into a fetch machine: `PC` walks
  0..60 by 4 (wrap via `PROG_WORDS` localparam = 16, must match `rtl/memory.v`), LEDS =
  `mem_rdata[4:0]`. 254 checks total (95+88+71), 91 LCs, 1 BRAM, Fmax 221 MHz.
  Surprises: (1) iverilog needs `reg PC` declared *before* the `Memory` instance that uses
  it ("declaration after use" is a hard elaboration error); (2) yosys narrows `mem_rdata`
  to the 5 bits LEDS uses, so the ROM maps to ONE 256x16 RAM4K (INIT_0 only) — expect 2
  BRAMs once the Processor reads full 32-bit words; (3) word 0 displays for 17 edges
  (16 reset + 1) because PC is held at 0 through POR while the strobe is tied high — the
  soc_tb pass loop starts sampling after edge 17. Benches keep independent copies of the
  16 ROM constants, cross-checked against `dut.memory.MEM[i]` (note the instance path).
  Next: decoder task is pure combinational — hand-encode ~15 instructions, check every
  output incl. all five immediates; cross-check against the lib's RType/IType encodings.
