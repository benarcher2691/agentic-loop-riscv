`timescale 1ns/1ps
`default_nettype none
// T3 exact-match IO decode. The four IO words must decode by equality on
// mem_addr[5:2] (0001 LEDS 0x400004, 0010 UART data 0x400008, 0100 status
// 0x400010, 1000 RX 0x400020); every other IO offset reads as 0 with no side
// effect (rxAvail must survive) and drops writes. Regression program:
//   w2  SW 21 -> 0x400004          LEDs = 5'b10101
//   w4  SW -1 -> 0x40000C          bad store: must be dropped entirely
//                                  (pre-fix it latches LEDs=31 AND starts a
//                                  0xFF TX frame, because bits 2 and 3 are
//                                  both set in the word offset 3)
//   w5  LW 0x400000  -> x9         unmapped, must be 0 (pre-fix: LED word)
//   w6  LW 0x400014  -> x10        unmapped, must be 0 (pre-fix: status word)
//   w8/w12 SW 0x55 -> 0x400008     two legit full-word TX writes: the RX byte
//                                  (sent by the bench at t=40us, completes
//                                  ~127us) becomes pending while the CPU is
//                                  still polling the busy bit (~177us)
//   w16 LW 0x40000C  -> x8         unmapped with RX pending: 0, avail survives
//   w17 LW 0x400024  -> x12        unmapped RX-alias: 0, avail survives
//                                  (pre-fix bit 5 decode clears rxAvail here)
//   w18 LW 0x400020  -> x13        the real RX read: {avail=1, 0x5A} = 0x15A
//   w19 LW 0x400024  -> x14        unmapped again (avail now clear): 0
//   w20 LW 0x400018  -> x15        unmapped status-alias: 0
// The TXD stream must contain exactly the two 0x55 frames and nothing else.
module ioexact_tb;
  `include "check.vh"
  `WATCHDOG(2_000_000)

  reg CLK = 0;
  reg RXD = 1;
  wire       TXD;
  wire [4:0] LEDS;

  SOC #(.SLOW(0)) dut (.CLK(CLK), .RXD(RXD), .TXD(TXD), .LEDS(LEDS));

  always #41.667 CLK = ~CLK;   // 12 MHz

  // The emitter's data register has no power-on value (see io_tb).
  initial dut.uart.data = 10'd0;

  // ---- the program -------------------------------------------------------
  reg [31:0] MEM [0:31];
  `include "riscv_assembly.v"
  integer S1 = 36, S2 = 52;   // busy-wait loop heads (byte addrs)
  integer i;

  // Hand-assembled copy (independent encoder, spec formulas).
  reg [31:0] EXP [0:21];
  initial begin
    EXP[ 0] = 32'h004002B7;  // lui x5,0x400        (x5 = 0x400000 IO base)
    EXP[ 1] = 32'h01500313;  // addi x6,x0,21
    EXP[ 2] = 32'h0062A223;  // sw x6,4(x5)         LEDS <- 21
    EXP[ 3] = 32'hFFF00393;  // addi x7,x0,-1
    EXP[ 4] = 32'h0072A623;  // sw x7,12(x5)        bad store -> 0x40000C
    EXP[ 5] = 32'h0002A483;  // lw x9,0(x5)         unmapped 0x400000
    EXP[ 6] = 32'h0142A503;  // lw x10,20(x5)       unmapped 0x400014
    EXP[ 7] = 32'h05500313;  // addi x6,x0,0x55
    EXP[ 8] = 32'h0062A423;  // sw x6,8(x5)         TX <- 0x55 (frame 1)
    EXP[ 9] = 32'h0102A583;  // S1: lw x11,16(x5)   status
    EXP[10] = 32'h2005F593;  // andi x11,x11,512    busy = bit 9
    EXP[11] = 32'hFE059CE3;  // bne x11,x0,S1       (-8 from the branch)
    EXP[12] = 32'h0062A423;  // sw x6,8(x5)         TX <- 0x55 (frame 2)
    EXP[13] = 32'h0102A583;  // S2: lw x11,16(x5)
    EXP[14] = 32'h2005F593;  // andi x11,x11,512
    EXP[15] = 32'hFE059CE3;  // bne x11,x0,S2
    EXP[16] = 32'h00C2A403;  // lw x8,12(x5)        unmapped 0x40000C
    EXP[17] = 32'h0242A603;  // lw x12,36(x5)       unmapped 0x400024
    EXP[18] = 32'h0202A683;  // lw x13,32(x5)       real RX read
    EXP[19] = 32'h0242A703;  // lw x14,36(x5)       unmapped again
    EXP[20] = 32'h0182A783;  // lw x15,24(x5)       unmapped 0x400018
    EXP[21] = 32'h00100073;  // ebreak              (byte 84)
  end

  initial begin
    #1;   // the lib's `initial memPC = 0` has run
    LUI(x5, 32'h00400000);
    ADDI(x6, x0, 21);
    SW(x6, x5, 4);
    ADDI(x7, x0, -1);
    SW(x7, x5, 12);
    LW(x9, x5, 0);
    LW(x10, x5, 20);
    ADDI(x6, x0, 8'h55);
    SW(x6, x5, 8);
    Label(S1); LW(x11, x5, 16);
    ANDI(x11, x11, 512);
    BNE(x11, x0, LabelRef(S1));
    SW(x6, x5, 8);
    Label(S2); LW(x11, x5, 16);
    ANDI(x11, x11, 512);
    BNE(x11, x0, LabelRef(S2));
    LW(x8, x5, 12);
    LW(x12, x5, 36);
    LW(x13, x5, 32);
    LW(x14, x5, 36);
    LW(x15, x5, 24);
    EBREAK();
    endASM();
    for (i = 0; i < 22; i = i + 1)
      `CHECK_EQ(MEM[i], EXP[i], "assembled word matches the hand encoding")
    // Load the program while the CPU is held by power-on reset.
    for (i = 0; i < 22; i = i + 1)
      dut.memory.MEM[i] = MEM[i];
  end

  // ---- serial models: 115200 baud ----------------------------------------
  localparam real BITNS = 1000000000.0 / 115200.0;   // 8680.6 ns per bit

  task send_byte(input [7:0] b);
    integer k;
    begin
      RXD = 1'b0; #(BITNS);          // start bit
      for (k = 0; k < 8; k = k + 1) begin
        RXD = b[k]; #(BITNS);        // LSB first
      end
      RXD = 1'b1; #(BITNS);          // stop bit
    end
  endtask

  // One RX byte, timed to complete (~127 us) while the CPU is still polling
  // the TX-busy bit (~177 us): avail is pending across the w16/w17 loads.
  initial begin
    #40_000;
    send_byte(8'h5A);
  end

  // TXD frame recorder: logs every frame's data byte; flags any frame beyond
  // the two legit ones (stray start bit or bad stop bit). Event-driven, so it
  // cannot miss a frame regardless of when the checker looks at it.
  reg [7:0] txdLog [0:3];
  integer txdN = 0;
  reg txdFell = 1'b0;
  integer k;
  initial begin
    forever begin
      @(negedge TXD);                // start bit edge
      if (txdN >= 2) txdFell = 1'b1; // a third frame must never come
      #(BITNS * 1.5);                // centre of data bit 0
      for (k = 0; k < 8; k = k + 1) begin
        if (txdN < 4) txdLog[txdN][k] = TXD;   // LSB first
        #(BITNS);
      end
      if (txdN < 2) `CHECK_EQ(TXD, 1'b1, "stop bit is high")
      else if (TXD !== 1'b1) txdFell = 1'b1;
      if (txdN < 4) txdN = txdN + 1;
    end
  end

  initial begin
    // Phase A watch: PC==28 is w7, after the bad store, before any legit TX
    // write — the bad store must have left LEDs, TXD and txStarted alone.
    wait (dut.processor.PC == 28); @(posedge CLK); #1;
    `CHECK_EQ(dut.txStarted, 1'b0, "store to 0x40000C started no TX frame")
    `CHECK_EQ(LEDS, 5'b10101, "store to 0x40000C did not change the LEDs")
    `CHECK_EQ(TXD, 1'b1, "TXD still idle after the bad store")

    // The CPU halts at the EBREAK (byte 84); the two TX frames are done by
    // then (S2 exits only after frame 2 clears busy). Give the recorder its
    // ~half-bit stop-sample lag before counting frames.
    wait (dut.processor.PC == 84);
    i = 0;
    while (txdN < 2 && i < 1000) begin @(posedge CLK); #1; i = i + 1; end
    `CHECK_EQ(txdN, 2, "TXD carried exactly two frames")
    `CHECK_EQ(txdLog[0], 8'h55, "first TX frame is the CPU's 0x55")
    `CHECK_EQ(txdLog[1], 8'h55, "second TX frame is the CPU's 0x55")
    `CHECK(!txdFell, "no TX frame after the two CPU bytes")

    repeat (5) begin
      @(posedge CLK); #1;
      `CHECK_EQ(dut.processor.PC, 32'd84, "PC stays frozen at EBREAK")
    end

    `CHECK_EQ(dut.processor.RegisterBank[9],  32'd0, "LW 0x400000 (unmapped) returned 0")
    `CHECK_EQ(dut.processor.RegisterBank[10], 32'd0, "LW 0x400014 (unmapped) returned 0")
    `CHECK_EQ(dut.processor.RegisterBank[8],  32'd0, "LW 0x40000C (unmapped, RX pending) returned 0")
    `CHECK_EQ(dut.processor.RegisterBank[12], 32'd0, "LW 0x400024 (RX-alias unmapped) returned 0")
    `CHECK_EQ(dut.processor.RegisterBank[13], 32'h15A, "real RX read: avail bit set + byte 0x5A")
    `CHECK_EQ(dut.processor.RegisterBank[14], 32'd0, "LW 0x400024 again (avail clear) returned 0")
    `CHECK_EQ(dut.processor.RegisterBank[15], 32'd0, "LW 0x400018 (status-alias unmapped) returned 0")
    `CHECK_EQ(dut.rxAvail, 1'b0, "rxAvail cleared by the real RX read, not before")
    `CHECK_EQ(LEDS, 5'b10101, "LEDS keep the written pattern after halt")
    `CHECK_EQ(dut.memory.MEM[5],  EXP[5],  "IO stores did not corrupt RAM word 5")
    `CHECK_EQ(dut.memory.MEM[16], EXP[16], "IO stores did not corrupt RAM word 16")

    `DONE
  end
endmodule
`default_nettype wire
