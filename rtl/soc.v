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

    // Fetch machine: PC walks the ROM program word by word and LEDS show the
    // low 5 bits of the word at PC. PROG_WORDS must match the number of words
    // the program in rtl/memory.v initialises.
    localparam integer PROG_WORDS = 16;

    reg [31:0] PC = 32'd0;    // byte address of the word being fetched

    wire [31:0] mem_rdata;
    Memory memory (
        .clk       (clk),
        .mem_addr  (PC),
        .mem_rdata (mem_rdata),
        .mem_rstrb (1'b1)     // always reading; the strobe matters for RAM later
    );

    always @(posedge clk) begin
        if (!resetn)                     PC <= 32'd0;
        else if (PC >= (PROG_WORDS-1)*4) PC <= 32'd0;  // wrap after the last word
        else                             PC <= PC + 32'd4;
    end

    assign LEDS = mem_rdata[4:0];

    assign TXD = 1'b1;      // UART line idles high
endmodule
`default_nettype wire
