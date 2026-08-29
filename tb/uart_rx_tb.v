`timescale 1ns/1ps
// UartRx bench — 8N1 receiver tested against a serial transmitter model in
// the bench. Scenarios: single byte, back-to-back bytes, byte after long
// idle, glitch rejection; then the SOC IO word at 0x400020.
module uart_rx_tb;
    `include "check.vh"

    // 12 MHz / 115200-8N1. The bench clock rounds to 83.334 ns (1 ps
    // precision, same as io_tb); the transmitter uses the nominal bit period.
    localparam real CLK_NS = 83.333333;                 // 12 MHz
    localparam real BIT_NS = 1000000000.0 / 115200.0;   // 8680.6 ns per bit

    reg clk = 1'b0;
    always #(CLK_NS/2.0) clk = ~clk;

    reg resetn = 1'b0;
    reg rxd    = 1'b1;   // idle high

    wire [7:0] rxData;
    wire       rxValid;
    UartRx #(.CLK_HZ(12_000_000), .BAUD(115200)) dut (
        .clk(clk), .resetn(resetn), .rx(rxd), .data(rxData), .valid(rxValid)
    );

    // ---- pulse capture ----------------------------------------------------
    // valid is one clock wide and arrives at mid-stop, i.e. BEFORE send_byte
    // returns (the stop-bit delay is still running) — a task that starts
    // polling afterwards would miss it. This monitor records every pulse
    // (data, timestamp) and checks the one-clock width right here.
    reg [7:0] capData [0:15];
    real      capT    [0:15];
    integer   capN    = 0;
    always @(posedge clk) begin
        if (rxValid === 1'b1) begin
            capData[capN % 16] = rxData;
            capT   [capN % 16] = $realtime;
            capN = capN + 1;
            @(posedge clk);
            `CHECK(rxValid === 1'b0, "valid is exactly one clk wide");
        end
    end

    real tFall;    // when the transmitter model drives the start bit low
    real tValid;   // posedge at which the monitor captured the pulse

    // ---- bench transmitter model: 8N1, LSB first -------------------------
    task send_byte(input [7:0] b);
        integer i;
        begin
            tFall = $realtime;
            rxd = 1'b0;                       // start bit
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                rxd = b[i];                   // data bits, LSB first
                #(BIT_NS);
            end
            rxd = 1'b1;                       // stop bit
            #(BIT_NS);
        end
    endtask

    // ---- SOC integration: the IO word at 0x400020 -------------------------
    reg  [4:0] socLeds;
    wire       socTxd;
    reg        socRxd = 1'b1;
    SOC #(.SLOW(0)) soc (
        .CLK (clk),
        .RXD (socRxd),
        .TXD (socTxd),
        .LEDS(socLeds)
    );
    // The emitter's data reg has no power-on value in RTL sim (task-17
    // note): kick it so the demo program's handshake resolves, not X.
    initial soc.uart.data = 8'd0;

    task send_soc(input [7:0] b);
        integer i;
        begin
            socRxd = 1'b0;
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                socRxd = b[i];
                #(BIT_NS);
            end
            socRxd = 1'b1;
            #(BIT_NS);
        end
    endtask

    // Consume the next captured pulse and check its data.
    integer capRead = 0;
    integer guard;
    task wait_valid(input [7:0] exp);
        begin
            guard = 0;
            while (capRead >= capN && guard < 3000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            `CHECK(capRead < capN, "valid pulse arrived");
            if (capRead < capN) begin
                `CHECK_EQ(capData[capRead % 16], exp, "data when valid is high");
                tValid = capT[capRead % 16];
                capRead = capRead + 1;
            end
        end
    endtask

    integer i;
    initial begin
        // Reset, then idle: the line sits high and the receiver must stay
        // completely quiet.
        repeat (4) @(posedge clk);
        resetn = 1'b1;
        repeat (2000) @(posedge clk);   // ~23 bit periods of idle
        `CHECK(rxValid === 1'b0, "idle: no valid");
        `CHECK_EQ(capN, 0, "idle: no valid pulses");
        `CHECK_EQ(rxData, 8'h00, "data resets to 0");

        // ---- single byte 0xA5 --------------------------------------------
        send_byte(8'hA5);
        wait_valid(8'hA5);
        // valid must land at mid-stop: 9.5 bit periods + the synchroniser /
        // edge-detect delay (1..4 clocks) after the start edge — NOT at the
        // frame end (10 bits). This is what distinguishes mid-bit sampling
        // from edge sampling.
        `CHECK((tValid - tFall) > (9.5*BIT_NS + 0.5*CLK_NS) &&
               (tValid - tFall) < (9.5*BIT_NS + 5.0*CLK_NS),
               "valid arrives at mid-stop, not frame end");

        // ---- two back-to-back bytes (start falls as stop ends) ------------
        send_byte(8'h3C);
        send_byte(8'hC3);
        wait_valid(8'h3C);
        wait_valid(8'hC3);

        // ---- a byte after a long idle (~34 bit periods) -------------------
        repeat (3600) @(posedge clk);
        send_byte(8'h5A);
        wait_valid(8'h5A);

        // ---- glitch shorter than half a bit must be ignored ----------------
        rxd = 1'b0;                       // ~20 clocks low (< 26 = half of half)
        #(20.0 * CLK_NS);
        rxd = 1'b1;
        repeat (400) @(posedge clk);      // ~4.6 bit periods: mid-start sample
                                          // has passed, no byte may complete
        `CHECK_EQ(capN, 4, "glitch produced no valid pulse");
        // the receiver must be back in idle and receive a normal byte
        send_byte(8'h96);
        wait_valid(8'h96);

        `CHECK_EQ(capRead, capN, "every captured pulse was consumed");
        `CHECK_EQ(capN, 5, "exactly five pulses for five bytes");

        // ---- SOC: byte arrives, avail sets, read returns {avail, data} ----
        // 'A' = 0x41: its low 7 bits are not a valid opcode, so if the CPU
        // happens to decode the RX word off the bus during a forced read it
        // executes a NOP and the demo program just shrugs.
        send_soc(8'h41);
        guard = 0;
        while (soc.rxAvail !== 1'b1 && guard < 3000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        `CHECK(soc.rxAvail === 1'b1, "SOC: rxAvail set after a byte");
        `CHECK_EQ(soc.uartRx.data, 8'h41, "SOC: receiver data holds the byte");

        // Hijack the bus for exactly one read strobe at 0x400020 (the CPU is
        // running the demo program; its own strobes resume after release).
        force soc.mem_rstrb = 1'b1;
        force soc.mem_addr  = 32'h00400020;
        @(posedge clk);
        release soc.mem_rstrb;
        release soc.mem_addr;
        @(posedge clk);   // ioSelR now routes the registered ioRdata out
        `CHECK_EQ(soc.mem_rdata, {23'd0, 1'b1, 8'h41},
                  "SOC: RX word reads {avail, data}");
        `CHECK(soc.rxAvail === 1'b0, "SOC: read clears avail");

        // Second read: avail stays clear, the data field persists.
        force soc.mem_rstrb = 1'b1;
        force soc.mem_addr  = 32'h00400020;
        @(posedge clk);
        release soc.mem_rstrb;
        release soc.mem_addr;
        @(posedge clk);
        `CHECK_EQ(soc.mem_rdata, {23'd0, 1'b0, 8'h41},
                  "SOC: second read, avail clear, data held");

        `DONE
    end

    `WATCHDOG(20000000)
endmodule
