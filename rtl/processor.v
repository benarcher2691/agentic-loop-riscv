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
//                isSYSTEM (EBREAK) halts: state and PC stay put.
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
    // Branches compare rs1 vs rs2 through the ALU's dedicated compare
    // outputs (funct3-independent); funct3 only picks which comparison
    // decides the branch. The second ALU operand is therefore rs2 for
    // branches as well — Iimm would corrupt the compare.
    wire        useAlu = isALUreg | isALUimm;
    // Stores add their Simm (not Iimm) through the same ALU adder; branches
    // compare rs2, everything else adds Iimm.
    wire [31:0] aluIn2 = (isALUreg | isBranch) ? rs2Val :
                         isStore            ? Simm  : Iimm;
    wire        aluF75 = isALUreg ? funct7[5] :
                         (isALUimm && funct3 == 3'b101) ? funct7[5] : 1'b0;

    wire [31:0] aluOut;
    wire        aluEQ, aluLT, aluLTU;   // EQ/LT/LTU: used by branches later
    // Loads and stores reuse the ALU's adder as the effective-address
    // adder: forcing funct3 to 000 (with aluF75 already 0 for both) makes
    // aluOut the rs1 + immediate address. EQ/LT/LTU do not depend on
    // funct3, so branches are unaffected.
    wire [2:0]  aluFunct3 = (isLoad | isStore) ? 3'b000 : funct3;
    ALU alu (
        .in1      (rs1Val),
        .in2      (aluIn2),
        .funct3   (aluFunct3),
        .funct7_5 (aluF75),
        .out      (aluOut),
        .EQ       (aluEQ),
        .LT       (aluLT),
        .LTU      (aluLTU)
    );

// One shared PC+immediate adder serves JAL's target, AUIPC's writeback
    // and the branch target — the three classes are mutually exclusive, so
    // a mux in front of the adder picks the immediate. JALR reuses the
    // ALU's ADD (its funct3 is 000 and aluIn2 is Iimm) and clears bit 0.
    // The adder stays 32-bit because AUIPC writes the full PC + Uimm to
    // rd; JAL/branch targets only use the low 10 bits (1 KB memory).
    wire [31:0] pcImm      = isJAL ? Jimm : isAUIPC ? Uimm : Bimm;
    wire [31:0] pcPlusImm  = PC + pcImm;
    wire [31:0] jumpTarget = isJAL ? pcPlusImm : (aluOut & ~32'h00000001);

    // Sequential PC arithmetic is 10-bit: the memory is 1 KB, so only
    // PC[9:0] is ever architecturally visible (PC is stored 32-bit with
    // high zeros — the benches read it as a 32-bit value). This keeps the
    // +4 adder and the next-PC mux at 10 bits; the JAL/JALR link (also
    // PC + 4) shares the same 10-bit sum, zero-extended.
    wire [9:0] pc10    = PC[9:0];
    wire [9:0] pcPlus4 = pc10 + 10'd4;

    wire        wrEn   = useAlu | doJump | isLUI | isAUIPC;
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
    // 100 LBU, 101 LHU. Built as one parallel mux so the writeback tree
    // stays shallow.
    reg [31:0] ldExt;
    always @(*) begin
      case (ldFunct3)
        3'b000:  ldExt = {{24{ldByte[7]}},  ldByte};            // LB
        3'b001:  ldExt = {{16{ldHiByte[7]}}, half};             // LH
        3'b100:  ldExt = {24'b0, ldByte};                       // LBU
        3'b101:  ldExt = {16'b0, half};                         // LHU
        default: ldExt = mem_rdata;                             // LW
      endcase
    end
    // LUI writes the immediate itself; AUIPC writes PC + Uimm (PC still
    // holds this instruction's address during EXECUTE). Jumps write the
    // link address PC + 4; a load in the LOAD state writes its extended
    // data; everything else comes from the ALU. The load arms live inside
    // this one mux so the writeback tree is shared. The ldState arm MUST
    // come first: during LOAD mem_rdata holds load data, not an
    // instruction, so the decoder outputs (doJump/isLUI/isAUIPC) are
    // garbage — a loaded 0xDEADBEEF decodes as JAL and would otherwise
    // write back PC + 4 instead of the data.
    wire [31:0] wrData = ldState ? ldExt :
                         doJump  ? {22'b0, pcPlus4} :
                         isLUI   ? Uimm :
                         isAUIPC ? pcPlusImm :
                                   aluOut;
    // One register-file write port for both writeback states: the decoder
    // is only valid in EXECUTE, the latched load bookkeeping in LOAD.
    wire        doWrite = ldState ? ldActive : wrEn;
    wire [4:0]  wrReg   = ldState ? ldRd     : rdId;

    // During EXECUTE of a load the memory port reads the data address
    // instead of the PC; the LOAD state drops the strobe so mem_rdata
    // keeps holding the loaded word. During EXECUTE of a store the same
    // address mux carries the store target; the write is committed by the
    // memory on the edge that leaves EXECUTE, so stores need no wait
    // state. Only the low 10 address bits reach the memory (1 KB), so the
    // fetch/load/store mux is 10-bit, not 32.
    wire loadRead   = isLoad & (state == EXECUTE);
    wire storeWrite = isStore & (state == EXECUTE);
    assign mem_addr  = (loadRead | storeWrite) ? {22'b0, aluOut[9:0]}
                                               : {22'b0, pc10};
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
    // Bench-visible aliases of the shared adder's result (pure wiring).
    wire [31:0] branchTarget = pcPlusImm;

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
                    if (isSYSTEM) begin
                        // EBREAK: halt — state and PC stay put.
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
                        PC    <= doJump    ? {22'b0, jumpTarget[9:0]} :
                                 doBranch  ? {22'b0, pcPlusImm[9:0]} :
                                             {22'b0, pcPlus4};
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
                    PC    <= {22'b0, pcPlus4};
                    state <= FETCH_INSTR;
                end
                default: state <= FETCH_INSTR;
            endcase
        end
    end
endmodule
`default_nettype wire
