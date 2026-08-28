`default_nettype none
// 1 KB word-accessed memory (ROM program now, RAM from the stores task on).
// mem_addr is a byte address; mem_addr[9:2] selects the 32-bit word.
// The read is synchronous and gated by mem_rstrb: when the strobe is low,
// mem_rdata holds its previous value.
module Memory (
    input  wire        clk,
    input  wire [31:0] mem_addr,
    output reg  [31:0] mem_rdata,
    input  wire        mem_rstrb
);
    reg [31:0] MEM [0:255];

    // ROM program: LED pattern, one word per PC step (LEDS = mem_rdata[4:0]).
    // SOC's PROG_WORDS must match the number of words initialised here;
    // tb/memory_tb.v and tb/soc_tb.v keep independent copies of these constants.
    initial begin
        MEM[0]  = 32'h00000001;  // 00001
        MEM[1]  = 32'h00000002;  // 00010
        MEM[2]  = 32'h00000004;  // 00100
        MEM[3]  = 32'h00000008;  // 01000
        MEM[4]  = 32'h00000010;  // 10000
        MEM[5]  = 32'h00000015;  // 10101
        MEM[6]  = 32'h0000000A;  // 01010
        MEM[7]  = 32'hDEADBEEF;  // 01111 (low 5 bits of 0xEF)
        MEM[8]  = 32'h0000001F;  // 11111
        MEM[9]  = 32'h00000000;  // 00000
        MEM[10] = 32'h80000015;  // 10101 (bit 31 set)
        MEM[11] = 32'h7FFFFFFF;  // 11111
        MEM[12] = 32'h0000000C;  // 01100
        MEM[13] = 32'h00000003;  // 00011
        MEM[14] = 32'h00000018;  // 11000
        MEM[15] = 32'hCAFEBABE;  // 11110 (low 5 bits of 0xBE)
    end

    always @(posedge clk) begin
        if (mem_rstrb) mem_rdata <= MEM[mem_addr[9:2]];
    end
endmodule
`default_nettype wire
