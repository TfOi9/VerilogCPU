`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32im_decoder (
    input  wire [31:0] instruction_i,

    output reg         legal_o,
    output reg  [`RV32_OP_WIDTH-1:0] op_o,
    output reg  [`RV32_CLASS_WIDTH-1:0] class_o,
    output reg  [4:0]  rd_o,
    output reg  [4:0]  rs1_o,
    output reg  [4:0]  rs2_o,
    output reg         uses_rs1_o,
    output reg         uses_rs2_o,
    output reg         writes_rd_o,
    output reg  [31:0] immediate_o,
    output reg  [`RV32_MEMORY_WIDTH-1:0] memory_width_o,
    output reg         load_unsigned_o,
    output reg         serialize_o
);

    wire [6:0] opcode;
    wire [2:0] funct3;
    wire [6:0] funct7;

    assign opcode = instruction_i[6:0];
    assign funct3 = instruction_i[14:12];
    assign funct7 = instruction_i[31:25];

    always @* begin
        legal_o         = 1'b0;
        op_o            = `RV32_OP_INVALID;
        class_o         = `RV32_CLASS_INVALID;
        rd_o            = 5'd0;
        rs1_o           = 5'd0;
        rs2_o           = 5'd0;
        uses_rs1_o      = 1'b0;
        uses_rs2_o      = 1'b0;
        writes_rd_o     = 1'b0;
        immediate_o     = 32'd0;
        memory_width_o  = `RV32_MEMORY_NONE;
        load_unsigned_o = 1'b0;
        serialize_o     = 1'b0;

        if (instruction_i == 32'h0ff00513) begin
            legal_o = 1'b1;
            op_o    = `RV32_OP_HALT;
            class_o = `RV32_CLASS_HALT;
        end else begin
            case (opcode)
                7'b0110111: begin
                    legal_o     = 1'b1;
                    op_o        = `RV32_OP_LUI;
                    class_o     = `RV32_CLASS_INT;
                    rd_o        = instruction_i[11:7];
                    writes_rd_o = instruction_i[11:7] != 5'd0;
                    immediate_o = {instruction_i[31:12], 12'd0};
                end

                7'b0010111: begin
                    legal_o     = 1'b1;
                    op_o        = `RV32_OP_AUIPC;
                    class_o     = `RV32_CLASS_INT;
                    rd_o        = instruction_i[11:7];
                    writes_rd_o = instruction_i[11:7] != 5'd0;
                    immediate_o = {instruction_i[31:12], 12'd0};
                end

                7'b1101111: begin
                    legal_o     = 1'b1;
                    op_o        = `RV32_OP_JAL;
                    class_o     = `RV32_CLASS_JUMP;
                    rd_o        = instruction_i[11:7];
                    writes_rd_o = instruction_i[11:7] != 5'd0;
                    immediate_o = {
                        {11{instruction_i[31]}},
                        instruction_i[31],
                        instruction_i[19:12],
                        instruction_i[20],
                        instruction_i[30:21],
                        1'b0
                    };
                end

                7'b1100111: begin
                    if (funct3 == 3'b000) begin
                        legal_o     = 1'b1;
                        op_o        = `RV32_OP_JALR;
                        class_o     = `RV32_CLASS_JUMP;
                        rd_o        = instruction_i[11:7];
                        rs1_o       = instruction_i[19:15];
                        uses_rs1_o  = 1'b1;
                        writes_rd_o = instruction_i[11:7] != 5'd0;
                        immediate_o = {
                            {20{instruction_i[31]}}, instruction_i[31:20]
                        };
                    end
                end

                7'b1100011: begin
                    case (funct3)
                        3'b000: op_o = `RV32_OP_BEQ;
                        3'b001: op_o = `RV32_OP_BNE;
                        3'b100: op_o = `RV32_OP_BLT;
                        3'b101: op_o = `RV32_OP_BGE;
                        3'b110: op_o = `RV32_OP_BLTU;
                        3'b111: op_o = `RV32_OP_BGEU;
                        default: op_o = `RV32_OP_INVALID;
                    endcase

                    if (op_o != `RV32_OP_INVALID) begin
                        legal_o     = 1'b1;
                        class_o     = `RV32_CLASS_BRANCH;
                        rs1_o       = instruction_i[19:15];
                        rs2_o       = instruction_i[24:20];
                        uses_rs1_o  = 1'b1;
                        uses_rs2_o  = 1'b1;
                        immediate_o = {
                            {19{instruction_i[31]}},
                            instruction_i[31],
                            instruction_i[7],
                            instruction_i[30:25],
                            instruction_i[11:8],
                            1'b0
                        };
                    end
                end

                7'b0000011: begin
                    case (funct3)
                        3'b000: begin
                            op_o           = `RV32_OP_LB;
                            memory_width_o = `RV32_MEMORY_BYTE;
                        end
                        3'b001: begin
                            op_o           = `RV32_OP_LH;
                            memory_width_o = `RV32_MEMORY_HALF;
                        end
                        3'b010: begin
                            op_o           = `RV32_OP_LW;
                            memory_width_o = `RV32_MEMORY_WORD;
                        end
                        3'b100: begin
                            op_o            = `RV32_OP_LBU;
                            memory_width_o  = `RV32_MEMORY_BYTE;
                            load_unsigned_o = 1'b1;
                        end
                        3'b101: begin
                            op_o            = `RV32_OP_LHU;
                            memory_width_o  = `RV32_MEMORY_HALF;
                            load_unsigned_o = 1'b1;
                        end
                        default: begin
                            op_o            = `RV32_OP_INVALID;
                            memory_width_o  = `RV32_MEMORY_NONE;
                            load_unsigned_o = 1'b0;
                        end
                    endcase

                    if (op_o != `RV32_OP_INVALID) begin
                        legal_o     = 1'b1;
                        class_o     = `RV32_CLASS_LOAD;
                        rd_o        = instruction_i[11:7];
                        rs1_o       = instruction_i[19:15];
                        uses_rs1_o  = 1'b1;
                        writes_rd_o = instruction_i[11:7] != 5'd0;
                        immediate_o = {
                            {20{instruction_i[31]}}, instruction_i[31:20]
                        };
                    end
                end

                7'b0100011: begin
                    case (funct3)
                        3'b000: begin
                            op_o           = `RV32_OP_SB;
                            memory_width_o = `RV32_MEMORY_BYTE;
                        end
                        3'b001: begin
                            op_o           = `RV32_OP_SH;
                            memory_width_o = `RV32_MEMORY_HALF;
                        end
                        3'b010: begin
                            op_o           = `RV32_OP_SW;
                            memory_width_o = `RV32_MEMORY_WORD;
                        end
                        default: begin
                            op_o           = `RV32_OP_INVALID;
                            memory_width_o = `RV32_MEMORY_NONE;
                        end
                    endcase

                    if (op_o != `RV32_OP_INVALID) begin
                        legal_o     = 1'b1;
                        class_o     = `RV32_CLASS_STORE;
                        rs1_o       = instruction_i[19:15];
                        rs2_o       = instruction_i[24:20];
                        uses_rs1_o  = 1'b1;
                        uses_rs2_o  = 1'b1;
                        immediate_o = {
                            {20{instruction_i[31]}},
                            instruction_i[31:25],
                            instruction_i[11:7]
                        };
                    end
                end

                7'b0010011: begin
                    case (funct3)
                        3'b000: op_o = `RV32_OP_ADDI;
                        3'b010: op_o = `RV32_OP_SLTI;
                        3'b011: op_o = `RV32_OP_SLTIU;
                        3'b100: op_o = `RV32_OP_XORI;
                        3'b110: op_o = `RV32_OP_ORI;
                        3'b111: op_o = `RV32_OP_ANDI;
                        3'b001: begin
                            if (funct7 == 7'b0000000)
                                op_o = `RV32_OP_SLLI;
                        end
                        3'b101: begin
                            if (funct7 == 7'b0000000)
                                op_o = `RV32_OP_SRLI;
                            else if (funct7 == 7'b0100000)
                                op_o = `RV32_OP_SRAI;
                        end
                        default: op_o = `RV32_OP_INVALID;
                    endcase

                    if (op_o != `RV32_OP_INVALID) begin
                        legal_o     = 1'b1;
                        class_o     = `RV32_CLASS_INT;
                        rd_o        = instruction_i[11:7];
                        rs1_o       = instruction_i[19:15];
                        uses_rs1_o  = 1'b1;
                        writes_rd_o = instruction_i[11:7] != 5'd0;
                        if ((op_o == `RV32_OP_SLLI) ||
                            (op_o == `RV32_OP_SRLI) ||
                            (op_o == `RV32_OP_SRAI)) begin
                            immediate_o = {27'd0, instruction_i[24:20]};
                        end else begin
                            immediate_o = {
                                {20{instruction_i[31]}}, instruction_i[31:20]
                            };
                        end
                    end
                end

                7'b0110011: begin
                    if (funct7 == 7'b0000000) begin
                        class_o = `RV32_CLASS_INT;
                        case (funct3)
                            3'b000: op_o = `RV32_OP_ADD;
                            3'b001: op_o = `RV32_OP_SLL;
                            3'b010: op_o = `RV32_OP_SLT;
                            3'b011: op_o = `RV32_OP_SLTU;
                            3'b100: op_o = `RV32_OP_XOR;
                            3'b101: op_o = `RV32_OP_SRL;
                            3'b110: op_o = `RV32_OP_OR;
                            3'b111: op_o = `RV32_OP_AND;
                        endcase
                    end else if (funct7 == 7'b0100000) begin
                        class_o = `RV32_CLASS_INT;
                        case (funct3)
                            3'b000: op_o = `RV32_OP_SUB;
                            3'b101: op_o = `RV32_OP_SRA;
                            default: op_o = `RV32_OP_INVALID;
                        endcase
                    end else if (funct7 == 7'b0000001) begin
                        case (funct3)
                            3'b000: begin
                                op_o    = `RV32_OP_MUL;
                                class_o = `RV32_CLASS_MUL;
                            end
                            3'b001: begin
                                op_o    = `RV32_OP_MULH;
                                class_o = `RV32_CLASS_MUL;
                            end
                            3'b010: begin
                                op_o    = `RV32_OP_MULHSU;
                                class_o = `RV32_CLASS_MUL;
                            end
                            3'b011: begin
                                op_o    = `RV32_OP_MULHU;
                                class_o = `RV32_CLASS_MUL;
                            end
                            3'b100: begin
                                op_o    = `RV32_OP_DIV;
                                class_o = `RV32_CLASS_DIV;
                            end
                            3'b101: begin
                                op_o    = `RV32_OP_DIVU;
                                class_o = `RV32_CLASS_DIV;
                            end
                            3'b110: begin
                                op_o    = `RV32_OP_REM;
                                class_o = `RV32_CLASS_DIV;
                            end
                            3'b111: begin
                                op_o    = `RV32_OP_REMU;
                                class_o = `RV32_CLASS_DIV;
                            end
                        endcase
                    end

                    if (op_o != `RV32_OP_INVALID) begin
                        legal_o     = 1'b1;
                        rd_o        = instruction_i[11:7];
                        rs1_o       = instruction_i[19:15];
                        rs2_o       = instruction_i[24:20];
                        uses_rs1_o  = 1'b1;
                        uses_rs2_o  = 1'b1;
                        writes_rd_o = instruction_i[11:7] != 5'd0;
                    end else begin
                        class_o = `RV32_CLASS_INVALID;
                    end
                end

                7'b0001111: begin
                    if (funct3 == 3'b000) begin
                        legal_o     = 1'b1;
                        op_o        = `RV32_OP_FENCE;
                        class_o     = `RV32_CLASS_SYSTEM;
                        serialize_o = 1'b1;
                    end
                end

                7'b1110011: begin
                    if (instruction_i == 32'h00000073) begin
                        legal_o = 1'b1;
                        op_o    = `RV32_OP_ECALL;
                        class_o = `RV32_CLASS_SYSTEM;
                    end else if (instruction_i == 32'h00100073) begin
                        legal_o = 1'b1;
                        op_o    = `RV32_OP_EBREAK;
                        class_o = `RV32_CLASS_SYSTEM;
                    end
                end

                default: begin
                    legal_o = 1'b0;
                end
            endcase
        end
    end

endmodule
