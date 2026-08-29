`timescale 1ns/1ps
`default_nettype none
// SOC end-to-end demo test: the ROM program prints "Loop RISC-V\n" over the
// UART (busy-wait between bytes), walks the LED pattern 1,2,4,8,16 exactly
// once with a software delay loop (delay constant shrunk under `ifdef
// FAST_SIM so simulation stays fast), then echoes UART input forever: poll
// the RX word, write the byte back to the UART data register, show byte & 31
// on the LEDs. The bench carries a 115200-baud serial receiver (mid-bit
// sampling, nominal bit time — the emitter's real bit is 106 clocks = 1.7%
// slow, which still leaves 0.35-bit margin on the last data bit) and a
// transmitter model driving RXD. Checks: all 12 banner bytes + stop bits,
// LEDS dark until the banner is done, the LED walk 1,2,4,8,16, the
// delay-loop pacing, the echo round-trip of "hi" with LEDS == "i" & 31, and
// a three-way ROM cross-check (hand-assembled constants vs a lib-assembled
// copy vs dut.memory.MEM).
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
  reg [31:0] MEM [0:32];
  `include "riscv_assembly.v"
  integer WBYTE = 12, WBUSY = 20, LSTEP = 48, WDELAY = 60, ECHO = 80, EBUSY = 96;
  integer i, wi;   // wi: the assembly block's own index — `i` is shared with
                   // the main block's loops and must not be clobbered at t=1ns

  // Hand-assembled copy (independent python encoder, spec formulas).
  // BENCH build: words 13/14 are the small delay; hardware build swaps in
  // LUI 0x7A000 + ADDI 0x120 = 500000 iterations x 6 cycles = 0.25 s/step.
  reg [31:0] HAND [0:32];
  initial begin
    HAND[ 0] = 32'h004002B7;  // lui x5,0x40000       x5 = 0x400000 IO base
    HAND[ 1] = 32'h07800313;  // addi x6,x0,120       x6 = &message (byte 120)
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
`ifdef BENCH
    HAND[13] = 32'h00200713;  // addi x14,x0,2        ~30 cycles per step
    HAND[14] = 32'h00070713;  // addi x14,x14,0
`else
    HAND[13] = 32'h0007A737;  // lui x14,0x7A000      500000 = 0x7A120
    HAND[14] = 32'h12070713;  // addi x14,x14,0x120   x 6 cycles = 0.25 s
`endif
    HAND[15] = 32'hFFF70713;  // WDELAY: addi x14,x14,-1
    HAND[16] = 32'hFE071EE3;  // bne x14,x0,WDELAY    (64 -> 60)
    HAND[17] = 32'h009484B3;  // add x9,x9,x9         pattern <<= 1
    HAND[18] = 32'h01F4F493;  // andi x9,x9,31        keep 5 bits
    HAND[19] = 32'hFE0492E3;  // bne x9,x0,LSTEP      (76 -> 48)
    HAND[20] = 32'h0202A403;  // ECHO: lw x8,32(x5)   RX word (avail bit 8)
    HAND[21] = 32'h10047593;  // andi x11,x8,256      avail?
    HAND[22] = 32'hFE058CE3;  // beq x11,x0,ECHO      (88 -> 80)
    HAND[23] = 32'h0082A423;  // sw x8,8(x5)          UART data <- byte
    HAND[24] = 32'h0102A603;  // EBUSY: lw x12,16(x5) UART status
    HAND[25] = 32'h20067613;  // andi x12,x12,512     busy = bit 9
    HAND[26] = 32'hFE061CE3;  // bne x12,x0,EBUSY     (100 -> 96)
    HAND[27] = 32'h01F47693;  // andi x13,x8,31       LEDs <- byte & 31
    HAND[28] = 32'h00D2A223;  // sw x13,4(x5)         LEDS <- byte & 31
    HAND[29] = 32'hFDDFF06F;  // jal x0,ECHO          (116 -> 80)
    HAND[30] = 32'h706F6F4C;  // "Loop"
    HAND[31] = 32'h53495220;  // " RIS"
    HAND[32] = 32'h0A562D43;  // "C-V\n"
  end

  // Assemble the same program here with the lib macros.
  initial begin
    #1;   // the lib's `initial memPC = 0` has run
    LUI(x5, 32'h00400000);
    ADDI(x6, x0, 120);
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
`ifdef BENCH
    ADDI(x14, x0, 2);
    ADDI(x14, x14, 0);
`else
    LUI(x14, 32'h0007A000);
    ADDI(x14, x14, 32'h120);
`endif
    Label(WDELAY); ADDI(x14, x14, -1);
    BNE(x14, x0, LabelRef(WDELAY));
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
    for (wi = 0; wi < 33; wi = wi + 1)
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

  // Wait until LEDS == p (bounded); one check.
  task wait_leds(input [4:0] p, input integer timeout);
    integer n;
    begin
      n = 0;
      while (LEDS !== p && n < timeout) begin
        @(posedge CLK); #1;
        n = n + 1;
      end
      `CHECK_EQ(LEDS, p, "LED pattern reached")
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
    // the echo loop (the shift-and-mask wraps the pattern to 0).
    wait_leds(5'b00001, 200_000);
    gap = 0;
    while (LEDS !== 5'b00010 && gap < 1000) begin @(posedge CLK); #1; gap = gap + 1; end
    `CHECK_EQ(LEDS, 5'b00010, "second pattern is 2")
    `CHECK(gap >= 25 && gap <= 60,
           "delay loop paces the steps (~30 cycles under BENCH, delay=2)")
    wait_leds(5'b00100, 1000);
    wait_leds(5'b01000, 1000);
    wait_leds(5'b10000, 1000);

    // Walk done: the echo loop polls the RX word; with the line idle nothing
    // changes. LEDS hold 16 across 200 cycles and PC lives in the echo loop.
    for (i = 0; i < 200; i = i + 1) begin
      @(posedge CLK); #1;
      `CHECK_EQ(LEDS, 5'b10000, "LEDS hold the last walk step while polling")
    end
    `CHECK(dut.processor.PC >= 32'd80 && dut.processor.PC < 32'd120,
           "PC keeps cycling in the echo poll loop (bytes 80..116)")

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
    wait_leds(5'b01000, 4000);   // 'h' & 31 = 8

    // Echo 'i' (0x69): back on TXD, LEDs <- 'i' & 31 = 9.
    fork
      send_byte(8'h69);
      recv_byte(eb);
    join
    `CHECK_EQ(eb, 8'h69, "echo of 'i' comes back on TXD")
    wait_leds(5'b01001, 4000);   // "i" & 31 = 9
    `CHECK_EQ(LEDS, "i" & 31, "LEDS show the low 5 bits of the last echoed byte")

    // ROM words: the live memory matches the hand-assembled copy.
    for (i = 0; i < 33; i = i + 1)
      `CHECK_EQ(dut.memory.MEM[i], HAND[i], "ROM word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
