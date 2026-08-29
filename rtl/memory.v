`default_nettype none
// 6 KB word-accessed memory: program ROM and data RAM. mem_addr is a byte
// address; mem_addr[12:2] selects the 32-bit word (1536 words). The read is
// synchronous and gated by mem_rstrb: when the strobe is low, mem_rdata
// holds its previous value. Writes are synchronous with per-byte enables:
// only the lanes whose mem_wmask bit is high take mem_wdata's byte.
module Memory (
    input  wire        clk,
    input  wire [31:0] mem_addr,
    output reg  [31:0] mem_rdata,
    input  wire        mem_rstrb,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wmask
);
    reg [31:0] MEM [0:1535];

    // ROM program: the hardware demo. Prints "Loop RISC-V\n" over the UART
    // (byte loads from the message at word 32, busy-wait on the status word
    // between bytes), then walks a 1 across LEDS exactly once (1,2,4,8,16 —
    // the walk's shift-and-mask wraps the pattern to 0, which ends the loop),
    // then echoes UART input forever: poll the RX word (0x400020), when the
    // avail bit (8) is set write the byte back to the UART data register
    // (busy-wait on status bit 9) and show byte & 31 on the LEDs. Each walk
    // step waits on the RDCYCLE counter: read cycle (CSR 0xC00) once, then
    // loop until the 32-bit-wrap-safe difference now-start reaches DELAY
    // (3 000 000 on hardware = 0.25 s at 12 MHz; a small value under `ifdef
    // FAST_SIM so simulations stay fast). tb/soc_tb.v and tb/memory_tb.v
    // keep independent copies of these words.
    `include "../lib/riscv_assembly.v"
    integer WBYTE = 12, WBUSY = 20, LSTEP = 48, WDELAY = 64, ECHO = 88, EBUSY = 104;
    initial begin
        LUI(x5, 32'h00400000);   // x5 = 0x400000 IO base
        ADDI(x6, x0, 128);       // x6 = &message (byte 128 = word 32)
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
        CSRRS(x14, 12'hC00, x0); // x14 = cycle: start of this step's delay
`ifdef FAST_SIM
        ADDI(x16, x0, 300);      // DELAY = 300 cycles per step in simulation
        ADDI(x16, x16, 0);
`else
        LUI(x16, 32'h002DC);     // 3000000 = 0x2DC6C0 ...
        ADDI(x16, x16, 32'h6C0); // ... cycles = 0.25 s per step at 12 MHz
`endif
        Label(WDELAY);
        CSRRS(x15, 12'hC00, x0); // x15 = cycle now
        SUB(x15, x15, x14);      // x15 = now - start: the difference is
        BLTU(x15, x16, LabelRef(WDELAY)); // wrap-safe; loop while it < DELAY
        ADD(x9, x9, x9);         // pattern <<= 1
        ANDI(x9, x9, 31);        // keep 5 bits
        BNE(x9, x0, LabelRef(LSTEP));  // 5 steps (1,2,4,8,16); 32&31 = 0 ends it
        Label(ECHO);
        LW(x8, x5, 32);          // RX word {23'd0, avail, data}; read clears avail
        ANDI(x11, x8, 256);      // avail = bit 8
        BEQ(x11, x0, LabelRef(ECHO));
        SW(x8, x5, 8);           // UART data <- byte (low 8 bits)
        Label(EBUSY);
        LW(x12, x5, 16);         // UART status
        ANDI(x12, x12, 512);     // busy = bit 9
        BNE(x12, x0, LabelRef(EBUSY));
        ANDI(x13, x8, 31);       // LEDs <- byte & 31
        SW(x13, x5, 4);
        JAL(x0, LabelRef(ECHO));
        DATAB(8'h4C, 8'h6F, 8'h6F, 8'h70);   // "Loop"
        DATAB(8'h20, 8'h52, 8'h49, 8'h53);   // " RIS"
        DATAB(8'h43, 8'h2D, 8'h56, 8'h0A);   // "C-V\n"
        endASM();
    end

    always @(posedge clk) begin
        if (mem_rstrb)    mem_rdata <= MEM[mem_addr[12:2]];
        if (mem_wmask[0]) MEM[mem_addr[12:2]][ 7: 0] <= mem_wdata[ 7: 0];
        if (mem_wmask[1]) MEM[mem_addr[12:2]][15: 8] <= mem_wdata[15: 8];
        if (mem_wmask[2]) MEM[mem_addr[12:2]][23:16] <= mem_wdata[23:16];
        if (mem_wmask[3]) MEM[mem_addr[12:2]][31:24] <= mem_wdata[31:24];
    end
endmodule
`default_nettype wire
