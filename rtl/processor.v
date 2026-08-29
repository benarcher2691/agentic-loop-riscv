`default_nettype none
// RV32I processor, part 2: fetch machine, register bank, all ALU-reg and
// ALU-imm instructions, EBREAK halt.
//
// Three-state machine, one instruction every three clk cycles:
//   FETCH_INSTR  mem_rstrb high with mem_addr = PC; the memory returns the
//                word one cycle later (synchronous read).
//   FETCH_REGS   mem_rdata now holds the instruction (and keeps holding it
//                through EXECUTE — the memory only updates while the fetch
//                strobe is high): the Decoder decodes it live and the
//                register read ports sample rs1/rs2, latching rs1Val/rs2Val
//                on the edge leaving this state.
//   EXECUTE      the ALU (combinational on the latched operands) writes back
//                and PC <= PC + 4. JAL/JALR write the link PC + 4 and set
//                PC to their target instead. LUI writes Uimm, AUIPC writes
//                PC + Uimm. A load instead asserts the read strobe with the
//                effective address rs1 + Iimm (computed by the ALU's ADD —
//                its funct3 input is forced to 000 for loads) and moves on.
//                A CSR read (CSRRS, rs1 = x0, address 0xC00/0xC80) writes
//                the cycle counter (or 0 for cycleh) to rd and advances.
//                isSYSTEM otherwise (EBREAK, any other SYSTEM encoding)
//                halts: state and PC stay put.
//   LOAD         wait state: the synchronous memory has latched the loaded
//                word into mem_rdata (the strobe is low again, so it holds).
//                The byte/halfword lane comes from the effective address's
//                low bits, latched into ldOff leaving EXECUTE; width and
//                sign/zero extension come from ldFunct3. The decoder cannot
//                be used here — mem_rdata now holds load DATA, not the
//                instruction — so ldActive/ldRd were latched earlier. rd is
//                written, PC <= PC + 4.
//
// x0 always reads 0 (read mux; writes to rd 0 are dropped). The x1 output
// mirrors RegisterBank[1] through a register written on the same edge with
// the same data — an asynchronous read of the register file would stop it
// mapping to block RAM and blow the hx1k logic budget.
module Processor (
    input  wire        clk,
    input  wire        resetn,
    output wire [31:0] mem_addr,
    input  wire [31:0] mem_rdata,
    output wire        mem_rstrb,
    output wire [31:0] mem_wdata,   // store data (lane-replicated, see below)
    output wire [3:0]  mem_wmask,   // byte-write enables, one per memory lane
    output reg  [31:0] x1 = 32'd0   // mirror of RegisterBank[1], starts at 0
);
    localparam [1:0] FETCH_INSTR = 2'd0,
                     FETCH_REGS  = 2'd1,
                     EXECUTE     = 2'd2,
                     LOAD        = 2'd3;

    reg [1:0]  state = FETCH_INSTR;
    reg [31:0] PC    = 32'd0;
    reg [31:0] rs1Val, rs2Val;

    // Free-running 64-bit cycle counter (RV32I RDCYCLE/RDCYCLEH): the pair
    // {cycleh, cycles} increments by 1 every clk, cleared by !resetn. It does
    // not depend on the FSM — it keeps counting through fetches, load waits
    // and the EBREAK halt (wall-clock time; part 2 builds delays on it). The
    // low word is a plain +1; the high word increments only on the clk where
    // the low word rolls over (all ones -> 0), so the carry into the high
    // word is a single AND-reduce, not a 64-bit ripple.
    reg [31:0] cycles = 32'd0;   // RDCYCLE  (CSR 0xC00): low 32 bits
    reg [31:0] cycleh = 32'd0;   // RDCYCLEH (CSR 0xC80): high 32 bits
    wire       cyRoll = &cycles; // low word about to wrap this clk
    always @(posedge clk) begin
        if (!resetn) begin
            cycles <= 32'd0;
            cycleh <= 32'd0;
        end else begin
            cycles <= cycles + 32'd1;
            if (cyRoll) cycleh <= cycleh + 32'd1;
        end
    end

    // Load bookkeeping, latched while the decoder still sees the instruction
    // (mem_rdata is clobbered by the load data during the LOAD state).
    reg        ldActive;   // instruction in flight is a load
    reg [2:0]  ldFunct3;   // width / signedness selector
    reg [4:0]  ldRd;       // destination register
    reg [1:0]  ldOff;      // byte lane within the word, from the eff. address

    reg [31:0] RegisterBank [0:31];
    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) RegisterBank[i] = 32'd0;
    end

    // Decoder input: the memory's synchronous read only updates while the
    // fetch strobe is high, so mem_rdata holds the instruction word through
    // FETCH_REGS and EXECUTE — no separate instruction register needed.
    wire isALUreg, isALUimm, isBranch, isJALR, isJAL, isAUIPC, isLUI, isLoad, isStore, isSYSTEM;
    wire [4:0]  rs1Id, rs2Id, rdId;
    wire [2:0]  funct3;
    wire [6:0]  funct7;
    wire [31:0] Iimm, Simm, Bimm, Uimm, Jimm;

    Decoder decoder (
        .instr    (mem_rdata),
        .isALUreg (isALUreg),  .isALUimm (isALUimm), .isBranch (isBranch),
        .isJALR   (isJALR),    .isJAL    (isJAL),    .isAUIPC  (isAUIPC),
        .isLUI    (isLUI),     .isLoad   (isLoad),   .isStore  (isStore),
        .isSYSTEM (isSYSTEM),
        .rs1Id    (rs1Id),     .rs2Id    (rs2Id),    .rdId     (rdId),
        .funct3   (funct3),    .funct7   (funct7),
        .Iimm     (Iimm),      .Simm     (Simm),     .Bimm     (Bimm),
        .Uimm     (Uimm),      .Jimm     (Jimm)
    );

    // Part 3 write path: JAL/JALR write the link address PC + 4 and
    // redirect the PC. JAL adds Jimm; JALR adds Iimm to the latched rs1
    // value and clears bit 0 as the spec requires. funct7[5] selects SUB
    // only for register ADD and SRA for both shift forms; for the other
    // immediate ops (notably ADDI) instr[30] is an immediate bit and must
    // not reach the ALU.
    wire        doJump  = isJAL | isJALR;
    // CSR read: CSRRS (funct3 = 010) with rs1 = x0 and the CSR address
    // (Iimm[11:0]) 0xC00 (cycle) or 0xC80 (cycleh). The value is written to
    // rd and the PC advances like any other instruction; every other SYSTEM
    // encoding — EBREAK, CSRRW/CSRRC, CSRRS with rs1 != 0 or any other
    // address — still halts (isSYSTEM && !isCSRread in EXECUTE).
    // CSR address pattern: 0xC00/0xC80 differ only in Iimm[7], so the other
    // 11 bits are checked once and Iimm[7] then selects the high half.
    wire isCSRaddr = (Iimm[11:8] == 4'hC) & (Iimm[6:0] == 7'd0);
    wire isCSRread = isSYSTEM & (funct3 == 3'b010) & (rs1Id == 5'd0) & isCSRaddr;
    // 0xC00 -> low word (cycles), 0xC80 -> high word (cycleh). One 32-bit
    // mux; only meaningful when isCSRread gates it into the writeback below.
    wire [31:0] csrData = Iimm[7] ? cycleh : cycles;
    // Branches compare rs1 vs rs2 through the ALU's dedicated compare
    // outputs (funct3-independent); funct3 only picks which comparison
    // decides the branch. The second ALU operand is therefore rs2 for
    // branches as well — Iimm would corrupt the compare.
    wire        useAlu = isALUreg | isALUimm;
    // AUIPC and LUI both run through the ALU (in1 = PC resp. 0, in2 =
    // Uimm, funct3 forced to ADD) so the separate PC+immediate adder only
    // serves JAL/branch targets, which use 13 bits — see below, and the
    // writeback mux has no Uimm arm (LUI's 0 + Uimm = Uimm falls through
    // to aluOut). Branches compare rs2, stores add Simm, everything else
    // adds Iimm.
    wire [31:0] aluIn1 = isAUIPC ? PC : isLUI ? 32'b0 : rs1Val;
    // ALU operand 2 is a 4-way priority mux (Uimm / rs2Val / Simm / Iimm),
    // but the immediate forms coincide above bit 4: Simm and Iimm are both
    // {20{instr[31]}} down to bit 12 and share instr[31:25] in bits [11:5],
    // and Uimm is zero in [11:0]. So [31:12] is a 3-way mux, [11:5] a
    // 3-way with a constant arm, and only [4:0] needs all four data arms
    // (pre-muxed: isStore ? Simm : Iimm). Every slice is then a <=5-input
    // function — 1-2 LUT4 per bit instead of the 3 a full 7-input 4-way
    // mux costs.
    wire        in2UL = isAUIPC | isLUI;
    wire        in2RB = isALUreg | isBranch;
    wire [4:0]  in2Lo = isStore ? Simm[4:0] : Iimm[4:0];
    reg [19:0]  in2Hi;
    reg [6:0]   in2Mid;
    reg [4:0]   in2LoS;
    always @(*) begin
      // 2-bit case: at most 3 data arms per slice, so each output bit is
      // a <=5-input function (abc maps 2-bit cases at 1-2 LUT4/bit; the
      // 3-select 4-way form cost 3).
      case ({in2UL, in2RB})
        2'b00:   begin in2Hi  = Iimm[31:12];  in2Mid = Iimm[11:5];
                       in2LoS = in2Lo;                            end
        2'b01:   begin in2Hi  = rs2Val[31:12]; in2Mid = rs2Val[11:5];
                       in2LoS = rs2Val[4:0];                     end
        default: begin in2Hi  = Uimm[31:12];  in2Mid = 7'b0;
                       in2LoS = 5'b0;                            end
      endcase
    end
    wire [31:0] aluIn2 = {in2Hi, in2Mid, in2LoS};
    wire        aluF75 = isALUreg ? funct7[5] :
                         (isALUimm && funct3 == 3'b101) ? funct7[5] : 1'b0;

    wire [31:0] aluOut;
    wire        aluEQ, aluLT, aluLTU;   // EQ/LT/LTU: used by branches later
    // Loads, stores, AUIPC and LUI reuse the ALU's adder (funct3 forced
    // to 000 with aluF75 already 0 for all four): aluOut is then the
    // effective address rs1 + Iimm (loads), rs1 + Simm (stores), PC +
    // Uimm (AUIPC) or Uimm (LUI, in1 forced to 0). EQ/LT/LTU do not
    // depend on funct3, so branches are unaffected.
    wire [2:0]  aluFunct3 = (isLoad | isStore | isAUIPC | isLUI) ? 3'b000 : funct3;
    ALU alu (
        .in1      (aluIn1),
        .in2      (aluIn2),
        .funct3   (aluFunct3),
        .funct7_5 (aluF75),
        // The ALU shares one add/sub unit, so its EQ/LT/LTU are defined only
        // while it subtracts. A branch's funct3 does not select subtraction
        // (BEQ is 000, like ADD), so branches assert cmp to force it. SUB,
        // SLT and SLTU subtract from their own funct3 and need no cmp.
        .cmp      (isBranch),
        .out      (aluOut),
        .EQ       (aluEQ),
        .LT       (aluLT),
        .LTU      (aluLTU)
    );

    // Sequential PC arithmetic is 13-bit: the memory is 6 KB, so only
    // PC[12:0] is ever architecturally visible (PC is stored 32-bit with
    // high zeros — the benches read it as a 32-bit value). This keeps the
    // +4 adder and the next-PC mux at 13 bits; the JAL/JALR link (also
    // PC + 4) shares the same 13-bit sum, zero-extended.
    wire [12:0] pc13    = PC[12:0];
    wire [12:0] pcPlus4 = pc13 + 13'd4;

    // One shared PC+immediate adder serves JAL's target and the branch
    // target — the two classes are mutually exclusive, so a mux in front
    // of the adder picks the immediate. AUIPC now goes through the ALU
    // (see aluIn1/aluIn2 above), which lets this adder stay narrow:
    // JAL/branch targets only use the low 13 bits (6 KB memory), and the
    // PC update below always took the sum's low bits anyway. JALR reuses
    // the ALU's ADD (its funct3 is 000 and aluIn2 is Iimm) and clears
    // bit 0.
    wire [12:0] pcImm13      = isJAL ? Jimm[12:0] : Bimm[12:0];
    wire [12:0] pcPlusImm13  = pc13 + pcImm13;
    wire [31:0] jumpTarget   = isJAL ? {19'b0, pcPlusImm13}
                                     : (aluOut & ~32'h00000001);

    wire        wrEn   = useAlu | doJump | isLUI | isAUIPC | isCSRread;
    // Byte/halfword selection of the loaded word. The lane comes from
    // ldOff (latched effective address bits [1:0]), the width from
    // ldFunct3: 000 LB, 001 LH, 010 LW, 100 LBU, 101 LHU. ldByte is the
    // addressed byte, ldHiByte its neighbour above (only needed for
    // halfword loads, which are required only at offsets 0/2). The result
    // is built directly inside the wrData mux below so the load arms share
    // the writeback mux tree instead of adding a second one.
    wire ldState = (state == LOAD);
    // The addressed halfword (loads are only required at even offsets, so
    // no byte swap is needed) and the addressed byte. ldHiByte is just the
    // upper half of half — pure wiring.
    wire [15:0] half     = ldOff[1] ? mem_rdata[31:16] : mem_rdata[15:0];
    wire [7:0]  ldByte   = ldOff[1] ? (ldOff[0] ? mem_rdata[31:24]
                                                : mem_rdata[23:16])
                                    : (ldOff[0] ? mem_rdata[15:8]
                                                : mem_rdata[7:0]);
    wire [7:0]  ldHiByte = half[15:8];
    // Width / sign-extension of the loaded word: 000 LB, 001 LH, 010 LW,
    // 100 LBU, 101 LHU. Three data arms (word / half / byte) shared by the
    // signed/unsigned pairs: ldFunct3[2] picks zero- vs sign-fill (one bit
    // mux feeding the replication wiring) instead of separate arms per
    // load type.
    wire        ldZero = ldFunct3[2];                       // LBU/LHU fill
    wire [7:0]  ldTop  = ldFunct3[0] ? ldHiByte : ldByte;   // unit's top byte
    wire        ldFill = ldZero ? 1'b0 : ldTop[7];
    wire [31:0] ldExt  = (ldFunct3 == 3'b010) ? mem_rdata : // LW: as-is
                         ldFunct3[0] ?
                         {{16{ldFill}}, half} :              // LH/LHU
                         {{24{ldFill}}, ldByte};             // LB/LBU
    // LUI's Uimm now comes from the ALU (in1 = 0, in2 = Uimm — see
    // aluIn1/aluIn2 above), so it falls through to aluOut with no
    // dedicated arm. AUIPC's PC + Uimm comes from the ALU the same way
    // (in1 = PC; PC still holds this instruction's address during
    // EXECUTE). Jumps write the link address PC + 4; a load in the LOAD
    // state writes its extended data; everything else comes from the ALU.
    // The load arms live inside this one mux so the writeback tree is
    // shared. The ldState arm MUST come first: during LOAD mem_rdata
    // holds load data, not an instruction, so the decoder outputs
    // (doJump/isLUI/isAUIPC) are garbage — a loaded 0xDEADBEEF decodes as
    // JAL and would otherwise write back PC + 4 instead of the data.
    // CSR reads are OR-ed into the ALU arm instead of adding a mux arm:
    // during a CSR read the ALU output is provably 0 — in1 = rs1Val =
    // RegisterBank[0] = 0, in2 = Iimm = 0xFFFFFC00/0xFFFFFC80 (negative),
    // funct3 = SLT, and 0 < negative is false — so aluOut | csrVal = csrVal.
    // For every other instruction isCSRread is 0 and csrVal is 0, so the OR
    // is the identity. csrVal picks the requested 64-bit half (0xC00 low,
    // 0xC80 high) gated by isCSRread; each bit is a single 4-input function
    // (isCSRread, Iimm[7], cycleh[i], cycles[i]).
    wire [31:0] csrVal = {32{isCSRread}} & csrData;
    wire [31:0] wbAlu  = aluOut | csrVal;   // ALU result or the CSR read
    // Writeback: load data in LOAD, else the JAL/JALR link (PC+4, low 13
    // bits) for jumps, else the ALU/CSR arm. Above bit 13 the link is 0, so
    // that mux collapses to ~doJump & wbAlu there.
    wire [31:0] wrData = ldState ? ldExt :
                         doJump  ? {19'b0, pcPlus4} : wbAlu;
    // One register-file write port for both writeback states: the decoder
    // is only valid in EXECUTE, the latched load bookkeeping in LOAD.
    wire        doWrite = ldState ? ldActive : wrEn;
    wire [4:0]  wrReg   = ldState ? ldRd     : rdId;

    // During EXECUTE of a load the memory port reads the data address
    // instead of the PC; the LOAD state drops the strobe so mem_rdata
    // keeps holding the loaded word. During EXECUTE of a store the same
    // address mux carries the store target; the write is committed by the
    // memory on the edge that leaves EXECUTE, so stores need no wait
    // state. The fetch side only needs the 13-bit PC. Loads/stores
    // present the effective address, of which only 14 bits are consumed:
    // bit 22 (the SOC's IO-space select) and bits [12:0] (the 6 KB RAM
    // word index [12:2] plus the IO word-offset bits [5:2]) — bits
    // [21:13] drive nothing, so the mux is 14 bits wide, not 23.
    wire loadRead   = isLoad & (state == EXECUTE);
    wire storeWrite = isStore & (state == EXECUTE);
    assign mem_addr  = (loadRead | storeWrite)
                                ? {9'b0, aluOut[22], 9'b0, aluOut[12:0]}
                                : {19'b0, pc13};
    assign mem_rstrb = (state == FETCH_INSTR) | loadRead;

    // Store data and byte enables. The addressed lane is selected by the
    // memory's wmask, so the data word simply replicates the stored unit
    // across all four lanes (pure wiring): SB repeats its byte, SH its
    // halfword, SW uses the register as-is. The lane comes from the
    // effective address bits [1:0] (aluOut during EXECUTE), the width from
    // funct3: 000 SB, 001 SH, 010 SW.
    wire [31:0] stData = (funct3 == 3'b000) ? {4{rs2Val[7:0]}}  :  // SB
                         (funct3 == 3'b001) ? {2{rs2Val[15:0]}} :  // SH
                                              rs2Val;              // SW
    reg  [3:0]  stMask;
    always @(*) begin
      case (funct3)
        3'b000: begin                                   // SB: one byte
          case (aluOut[1:0])
            2'd0:    stMask = 4'b0001;
            2'd1:    stMask = 4'b0010;
            2'd2:    stMask = 4'b0100;
            default: stMask = 4'b1000;
          endcase
        end
        3'b001:   stMask = aluOut[1] ? 4'b1100 : 4'b0011;  // SH: two bytes
        default:  stMask = 4'b1111;                        // SW: whole word
      endcase
    end
    assign mem_wdata = stData;
    assign mem_wmask = storeWrite ? stMask : 4'b0000;

    // Branch condition: funct3 selects among the ALU's EQ/LT/LTU and their
    // complements (BGE/BNE/BGEU). Branches write no rd — isBranch stays out
    // of wrEn — they only redirect the PC.
    reg branchCond;
    always @(*) begin
      case (funct3)
        3'b000:  branchCond = aluEQ;     // BEQ
        3'b001:  branchCond = ~aluEQ;    // BNE
        3'b100:  branchCond = aluLT;     // BLT
        3'b101:  branchCond = ~aluLT;    // BGE
        3'b110:  branchCond = aluLTU;    // BLTU
        3'b111:  branchCond = ~aluLTU;   // BGEU
        default: branchCond = 1'b0;
      endcase
    end
    wire        doBranch     = isBranch & branchCond;
    // Bench-visible alias of the shared adder's result (pure wiring; the
    // 13-bit sum zero-extended — benches only check small positive targets).
    wire [31:0] branchTarget = {19'b0, pcPlusImm13};

    always @(posedge clk) begin
        if (!resetn) begin
            state <= FETCH_INSTR;
            PC    <= 32'd0;
        end else begin
            case (state)
                FETCH_INSTR: begin
                    state <= FETCH_REGS;
                end
                FETCH_REGS: begin
                    // Register reads are synchronous (sampled at the edge
                    // leaving FETCH_REGS) so the bank can map to BRAM.
                    // No x0 read mux needed: RegisterBank[0] is initialised
                    // to 0 and writes to rd 0 are dropped below, so it can
                    // only ever read as 0.
                    rs1Val <= RegisterBank[rs1Id];
                    rs2Val <= RegisterBank[rs2Id];
                    // Load bookkeeping: the decoder is still valid here,
                    // but mem_rdata will hold load data during LOAD.
                    ldActive <= isLoad;
                    ldFunct3 <= funct3;
                    ldRd     <= rdId;
                    state    <= EXECUTE;
                end
                EXECUTE: begin
                    if (isSYSTEM && !isCSRread) begin
                        // EBREAK and every non-CSR-read SYSTEM encoding:
                        // halt — state and PC stay put.
                    end else if (isLoad) begin
                        // Read strobe and data address are already driven
                        // combinationally; remember the byte lane and wait
                        // one cycle for the synchronous memory.
                        ldOff <= aluOut[1:0];
                        state <= LOAD;
                    end else begin
                        if (doWrite && wrReg != 5'd0)
                            RegisterBank[wrReg] <= wrData;
                        if (doWrite && wrReg == 5'd1)
                            x1 <= wrData;      // mirror of RegisterBank[1]
                        PC    <= doJump    ? {19'b0, jumpTarget[12:0]} :
                                 doBranch  ? {19'b0, pcPlusImm13} :
                                             {19'b0, pcPlus4};
                        state <= FETCH_INSTR;
                    end
                end
                LOAD: begin
                    // Write back the extended load data (lane/width from the
                    // latched bookkeeping — the decoder sees data now) via
                    // the shared write port, then resume fetching. PC still
                    // holds this instruction's own address.
                    if (doWrite && wrReg != 5'd0)
                        RegisterBank[wrReg] <= wrData;
                    if (doWrite && wrReg == 5'd1)
                        x1 <= wrData;      // mirror of RegisterBank[1]
                    PC    <= {19'b0, pcPlus4};
                    state <= FETCH_INSTR;
                end
                default: state <= FETCH_INSTR;
            endcase
        end
    end
endmodule
`default_nettype wire
