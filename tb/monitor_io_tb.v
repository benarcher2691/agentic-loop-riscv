`timescale 1ns/1ps
`default_nettype none
// Stack + UART byte primitives, end to end, via the monitor's V command.
// The ROM program prints the banner, then runs the monitor command loop:
// GETBYTE (leaf: blocking poll of the RX word 0x400020 until avail bit 8,
// the read clears avail) reads a command byte, MAIN dispatches. 'V' calls
// PUT32 — a NON-leaf helper that pushes an 8-byte frame on the stack
// (sp = x2 = 0x1800 growing down: saved ra at sp+4 = 0x17FC, scratch word
// at sp+0 = 0x17F8), disassembles a0 with LBU and calls PUTBYTE (leaf:
// poll TX status 0x400010 until busy bit 9 low, write 0x400008) four
// times, then pops and RETs. The bench checks the banner, the "RV32"
// reply, that PUT32's stack frame really appears (sp dips to 0x17F8 and
// the pushed ra word lands at 0x17FC), that sp/ra return to their
// convention values, and that unknown bytes (including the edge values
// 0x00/0x7F/0xFF) each come back as '?' — proving GETBYTE's byte path and
// that the loop keeps running with no stack drift.
module monitor_io_tb;
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

  // ---- serial models (same shape as monitor_tb) ---------------------------
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

  task send_byte;
    input [7:0] b;
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

  // Wait until the CPU idles in the GETBYTE poll (ROM bytes 348..363).
  task wait_idle;
    integer n;
    begin
      n = 0;
      while ((dut.processor.PC < 32'd348 || dut.processor.PC >= 32'd364) && n < 100000) begin
        @(posedge CLK); #1;
        n = n + 1;
      end
      `CHECK(dut.processor.PC >= 32'd348 && dut.processor.PC < 32'd364,
             "PC polls in the GETBYTE loop (bytes 348..363) while idle")
    end
  endtask

  reg [95:0] BANNER_STR = "Loop RISC-V\n";  // first char in the MSBs
  reg  [7:0] banner [0:11];
  reg  [7:0] b, e0, e1, e2, e3;
  reg        caught;
  integer i;

  initial begin
    for (i = 0; i < 12; i = i + 1)
      banner[i] = BANNER_STR[(11-i)*8 +: 8];

    `CHECK_EQ(TXD, 1'b1, "TXD idles high before the first byte")

    // Banner: 12 bytes, in order, clean framing.
    for (i = 0; i < 12; i = i + 1) begin
      recv_byte(b);
      `CHECK_EQ(b, banner[i], "banner byte received in order")
    end
    `CHECK_EQ(LEDS, 5'd0, "LEDS dark (the monitor never writes them)")

    // V: PUT32 sends "RV32" as 4 PUTBYTE calls through its stack frame.
    // The spy thread watches for the frame: sp must dip to 0x17F8 while
    // the reply bytes go out (the frame lives longer than a byte time —
    // PUTBYTE returns when the emitter ACCEPTS the byte, not when the
    // stop bit is on the wire).
    caught = 0;
    fork
      send_byte(8'h56);                    // 'V'
      begin
        recv_byte(e0);
        recv_byte(e1);
        recv_byte(e2);
        recv_byte(e3);
      end
      begin : spy
        wait (dut.processor.RegisterBank[2] == 32'h17F8);
        caught = 1;
      end
    join
    `CHECK(caught, "PUT32's stack frame observed: sp dipped to 0x17F8")
    `CHECK_EQ(e0, 8'h52, "V reply byte 0 is 'R'")
    `CHECK_EQ(e1, 8'h56, "V reply byte 1 is 'V'")
    `CHECK_EQ(e2, 8'h33, "V reply byte 2 is '3'")
    `CHECK_EQ(e3, 8'h32, "V reply byte 3 is '2'")

    // Back in the MAIN GETBYTE poll: the whole call chain restored. sp is
    // at the convention value 0x1800 (the pop really happened), ra holds
    // MAIN's link (the JAL at byte 44 links to 48), and the pushed ra word
    // at 0x17FC still holds PUT32's return link 68 (the JAL at byte 64).
    wait_idle;
    `CHECK_EQ(dut.processor.RegisterBank[2], 32'h1800,
              "sp back at 0x1800: PUT32's pop really happened")
    `CHECK_EQ(dut.processor.RegisterBank[1], 32'd48,
              "ra holds MAIN's GETBYTE link (the JAL at byte 44 -> 48)")
    `CHECK_EQ(dut.memory.MEM[1535], 32'd68,
              "pushed ra word at 0x17FC holds PUT32's return link")

    // Unknown commands: each byte comes back as '?' (0x3F). The set covers
    // the edge bytes 0x00 (all-zero data bits), 0x7F and 0xFF (MSB set) —
    // the byte path must not sign-extend or lose the MSB.
    fork send_byte(8'h5A); recv_byte(e0); join
    `CHECK_EQ(e0, 8'h3F, "'Z' is an unknown command: '?' comes back")
    fork send_byte(8'h00); recv_byte(e0); join
    `CHECK_EQ(e0, 8'h3F, "0x00 is an unknown command: '?' comes back")
    fork send_byte(8'h7F); recv_byte(e0); join
    `CHECK_EQ(e0, 8'h3F, "0x7F is an unknown command: '?' comes back")
    fork send_byte(8'hFF); recv_byte(e0); join
    `CHECK_EQ(e0, 8'h3F, "0xFF is an unknown command: '?' comes back")

    // No stack drift across the four round trips (a leaked push/pop would
    // have moved sp off 0x1800), and the monitor is still polling.
    wait_idle;
    `CHECK_EQ(dut.processor.RegisterBank[2], 32'h1800,
              "sp still at 0x1800 after the unknown-command round trips")
    `CHECK_EQ(LEDS, 5'd0, "LEDS still dark at the end")

    `DONE
  end
endmodule
`default_nettype wire
