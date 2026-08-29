`timescale 1ns/1ps
`default_nettype none
// SOC end-to-end demo test: the ROM program prints "Loop RISC-V\n" over the
// UART (one byte per message word through PUTBYTE, which busy-waits before
// each write), then calls ECHO2 forever — a NON-leaf routine that pushes ra
// on the stack (sp = x2 = 0x1800, one past the top of the 6 KB RAM, growing
// down), reads one byte with GETBYTE (blocking poll of the RX word 0x400020
// until avail bit 8; the read clears avail), calls PUTBYTE twice (byte, then
// byte+1) through the stack, restores ra/sp and returns. PUTBYTE polls the
// TX status 0x400010 until busy (bit 9) is low, then writes the byte to
// 0x400008. LEDS are never written (dark). The bench carries a 115200-baud
// serial receiver (mid-bit sampling, nominal bit time — the emitter's real
// bit is 106 clocks = 1.7% slow, which still leaves 0.35-bit margin on the
// last data bit) and a transmitter model driving RXD. Checks: all 12 banner
// bytes + stop bits, LEDS dark throughout, the ECHO2 round trip of 'h'
// coming back as 'h','i' (the nested PUTBYTE call), a sentinel 'Z' ->
// 'Z','[' proving execution continued correctly after the nested return,
// the deterministic idle state of the poll loop (PC range, pushed sp, ra
// link, the saved-ra stack word), and a three-way ROM cross-check
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
  reg [31:0] MEM [0:43];
  `include "riscv_assembly.v"
  integer WBYTE = 20, MAIN = 40, ECHO2 = 48, GETBYTE = 84, GBDONE = 100, PUTBYTE = 108;
  integer i, wi;   // wi: the assembly block's own index — `i` is shared with
                   // the main block's loops and must not be clobbered at t=1ns

  // Hand-assembled copy (independent python encoder, spec formulas).
  reg [31:0] HAND [0:43];
  initial begin
    HAND[ 0] = 32'h004002B7;  // word 0 (byte 0):   lui x5,0x40000  x5 = 0x400000 IO base
    HAND[ 1] = 32'h00002137;  // word 1 (byte 4):   lui x2,0x2      x2 = 0x2000
    HAND[ 2] = 32'h80010113;  // word 2 (byte 8):   addi x2,x2,-2048  sp = 0x1800 (top of RAM)
    HAND[ 3] = 32'h08000313;  // word 3 (byte 12):  addi x6,x0,128  x6 = &message (byte 128)
    HAND[ 4] = 32'h00C00393;  // word 4 (byte 16):  addi x7,x0,12   12 banner bytes
    HAND[ 5] = 32'h00032503;  // word 5 (byte 20):  WBYTE: lw x10,0(x6)  char in bits [7:0]
    HAND[ 6] = 32'h054000EF;  // word 6 (byte 24):  jal x1,PUTBYTE  (24 -> 108, ra = 28)
    HAND[ 7] = 32'h00430313;  // word 7 (byte 28):  addi x6,x6,4    one word per char
    HAND[ 8] = 32'hFFF38393;  // word 8 (byte 32):  addi x7,x7,-1
    HAND[ 9] = 32'hFE0398E3;  // word 9 (byte 36):  bne x7,x0,WBYTE (36 -> 20)
    HAND[10] = 32'h008000EF;  // word 10 (byte 40): MAIN: jal x1,ECHO2  (40 -> 48, ra = 44)
    HAND[11] = 32'hFFDFF06F;  // word 11 (byte 44): jal x0,MAIN        (44 -> 40)
    HAND[12] = 32'hFFC10113;  // word 12 (byte 48): ECHO2: addi x2,x2,-4  push
    HAND[13] = 32'h00112023;  // word 13 (byte 52): sw x1,0(x2)     save ra at 0x17FC
    HAND[14] = 32'h01C000EF;  // word 14 (byte 56): jal x1,GETBYTE  (56 -> 84, ra = 60)
    HAND[15] = 32'h030000EF;  // word 15 (byte 60): jal x1,PUTBYTE  (60 -> 108, ra = 64)
    HAND[16] = 32'h00150513;  // word 16 (byte 64): addi x10,x10,1  a0 = byte + 1
    HAND[17] = 32'h028000EF;  // word 17 (byte 68): jal x1,PUTBYTE  (68 -> 108, ra = 72)
    HAND[18] = 32'h00012083;  // word 18 (byte 72): lw x1,0(x2)     restore ra
    HAND[19] = 32'h00410113;  // word 19 (byte 76): addi x2,x2,4    pop
    HAND[20] = 32'h00008067;  // word 20 (byte 80): ret (jalr x0,x1,0)
    HAND[21] = 32'h0202A503;  // word 21 (byte 84): GETBYTE: lw x10,32(x5)  RX word, read clears avail
    HAND[22] = 32'h10057593;  // word 22 (byte 88): andi x11,x10,256  avail = bit 8
    HAND[23] = 32'h00059463;  // word 23 (byte 92): bne x11,x0,GBDONE (92 -> 100)
    HAND[24] = 32'hFF5FF06F;  // word 24 (byte 96): jal x0,GETBYTE    (96 -> 84)
    HAND[25] = 32'h0FF57513;  // word 25 (byte 100): GBDONE: andi x10,x10,255  a0 = byte
    HAND[26] = 32'h00008067;  // word 26 (byte 104): ret
    HAND[27] = 32'h0102A583;  // word 27 (byte 108): PUTBYTE: lw x11,16(x5)  UART status
    HAND[28] = 32'h2005F593;  // word 28 (byte 112): andi x11,x11,512  busy = bit 9
    HAND[29] = 32'hFE059CE3;  // word 29 (byte 116): bne x11,x0,PUTBYTE (116 -> 108)
    HAND[30] = 32'h00A2A423;  // word 30 (byte 120): sw x10,8(x5)   UART data <- a0 (low byte)
    HAND[31] = 32'h00008067;  // word 31 (byte 124): ret
    HAND[32] = 32'h0000004C;  // word 32 (byte 128): 'L'  (one byte per word,
    HAND[33] = 32'h0000006F;  // word 33 (byte 132): 'o'   upper bytes 0 —
    HAND[34] = 32'h0000006F;  // word 34 (byte 136): 'o'   the program uses
    HAND[35] = 32'h00000070;  // word 35 (byte 140): 'p'   no LB, so the
    HAND[36] = 32'h00000020;  // word 36 (byte 144): ' '   flattened netlist
    HAND[37] = 32'h00000052;  // word 37 (byte 148): 'R'   prunes the byte-
    HAND[38] = 32'h00000049;  // word 38 (byte 152): 'I'   lane load logic
    HAND[39] = 32'h00000053;  // word 39 (byte 156): 'S'   and stays under
    HAND[40] = 32'h00000043;  // word 40 (byte 160): 'C'   the LC budget)
    HAND[41] = 32'h0000002D;  // word 41 (byte 164): '-'
    HAND[42] = 32'h00000056;  // word 42 (byte 168): 'V'
    HAND[43] = 32'h0000000A;  // word 43 (byte 172): '\n'
  end

  // Assemble the same program here with the lib macros.
  initial begin
    #1;   // the lib's `initial memPC = 0` has run
    LUI(x5, 32'h00400000);
    LUI(x2, 32'h2000);       // lib LUI takes the FINAL rd value
    ADDI(x2, x2, -2048);
    ADDI(x6, x0, 128);
    ADDI(x7, x0, 12);
    Label(WBYTE); LW(x10, x6, 0);
    JAL(x1, LabelRef(PUTBYTE));
    ADDI(x6, x6, 4);
    ADDI(x7, x7, -1);
    BNE(x7, x0, LabelRef(WBYTE));
    Label(MAIN); JAL(x1, LabelRef(ECHO2));
    JAL(x0, LabelRef(MAIN));
    Label(ECHO2); ADDI(x2, x2, -4);
    SW(x1, x2, 0);
    JAL(x1, LabelRef(GETBYTE));
    JAL(x1, LabelRef(PUTBYTE));
    ADDI(x10, x10, 1);
    JAL(x1, LabelRef(PUTBYTE));
    LW(x1, x2, 0);
    ADDI(x2, x2, 4);
    JALR(x0, x1, 0);         // RET
    Label(GETBYTE); LW(x10, x5, 32);
    ANDI(x11, x10, 256);
    BNE(x11, x0, LabelRef(GBDONE));
    JAL(x0, LabelRef(GETBYTE));
    Label(GBDONE); ANDI(x10, x10, 255);
    JALR(x0, x1, 0);         // RET
    Label(PUTBYTE); LW(x11, x5, 16);
    ANDI(x11, x11, 512);
    BNE(x11, x0, LabelRef(PUTBYTE));
    SW(x10, x5, 8);
    JALR(x0, x1, 0);         // RET
    DATAB(8'h4C, 8'h00, 8'h00, 8'h00);   // 'L'
    DATAB(8'h6F, 8'h00, 8'h00, 8'h00);   // 'o'
    DATAB(8'h6F, 8'h00, 8'h00, 8'h00);   // 'o'
    DATAB(8'h70, 8'h00, 8'h00, 8'h00);   // 'p'
    DATAB(8'h20, 8'h00, 8'h00, 8'h00);   // ' '
    DATAB(8'h52, 8'h00, 8'h00, 8'h00);   // 'R'
    DATAB(8'h49, 8'h00, 8'h00, 8'h00);   // 'I'
    DATAB(8'h53, 8'h00, 8'h00, 8'h00);   // 'S'
    DATAB(8'h43, 8'h00, 8'h00, 8'h00);   // 'C'
    DATAB(8'h2D, 8'h00, 8'h00, 8'h00);   // '-'
    DATAB(8'h56, 8'h00, 8'h00, 8'h00);   // 'V'
    DATAB(8'h0A, 8'h00, 8'h00, 8'h00);   // '\n'
    endASM();
    // lib copy vs hand constants (catches the two drifting apart)
    for (wi = 0; wi < 44; wi = wi + 1)
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
  reg  [7:0] b, e0, e1;
  integer n;

  // One ECHO2 round trip: send c, receive the two echoes. The recvs run in
  // ONE forked thread, sequentially: the first echo starts at the incoming
  // frame's mid-stop (before send_byte's stop-bit delay returns — a
  // sequential recv would miss its start edge), the second follows it.
  task echo2(input [7:0] c);
    begin
      fork
        send_byte(c);
        begin
          recv_byte(e0);
          recv_byte(e1);
        end
      join
      `CHECK_EQ(e0, c,        "first echo is the byte itself")
      `CHECK_EQ(e1, c + 8'd1, "second echo is byte+1 (nested PUTBYTE call)")
    end
  endtask

  // Wait until the PC polls inside [lo, hi) (bounded); the program's
  // deterministic idle state between echoes.
  task wait_pc_range(input integer lo, input integer hi);
    begin
      n = 0;
      while ((dut.processor.PC < lo || dut.processor.PC >= hi) && n < 1000) begin
        @(posedge CLK); #1;
        n = n + 1;
      end
      `CHECK(dut.processor.PC >= lo && dut.processor.PC < hi,
             "PC polls in the GETBYTE loop while idle")
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

    // The program never writes the LEDS: they stay dark for the whole run.
    // Then the ECHO2 round trips: 'h' comes back as 'h','i' (byte, byte+1
    // through the nested PUTBYTE call), and the sentinel 'Z' as 'Z','[' —
    // a clobbered ra would derail the program before the sentinel could be
    // echoed, so coming back proves the return chain works. A concurrent
    // watcher checks LEDS dark on every cycle while the echo traffic flows
    // (the new invariant that replaced the old LED-walk checks).
    wait_pc_range(84, 100);
    fork
      begin
        echo2(8'h68);
        wait_pc_range(84, 100);
        // Deterministic idle state inside ECHO2 #2's GETBYTE poll: sp holds
        // the pushed value (0x17FC), ra holds GETBYTE's return link (JAL at
        // byte 56 links to 60), and the stack word at 0x17FC holds the
        // main-loop link 44.
        `CHECK_EQ(dut.processor.RegisterBank[2], 32'h17FC,
                  "sp at the pushed 0x17FC while ECHO2 waits in GETBYTE")
        `CHECK_EQ(dut.processor.RegisterBank[1], 32'd60,
                  "ra holds GETBYTE's return link (the JAL at byte 56 -> 60)")
        `CHECK_EQ(dut.memory.MEM[1535], 32'd44,
                  "pushed ra word at 0x17FC holds the main-loop link")
        echo2(8'h5A);
        wait_pc_range(84, 100);
        // Same pushed sp as after ECHO2 #1: a leaked pop would have drifted
        // it to 0x17F8 by this third iteration — so the pop really happened.
        `CHECK_EQ(dut.processor.RegisterBank[2], 32'h17FC,
                  "sp back at the pushed 0x17FC: no stack drift across iterations")
      end
      begin
        repeat (4500) begin
          @(posedge CLK); #1;
          `CHECK_EQ(LEDS, 5'd0, "LEDS dark on every cycle while echo traffic flows")
        end
      end
    join

    // Edge-case bytes through the same machinery: 0x00 (all-zero data bits),
    // 0x7F (byte+1 = 0x80 sets the echo's MSB) and 0xFF (byte+1 wraps to
    // 0x00 — the SOC takes the UART data's low byte, so the wrap is real).
    echo2(8'h00);
    echo2(8'h7F);
    echo2(8'hFF);
    wait_pc_range(84, 100);
    `CHECK_EQ(dut.processor.RegisterBank[2], 32'h17FC,
              "sp still at the pushed 0x17FC after the edge-case echoes")
    `CHECK_EQ(LEDS, 5'd0, "LEDS dark at the end (never written)")

    // ROM words: the live memory matches the hand-assembled copy.
    for (i = 0; i < 44; i = i + 1)
      `CHECK_EQ(dut.memory.MEM[i], HAND[i], "ROM word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
