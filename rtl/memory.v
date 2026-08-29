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

    // ROM program: the hardware demo. Prints "Loop RISC-V\n" over the UART
    // (byte loads from the message at word 22, busy-wait on the status word
    // between bytes), then walks a 1 across LEDS (1,2,4,8,16, restart)
    // forever with a software delay loop. The delay constant is shrunk under
    // `ifdef BENCH so simulations stay fast; on hardware it is 500000
    // iterations x 6 cycles = 3.0M cycles = 0.25 s per step at 12 MHz.
    // tb/soc_tb.v and tb/memory_tb.v keep independent copies of these words.
    `include "../lib/riscv_assembly.v"
    integer WBYTE = 12, WBUSY = 20, LSTEP = 48, WDELAY = 60;
    initial begin
        LUI(x5, 32'h00400000);   // x5 = 0x400000 IO base
        ADDI(x6, x0, 88);        // x6 = &message (byte 88 = word 22)
        ADDI(x7, x0, 12);        // 12 banner bytes
        Label(WBYTE);
        LB(x10, x6, 0);          // x10 = *p
        SW(x10, x5, 8);          // UART data <- char
        Label(WBUSY);
        LW(x8, x5, 16);          // UART status
        ANDI(x8, x8, 512);       // busy = bit 9
        BNE(x8, x0, LabelRef(WBUSY));
        ADDI(x6, x6, 1);         // p++
        ADDI(x7, x7, -1);        // count--
        BNE(x7, x0, LabelRef(WBYTE));
        ADDI(x9, x0, 1);         // LED pattern = 1
        Label(LSTEP);
        SW(x9, x5, 4);           // LEDS <- pattern
`ifdef FAST_SIM
        ADDI(x14, x0, 2);        // ~30 cycles per step in simulation
        ADDI(x14, x14, 0);
`else
        LUI(x14, 32'h0007A000);  // 500000 = 0x7A120 ...
        ADDI(x14, x14, 32'h120); // ... x 6 cycles = 0.25 s per step at 12 MHz
`endif
        Label(WDELAY);
        ADDI(x14, x14, -1);
        BNE(x14, x0, LabelRef(WDELAY));
        ADD(x9, x9, x9);         // pattern <<= 1
        ANDI(x9, x9, 31);        // keep 5 bits
        BNE(x9, x0, LabelRef(LSTEP));
        ADDI(x9, x0, 1);         // restart the walk
        JAL(x0, LabelRef(LSTEP));
        DATAB(8'h4C, 8'h6F, 8'h6F, 8'h70);   // "Loop"
        DATAB(8'h20, 8'h52, 8'h49, 8'h53);   // " RIS"
        DATAB(8'h43, 8'h2D, 8'h56, 8'h0A);   // "C-V\n"
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
