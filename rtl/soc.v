`default_nettype none
// Top level for the iCEstick. Port names must match boards/icestick.pcf.
// Processor + Memory run at full CLK speed (SLOW = 0 passes CLK through).
// Address bit 22 selects IO space instead of RAM; the four IO words decode
// by exact equality on the word offset mem_addr[5:2] (see below). Any other
// IO offset reads as 0 with no side effect and drops writes.
module SOC #(
    parameter SLOW = 0    // 0 = CPU at full CLK speed; >0 divides CLK by 2^SLOW
) (
    input  wire       CLK,   // 12 MHz board clock
    input  wire       RXD,   // UART receive (host -> FPGA)
    output wire       TXD,   // UART transmit (FPGA -> host)
    output wire [4:0] LEDS   // D1..D5
);
    wire clk, resetn;
    Clockworks #(.SLOW(SLOW)) clockworks (.CLK(CLK), .clk(clk), .resetn(resetn));

    wire [31:0] mem_addr, mem_rdata, mem_wdata;
    wire        mem_rstrb;
    wire [3:0]  mem_wmask;

    // ---- IO space decode -------------------------------------------------
    // mem_addr[22] is only ever set by a load/store (the fetch address is a
    // 13-bit PC, zero-extended). The four IO words decode by EXACT equality
    // on the word offset mem_addr[5:2]:
    //   0001 -> LEDS  0x400004: a write updates ledReg from mem_wdata[4:0]
    //            on the low byte lane only (mem_wmask[0]); reads return
    //            {27'd0, ledReg} (so the monitor's R command can read it back)
    //   0010 -> UART data write 0x400008, full-word stores only
    //            (mem_wmask == 4'b1111): the monitor's byte-wise W command
    //            must be able to walk across IO words without firing the
    //            transmitter, and PUTBYTE sends with SW
    //   0100 -> UART status read 0x400010, bit 9 of the word = transmitter busy
    //   1000 -> UART RX read 0x400020: {23'd0, avail, data}, avail clears
    // Any other IO offset: reads return 32'd0 with no side effect (rxAvail
    // survives), writes are dropped.
    // A store pulse is |mem_wmask, which the Processor gates to the store's
    // EXECUTE cycle — exactly one clk edge per store, with mem_addr = the
    // effective address.
    wire ioSel    = mem_addr[22];
    wire [3:0] ioWord = mem_addr[5:2];
    wire ioLeds   = ioSel & (ioWord == 4'b0001);              // read + write
    wire ioLedsW  = ioLeds & mem_wmask[0];
    wire ioUartW  = ioSel & (ioWord == 4'b0010) & (mem_wmask == 4'b1111);
    wire ioUartS  = ioSel & (ioWord == 4'b0100);
    wire ioUartRx = ioSel & (ioWord == 4'b1000);
    wire uartReady;   // emitter handshake (declared early: used below)
    wire uartTx;

    // UART receiver (host -> FPGA). rxAvail is the "unread byte pending"
    // flag. Overrun policy: LAST-WRITER-WINS — a byte that completes while
    // an earlier byte is still unread overwrites uartRxData and re-sets
    // rxAvail; the earlier byte is gone. The host must therefore throttle:
    // send at most one byte, then wait until software has read the RX word
    // (avail clears) before sending the next — the monitor's GETBYTE poll
    // keeps up at 115200 baud, but nothing in hardware queues bytes.
    // Set-priority over the read-clear: a byte completing exactly on the
    // read cycle wins — that read returns the pre-completion avail bit
    // (0), but rxAvail ends SET, so a follow-up read still delivers the
    // completing byte; nothing is lost at the race (pinned by
    // tb/rxoverrun_tb.v).
    wire       uartRxValid;
    wire [7:0] uartRxData;
    reg        rxAvail = 1'b0;
    reg [4:0]  ledReg = 5'd0;   // LEDS: written by software, reset dark
    always @(posedge clk) begin
        if (!resetn)                   rxAvail <= 1'b0;
        else if (uartRxValid)          rxAvail <= 1'b1;
        else if (mem_rstrb & ioUartRx) rxAvail <= 1'b0;
    end
    UartRx #(
        .CLK_HZ(12_000_000),
        .BAUD  (115200)
    ) uartRx (
        .clk   (clk),
        .resetn(resetn),
        .rx    (RXD),
        .data  (uartRxData),
        .valid (uartRxValid)
    );

    Processor processor (
        .clk      (clk),
        .resetn   (resetn),
        .mem_addr (mem_addr),
        .mem_rdata(mem_rdata),
        .mem_rstrb(mem_rstrb),
        .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask)
    );

    // RAM: reads and writes are suppressed while the bus is in IO space, so
    // an IO access at 0x4000xx cannot alias into MEM[addr[9:2]].
    wire [31:0] memRamRdata;
    Memory memory (
        .clk      (clk),
        .mem_addr (mem_addr),
        .mem_rdata(memRamRdata),
        .mem_rstrb(mem_rstrb & ~ioSel),
        .mem_wdata(mem_wdata),
        .mem_wmask(ioSel ? 4'b0000 : mem_wmask)
    );

    // Read return path: the RAM's synchronous read, or the IO status word.
    // ioSelR registers the fact that the strobe in flight targeted IO (the
    // combinational ioSel is gone by the LOAD wait state, when the
    // Processor actually consumes mem_rdata). Exact-match decode: RX word,
    // status word, LEDS word — anything else reads as 0 with no side effect.
    reg        ioSelR = 1'b0;
    reg [31:0] ioRdata = 32'd0;
    always @(posedge clk) begin
        ioSelR <= mem_rstrb & ioSel;
        if (mem_rstrb & ioSel)
            ioRdata <= ioUartRx ? {23'd0, rxAvail, uartRxData}
                                : ioUartS ? {22'd0, ~uartReady, 9'd0}
                                : ioLeds  ? {27'd0, ledReg}
                                : 32'd0;
    end
    assign mem_rdata = ioSelR ? ioRdata : memRamRdata;

    // LEDS: written by software (declaration above, needed early for the
    // read path), reset dark.
    always @(posedge clk) begin
        if (!resetn)      ledReg <= 5'd0;
        else if (ioLedsW) ledReg <= mem_wdata[4:0];
    end
    assign LEDS = ledReg;

    // UART transmitter. A data write is only accepted while the emitter is
    // idle (o_ready); uartValid is then held until the emitter acknowledges
    // by dropping o_ready — the standard valid/ready handshake, with the
    // clear arm below as the acknowledge, so the byte is presented until
    // taken and taken exactly once (the emitter loads i_data only on
    // i_valid & o_ready). (An earlier comment claimed the hold also rides
    // out the emitter's per-bit shift cycle; that is wrong — the shift
    // branch fires only at bit-rate counter wraps, which happen only while
    // busy (o_ready = 0) or at the wrap where o_ready rises (i_valid &
    // o_ready already false there), and while idle the reload pins the
    // counter's top bit to 0 — a load can never be swallowed.) Writes while
    // busy are dropped (software waits on the status word's busy bit;
    // pinned by tb/txbusy_tb.v).
    reg       uartValid = 1'b0;
    reg [7:0] uartData  = 8'd0;
    always @(posedge clk) begin
        if (!resetn)                    uartValid <= 1'b0;
        else if (ioUartW & uartReady)   uartValid <= 1'b1;
        else if (uartValid & !uartReady) uartValid <= 1'b0;
        if (ioUartW & uartReady) uartData <= mem_wdata[7:0];
    end
    corescore_emitter_uart #(
        .clk_freq_hz(12_000_000),
        .baud_rate  (115200)
    ) uart (
        .i_clk     (clk),
        .i_rst     (~resetn),
        .i_data    (uartData),
        .i_valid   (uartValid),
        .o_ready   (uartReady),
        .o_uart_tx (uartTx)
    );

    // TXD idles high from power-up; only the first accepted write hands the
    // line to the emitter (whose internal shift register is X until its
    // first load in simulation).
    reg txStarted = 1'b0;
    always @(posedge clk) begin
        if (!resetn)                  txStarted <= 1'b0;
        else if (ioUartW & uartReady) txStarted <= 1'b1;
    end
    assign TXD = uartTx | ~txStarted;
endmodule
`default_nettype wire
