`default_nettype none
// 8N1 UART receiver.
//
// Two-flop synchroniser on rx, start-bit detection on the synchronised
// falling edge, every bit sampled at mid-bit (CLK_HZ/BAUD clocks per bit).
// valid is a one-clock pulse when a byte is complete; a false start bit
// (line back high at the mid-start sample) returns to idle with no pulse.
module UartRx #(
    parameter integer CLK_HZ = 12000000,
    parameter integer BAUD   = 115200
) (
    input  wire       clk,
    input  wire       resetn,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid
);
    // Clocks per bit, rounded to nearest: 104 at 12 MHz / 115200. The 0.17
    // clocks/bit rounding drift over a 10-bit frame (~1.7 clocks) stays far
    // inside the half-bit sampling margin.
    localparam integer BIT_CLKS  = (CLK_HZ + BAUD/2) / BAUD;   // 104
    localparam integer HALF_CLKS = BIT_CLKS / 2;               // 52

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0] sync   = 2'b11;   // two-flop synchroniser on rx
    reg       rxsOld = 1'b1;    // previous synchronised level (edge detect)
    reg [1:0] state  = S_IDLE;
    // Position within a bit, 0..BIT_CLKS-1. Sized from BIT_CLKS so any
    // CLK_HZ/BAUD pairing fits (104 clocks/bit at 12 MHz/115200 -> 7 bits);
    // $clog2(104) = 7, so this is the same [6:0] it always was — no
    // behaviour change, just no silent truncation if the parameters move.
    reg [$clog2(BIT_CLKS)-1:0] count = 0;
    reg [2:0] bitIdx = 3'd0;
    reg [7:0] shreg  = 8'd0;

    wire rxs  = sync[1];
    wire fall = rxsOld & ~rxs;

    always @(posedge clk) begin
        if (!resetn) begin
            sync   <= 2'b11;
            rxsOld <= 1'b1;
            state  <= S_IDLE;
            count  <= 7'd0;
            bitIdx <= 3'd0;
            shreg  <= 8'd0;
            data   <= 8'd0;
            valid  <= 1'b0;
        end else begin
            sync   <= {sync[0], rx};
            rxsOld <= rxs;
            valid  <= 1'b0;    // default: valid is a one-clock pulse
            case (state)
                S_IDLE: begin
                    count  <= 7'd0;
                    bitIdx <= 3'd0;
                    if (fall) state <= S_START;
                end
                S_START: begin         // wait for the mid-start sample
                    if (count == HALF_CLKS - 1) begin
                        count <= 7'd0;
                        if (!rxs) state <= S_DATA;   // real start bit
                        else      state <= S_IDLE;   // false start: ignored
                    end else count <= count + 7'd1;
                end
                S_DATA: begin          // one mid-bit sample per bit, LSB first
                    if (count == BIT_CLKS - 1) begin
                        count <= 7'd0;
                        shreg <= {rxs, shreg[7:1]};
                        if (bitIdx == 3'd7) state <= S_STOP;
                        else                bitIdx <= bitIdx + 3'd1;
                    end else count <= count + 7'd1;
                end
                S_STOP: begin          // byte complete at mid-stop
                    if (count == BIT_CLKS - 1) begin
                        count <= 7'd0;
                        data  <= shreg;
                        valid <= 1'b1;
                        state <= S_IDLE;
                    end else count <= count + 7'd1;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
