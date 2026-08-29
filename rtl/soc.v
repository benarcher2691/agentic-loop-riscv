`default_nettype none
// Top level for the iCEstick. Port names must match boards/icestick.pcf.
// Processor + Memory run at full CLK speed (SLOW = 0 passes CLK through).
// Address bit 22 selects IO space instead of RAM (word offsets):
//   bit 2 -> LEDS write, bit 3 -> UART data write, bit 4 -> UART status
//   read (bit 9 of the returned word = transmitter busy), bit 5 -> UART RX
//   read: {23'd0, avail, data}, avail (bit 8) clears on the read.
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
    wire [31:0] x1;

    // ---- IO space decode -------------------------------------------------
    // mem_addr[22] is only ever set by a load/store (the fetch address is a
    // 13-bit PC, zero-extended). A store pulse is |mem_wmask, which the
    // Processor gates to the store's EXECUTE cycle — exactly one clk edge
    // per store, with mem_addr = the effective address.
    wire ioSel    = mem_addr[22];
    wire storeNow = |mem_wmask;
    wire ioLedsW  = ioSel & storeNow & mem_addr[2];
    wire ioUartW  = ioSel & storeNow & mem_addr[3];
    wire ioUartS  = ioSel & mem_addr[4];
    wire ioUartRx = ioSel & mem_addr[5];
    wire uartReady;   // emitter handshake (declared early: used below)
    wire uartTx;

    // UART receiver (host -> FPGA). rxAvail is the "unread byte pending"
    // flag: set when the receiver completes a byte, cleared when software
    // reads the RX word. Set-priority over the read-clear so a byte that
    // completes exactly on the read cycle is not lost.
    wire       uartRxValid;
    wire [7:0] uartRxData;
    reg        rxAvail = 1'b0;
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
        .mem_wmask(mem_wmask),
        .x1       (x1)
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
    // Processor actually consumes mem_rdata).
    reg        ioSelR = 1'b0;
    reg [31:0] ioRdata = 32'd0;
    always @(posedge clk) begin
        ioSelR <= mem_rstrb & ioSel;
        if (mem_rstrb & ioSel)
            ioRdata <= ioUartRx ? {23'd0, rxAvail, uartRxData}
                                : ioUartS ? {22'd0, ~uartReady, 9'd0}
                                          : 32'd0;
    end
    assign mem_rdata = ioSelR ? ioRdata : memRamRdata;

    // LEDS: written by software, reset dark.
    reg [4:0] ledReg = 5'd0;
    always @(posedge clk) begin
        if (!resetn)      ledReg <= 5'd0;
        else if (ioLedsW) ledReg <= mem_wdata[4:0];
    end
    assign LEDS = ledReg;

    // UART transmitter. A data write is only accepted while the emitter is
    // idle (o_ready); i_valid is then held until the emitter acknowledges by
    // dropping o_ready — this also rides out the one cycle per bit where
    // the emitter's internal shift fires and would swallow a single-cycle
    // pulse. Writes while busy are dropped (software waits on the status
    // word's busy bit).
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
