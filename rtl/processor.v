`default_nettype none
// RV32I processor, part 2: fetch machine, register bank, all ALU-reg and
// ALU-imm instructions, EBREAK halt.
//
// Three-state machine, one instruction every three clk cycles:
//   FETCH_INSTR  mem_rstrb high with mem_addr = PC; the memory returns the
//                word one cycle later (synchronous read).
//   FETCH_REGS   mem_rdata now holds the instruction: the Decoder input muxes
//                it in, the register read ports sample rs1/rs2, and instr,
//                rs1Val, rs2Val are latched on the edge leaving this state.
//   EXECUTE      the ALU (combinational on the latched operands) writes back
//                and PC <= PC + 4. Jumps/branches/loads/stores/LUI/AUIPC are
//                still NOPs that advance PC. isSYSTEM (EBREAK) halts: state
//                and PC stay put.
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
    reg [31:0] instr;
    reg [31:0] rs1Val, rs2Val;

    reg [31:0] RegisterBank [0:31];
    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) RegisterBank[i] = 32'd0;
    end

    // Decoder input: the instruction word arrives from memory during
    // FETCH_REGS; before and after that, the latched copy is used.
    wire [31:0] dec_instr = (state == FETCH_REGS) ? mem_rdata : instr;

    wire isALUreg, isALUimm, isBranch, isJALR, isJAL, isAUIPC, isLUI, isLoad, isStore, isSYSTEM;
    wire [4:0]  rs1Id, rs2Id, rdId;
    wire [2:0]  funct3;
    wire [6:0]  funct7;
    wire [31:0] Iimm, Simm, Bimm, Uimm, Jimm;

    Decoder decoder (
        .instr    (dec_instr),
        .isALUreg (isALUreg),  .isALUimm (isALUimm), .isBranch (isBranch),
        .isJALR   (isJALR),    .isJAL    (isJAL),    .isAUIPC  (isAUIPC),
        .isLUI    (isLUI),     .isLoad   (isLoad),   .isStore  (isStore),
        .isSYSTEM (isSYSTEM),
        .rs1Id    (rs1Id),     .rs2Id    (rs2Id),    .rdId     (rdId),
        .funct3   (funct3),    .funct7   (funct7),
        .Iimm     (Iimm),      .Simm     (Simm),     .Bimm     (Bimm),
        .Uimm     (Uimm),      .Jimm     (Jimm)
    );

    // Part 2 write path: every ALU-reg and ALU-imm instruction. The second
    // operand is rs2 for isALUreg and Iimm for isALUimm. funct7[5] selects
    // SUB only for register ADD and SRA for both shift forms; for the other
    // immediate ops (notably ADDI) instr[30] is an immediate bit and must
    // not reach the ALU.
    wire        useAlu = isALUreg | isALUimm;
    wire [31:0] aluIn2 = isALUreg ? rs2Val : Iimm;
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

    wire        wrEn   = useAlu;
    wire [31:0] wrData = aluOut;

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
                    instr  <= mem_rdata;
                    // Register reads are synchronous (sampled at the edge
                    // leaving FETCH_REGS) so the bank can map to BRAM.
                    rs1Val <= (rs1Id == 5'd0) ? 32'd0 : RegisterBank[rs1Id];
                    rs2Val <= (rs2Id == 5'd0) ? 32'd0 : RegisterBank[rs2Id];
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
                        PC    <= PC + 32'd4;
                        state <= FETCH_INSTR;
                    end
                end
                default: state <= FETCH_INSTR;
            endcase
        end
    end
endmodule
`default_nettype wire
