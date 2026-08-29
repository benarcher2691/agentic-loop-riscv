`timescale 1ns/1ps
`default_nettype none
// SOC end-to-end test: the ROM program prints "Loop RISC-V\n" over the UART
// (one byte per message word through PUTBYTE, which busy-waits before each
// write), then runs the monitor command loop forever: GETBYTE (blocking
// poll of the RX word 0x400020 until avail bit 8; the read clears avail)
// reads a command byte, MAIN dispatches. 'V' calls PUT32 — a non-leaf
// helper with an 8-byte stack frame (sp = x2 = 0x1800 growing down: saved
// ra at sp+4, scratch word at sp+0) that sends "RV32" as four PUTBYTE
// calls; unknown bytes reply '?'. PUTBYTE polls the TX status 0x400010
// until busy (bit 9) is low, then writes the byte to 0x400008. LEDS are
// never written (dark). The bench carries a 115200-baud serial receiver
// (mid-bit sampling, nominal bit time — the emitter's real bit is 106
// clocks = 1.7% slow, which still leaves 0.35-bit margin on the last data
// bit) and a transmitter model driving RXD. Checks: power-on reset
// behaviour, all 12 banner bytes + stop bits, the V round trip ("RV32"
// through PUT32's stack frame) with a concurrent LEDS-dark watcher, the
// deterministic idle state of the GETBYTE poll loop (PC range, sp, ra
// link, the stale pushed-ra stack word), an unknown-command round trip,
// and a three-way ROM cross-check (hand-assembled constants vs a
// lib-assembled copy vs dut.memory.MEM). The full protocol matrix (W/R/G,
// LED word) lives in tb/monitor_tb.v; the stack/byte-primitive details in
// tb/monitor_io_tb.v.
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
  reg [31:0] MEM [0:109];
  `include "riscv_assembly.v"
  integer WBYTE = 20, MAIN = 40, CHK_W = 72, WLOOP = 96, WBODY = 104,
         WK = 124, CHK_R = 136, RLOOP = 160, RBODY = 168, CHK_G = 188,
         UNK = 224, GET32 = 236, PUT32 = 292, GETBYTE = 348, GBDONE = 364,
         PUTBYTE = 372;
  integer i, wi;   // wi: the assembly block's own index — `i` is shared with
                   // the main block's loops and must not be clobbered at t=1ns

  // Hand-assembled copy (independent python encoder, spec formulas).
  reg [31:0] HAND [0:109];
  initial begin
    HAND[ 0] = 32'h004002B7;  // word  0 (byte   0): lui x5,0x40000        x5 = 0x400000 IO base
    HAND[ 1] = 32'h00002137;  // word  1 (byte   4): lui x2,0x2            x2 = 0x2000
    HAND[ 2] = 32'h80010113;  // word  2 (byte   8): addi x2,x2,-2048      sp = 0x1800 (one past top of RAM)
    HAND[ 3] = 32'h18800313;  // word  3 (byte  12): addi x6,x0,392        x6 = &message (byte 392 = word 98)
    HAND[ 4] = 32'h00C00393;  // word  4 (byte  16): addi x7,x0,12         12 banner bytes
    HAND[ 5] = 32'h00032503;  // word  5 (byte  20): WBYTE: lw x10,0(x6)   char in bits [7:0]
    HAND[ 6] = 32'h15C000EF;  // word  6 (byte  24): jal x1,PUTBYTE        blocking write of a0's low byte
    HAND[ 7] = 32'h00430313;  // word  7 (byte  28): addi x6,x6,4          p++ (one word per char)
    HAND[ 8] = 32'hFFF38393;  // word  8 (byte  32): addi x7,x7,-1         count--
    HAND[ 9] = 32'hFE0398E3;  // word  9 (byte  36): bne x7,x0,WBYTE
    HAND[10] = 32'h004002B7;  // word 10 (byte  40): MAIN: lui x5,0x40000  re-establish IO base (G clobbers regs)
    HAND[11] = 32'h130000EF;  // word 11 (byte  44): jal x1,GETBYTE        a0 = command byte
    HAND[12] = 32'h05600593;  // word 12 (byte  48): addi x11,x0,0x56      'V'
    HAND[13] = 32'h00B51A63;  // word 13 (byte  52): bne x10,x11,CHK_W
    HAND[14] = 32'h32335537;  // word 14 (byte  56): lui x10,0x32335       a0 = "RV32" little-endian (high)
    HAND[15] = 32'h65250513;  // word 15 (byte  60): addi x10,x10,0x652      ...low: 0x32335652 = 'R','V','3','2'
    HAND[16] = 32'h0E4000EF;  // word 16 (byte  64): jal x1,PUT32
    HAND[17] = 32'hFE5FF06F;  // word 17 (byte  68): jal x0,MAIN
    HAND[18] = 32'h05700593;  // word 18 (byte  72): CHK_W: addi x11,x0,0x57  'W'
    HAND[19] = 32'h02B51E63;  // word 19 (byte  76): bne x10,x11,CHK_R
    HAND[20] = 32'h09C000EF;  // word 20 (byte  80): jal x1,GET32          a0 = addr
    HAND[21] = 32'h00050493;  // word 21 (byte  84): addi x9,x10,0         x9 = ptr
    HAND[22] = 32'h094000EF;  // word 22 (byte  88): jal x1,GET32          a0 = len
    HAND[23] = 32'h00050713;  // word 23 (byte  92): addi x14,x10,0        x14 = count
    HAND[24] = 32'h00071463;  // word 24 (byte  96): WLOOP: bne x14,x0,WBODY
    HAND[25] = 32'h0180006F;  // word 25 (byte 100): jal x0,WK             count == 0: done, reply K
    HAND[26] = 32'h0F4000EF;  // word 26 (byte 104): WBODY: jal x1,GETBYTE a0 = data byte
    HAND[27] = 32'h00A48023;  // word 27 (byte 108): sb x10,0(x9)          *ptr = byte (RAM or IO space)
    HAND[28] = 32'h00148493;  // word 28 (byte 112): addi x9,x9,1          ptr++
    HAND[29] = 32'hFFF70713;  // word 29 (byte 116): addi x14,x14,-1       count--
    HAND[30] = 32'hFE9FF06F;  // word 30 (byte 120): jal x0,WLOOP
    HAND[31] = 32'h04B00513;  // word 31 (byte 124): WK: addi x10,x0,0x4B  'K'
    HAND[32] = 32'h0F4000EF;  // word 32 (byte 128): jal x1,PUTBYTE
    HAND[33] = 32'hFA5FF06F;  // word 33 (byte 132): jal x0,MAIN
    HAND[34] = 32'h05200593;  // word 34 (byte 136): CHK_R: addi x11,x0,0x52  'R'
    HAND[35] = 32'h02B51863;  // word 35 (byte 140): bne x10,x11,CHK_G
    HAND[36] = 32'h05C000EF;  // word 36 (byte 144): jal x1,GET32          a0 = addr
    HAND[37] = 32'h00050493;  // word 37 (byte 148): addi x9,x10,0         x9 = ptr
    HAND[38] = 32'h054000EF;  // word 38 (byte 152): jal x1,GET32          a0 = len
    HAND[39] = 32'h00050713;  // word 39 (byte 156): addi x14,x10,0        x14 = count
    HAND[40] = 32'h00071463;  // word 40 (byte 160): RLOOP: bne x14,x0,RBODY
    HAND[41] = 32'hF85FF06F;  // word 41 (byte 164): jal x0,MAIN           done (no reply byte)
    HAND[42] = 32'h0004C503;  // word 42 (byte 168): RBODY: lbu x10,0(x9)  a0 = *ptr (zero-extended byte)
    HAND[43] = 32'h0C8000EF;  // word 43 (byte 172): jal x1,PUTBYTE
    HAND[44] = 32'h00148493;  // word 44 (byte 176): addi x9,x9,1          ptr++
    HAND[45] = 32'hFFF70713;  // word 45 (byte 180): addi x14,x14,-1       count--
    HAND[46] = 32'hFE9FF06F;  // word 46 (byte 184): jal x0,RLOOP
    HAND[47] = 32'h04700593;  // word 47 (byte 188): CHK_G: addi x11,x0,0x47  'G'
    HAND[48] = 32'h02B51063;  // word 48 (byte 192): bne x10,x11,UNK
    HAND[49] = 32'h028000EF;  // word 49 (byte 196): jal x1,GET32          a0 = routine address
    HAND[50] = 32'h00050493;  // word 50 (byte 200): addi x9,x10,0         x9 = target
    HAND[51] = 32'h000480E7;  // word 51 (byte 204): jalr x1,x9,0          call it; returns with RET
    HAND[52] = 32'h004002B7;  // word 52 (byte 208): lui x5,0x40000        the routine clobbered x5 (and the rest)
    HAND[53] = 32'h04B00513;  // word 53 (byte 212): addi x10,x0,0x4B      'K'
    HAND[54] = 32'h09C000EF;  // word 54 (byte 216): jal x1,PUTBYTE
    HAND[55] = 32'hF4DFF06F;  // word 55 (byte 220): jal x0,MAIN
    HAND[56] = 32'h03F00513;  // word 56 (byte 224): UNK: addi x10,x0,0x3F '?'
    HAND[57] = 32'h090000EF;  // word 57 (byte 228): jal x1,PUTBYTE
    HAND[58] = 32'hF41FF06F;  // word 58 (byte 232): jal x0,MAIN
    HAND[59] = 32'hFF810113;  // word 59 (byte 236): GET32: addi x2,x2,-8  push {ra, scratch word}
    HAND[60] = 32'h00112223;  // word 60 (byte 240): sw x1,4(x2)           save ra at sp+4
    HAND[61] = 32'h068000EF;  // word 61 (byte 244): jal x1,GETBYTE
    HAND[62] = 32'h00A10023;  // word 62 (byte 248): sb x10,0(x2)          byte 0 -> lane 0 (LSB)
    HAND[63] = 32'h060000EF;  // word 63 (byte 252): jal x1,GETBYTE
    HAND[64] = 32'h00A100A3;  // word 64 (byte 256): sb x10,1(x2)          byte 1 -> lane 1
    HAND[65] = 32'h058000EF;  // word 65 (byte 260): jal x1,GETBYTE
    HAND[66] = 32'h00A10123;  // word 66 (byte 264): sb x10,2(x2)          byte 2 -> lane 2
    HAND[67] = 32'h050000EF;  // word 67 (byte 268): jal x1,GETBYTE
    HAND[68] = 32'h00A101A3;  // word 68 (byte 272): sb x10,3(x2)          byte 3 -> lane 3 (MSB)
    HAND[69] = 32'h00012503;  // word 69 (byte 276): lw x10,0(x2)          a0 = assembled word
    HAND[70] = 32'h00412083;  // word 70 (byte 280): lw x1,4(x2)           restore ra
    HAND[71] = 32'h00810113;  // word 71 (byte 284): addi x2,x2,8          pop
    HAND[72] = 32'h00008067;  // word 72 (byte 288): ret
    HAND[73] = 32'hFF810113;  // word 73 (byte 292): PUT32: addi x2,x2,-8  push {ra, scratch word}
    HAND[74] = 32'h00112223;  // word 74 (byte 296): sw x1,4(x2)           save ra at sp+4
    HAND[75] = 32'h00A12023;  // word 75 (byte 300): sw x10,0(x2)          word -> scratch
    HAND[76] = 32'h00014503;  // word 76 (byte 304): lbu x10,0(x2)         byte 0 (LSB)
    HAND[77] = 32'h040000EF;  // word 77 (byte 308): jal x1,PUTBYTE
    HAND[78] = 32'h00114503;  // word 78 (byte 312): lbu x10,1(x2)         byte 1
    HAND[79] = 32'h038000EF;  // word 79 (byte 316): jal x1,PUTBYTE
    HAND[80] = 32'h00214503;  // word 80 (byte 320): lbu x10,2(x2)         byte 2
    HAND[81] = 32'h030000EF;  // word 81 (byte 324): jal x1,PUTBYTE
    HAND[82] = 32'h00314503;  // word 82 (byte 328): lbu x10,3(x2)         byte 3 (MSB)
    HAND[83] = 32'h028000EF;  // word 83 (byte 332): jal x1,PUTBYTE
    HAND[84] = 32'h00412083;  // word 84 (byte 336): lw x1,4(x2)           restore ra
    HAND[85] = 32'h00810113;  // word 85 (byte 340): addi x2,x2,8          pop
    HAND[86] = 32'h00008067;  // word 86 (byte 344): ret
    HAND[87] = 32'h0202A503;  // word 87 (byte 348): GETBYTE: lw x10,32(x5)  RX word, read clears avail
    HAND[88] = 32'h10057593;  // word 88 (byte 352): andi x11,x10,256      avail = bit 8
    HAND[89] = 32'h00059463;  // word 89 (byte 356): bne x11,x0,GBDONE
    HAND[90] = 32'hFF5FF06F;  // word 90 (byte 360): jal x0,GETBYTE
    HAND[91] = 32'h0FF57513;  // word 91 (byte 364): GBDONE: andi x10,x10,255  a0 = byte
    HAND[92] = 32'h00008067;  // word 92 (byte 368): ret
    HAND[93] = 32'h0102A583;  // word 93 (byte 372): PUTBYTE: lw x11,16(x5)  UART status
    HAND[94] = 32'h2005F593;  // word 94 (byte 376): andi x11,x11,512      busy = bit 9
    HAND[95] = 32'hFE059CE3;  // word 95 (byte 380): bne x11,x0,PUTBYTE
    HAND[96] = 32'h00A2A423;  // word 96 (byte 384): sw x10,8(x5)          UART data <- a0 (low byte)
    HAND[97] = 32'h00008067;  // word 97 (byte 388): ret
    HAND[98] = 32'h0000004C;  // word  98 (byte 392): 'L'  (one byte per word,
    HAND[99] = 32'h0000006F;  // word  99 (byte 396): 'o'   upper bytes 0)
    HAND[100] = 32'h0000006F;  // word 100 (byte 400): 'o'
    HAND[101] = 32'h00000070;  // word 101 (byte 404): 'p'
    HAND[102] = 32'h00000020;  // word 102 (byte 408): ' '
    HAND[103] = 32'h00000052;  // word 103 (byte 412): 'R'
    HAND[104] = 32'h00000049;  // word 104 (byte 416): 'I'
    HAND[105] = 32'h00000053;  // word 105 (byte 420): 'S'
    HAND[106] = 32'h00000043;  // word 106 (byte 424): 'C'
    HAND[107] = 32'h0000002D;  // word 107 (byte 428): '-'
    HAND[108] = 32'h00000056;  // word 108 (byte 432): 'V'
    HAND[109] = 32'h0000000A;  // word 109 (byte 436): newline
  end

  // Assemble the same program here with the lib macros.
  initial begin
    #1;   // the lib's `initial memPC = 0` has run
    LUI(x5, 32'h00400000);
    LUI(x2, 32'h2000);       // lib LUI takes the FINAL rd value
    ADDI(x2, x2, -2048);
    ADDI(x6, x0, 392);
    ADDI(x7, x0, 12);
    Label(WBYTE); LW(x10, x6, 0);
    JAL(x1, LabelRef(PUTBYTE));
    ADDI(x6, x6, 4);
    ADDI(x7, x7, -1);
    BNE(x7, x0, LabelRef(WBYTE));
    Label(MAIN); LUI(x5, 32'h00400000);
    JAL(x1, LabelRef(GETBYTE));
    ADDI(x11, x0, 8'h56);
    BNE(x10, x11, LabelRef(CHK_W));
    LUI(x10, 32'h32335000);
    ADDI(x10, x10, 32'h652);
    JAL(x1, LabelRef(PUT32));
    JAL(x0, LabelRef(MAIN));
    Label(CHK_W); ADDI(x11, x0, 8'h57);
    BNE(x10, x11, LabelRef(CHK_R));
    JAL(x1, LabelRef(GET32));
    ADDI(x9, x10, 0);
    JAL(x1, LabelRef(GET32));
    ADDI(x14, x10, 0);
    Label(WLOOP); BNE(x14, x0, LabelRef(WBODY));
    JAL(x0, LabelRef(WK));
    Label(WBODY); JAL(x1, LabelRef(GETBYTE));
    SB(x10, x9, 0);
    ADDI(x9, x9, 1);
    ADDI(x14, x14, -1);
    JAL(x0, LabelRef(WLOOP));
    Label(WK); ADDI(x10, x0, 8'h4B);
    JAL(x1, LabelRef(PUTBYTE));
    JAL(x0, LabelRef(MAIN));
    Label(CHK_R); ADDI(x11, x0, 8'h52);
    BNE(x10, x11, LabelRef(CHK_G));
    JAL(x1, LabelRef(GET32));
    ADDI(x9, x10, 0);
    JAL(x1, LabelRef(GET32));
    ADDI(x14, x10, 0);
    Label(RLOOP); BNE(x14, x0, LabelRef(RBODY));
    JAL(x0, LabelRef(MAIN));
    Label(RBODY); LBU(x10, x9, 0);
    JAL(x1, LabelRef(PUTBYTE));
    ADDI(x9, x9, 1);
    ADDI(x14, x14, -1);
    JAL(x0, LabelRef(RLOOP));
    Label(CHK_G); ADDI(x11, x0, 8'h47);
    BNE(x10, x11, LabelRef(UNK));
    JAL(x1, LabelRef(GET32));
    ADDI(x9, x10, 0);
    JALR(x1, x9, 0);
    LUI(x5, 32'h00400000);
    ADDI(x10, x0, 8'h4B);
    JAL(x1, LabelRef(PUTBYTE));
    JAL(x0, LabelRef(MAIN));
    Label(UNK); ADDI(x10, x0, 8'h3F);
    JAL(x1, LabelRef(PUTBYTE));
    JAL(x0, LabelRef(MAIN));
    Label(GET32); ADDI(x2, x2, -8);
    SW(x1, x2, 4);
    JAL(x1, LabelRef(GETBYTE));
    SB(x10, x2, 0);
    JAL(x1, LabelRef(GETBYTE));
    SB(x10, x2, 1);
    JAL(x1, LabelRef(GETBYTE));
    SB(x10, x2, 2);
    JAL(x1, LabelRef(GETBYTE));
    SB(x10, x2, 3);
    LW(x10, x2, 0);
    LW(x1, x2, 4);
    ADDI(x2, x2, 8);
    JALR(x0, x1, 0);         // RET
    Label(PUT32); ADDI(x2, x2, -8);
    SW(x1, x2, 4);
    SW(x10, x2, 0);
    LBU(x10, x2, 0);
    JAL(x1, LabelRef(PUTBYTE));
    LBU(x10, x2, 1);
    JAL(x1, LabelRef(PUTBYTE));
    LBU(x10, x2, 2);
    JAL(x1, LabelRef(PUTBYTE));
    LBU(x10, x2, 3);
    JAL(x1, LabelRef(PUTBYTE));
    LW(x1, x2, 4);
    ADDI(x2, x2, 8);
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
    for (wi = 0; wi < 110; wi = wi + 1)
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
  reg  [7:0] b, e0, e1, e2, e3;
  integer n;

  // Wait until the PC polls inside [lo, hi) (bounded); the program's
  // deterministic idle state between commands.
  task wait_pc_range(input integer lo, input integer hi);
    begin
      n = 0;
      while ((dut.processor.PC < lo || dut.processor.PC >= hi) && n < 100000) begin
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

    // The monitor round trip: 'V' comes back as "RV32" through PUT32's
    // stack frame. A concurrent watcher checks LEDS dark on every cycle
    // while the traffic flows (the program never writes the LEDS).
    wait_pc_range(348, 364);
    fork
      begin
        fork
          send_byte(8'h56);                    // 'V'
          begin
            recv_byte(e0);
            recv_byte(e1);
            recv_byte(e2);
            recv_byte(e3);
          end
        join
        `CHECK_EQ(e0, 8'h52, "V reply byte 0 is 'R'")
        `CHECK_EQ(e1, 8'h56, "V reply byte 1 is 'V'")
        `CHECK_EQ(e2, 8'h33, "V reply byte 2 is '3'")
        `CHECK_EQ(e3, 8'h32, "V reply byte 3 is '2'")
        wait_pc_range(348, 364);
        // Deterministic idle state in MAIN's GETBYTE poll: sp holds the
        // convention value 0x1800 (PUT32's pop really happened), ra holds
        // MAIN's link (the JAL at byte 44 links to 48), and the stack word
        // at 0x17FC still holds PUT32's return link 68 (JAL at byte 64).
        `CHECK_EQ(dut.processor.RegisterBank[2], 32'h1800,
                  "sp back at 0x1800: PUT32's pop really happened")
        `CHECK_EQ(dut.processor.RegisterBank[1], 32'd48,
                  "ra holds MAIN's GETBYTE link (the JAL at byte 44 -> 48)")
        `CHECK_EQ(dut.memory.MEM[1535], 32'd68,
                  "stale pushed ra word at 0x17FC holds PUT32's return link")
        // An unknown command round trip: '?' comes back, the loop continues.
        fork
          send_byte(8'h5A);                    // 'Z': not a command
          recv_byte(e0);
        join
        `CHECK_EQ(e0, 8'h3F, "unknown command replies '?'")
        wait_pc_range(348, 364);
        `CHECK_EQ(dut.processor.RegisterBank[2], 32'h1800,
                  "sp still at 0x1800 after the unknown-command round trip")
      end
      begin
        repeat (4500) begin
          @(posedge CLK); #1;
          `CHECK_EQ(LEDS, 5'd0, "LEDS dark on every cycle while traffic flows")
        end
      end
    join
    `CHECK_EQ(LEDS, 5'd0, "LEDS dark at the end (never written)")

    // ROM words: the live memory matches the hand-assembled copy.
    for (i = 0; i < 110; i = i + 1)
      `CHECK_EQ(dut.memory.MEM[i], HAND[i], "ROM word matches the hand encoding")

    `DONE
  end
endmodule
`default_nettype wire
