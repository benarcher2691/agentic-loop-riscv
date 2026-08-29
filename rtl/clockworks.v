`default_nettype none
// Clockworks: clock divider and power-on reset for the iCEstick.
//   clk    = CLK / 2^SLOW  (SLOW = 0 passes CLK through unchanged)
//   resetn = power-on reset: low for the first RESET_CYCLES CLK cycles after
//            power-up, then high forever (the board has no reset button).
//
// RESET_CYCLES defaults to 65536 on hardware: the iCE40 block RAM is not
// readable for several microseconds after configuration (the reference design
// waits 2^16 clocks), so the CPU must be held in reset until it is — otherwise
// it fetches garbage and the board stays dark. Under `ifdef FAST_SIM (every
// simulation and the equiv netlist) the default is 16 so all bench timing is
// unchanged; simulated BRAM is ready at t = 0.
// RESET_CYCLES must be a power of two: the counter sticks at 2^(PORW-1).
module Clockworks #(
    parameter SLOW = 0,
`ifdef FAST_SIM
    parameter RESET_CYCLES = 16       // simulations: BRAM ready at t = 0
`else
    parameter RESET_CYCLES = 65536    // hardware: wait 2^16 clocks for the BRAM
`endif
) (
    input  wire CLK,     // 12 MHz board clock
    output wire clk,     // divided clock
    output wire resetn   // active-low power-on reset
);
    // Power-on reset: counter counts 0..RESET_CYCLES and sticks at its
    // terminal value. resetn (the MSB) is low while the counter is below
    // RESET_CYCLES, i.e. for exactly the first RESET_CYCLES CLK cycles.
    localparam PORW = $clog2(RESET_CYCLES) + 1;   // bits needed to reach RESET_CYCLES
    reg [PORW-1:0] por = {PORW{1'b0}};
    always @(posedge CLK) begin
        if (!por[PORW-1]) por <= por + 1'b1;
    end
    assign resetn = por[PORW-1];

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
