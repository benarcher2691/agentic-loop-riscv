`default_nettype none
// 1 KB word-accessed memory: program ROM and data RAM. mem_addr is a byte
// address; mem_addr[9:2] selects the 32-bit word. The read is synchronous
// and gated by mem_rstrb: when the strobe is low, mem_rdata holds its
// previous value. Writes are synchronous with per-byte enables: only the
// lanes whose mem_wmask bit is high take mem_wdata's byte.
module Memory (
    input  wire        clk,
    input  wire [31:0] mem_addr,
    output reg  [31:0] mem_rdata,
    input  wire        mem_rstrb,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wmask
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
        if (mem_rstrb)    mem_rdata <= MEM[mem_addr[9:2]];
        if (mem_wmask[0]) MEM[mem_addr[9:2]][ 7: 0] <= mem_wdata[ 7: 0];
        if (mem_wmask[1]) MEM[mem_addr[9:2]][15: 8] <= mem_wdata[15: 8];
        if (mem_wmask[2]) MEM[mem_addr[9:2]][23:16] <= mem_wdata[23:16];
        if (mem_wmask[3]) MEM[mem_addr[9:2]][31:24] <= mem_wdata[31:24];
    end
endmodule
`default_nettype wire
