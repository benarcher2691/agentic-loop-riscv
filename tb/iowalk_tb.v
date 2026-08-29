`timescale 1ns/1ps
`default_nettype none
// T3 exact-match IO decode, monitor byte-walk regression. The monitor's W
// command writes len bytes sequentially with SB, so
//   W 0x400004 len=8  with data 15 AA BB CC DD EE 11 22
// walks 0x400004..0x40000B: byte 0 latches ledReg (lane 0), bytes 1-3 hit the
// LEDS word's high lanes (dropped by the mem_wmask[0] gate), byte 4 lands
// exactly on the UART data word 0x400008 and bytes 5-7 are unmapped. With
// exact-match decode + the full-word-store contract for the UART data port,
// none of the walked bytes may transmit: the TXD stream must be the 12-byte
// power-on banner followed by exactly one 'K' reply. (Pre-fix, byte 4's SB
// fires the transmitter and a 0xDD frame appears between the banner and K.)
module iowalk_tb;
  `include "check.vh"
  `WATCHDOG(6_000_000)

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

  // TXD frame recorder: logs every frame's data byte; flags any frame beyond
  // the 13 expected ones (12 banner bytes + 'K').
  reg [7:0] txdLog [0:15];
  integer txdN = 0;
  reg txdFell = 1'b0;
  integer k;
  integer i;
  initial begin
    forever begin
      @(negedge TXD);                // start bit edge
      if (txdN >= 13) txdFell = 1'b1;
      #(BITNS * 1.5);                // centre of data bit 0
      for (k = 0; k < 8; k = k + 1) begin
        if (txdN < 16) txdLog[txdN][k] = TXD;   // LSB first
        #(BITNS);
      end
      if (TXD !== 1'b1) txdFell = 1'b1;         // broken stop bit
      if (txdN < 16) txdN = txdN + 1;
    end
  end

  // The banner is 12 bytes; once it is out, the monitor sits in GETBYTE.
  initial begin
    i = 0;
    while (txdN < 12 && i < 20000) begin @(posedge CLK); #1; i = i + 1; end
    // W 0x400004 len=8, little-endian addr/len, then the 8 data bytes.
    send_byte(8'h57);                          // 'W'
    send_byte(8'h04); send_byte(8'h00);        // addr 0x400004 LSB first
    send_byte(8'h40); send_byte(8'h00);
    send_byte(8'h08); send_byte(8'h00);        // len = 8
    send_byte(8'h00); send_byte(8'h00);
    send_byte(8'h15);                          // byte 0 -> ledReg = 5'b10101
    send_byte(8'hAA); send_byte(8'hBB);        // LEDS word lanes 1-3: dropped
    send_byte(8'hCC); send_byte(8'hDD);        // 0x400008: must NOT transmit
    send_byte(8'hEE); send_byte(8'h11);        // unmapped: dropped
    send_byte(8'h22);

    // Exactly one reply frame, and it is 'K'.
    i = 0;
    while (txdN < 13 && i < 30000) begin @(posedge CLK); #1; i = i + 1; end
    `CHECK_EQ(txdN, 13, "TXD carried banner + exactly one reply frame")
    `CHECK_EQ(txdLog[12], 8'h4B, "the reply frame is 'K'")
    `CHECK(!txdFell, "no TX frame beyond the 'K' reply")
    `CHECK_EQ(LEDS, 5'b10101, "LEDs latched from byte 0 of the W")

    `DONE
  end
endmodule
`default_nettype wire
