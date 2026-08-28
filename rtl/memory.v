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

    // ROM program: small ADDI demo. LEDS (= x1[4:0]) walk 1,3,7,15,31, then
    // EBREAK halts the Processor. tb/memory_tb.v and tb/soc_tb.v keep
    // hand-assembled copies of these words.
    `include "../lib/riscv_assembly.v"
    initial begin
        ADDI(x1, x0, 1);
        ADDI(x1, x1, 2);
        ADDI(x1, x1, 4);
        ADDI(x1, x1, 8);
        ADDI(x1, x1, 16);
        EBREAK();
        endASM();
    end

    always @(posedge clk) begin
        if (mem_rstrb) mem_rdata <= MEM[mem_addr[9:2]];
    end
endmodule
`default_nettype wire
