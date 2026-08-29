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

    // ROM program: the hardware demo / monitor front end. Sets up the IO
    // base (x5 = 0x400000) and the stack pointer (x2 = 0x1800, one past the
    // top of the 6 KB RAM, growing down; the monitor's code will live low),
    // prints "Loop RISC-V\n" over the UART one byte per message word via
    // PUTBYTE, then calls ECHO2 forever. ECHO2 is a non-leaf subroutine: it
    // pushes ra (x1) at sp-4, reads one byte with GETBYTE (blocking poll of
    // the RX word 0x400020 until avail bit 8; the read clears avail), calls
    // PUTBYTE twice — once with the byte, once with byte+1 — restores ra and
    // sp, and returns. PUTBYTE polls the TX status 0x400010 until busy
    // (bit 9) is low, then writes the byte to the UART data register
    // 0x400008 (the SOC takes bits [7:0]). GETBYTE and PUTBYTE are leaves:
    // no calls, so they skip the push/pop. The program deliberately sticks
    // to LW/SW/ADDI/ANDI/BNE/JAL/JALR/LUI (no LB/BEQ): with the constant ROM
    // the flattened netlist then prunes the byte-lane load logic and the
    // branch-condition mux, which is what keeps the part under the LC
    // budget. tb/soc_tb.v, tb/memory_tb.v and tb/monitor_io_tb.v keep
    // copies / cross-checks of these words.
    `include "../lib/riscv_assembly.v"
    integer WBYTE = 20, MAIN = 40, ECHO2 = 48, GETBYTE = 84, GBDONE = 100, PUTBYTE = 108;
    initial begin
        LUI(x5, 32'h00400000);   // x5 = 0x400000 IO base
        LUI(x2, 32'h2000);       // x2 = 0x2000 (lib LUI takes the FINAL value)
        ADDI(x2, x2, -2048);     // sp = 0x1800: one past the top of RAM
        ADDI(x6, x0, 128);       // x6 = &message (byte 128 = word 32)
        ADDI(x7, x0, 12);        // 12 banner bytes
        Label(WBYTE);
        LW(x10, x6, 0);          // x10 = message word (char in bits [7:0])
        JAL(x1, LabelRef(PUTBYTE)); // blocking write of a0's low byte
        ADDI(x6, x6, 4);         // p++ (one word per char)
        ADDI(x7, x7, -1);        // count--
        BNE(x7, x0, LabelRef(WBYTE));
        Label(MAIN);
        JAL(x1, LabelRef(ECHO2)); // ra = 44 (the J below); call ECHO2
        JAL(x0, LabelRef(MAIN));  // forever
        Label(ECHO2);
        ADDI(x2, x2, -4);        // push: sp -= 4
        SW(x1, x2, 0);           // save ra
        JAL(x1, LabelRef(GETBYTE));  // a0 = one byte (blocking)
        JAL(x1, LabelRef(PUTBYTE));  // echo it
        ADDI(x10, x10, 1);       // a0 = byte + 1
        JAL(x1, LabelRef(PUTBYTE));  // echo it again (nested call #2)
        LW(x1, x2, 0);           // restore ra
        ADDI(x2, x2, 4);         // pop: sp += 4
        JALR(x0, x1, 0);         // RET
        Label(GETBYTE);          // leaf: a0 = blocking RX byte
        LW(x10, x5, 32);         // RX word {23'd0, avail, data}; read clears avail
        ANDI(x11, x10, 256);     // avail = bit 8
        BNE(x11, x0, LabelRef(GBDONE));
        JAL(x0, LabelRef(GETBYTE));
        Label(GBDONE);
        ANDI(x10, x10, 255);     // a0 = byte (bits [7:0])
        JALR(x0, x1, 0);         // RET
        Label(PUTBYTE);          // leaf: blocking TX of a0's low byte
        LW(x11, x5, 16);         // UART status
        ANDI(x11, x11, 512);     // busy = bit 9
        BNE(x11, x0, LabelRef(PUTBYTE));
        SW(x10, x5, 8);          // UART data <- a0 (SOC takes bits [7:0])
        JALR(x0, x1, 0);         // RET
        DATAB(8'h4C, 8'h00, 8'h00, 8'h00);   // 'L'
        DATAB(8'h6F, 8'h00, 8'h00, 8'h00);   // 'o'
        DATAB(8'h6F, 8'h00, 8'h00, 8'h00);   // 'o'
        DATAB(8'h70, 8'h00, 8'h00, 8'h00);   // 'p'
        DATAB(8'h20, 8'h00, 8'h00, 8'h00);   // ' '
        DATAB(8'h52, 8'h00, 8'h00, 8'h00);   // 'R'
        DATAB(8'h49, 8'h00, 8'h00, 8'h00);   // 'I'
        DATAB(8'h53, 8'h00, 8'h00, 8'h00);   // 'S'
        DATAB(8'h43, 8'h00, 8'h00, 8'h00);   // 'C'
        DATAB(8'h2D, 8'h00, 8'h00, 8'h00);   // '-'
        DATAB(8'h56, 8'h00, 8'h00, 8'h00);   // 'V'
        DATAB(8'h0A, 8'h00, 8'h00, 8'h00);   // '\n'
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
