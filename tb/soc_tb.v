`timescale 1ns/1ps
`default_nettype none
// SOC end-to-end demo test: the ROM program prints "Loop RISC-V\n" over the
// UART (busy-wait between bytes), walks the LED pattern 1,2,4,8,16 exactly
// once with an RDCYCLE-based delay (read the cycle counter, loop until the
// 32-bit-wrap-safe difference now-start reaches DELAY — small under `ifdef
// FAST_SIM so simulation stays fast), then echoes UART input forever: poll
// the RX word, write the byte back to the UART data register, show byte & 31
// on the LEDs. The bench carries a 115200-baud serial receiver (mid-bit
// sampling, nominal bit time — the emitter's real bit is 106 clocks = 1.7%
// slow, which still leaves 0.35-bit margin on the last data bit) and a
// transmitter model driving RXD. Checks: all 12 banner bytes + stop bits,
// LEDS dark until the banner is done, the LED walk 1,2,4,8,16 with each
// step's period measured against the bench's own cycle count (DELAY plus a
// modelled fixed instruction overhead, ± 3 instructions), a counter deposit
// just below 2^32 that makes the first delay loop span the 32-bit wrap
// (cycleh must tick 0 -> 1 and the period must not change), the echo
// round-trip of "hi" with LEDS == "i" & 31, and a three-way ROM cross-check
// (hand-assembled constants vs a lib-assembled copy vs dut.memory.MEM).
module soc_tb;
  `include "check.vh"
  `WATCHDOG(20_000_000)

  reg        CLK = 0;
  reg        RXD = 1;
  wire       TXD;
  wire [4:0] LEDS;

  SOC #(.SLOW(0)) dut (.CLK(CLK), .RXD(RXD), .TXD(TXD), .LEDS(LEDS));

  always #41.667 CLK = ~CLK;   // 12 MHz

  // The emitter's data register has no power-on value (X in RTL sim would
  // stall o_ready forever); one hierarchical write kicks it into idle.
  initial dut.uart.data = 10'd0;

  // ---- lib-assembled copy of the ROM program (must match rtl/memory.v) ---
  reg [31:0] MEM [0:34];
  `include "riscv_assembly.v"
  integer WBYTE = 12, WBUSY = 20, LSTEP = 48, WDELAY = 64, ECHO = 88, EBUSY = 104;
  integer i, wi;   // wi: the assembly block's own index — `i` is shared with
                   // the main block's loops and must not be clobbered at t=1ns

  // Hand-assembled copy (independent python encoder, spec formulas).
  // BENCH build: words 14/15 are the small delay; hardware build swaps in
  // LUI 0x2DC + ADDI 0x6C0 = DELAY 3000000 cycles = 0.25 s per step at 12 MHz.
  reg [31:0] HAND [0:34];
  initial begin
    HAND[ 0] = 32'h004002B7;  // lui x5,0x40000       x5 = 0x400000 IO base
    HAND[ 1] = 32'h08000313;  // addi x6,x0,128       x6 = &message (byte 128)
    HAND[ 2] = 32'h00C00393;  // addi x7,x0,12        12 banner bytes
    HAND[ 3] = 32'h00030503;  // WBYTE: lb x10,0(x6)  (LB = funct3 000)
    HAND[ 4] = 32'h00A2A423;  // sw x10,8(x5)         UART data <- char
    HAND[ 5] = 32'h0102A403;  // WBUSY: lw x8,16(x5)  UART status
    HAND[ 6] = 32'h20047413;  // andi x8,x8,512       busy = bit 9
    HAND[ 7] = 32'hFE041CE3;  // bne x8,x0,WBUSY      (28 -> 20)
    HAND[ 8] = 32'h00130313;  // addi x6,x6,1
    HAND[ 9] = 32'hFFF38393;  // addi x7,x7,-1
    HAND[10] = 32'hFE0392E3;  // bne x7,x0,WBYTE      (40 -> 12)
    HAND[11] = 32'h00100493;  // addi x9,x0,1         LED pattern = 1
    HAND[12] = 32'h0092A223;  // LSTEP: sw x9,4(x5)   LEDS <- pattern
    HAND[13] = 32'hC0002773;  // csrrs x14,cycle,x0   start = cycle (0xC0002073|14<<7)
`ifdef BENCH
    HAND[14] = 32'h12C00813;  // addi x16,x0,300      DELAY = 300 cycles/step
    HAND[15] = 32'h00080813;  // addi x16,x16,0
