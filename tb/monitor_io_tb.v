`timescale 1ns/1ps
`default_nettype none
// Stack + UART byte primitives, end to end: the ROM program prints the
// banner, then calls ECHO2 forever. ECHO2 is a NON-leaf routine: on entry
// it pushes ra (x1) on the stack (sp = x2 = 0x1800, one past the top of the
// 6 KB RAM, growing down), reads one byte with GETBYTE (blocking poll of
// the RX word 0x400020 until avail bit 8; the read clears avail), calls
// PUTBYTE with the byte and then with byte+1 (two nested calls), restores
// ra and sp, and returns. GETBYTE/PUTBYTE are leaves (no calls, no push);
// PUTBYTE polls the TX status 0x400010 until busy (bit 9) is low, then
// writes the byte to the UART data register 0x400008 (the SOC takes bits
// [7:0]). The bench sends 'A' and expects 'A','B' back in order on TXD;
// then a sentinel 'Z' whose echo pair proves execution continued correctly
// after the nested return (a clobbered ra would derail the program before
// it could come back). Also checks the stack was really used (the pushed
// ra word at 0x17FC) and that sp/ra land back on their convention values.
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

  // ---- serial models (same shape as soc_tb) ------------------------------
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
  integer i;

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

  initial begin
    for (i = 0; i < 12; i = i + 1)
      banner[i] = BANNER_STR[(11-i)*8 +: 8];

    `CHECK_EQ(TXD, 1'b1, "TXD idles high before the first byte")

    // Banner: 12 bytes, in order, clean framing.
    for (i = 0; i < 12; i = i + 1) begin
      recv_byte(b);
      `CHECK_EQ(b, banner[i], "banner byte received in order")
    end
    `CHECK_EQ(LEDS, 5'd0, "LEDS dark (the program never writes them)")

    // ECHO2 #1 through the stack: 'A' echoed as 'A' then 'B'.
    echo2(8'h41);

    // By the second echo's mid-stop the program has long returned from
    // ECHO2 #1, looped through MAIN and re-entered ECHO2 #2's GETBYTE
    // poll. That idle state is deterministic: wait for it, then check the
    // whole call chain. (sp == 0x1800 only exists for the ~6 cycles between
    // ECHO2's RET and the next push — not catchable from out here.)
    i = 0;
    while ((dut.processor.PC < 32'd84 || dut.processor.PC >= 32'd100) && i < 1000) begin
      @(posedge CLK); #1;
      i = i + 1;
    end
    `CHECK(dut.processor.PC >= 32'd84 && dut.processor.PC < 32'd100,
           "PC polls in the GETBYTE loop (bytes 84..96) while idle")
    // The push is real: the saved ra word at sp-4 = 0x17FC (word 1535)
    // holds the main-loop link 44 (MAIN's JAL at byte 40 links to 44).
    `CHECK_EQ(dut.memory.MEM[1535], 32'd44,
              "pushed ra word at 0x17FC holds the main-loop link")
    `CHECK_EQ(dut.processor.RegisterBank[2], 32'h17FC,
              "sp at the pushed 0x17FC while ECHO2 waits in GETBYTE")
    `CHECK_EQ(dut.processor.RegisterBank[1], 32'd60,
              "ra holds GETBYTE's return link (the JAL at byte 56 -> 60)")

    // Sentinel: a clobbered ra would derail the program before this byte
    // could be echoed; coming back proves the return chain works.
    echo2(8'h5A);
    i = 0;
    while ((dut.processor.PC < 32'd84 || dut.processor.PC >= 32'd100) && i < 1000) begin
      @(posedge CLK); #1;
      i = i + 1;
    end
    // Same pushed sp as after ECHO2 #1: a leaked pop would have drifted it
    // to 0x17F8 by this third iteration — so the pop really happened.
    `CHECK_EQ(dut.processor.RegisterBank[2], 32'h17FC,
              "sp back at the pushed 0x17FC: no stack drift across iterations")
    `CHECK_EQ(dut.memory.MEM[1535], 32'd44,
              "stack word still holds the main-loop link")

    // Edge-case bytes: 0x00 (all-zero data bits), 0x7F (byte+1 = 0x80 sets
    // the echo's MSB) and 0xFF (byte+1 wraps to 0x00 — the SOC takes the
    // UART data's low byte, so the wrap is real).
    echo2(8'h00);
    echo2(8'h7F);
    echo2(8'hFF);
    i = 0;
    while ((dut.processor.PC < 32'd84 || dut.processor.PC >= 32'd100) && i < 1000) begin
      @(posedge CLK); #1;
      i = i + 1;
    end
    `CHECK_EQ(dut.processor.RegisterBank[2], 32'h17FC,
              "sp still at the pushed 0x17FC after the edge-case echoes")
    `CHECK_EQ(LEDS, 5'd0, "LEDS still dark at the end")

    `DONE
  end
endmodule
`default_nettype wire
