`default_nettype none
// Top level for the iCEstick. Port names must match boards/icestick.pcf.
// Processor + Memory run at full CLK speed (SLOW = 0 passes CLK through);
// LEDS show x1[4:0] of the program in the ROM.
module SOC #(
    parameter SLOW = 0    // 0 = CPU at full CLK speed; >0 divides CLK by 2^SLOW
) (
    input  wire       CLK,   // 12 MHz board clock
    input  wire       RXD,   // UART receive (host -> FPGA), unused for now
    output wire       TXD,   // UART transmit (FPGA -> host)
    output wire [4:0] LEDS   // D1..D5
);
    wire clk, resetn;
    Clockworks #(.SLOW(SLOW)) clockworks (.CLK(CLK), .clk(clk), .resetn(resetn));

    wire [31:0] mem_addr, mem_rdata, mem_wdata;
    wire        mem_rstrb;
    wire [3:0]  mem_wmask;
    wire [31:0] x1;

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

    Memory memory (
        .clk      (clk),
        .mem_addr (mem_addr),
        .mem_rdata(mem_rdata),
        .mem_rstrb(mem_rstrb),
        .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask)
    );

    assign LEDS = x1[4:0];

    assign TXD = 1'b1;      // UART line idles high
endmodule
`default_nettype wire
