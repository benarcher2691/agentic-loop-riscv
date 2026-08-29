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
//                PC + Uimm. Branches/loads/stores are still NOPs that
//                advance PC. isSYSTEM (EBREAK) halts: state and PC stay put.
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
    output reg  [31:0] x1 = 32'd0   // mirror of RegisterBank[1], starts at 0
);
    localparam [1:0] FETCH_INSTR = 2'd0,
                     FETCH_REGS  = 2'd1,
                     EXECUTE     = 2'd2;

    reg [1:0]  state = FETCH_INSTR;
    reg [31:0] PC    = 32'd0;
    reg [31:0] rs1Val, rs2Val;

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
    wire [31:0] aluIn2 = (isALUreg | isBranch) ? rs2Val : Iimm;
    wire        aluF75 = isALUreg ? funct7[5] :
                         (isALUimm && funct3 == 3'b101) ? funct7[5] : 1'b0;

    wire [31:0] aluOut;
    wire        aluEQ, aluLT, aluLTU;   // EQ/LT/LTU: used by branches later
    ALU alu (
        .in1      (rs1Val),
        .in2      (aluIn2),
        .funct3   (funct3),
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
    wire [31:0] pcImm      = isJAL ? Jimm : isAUIPC ? Uimm : Bimm;
    wire [31:0] pcPlusImm  = PC + pcImm;
    wire [31:0] jumpTarget = isJAL ? pcPlusImm : (aluOut & ~32'h00000001);

    wire        wrEn   = useAlu | doJump | isLUI | isAUIPC;
    // LUI writes the immediate itself; AUIPC writes PC + Uimm (PC still
    // holds this instruction's address during EXECUTE). Jumps write the
    // link address PC + 4; everything else comes from the ALU.
    wire [31:0] wrData = doJump  ? (PC + 32'd4) :
                         isLUI   ? Uimm :
                         isAUIPC ? pcPlusImm :
                                   aluOut;

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

    assign mem_addr  = PC;
    assign mem_rstrb = (state == FETCH_INSTR);

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
                    state  <= EXECUTE;
                end
                EXECUTE: begin
                    if (isSYSTEM) begin
                        // EBREAK: halt — state and PC stay put.
                    end else begin
                        if (wrEn && rdId != 5'd0)
                            RegisterBank[rdId] <= wrData;
                        if (wrEn && rdId == 5'd1)
                            x1 <= wrData;      // mirror of RegisterBank[1]
                        PC    <= doJump    ? jumpTarget :
                                 doBranch  ? pcPlusImm :
                                             (PC + 32'd4);
                        state <= FETCH_INSTR;
                    end
                end
                default: state <= FETCH_INSTR;
            endcase
        end
    end
endmodule
`default_nettype wire
