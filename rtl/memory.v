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

    // ROM program: the UART monitor. Sets up the IO base (x5 = 0x400000)
    // and the stack pointer (x2 = 0x1800, one past the top of the 6 KB RAM,
    // growing down), prints "Loop RISC-V\n" over the UART one byte per
    // message word via PUTBYTE, then runs the monitor command loop forever:
    // read a command byte with GETBYTE, dispatch, repeat. Commands (all
    // multi-byte values little-endian 32-bit via GET32/PUT32, which call
    // GETBYTE/PUTBYTE four times through the stack):
    //   'V' (0x56)          -> PUT32 the 4 bytes "RV32"
    //   'W' addr len data.. -> write len bytes to addr (RAM or IO), reply 'K'
    //   'R' addr len        -> send the len bytes read from addr
    //   'G' addr            -> JALR to addr (routine returns with RET; it
    //                          may clobber everything but sp), reply 'K'
    //   anything else       -> reply '?'
    // GETBYTE (leaf) polls the RX word 0x400020 until avail (bit 8) is set
    // and returns the byte in a0; the read clears avail. PUTBYTE (leaf)
    // polls the TX status 0x400010 until busy (bit 9) is low, then writes
    // a0's low byte to 0x400008. GET32/PUT32 assemble/disassemble a word
    // through a scratch slot on their own stack frame (push 8: ra at sp+4,
    // word at sp+0) using SB / LBU — no shifts, no OR. MAIN re-establishes
    // x5 every iteration and the G arm re-establishes it after the call,
    // because a G routine may clobber every register except sp. The program
    // sticks to LW/SW/SB/LBU/ADD/ADDI/ANDI/LUI/BNE/JAL/JALR (no BEQ, no
    // halfword ops, no shifts). tb/soc_tb.v, tb/memory_tb.v,
    // tb/monitor_io_tb.v and tb/monitor_tb.v keep copies / cross-checks of
    // these words.
    `include "../lib/riscv_assembly.v"
    integer WBYTE = 20, MAIN = 40, CHK_W = 72, WLOOP = 96, WBODY = 104,
           WK = 124, CHK_R = 136, RLOOP = 160, RBODY = 168, CHK_G = 188,
           UNK = 224, GET32 = 236, PUT32 = 292, GETBYTE = 348, GBDONE = 364,
           PUTBYTE = 372;
    initial begin
        LUI(x5, 32'h00400000);   // x5 = 0x400000 IO base
        LUI(x2, 32'h2000);       // x2 = 0x2000 (lib LUI takes the FINAL value)
        ADDI(x2, x2, -2048);     // sp = 0x1800: one past the top of RAM
        ADDI(x6, x0, 392);       // x6 = &message (byte 392 = word 98)
        ADDI(x7, x0, 12);        // 12 banner bytes
        Label(WBYTE);
        LW(x10, x6, 0);          // x10 = message word (char in bits [7:0])
        JAL(x1, LabelRef(PUTBYTE)); // blocking write of a0's low byte
        ADDI(x6, x6, 4);         // p++ (one word per char)
        ADDI(x7, x7, -1);        // count--
        BNE(x7, x0, LabelRef(WBYTE));
        Label(MAIN);             // ---- command loop ----
        LUI(x5, 32'h00400000);   // re-establish IO base (G clobbers regs)
        JAL(x1, LabelRef(GETBYTE)); // a0 = command byte
        ADDI(x11, x0, 8'h56);    // 'V'
        BNE(x10, x11, LabelRef(CHK_W));
        LUI(x10, 32'h32335000);  // a0 = "RV32" little-endian:
        ADDI(x10, x10, 32'h652); //   0x32335652 = 'R','V','3','2'
        JAL(x1, LabelRef(PUT32));
        JAL(x0, LabelRef(MAIN));
        Label(CHK_W);
        ADDI(x11, x0, 8'h57);    // 'W'
        BNE(x10, x11, LabelRef(CHK_R));
        JAL(x1, LabelRef(GET32)); // a0 = addr
        ADDI(x9, x10, 0);        // x9 = ptr
        JAL(x1, LabelRef(GET32)); // a0 = len
        ADDI(x14, x10, 0);       // x14 = count
        Label(WLOOP);
        BNE(x14, x0, LabelRef(WBODY));
        JAL(x0, LabelRef(WK));   // count == 0: done, reply K
        Label(WBODY);
        JAL(x1, LabelRef(GETBYTE)); // a0 = data byte
        SB(x10, x9, 0);          // *ptr = byte (RAM or IO space)
        ADDI(x9, x9, 1);         // ptr++
        ADDI(x14, x14, -1);      // count--
        JAL(x0, LabelRef(WLOOP));
        Label(WK);
        ADDI(x10, x0, 8'h4B);    // 'K'
        JAL(x1, LabelRef(PUTBYTE));
        JAL(x0, LabelRef(MAIN));
        Label(CHK_R);
        ADDI(x11, x0, 8'h52);    // 'R'
        BNE(x10, x11, LabelRef(CHK_G));
        JAL(x1, LabelRef(GET32)); // a0 = addr
        ADDI(x9, x10, 0);        // x9 = ptr
        JAL(x1, LabelRef(GET32)); // a0 = len
        ADDI(x14, x10, 0);       // x14 = count
        Label(RLOOP);
        BNE(x14, x0, LabelRef(RBODY));
        JAL(x0, LabelRef(MAIN)); // done (no reply byte)
        Label(RBODY);
        LBU(x10, x9, 0);         // a0 = *ptr (zero-extended byte)
        JAL(x1, LabelRef(PUTBYTE));
        ADDI(x9, x9, 1);         // ptr++
        ADDI(x14, x14, -1);      // count--
        JAL(x0, LabelRef(RLOOP));
        Label(CHK_G);
        ADDI(x11, x0, 8'h47);    // 'G'
        BNE(x10, x11, LabelRef(UNK));
        JAL(x1, LabelRef(GET32)); // a0 = routine address
        ADDI(x9, x10, 0);        // x9 = target
        JALR(x1, x9, 0);         // call it; returns with RET
        LUI(x5, 32'h00400000);   // the routine clobbered x5 (and the rest)
        ADDI(x10, x0, 8'h4B);    // 'K'
        JAL(x1, LabelRef(PUTBYTE));
        JAL(x0, LabelRef(MAIN));
        Label(UNK);
        ADDI(x10, x0, 8'h3F);    // '?'
        JAL(x1, LabelRef(PUTBYTE));
        JAL(x0, LabelRef(MAIN));
        Label(GET32);            // a0 <- 4 UART bytes, little-endian
        ADDI(x2, x2, -8);        // push {ra, scratch word}
        SW(x1, x2, 4);           // save ra at sp+4
        JAL(x1, LabelRef(GETBYTE));
        SB(x10, x2, 0);          // byte 0 -> lane 0 (LSB)
        JAL(x1, LabelRef(GETBYTE));
        SB(x10, x2, 1);          // byte 1 -> lane 1
        JAL(x1, LabelRef(GETBYTE));
        SB(x10, x2, 2);          // byte 2 -> lane 2
        JAL(x1, LabelRef(GETBYTE));
        SB(x10, x2, 3);          // byte 3 -> lane 3 (MSB)
        LW(x10, x2, 0);          // a0 = assembled word
        LW(x1, x2, 4);           // restore ra
        ADDI(x2, x2, 8);         // pop
        JALR(x0, x1, 0);         // RET
        Label(PUT32);            // send a0's 4 bytes, little-endian
        ADDI(x2, x2, -8);        // push {ra, scratch word}
        SW(x1, x2, 4);           // save ra at sp+4
        SW(x10, x2, 0);          // word -> scratch
        LBU(x10, x2, 0);         // byte 0 (LSB)
        JAL(x1, LabelRef(PUTBYTE));
        LBU(x10, x2, 1);         // byte 1
        JAL(x1, LabelRef(PUTBYTE));
        LBU(x10, x2, 2);         // byte 2
        JAL(x1, LabelRef(PUTBYTE));
        LBU(x10, x2, 3);         // byte 3 (MSB)
        JAL(x1, LabelRef(PUTBYTE));
        LW(x1, x2, 4);           // restore ra
        ADDI(x2, x2, 8);         // pop
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
