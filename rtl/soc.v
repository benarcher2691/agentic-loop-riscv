`default_nettype none
// Top level for the iCEstick. Port names must match boards/icestick.pcf.
// The loop agent builds this up task by task (see TASKS.md).
module SOC #(
    parameter SLOW = 19   // LED step rate: clk = CLK / 2^SLOW (~43 ms at 12 MHz)
) (
    input  wire       CLK,   // 12 MHz board clock
    input  wire       RXD,   // UART receive (host -> FPGA), unused for now
    output wire       TXD,   // UART transmit (FPGA -> host)
    output wire [4:0] LEDS   // D1..D5
);
    wire clk, resetn;
    Clockworks #(.SLOW(SLOW)) clockworks (.CLK(CLK), .clk(clk), .resetn(resetn));

    // Blinker: 5-bit counter cleared by the power-on reset.
    reg [4:0] count = 5'd0;
    always @(posedge clk) begin
        if (!resetn) count <= 5'd0;
        else         count <= count + 5'd1;
    end
    assign LEDS = count;

    assign TXD = 1'b1;      // UART line idles high
endmodule
`default_nettype wire