`else
    HAND[14] = 32'h002DC837;  // lui x16,0x2DC        3000000 = 0x2DC6C0
    HAND[15] = 32'h06C08813;  // addi x16,x16,0x6C0   = 0.25 s at 12 MHz
`endif
    HAND[16] = 32'hC00027F3;  // WDELAY: csrrs x15,cycle,x0  now = cycle
    HAND[17] = 32'h40E787B3;  // sub x15,x15,x14      diff = now - start (wrap-safe)
    HAND[18] = 32'hFF07ECE3;  // bltu x15,x16,WDELAY  loop while diff < DELAY (72 -> 64)
    HAND[19] = 32'h009484B3;  // add x9,x9,x9         pattern <<= 1
    HAND[20] = 32'h01F4F493;  // andi x9,x9,31        keep 5 bits
    HAND[21] = 32'hFC049EE3;  // bne x9,x0,LSTEP      (84 -> 48)
    HAND[22] = 32'h0202A403;  // ECHO: lw x8,32(x5)   RX word (avail bit 8)
    HAND[23] = 32'h10047593;  // andi x11,x8,256      avail?
    HAND[24] = 32'hFE058CE3;  // beq x11,x0,ECHO      (96 -> 88)
    HAND[25] = 32'h0082A423;  // sw x8,8(x5)          UART data <- byte
    HAND[26] = 32'h0102A603;  // EBUSY: lw x12,16(x5) UART status
    HAND[27] = 32'h20067613;  // andi x12,x12,512     busy = bit 9
    HAND[28] = 32'hFE061CE3;  // bne x12,x0,EBUSY     (112 -> 104)
    HAND[29] = 32'h01F47693;  // andi x13,x8,31       LEDs <- byte & 31
    HAND[30] = 32'h00D2A223;  // sw x13,4(x5)         LEDS <- byte & 31
    HAND[31] = 32'hFDDFF06F;  // jal x0,ECHO          (124 -> 88)
    HAND[32] = 32'h706F6F4C;  // "Loop"
    HAND[33] = 32'h53495220;  // " RIS"
    HAND[34] = 32'h0A562D43;  // "C-V\n"
  end

  // Assemble the same program here with the lib macros.
  initial begin
    #1;   // the lib's `initial memPC = 0` has run
    LUI(x5, 32'h00400000);
    ADDI(x6, x0, 128);
    ADDI(x7, x0, 12);
    Label(WBYTE); LB(x10, x6, 0);
    SW(x10, x5, 8);
    Label(WBUSY); LW(x8, x5, 16);
    ANDI(x8, x8, 512);
    BNE(x8, x0, LabelRef(WBUSY));
    ADDI(x6, x6, 1);
    ADDI(x7, x7, -1);
    BNE(x7, x0, LabelRef(WBYTE));
    ADDI(x9, x0, 1);
    Label(LSTEP); SW(x9, x5, 4);
    CSRRS(x14, 12'hC00, x0);
`ifdef BENCH
    ADDI(x16, x0, 300);
    ADDI(x16, x16, 0);
`else
    LUI(x16, 32'h002DC);
    ADDI(x16, x16, 32'h6C0);
`endif
    Label(WDELAY); CSRRS(x15, 12'hC00, x0);
    SUB(x15, x15, x14);
    BLTU(x15, x16, LabelRef(WDELAY));
    ADD(x9, x9, x9);
    ANDI(x9, x9, 31);
    BNE(x9, x0, LabelRef(LSTEP));
    Label(ECHO); LW(x8, x5, 32);
    ANDI(x11, x8, 256);
    BEQ(x11, x0, LabelRef(ECHO));
    SW(x8, x5, 8);
    Label(EBUSY); LW(x12, x5, 16);
    ANDI(x12, x12, 512);
    BNE(x12, x0, LabelRef(EBUSY));
    ANDI(x13, x8, 31);
    SW(x13, x5, 4);
    JAL(x0, LabelRef(ECHO));
    DATAB(8'h4C, 8'h6F, 8'h6F, 8'h70);   // "Loop"
    DATAB(8'h20, 8'h52, 8'h49, 8'h53);   // " RIS"
    DATAB(8'h43, 8'h2D, 8'h56, 8'h0A);   // "C-V\n"
    endASM();
    // lib copy vs hand constants (catches the two drifting apart)
    for (wi = 0; wi < 35; wi = wi + 1)
      `CHECK_EQ(MEM[wi], HAND[wi], "lib-assembled word matches the hand encoding")
  end

  // ---- serial receiver model: 115200 baud nominal, sample mid-bit --------
  localparam real BITNS = 1000000000.0 / 115200.0;   // 8680.6 ns per bit
  task recv_byte;
    output [7:0] b;
    integer k;
    begin
      @(negedge TXD);          // start bit edge
      #(BITNS * 1.5);          // centre of data bit 0
      for (k = 0; k < 8; k = k + 1) begin
        b[k] = TXD;            // LSB first
        #(BITNS);
      end
      `CHECK_EQ(TXD, 1'b1, "stop bit is high")
    end
  endtask

  // ---- bench transmitter model: 8N1 into RXD, LSB first ------------------
  // Same shape as uart_rx_tb's send_soc: the UartRx samples mid-bit with
  // 104-clock bits (8666.7 ns), 0.16% fast vs this nominal bit time — the
  // drift over one 10-bit frame is ~0.02 bit, far inside the sampling margin.
  task send_byte(input [7:0] b);
    integer k;
    begin
      RXD = 1'b0;              // start bit
      #(BITNS);
      for (k = 0; k < 8; k = k + 1) begin
        RXD = b[k];            // data bits, LSB first
        #(BITNS);
      end
      RXD = 1'b1;              // stop bit
      #(BITNS);
    end
  endtask

  reg [95:0] BANNER_STR = "Loop RISC-V\n";  // first char in the MSBs
  reg  [7:0] banner [0:11];
  reg  [7:0] b, eb;
  integer gap, n;

  // The bench's own cycle count (incremented every CLK; read 1 ns after the
  // edge, so there is no race with the DUT or with the main block).
  integer cyc = 0;
  always @(posedge CLK) cyc = cyc + 1;

  // ---- LED period model (independent of the DUT) -------------------------
  // The program's delay step, from the SW that commits one LED pattern to
  // the SW that commits the next, at 3 cycles/instruction (no loads in the
  // path): SW | csrrs start | 2x delay const | N x (csrrs, sub, bltu) |
  // add, andi, bne(taken) | next SW. The start-read samples the counter 2
  // cycles after the committing edge and iteration k's read is 9k higher,
  // so the loop exits at N = ceil(DELAY/9); the next SW commits 21 cycles
  // after the last bltu. Expected period = 9*N + 21 cycles. The check
  // allows ± 3 instructions (± 9 cycles).
  `ifdef BENCH
  integer DELAY = 300;        // must match the ROM's `ifdef FAST_SIM constant
  `else
  integer DELAY = 3000000;    // must match the ROM's hardware constant
  `endif
  integer exp_period;
  initial exp_period = 9 * ((DELAY + 8) / 9) + 21;

  // Wait until LEDS == p (bounded); one check; reports the bench cycle at
  // detection (1 ns after the committing edge, so period differences are
  // exact).
  task wait_leds_c(input [4:0] p, input integer timeout, output integer t_out);
    integer n;
    begin
      n = 0;
      while (LEDS !== p && n < timeout) begin
        @(posedge CLK); #1;
        n = n + 1;
      end
      `CHECK_EQ(LEDS, p, "LED pattern reached")
      t_out = cyc;
    end
  endtask

  // One measured walk step: wait for pattern p, then the period since the
  // previous pattern must equal exp_period ± 3 instructions (± 9 cycles).
  integer t_last;
  task check_step(input [4:0] p);
    integer t_now;
    begin
      wait_leds_c(p, 5000, t_now);
      gap = t_now - t_last;
      t_last = t_now;
      `CHECK(gap >= exp_period - 9 && gap <= exp_period + 9,
             "LED period equals DELAY plus the fixed instruction overhead")
    end
  endtask

  initial begin
    for (i = 0; i < 12; i = i + 1)
      banner[i] = BANNER_STR[(11-i)*8 +: 8];

    `CHECK_EQ(TXD, 1'b1, "TXD idles high before the first byte")

    // Power-on reset: resetn low through the first 15 sampled cycles, released
    // by the 16th posedge (POR counter reaches 16); LEDS stay dark throughout.
    for (i = 0; i < 15; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(dut.clockworks.resetn, 1'b0, "resetn low during power-on reset")
      `CHECK_EQ(LEDS, 5'd0, "LEDS dark while resetn is low")
    end
    @(posedge CLK); #1;
    `CHECK_EQ(dut.clockworks.resetn, 1'b1, "reset released after 16 cycles")
    `CHECK_EQ(LEDS, 5'd0, "LEDS dark while resetn is low")
    `CHECK_EQ(dut.processor.PC, 32'd0, "PC starts at 0")

    // The banner: 12 bytes, in order, with clean framing. A broken busy-wait
    // would drop or repeat bytes and show up here.
    for (i = 0; i < 12; i = i + 1) begin
      recv_byte(b);
      `CHECK_EQ(b, banner[i], "banner byte received in order")
    end

    // The program is still in the last busy-wait here (the receiver samples
    // the stop bit ~6 us before the emitter re-asserts ready): LEDS dark.
    `CHECK_EQ(LEDS, 5'd0, "LEDS still dark right after the banner")

    // First (and only) LED walk: 1,2,4,8,16, then the program falls into
    // the echo loop (the shift-and-mask wraps the pattern to 0). Every
    // step's period is measured with the bench's own cycle count.
    wait_leds_c(5'b00001, 200_000, t_last);
    // Deposit the free-running counter just below 2^32 now: the step's
    // start-read (2 cycles after the committing edge) still samples a
    // pre-wrap value, the loop's reads then run past 0xFFFFFFFF -> 0, so
    // the wrap-safe difference now-start is what ends the loop. The
    // deposit shifts the counter without changing its rate, so the period
    // model is unchanged — a wrap-unsafe comparison would exit early (or
    // never) and fail the period check below.
    dut.processor.cycles = 32'hFFFFFF00;
    check_step(5'b00010);
    `CHECK_EQ(dut.processor.cycleh, 32'd1, "cycleh ticked 0 -> 1 across the wrap")
    check_step(5'b00100);
    check_step(5'b01000);
    check_step(5'b10000);

    // Walk done: the echo loop polls the RX word; with the line idle nothing
    // changes. LEDS hold 16 from the last walk step until the first echoed
    // byte — including through the whole last delay period — so the hold
    // must outlast one full period before the PC can be expected in the
    // echo loop (with the old ~30-cycle counted delay a short hold was
    // enough; the RDCYCLE period is 327 cycles under BENCH).
    for (i = 0; i < exp_period + 200; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(LEDS, 5'b10000, "LEDS hold the last walk step while polling")
    end
    `CHECK(dut.processor.PC >= 32'd88 && dut.processor.PC < 32'd124,
           "PC keeps cycling in the echo poll loop (bytes 88..124)")

    // Echo: send 'h' (0x68) and receive the echo CONCURRENTLY. The DUT
    // starts echoing at the incoming frame's mid-stop — i.e. before
    // send_byte's stop-bit delay returns — so a sequential recv_byte misses
    // the echo's start edge and locks onto a mid-frame transition (that
    // failure reads 0xfb). Then LEDs <- 'h' & 31 = 8. The next byte is only
    // sent after this one has been echoed: the RX buffer is one byte deep,
    // and the echo proves the program consumed it.
    fork
      send_byte(8'h68);
      recv_byte(eb);
    join
    `CHECK_EQ(eb, 8'h68, "echo of 'h' comes back on TXD")
    wait_leds_c(5'b01000, 4000, t_last);   // 'h' & 31 = 8

    // Echo 'i' (0x69): back on TXD, LEDs <- 'i' & 31 = 9.
    fork
      send_byte(8'h69);
      recv_byte(eb);
    join
    `CHECK_EQ(eb, 8'h69, "echo of 'i' comes back on TXD")
    wait_leds_c(5'b01001, 4000, t_last);   // "i" & 31 = 9
    `CHECK_EQ(LEDS, "i" & 31, "LEDS show the low 5 bits of the last echoed byte")

    // ROM words: the live memory matches the hand-assembled copy.
    for (i = 0; i < 35; i = i + 1)
      `CHECK_EQ(dut.memory.MEM[i], HAND[i], "ROM word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
