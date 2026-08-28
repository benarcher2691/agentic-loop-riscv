`default_nettype none
// Top level for the iCEstick. Port names must match boards/icestick.pcf.
// The loop agent builds this up task by task (see TASKS.md).
module SOC (
    input  wire       CLK,   // 12 MHz board clock
    input  wire       RXD,   // UART receive (host -> FPGA), unused for now
    output wire       TXD,   // UART transmit (FPGA -> host)
    output wire [4:0] LEDS   // D1..D5
);
    assign LEDS = 5'b00000;
    assign TXD  = 1'b1;      // UART line idles high
endmodule
`default_nettype wire
