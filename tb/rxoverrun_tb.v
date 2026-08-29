`timescale 1ns/1ps
`default_nettype none
// T4(a) UART RX contracts. The CPU is halted at an EBREAK planted at MEM[0]
// (loaded while resetn is low), so it issues no bus strobes and every read
// below is bench-forced and deterministic. Scenarios:
//
//   1. Overrun is LAST-WRITER-WINS: two back-to-back bytes with no read in
//      between leave rxAvail set and uartRxData holding the SECOND byte.
//      The single read returns {avail=1, second byte}; avail clears after;
//      a later byte still arrives and reads normally.
//
//   2. Set-vs-clear race, pinned deterministically: the bench detects the
//      edge on which uartRxValid rises, then arms mem_rstrb/mem_addr so the
//      forced read strobe is high on the NEXT edge — the edge where the
//      rxAvail block samples uartRxValid=1 (set) and the strobe (clear) at
//      the same time. Set wins: rxAvail ends SET and the completing byte is
//      preserved — the racing read's avail bit shows the pre-race 0, and a
//      follow-up read returns {avail=1, byte}.
//
// A witness records that a posedge really sampled uartRxValid=1 while the
// force was armed, so the race test cannot pass vacuously.
module rxoverrun_tb;
  `include "check.vh"
  `WATCHDOG(10_000_000)

  reg CLK = 0;
  reg RXD = 1;
  wire       TXD;
  wire [4:0] LEDS;

  SOC #(.SLOW(0)) dut (.CLK(CLK), .RXD(RXD), .TXD(TXD), .LEDS(LEDS));

  always #41.667 CLK = ~CLK;   // 12 MHz

  // Halt the CPU immediately: MEM[0] <- EBREAK, written after the monitor's
  // initial block has filled MEM but while resetn (16 cycles under
  // FAST_SIM) still holds the CPU in FETCH_INSTR.
  initial begin
    #1;
    dut.memory.MEM[0] = 32'h00100073;   // ebreak
  end

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

  // One forced RX-word read (the tb/uart_rx_tb.v technique with the
  // hold-past-the-edge fix from the T4 handoff: the force stays armed
  // through the strobe edge, the word is sampled at +1 ns once the NBA
  // updates have landed, and only then is the bus released). Returns
  // {23'd0, avail, data} and clears rxAvail.
  reg [31:0] w;
  task force_read_rx;
    begin
      force dut.mem_rstrb = 1'b1;
      force dut.mem_addr  = 32'h00400020;
      @(posedge CLK);   // strobe edge: ioSelR/ioRdata latch, rxAvail clears
      #1;               // NBA settled: ioSelR routes the registered ioRdata out
      w = dut.mem_rdata;
      release dut.mem_rstrb;
      release dut.mem_addr;
      @(posedge CLK);   // ioSelR pulse ends
      #1;
    end
  endtask

  // ---- race witness -------------------------------------------------------
  // While the race force is armed, record whether a posedge sampled
  // uartRxValid high: the forced strobe really overlapped the completing
  // byte's one-clock valid pulse.
  reg racing  = 1'b0;
  reg sawRace = 1'b0;
  always @(posedge CLK)
    if (racing && dut.uartRxValid === 1'b1) sawRace = 1'b1;

  integer guard;
  reg [31:0] raceRdata;
  reg        raceAvail;

  initial begin
    // Wait for the CPU to reach its permanent EXECUTE halt at the EBREAK.
    guard = 0;
    @(posedge CLK); #1;
    while (dut.processor.state !== 2'd2 && guard < 100) begin
      @(posedge CLK); #1; guard = guard + 1;
    end
    `CHECK_EQ(dut.processor.state, 2'd2, "CPU parked in EXECUTE (halted)")
    `CHECK_EQ(dut.processor.PC, 32'd0, "PC frozen at the EBREAK address 0")
    `CHECK_EQ(dut.rxAvail, 1'b0, "no byte yet: avail clear")
    `CHECK_EQ(dut.uartRx.data, 8'h00, "receiver data resets to 0")

    // ---- 1. overrun: two bytes, no read in between ----------------------
    send_byte(8'h11);
    send_byte(8'h22);          // completes while 0x11 is still unread
    repeat (4) @(posedge CLK); #1;
    `CHECK_EQ(dut.rxAvail, 1'b1, "overrun: avail set (no read between the bytes)")
    `CHECK_EQ(dut.uartRx.data, 8'h22, "overrun: the SECOND byte won the data register")

    force_read_rx;
    `CHECK_EQ(w, {23'd0, 1'b1, 8'h22}, "the single read returns avail=1 + the second byte")
    `CHECK_EQ(dut.rxAvail, 1'b0, "avail cleared by that read")

    force_read_rx;
    `CHECK_EQ(w, {23'd0, 1'b0, 8'h22}, "second read: avail clear, data field persists")

    // a subsequent byte still works
    send_byte(8'h33);
    guard = 0;
    @(posedge CLK); #1;
    while (dut.rxAvail !== 1'b1 && guard < 4000) begin
      @(posedge CLK); #1; guard = guard + 1;
    end
    `CHECK_EQ(dut.rxAvail, 1'b1, "byte after the overrun: avail sets again")
    force_read_rx;
    `CHECK_EQ(w, {23'd0, 1'b1, 8'h33}, "read returns the new byte")
    `CHECK_EQ(dut.rxAvail, 1'b0, "avail clear again")

    // ---- 2. set-vs-clear race on the exact uartRxValid cycle ------------
    `CHECK_EQ(dut.rxAvail, 1'b0, "fresh start for the race: avail clear")
    fork
      send_byte(8'h77);
      begin : poll_and_force
        @(posedge CLK); #1;
        guard = 0;
        while (dut.uartRxValid !== 1'b1 && guard < 4000) begin
          @(posedge CLK); #1; guard = guard + 1;
        end
        // uartRxValid rose at the edge just passed (P); the rxAvail block
        // samples it at the NEXT edge (P+1). Arm the forced strobe now so
        // it is high at P+1 — the set-vs-clear race edge — and release
        // right after sampling, before P+2 could clear the flag again.
        racing = 1'b1;
        force dut.mem_rstrb = 1'b1;
        force dut.mem_addr  = 32'h00400020;
        @(posedge CLK);      // P+1: uartRxValid=1 AND forced strobe=1
        #1;
        raceRdata = dut.mem_rdata;   // the racing read's returned word
        raceAvail = dut.rxAvail;     // the set must have won
        release dut.mem_rstrb;
        release dut.mem_addr;
        racing = 1'b0;
      end
    join
    `CHECK(sawRace, "the forced strobe overlapped the valid pulse (race really happened)")
    `CHECK_EQ(raceAvail, 1'b1, "set wins: avail ends SET on the race edge")
    `CHECK_EQ(raceRdata, {23'd0, 1'b0, 8'h77},
              "racing read returns the pre-race avail bit (0) — the byte is NOT lost")
    force_read_rx;
    `CHECK_EQ(w, {23'd0, 1'b1, 8'h77}, "follow-up read delivers the completing byte")
    force_read_rx;
    `CHECK_EQ(w, {23'd0, 1'b0, 8'h77}, "and then avail is clear")

    `DONE
  end
endmodule
`default_nettype wire
