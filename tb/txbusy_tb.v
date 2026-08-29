`timescale 1ns/1ps
`default_nettype none
// T4(b) UART TX busy-drop contract, driven through the monitor. The old M4
// test (a byte-wise monitor W landing on 0x400008) is vacuous since T3: the
// UART data port accepts FULL-WORD stores only (ioUartW requires
// mem_wmask == 4'b1111), so byte stores can never reach the transmitter.
// The live contract is instead: a full-word SW to 0x400008 while the
// transmitter is busy is DROPPED — software must poll the status word.
//
// The bench uploads a G routine that stores 'A' and then 'B' back-to-back to
// the UART data register and returns. The first store is accepted (emitter
// idle); the second lands three cycles later, one cycle after the emitter
// dropped o_ready — i.e. while the first frame is in flight. Checks:
//   1. Hierarchical witnesses (the test cannot pass vacuously): a store
//      pulse at the routine's first SW (PC = 0x60C) with uartReady high,
//      AND a store pulse at the second SW (PC = 0x610) with uartReady LOW.
//   2. The TXD stream is exactly: banner(12) + K(W upload) + 'A' + K(G
//      reply) + "RV32"(V reply). 'B' appears nowhere — the busy-dropped
//      byte never transmits — and later normal bytes do.
module txbusy_tb;
  `include "check.vh"
  `WATCHDOG(50_000_000)

  reg CLK = 0;
  reg RXD = 1;
  wire       TXD;
  wire [4:0] LEDS;

  SOC #(.SLOW(0)) dut (.CLK(CLK), .RXD(RXD), .TXD(TXD), .LEDS(LEDS));

  always #41.667 CLK = ~CLK;   // 12 MHz

  // The emitter's data register has no power-on value (see io_tb).
  initial dut.uart.data = 10'd0;

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

  // ---- TXD frame recorder (event-driven, from ioexact_tb) ----------------
  // Logs every frame's data byte; flags any frame beyond the 19 expected
  // ones or any broken stop bit.
  reg [7:0] txdLog [0:23];
  integer txdN = 0;
  reg txdFell = 1'b0;
  integer k;
  integer i;
  initial begin
    forever begin
      @(negedge TXD);                // start bit edge
      if (txdN >= 19) txdFell = 1'b1;
      #(BITNS * 1.5);                // centre of data bit 0
      for (k = 0; k < 8; k = k + 1) begin
        if (txdN < 24) txdLog[txdN][k] = TXD;   // LSB first
        #(BITNS);
      end
      if (TXD !== 1'b1) txdFell = 1'b1;         // broken stop bit
      if (txdN < 24) txdN = txdN + 1;
    end
  end

  // ---- hierarchical store witnesses ---------------------------------------
  // The store pulse fires during EXECUTE, where PC still holds the store's
  // own address. Routine layout at 0x600: LUI@600, ADDI@604, ADDI@608,
  // SW 'A'@60C, SW 'B'@610, RET@614.
  reg sawSw1Ready = 1'b0;   // first SW pulse with the transmitter idle
  reg sawSw2Busy  = 1'b0;   // second SW pulse while the transmitter was BUSY
  always @(posedge CLK) begin
    if (dut.ioUartW === 1'b1) begin
      if (dut.processor.PC === 32'h0000060C && dut.uartReady === 1'b1)
        sawSw1Ready = 1'b1;
      if (dut.processor.PC === 32'h00000610 && dut.uartReady === 1'b0)
        sawSw2Busy = 1'b1;
    end
  end

  // ---- the G routine, assembled with the lib ------------------------------
  // LUI x5,0x400000; ADDI x10,x0,'A'; ADDI x11,x0,'B';
  // SW x10,8(x5); SW x11,8(x5); RET   (leaf: clobbers x5/x10/x11 only)
  reg [31:0] MEM [0:7];
  `include "riscv_assembly.v"
  // Hand-assembled copy (independent encoder, spec formulas).
  reg [31:0] EXP [0:5];
  initial begin
    EXP[0] = 32'h004002B7;  // lui x5,0x040        (x5 = 0x400000 IO base)
    EXP[1] = 32'h04100513;  // addi x10,x0,0x41    'A'
    EXP[2] = 32'h04200593;  // addi x11,x0,0x42    'B'
    EXP[3] = 32'h00A2A423;  // sw x10,8(x5)        UART data <- 'A'
    EXP[4] = 32'h00B2A423;  // sw x11,8(x5)        UART data <- 'B' (busy)
    EXP[5] = 32'h00008067;  // ret
  end

  // ---- protocol helpers (from monitor_tb) ---------------------------------
  reg [7:0] txbuf [0:63];
  reg [7:0] rxbuf [0:7];

  task exchange(input integer txlen, input integer rxlen);
    begin
      fork
        begin : snd
          integer j;
          for (j = 0; j < txlen; j = j + 1) send_byte(txbuf[j]);
        end
        begin : rcv
          integer j2;
          integer kb;   // local: the recorder owns the module-level k
          for (j2 = 0; j2 < rxlen; j2 = j2 + 1) begin
            @(negedge TXD);          // start bit edge
            #(BITNS * 1.5);          // centre of data bit 0
            for (kb = 0; kb < 8; kb = kb + 1) begin
              rxbuf[j2][kb] = TXD;   // LSB first
              #(BITNS);
            end
          end
        end
      join
    end
  endtask

  // Fill txbuf[1..4] / txbuf[5..8] with addr / len, little-endian.
  task put_addr_len(input [31:0] addr, input [31:0] len);
    begin
      txbuf[1] = addr[ 7: 0]; txbuf[2] = addr[15: 8];
      txbuf[3] = addr[23:16]; txbuf[4] = addr[31:24];
      txbuf[5] = len[ 7: 0];  txbuf[6] = len[15: 8];
      txbuf[7] = len[23:16];  txbuf[8] = len[31:24];
    end
  endtask

  initial begin
    #1;   // the lib's `initial memPC = 0` has run
    LUI(x5, 32'h00400000);
    ADDI(x10, x0, 8'h41);
    ADDI(x11, x0, 8'h42);
    SW(x10, x5, 8);
    SW(x11, x5, 8);
    JALR(x0, x1, 0);            // RET
    endASM();
    for (i = 0; i < 6; i = i + 1)
      `CHECK_EQ(MEM[i], EXP[i], "routine word matches the hand encoding")

    // Wait for the 12-byte banner; the monitor then sits in GETBYTE.
    i = 0;
    while (txdN < 12 && i < 40000) begin @(posedge CLK); #1; i = i + 1; end
    `CHECK_EQ(txdN, 12, "banner complete")

    // Upload the routine: W 0x600 len=24 (6 words), reply 'K'.
    for (i = 0; i < 6; i = i + 1) begin
      txbuf[9 + 4*i + 0] = MEM[i][ 7: 0];
      txbuf[9 + 4*i + 1] = MEM[i][15: 8];
      txbuf[9 + 4*i + 2] = MEM[i][23:16];
      txbuf[9 + 4*i + 3] = MEM[i][31:24];
    end
    txbuf[0] = "W";
    put_addr_len(32'h00000600, 32'd24);
    exchange(9 + 24, 1);
    `CHECK_EQ(rxbuf[0], 8'h4B, "W (routine upload) replies K")

    // G 0x600: the routine stores 'A' (accepted) then 'B' (busy -> dropped)
    // and returns; the monitor replies K. No recv fork here: the routine's
    // own 'A' frame comes first and the event-driven recorder logs both.
    txbuf[0] = "G";
    put_addr_len(32'h00000600, 32'd0);
    fork
      begin : sndG
        integer j;
        for (j = 0; j < 5; j = j + 1) send_byte(txbuf[j]);
      end
    join
    // 'A' (frame 14) then the G reply 'K' (frame 15).
    i = 0;
    while (txdN < 15 && i < 40000) begin @(posedge CLK); #1; i = i + 1; end
    `CHECK_EQ(txdN, 15, "routine's 'A' frame and the G reply 'K' both arrived")

    // A later normal byte still transmits: V replies "RV32" (4 frames).
    txbuf[0] = "V";
    fork
      begin : sndV
        send_byte(txbuf[0]);
      end
    join
    i = 0;
    while (txdN < 19 && i < 40000) begin @(posedge CLK); #1; i = i + 1; end

    // ---- the checks ------------------------------------------------------
    `CHECK(sawSw1Ready, "first routine SW (PC=0x60C) pulsed with uartReady high")
    `CHECK(sawSw2Busy,  "second routine SW (PC=0x610) pulsed with uartReady LOW (not vacuous)")
    `CHECK_EQ(txdN, 19, "TXD carried exactly banner + K + 'A' + K + RV32")
    `CHECK(!txdFell, "no stray or malformed frame beyond the 19 expected")
    `CHECK_EQ(txdLog[12], 8'h4B, "frame 13 is the W upload's 'K'")
    `CHECK_EQ(txdLog[13], 8'h41, "frame 14 is the routine's first byte 'A'")
    `CHECK_EQ(txdLog[14], 8'h4B, "frame 15 is the G reply 'K' (routine returned)")
    `CHECK_EQ(txdLog[15], 8'h52, "V reply byte 0 is 'R' (later bytes still work)")
    `CHECK_EQ(txdLog[16], 8'h56, "V reply byte 1 is 'V'")
    `CHECK_EQ(txdLog[17], 8'h33, "V reply byte 2 is '3'")
    `CHECK_EQ(txdLog[18], 8'h32, "V reply byte 3 is '2'")
    for (i = 0; i < 19; i = i + 1)
      `CHECK(txdLog[i] !== 8'h42, "the busy-dropped byte 'B' never transmitted")

    `DONE
  end
endmodule
`default_nettype wire
