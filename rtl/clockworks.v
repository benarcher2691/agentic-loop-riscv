`default_nettype none
// Clockworks: clock divider and power-on reset for the iCEstick.
//   clk    = CLK / 2^SLOW  (SLOW = 0 passes CLK through unchanged)
//   resetn = power-on reset: low for the first 16 CLK cycles after power-up,
//            then high forever (the board has no reset button).
module Clockworks #(
    parameter SLOW = 0
) (
    input  wire CLK,     // 12 MHz board clock
    output wire clk,     // divided clock
    output wire resetn   // active-low power-on reset
);
    // Power-on reset: 5-bit counter counts 0..16 and sticks there.
    // Bit 4 (resetn) is low while the counter is 0..15, i.e. for exactly
    // the first 16 CLK cycles after power-up.
    reg [4:0] por = 5'd0;
    always @(posedge CLK) begin
        if (!por[4]) por <= por + 5'd1;
    end
    assign resetn = por[4];

    generate
        if (SLOW == 0) begin : g_passthrough
            assign clk = CLK;
        end else begin : g_divider
            // SLOW-bit free-running counter: its MSB toggles every
            // 2^(SLOW-1) CLK cycles, so clk has period 2^SLOW CLK cycles.
            reg [SLOW-1:0] div = {SLOW{1'b0}};
            always @(posedge CLK) div <= div + 1'b1;
            assign clk = div[SLOW-1];
        end
    endgenerate
endmodule
`default_nettype wire
