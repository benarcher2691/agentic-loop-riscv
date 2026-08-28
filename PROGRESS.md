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
- **Decoder, part 1** (task 3): `rtl/decoder.v` already existed complete from the interrupted
  session (all 10 class flags, fields, AND all five immediates already implemented) — verified
  it, did not rewrite it. New `tb/decoder_tb.v`: table-driven `check_vec` task, 10 hand-encoded
  vectors (one per class) × 15 checks + 1 illegal-opcode check = 151 checks, 405 total.
  Surprise: in I/S/B/U/J formats rs2/rd/funct7 overlap immediate bits, so expected values are
  raw instruction bits (addi x1,x0,5 → rs2Id=5; ebreak → rs2Id=1; jal x1,16 → rs2Id=16;
  lui → rs1=rs2=31, funct7=127). Next (part 2): immediates are already driven — bench-only
  work; extend `check_vec` with the five expected immediates per vector and add the task's
  positive/negative I/S/U vectors.
- **Decoder, part 2** (task 4): bench-only again (decoder already drove all five immediates).
  `check_vec` now takes eI/eS/eB/eU/eJ and checks all five immediate outputs on every vector;
  14 vectors (added addi -1, lw -8, sw +16, lui 0x12345 for bit-31-clear U) × 20 checks + 1
  illegal = 281, total 535. New hand encodings: lw x3,-8(x2) = 0xFF812183, sw x2,16(x1) =
  0x0020A823. Surprise: hand bit-slicing kept misaligning (nibble→bit-index slips), so the
  expected constants were computed by applying the spec formulas to the hand-encoded words
  with a throwaway python bit-slicer, anchored against the task text's own named values
  (Iimm=-1, Simm=-4, Uimm=0xFFFFF000, Jimm=16, Bimm=8, Iimm=64) and part-1's field checks —
  all matched, and sim passed first run. Advice: for part 3, reuse the same python slicer to
  pre-compute B/J immediate expectations, then do the assembler round-trip (RType..JType from
lib/riscv_assembly.v) as the true independent cross-check; note the lib needs a `MEM`-bearing
   module to include into.
- **Decoder, part 3** (task 5): bench-only again. Added 5 hand vectors (fwd bne +16, back bne -8
  and beq -8 = 0xFE209CE3/0xFE208CE3, back jal x0,-8 = 0xFF9FF06F, edge jal x1,4094 = 0x7FF000EF
  with imm[11]=1/imm[20]=0) + assembler round trip: `reg [31:0] MEM[0:15]` + lib include at
  module level, six RType..JType calls, each word first CHECK_EQ'd against the hand encoding,
  then run through check_vec. 761 checks total, pnr unchanged (91 LCs).
  Surprises: (1) the "jal x1,2046" word I first built was really jal x1,4094 — 0x7FF000EF has
  imm[11]=1; kept it as the swap-edge test; (2) two FAILs from transcribing funct3=000 for
  0xFF9FF06F where bits[14:12]=111 — the python slicer had it right, I overrode it by eye.
  Advice: trust the slicer output verbatim, never re-derive fields by hand. The lib include
  resolves via the Makefile's `-I lib`; it needs `MEM` + brings its own `memPC` (assign it
  before generating). Next task is the ALU (rtl/alu.v) — first new RTL module since Memory.
