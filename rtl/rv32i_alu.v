`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32i_alu #(
    parameter ROB_TAG_WIDTH = 5
) (
    input  wire                     clk_i,
    input  wire                     reset_i,
    input  wire                     flush_i,

    input  wire                     request_valid_i,
    output wire                     request_ready_o,
    input  wire [`RV32_OP_WIDTH-1:0] request_op_i,
    input  wire [31:0]              request_lhs_i,
    input  wire [31:0]              request_rhs_i,
    input  wire [31:0]              request_pc_i,
    input  wire [31:0]              request_immediate_i,
    input  wire [ROB_TAG_WIDTH-1:0] request_rob_tag_i,

    output wire                     response_valid_o,
    input  wire                     response_ready_i,
    output wire [31:0]              response_value_o,
    output wire [ROB_TAG_WIDTH-1:0] response_rob_tag_o,
    output wire                     response_control_valid_o,
    output wire                     response_control_taken_o,
    output wire [31:0]              response_next_pc_o
);

    reg                     response_valid_reg;
    reg [31:0]              response_value_reg;
    reg [ROB_TAG_WIDTH-1:0] response_rob_tag_reg;
    reg                     response_control_valid_reg;
    reg                     response_control_taken_reg;
    reg [31:0]              response_next_pc_reg;

    reg [31:0] result_value;
    reg        result_control_valid;
    reg        result_control_taken;
    reg [31:0] result_next_pc;

    wire request_fire;
    wire response_fire;

    assign request_ready_o = !reset_i && !flush_i &&
        (!response_valid_reg || response_ready_i);
    assign request_fire = request_valid_i && request_ready_o;
    assign response_fire = response_valid_reg && response_ready_i;

    assign response_valid_o = !reset_i && !flush_i && response_valid_reg;
    assign response_value_o = (!reset_i && !flush_i) ?
        response_value_reg : 32'd0;
    assign response_rob_tag_o = (!reset_i && !flush_i) ?
        response_rob_tag_reg : {ROB_TAG_WIDTH{1'b0}};
    assign response_control_valid_o = (!reset_i && !flush_i) ?
        response_control_valid_reg : 1'b0;
    assign response_control_taken_o = (!reset_i && !flush_i) ?
        response_control_taken_reg : 1'b0;
    assign response_next_pc_o = (!reset_i && !flush_i) ?
        response_next_pc_reg : 32'd0;

    always @* begin
        result_value = 32'd0;
        result_control_valid = 1'b0;
        result_control_taken = 1'b0;
        result_next_pc = 32'd0;

        case (request_op_i)
            `RV32_OP_LUI: begin
                result_value = request_immediate_i;
            end

            `RV32_OP_AUIPC: begin
                result_value = request_pc_i + request_immediate_i;
            end

            `RV32_OP_JAL: begin
                result_value = request_pc_i + 32'd4;
                result_control_valid = 1'b1;
                result_control_taken = 1'b1;
                result_next_pc = request_pc_i + request_immediate_i;
            end

            `RV32_OP_JALR: begin
                result_value = request_pc_i + 32'd4;
                result_control_valid = 1'b1;
                result_control_taken = 1'b1;
                result_next_pc =
                    (request_lhs_i + request_immediate_i) & 32'hfffffffe;
            end

            `RV32_OP_BEQ: begin
                result_control_valid = 1'b1;
                result_control_taken = request_lhs_i == request_rhs_i;
                result_next_pc = result_control_taken ?
                    request_pc_i + request_immediate_i : request_pc_i + 32'd4;
            end

            `RV32_OP_BNE: begin
                result_control_valid = 1'b1;
                result_control_taken = request_lhs_i != request_rhs_i;
                result_next_pc = result_control_taken ?
                    request_pc_i + request_immediate_i : request_pc_i + 32'd4;
            end

            `RV32_OP_BLT: begin
                result_control_valid = 1'b1;
                result_control_taken =
                    $signed(request_lhs_i) < $signed(request_rhs_i);
                result_next_pc = result_control_taken ?
                    request_pc_i + request_immediate_i : request_pc_i + 32'd4;
            end

            `RV32_OP_BGE: begin
                result_control_valid = 1'b1;
                result_control_taken =
                    $signed(request_lhs_i) >= $signed(request_rhs_i);
                result_next_pc = result_control_taken ?
                    request_pc_i + request_immediate_i : request_pc_i + 32'd4;
            end

            `RV32_OP_BLTU: begin
                result_control_valid = 1'b1;
                result_control_taken = request_lhs_i < request_rhs_i;
                result_next_pc = result_control_taken ?
                    request_pc_i + request_immediate_i : request_pc_i + 32'd4;
            end

            `RV32_OP_BGEU: begin
                result_control_valid = 1'b1;
                result_control_taken = request_lhs_i >= request_rhs_i;
                result_next_pc = result_control_taken ?
                    request_pc_i + request_immediate_i : request_pc_i + 32'd4;
            end

            `RV32_OP_ADDI: begin
                result_value = request_lhs_i + request_immediate_i;
            end

            `RV32_OP_SLTI: begin
                result_value = {31'd0,
                    $signed(request_lhs_i) < $signed(request_immediate_i)};
            end

            `RV32_OP_SLTIU: begin
                result_value = {31'd0,
                    request_lhs_i < request_immediate_i};
            end

            `RV32_OP_XORI: begin
                result_value = request_lhs_i ^ request_immediate_i;
            end

            `RV32_OP_ORI: begin
                result_value = request_lhs_i | request_immediate_i;
            end

            `RV32_OP_ANDI: begin
                result_value = request_lhs_i & request_immediate_i;
            end

            `RV32_OP_SLLI: begin
                result_value = request_lhs_i << request_immediate_i[4:0];
            end

            `RV32_OP_SRLI: begin
                result_value = request_lhs_i >> request_immediate_i[4:0];
            end

            `RV32_OP_SRAI: begin
                result_value = $signed(request_lhs_i) >>>
                    request_immediate_i[4:0];
            end

            `RV32_OP_ADD: begin
                result_value = request_lhs_i + request_rhs_i;
            end

            `RV32_OP_SUB: begin
                result_value = request_lhs_i - request_rhs_i;
            end

            `RV32_OP_SLL: begin
                result_value = request_lhs_i << request_rhs_i[4:0];
            end

            `RV32_OP_SLT: begin
                result_value = {31'd0,
                    $signed(request_lhs_i) < $signed(request_rhs_i)};
            end

            `RV32_OP_SLTU: begin
                result_value = {31'd0, request_lhs_i < request_rhs_i};
            end

            `RV32_OP_XOR: begin
                result_value = request_lhs_i ^ request_rhs_i;
            end

            `RV32_OP_SRL: begin
                result_value = request_lhs_i >> request_rhs_i[4:0];
            end

            `RV32_OP_SRA: begin
                result_value = $signed(request_lhs_i) >>> request_rhs_i[4:0];
            end

            `RV32_OP_OR: begin
                result_value = request_lhs_i | request_rhs_i;
            end

            `RV32_OP_AND: begin
                result_value = request_lhs_i & request_rhs_i;
            end

            default: begin
                result_value = 32'd0;
                result_control_valid = 1'b0;
                result_control_taken = 1'b0;
                result_next_pc = 32'd0;
            end
        endcase
    end

    always @(posedge clk_i) begin
        if (reset_i) begin
            response_valid_reg <= 1'b0;
            response_value_reg <= 32'd0;
            response_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
            response_control_valid_reg <= 1'b0;
            response_control_taken_reg <= 1'b0;
            response_next_pc_reg <= 32'd0;
        end else if (flush_i) begin
            response_valid_reg <= 1'b0;
            response_value_reg <= 32'd0;
            response_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
            response_control_valid_reg <= 1'b0;
            response_control_taken_reg <= 1'b0;
            response_next_pc_reg <= 32'd0;
        end else if (request_fire) begin
            response_valid_reg <= 1'b1;
            response_value_reg <= result_value;
            response_rob_tag_reg <= request_rob_tag_i;
            response_control_valid_reg <= result_control_valid;
            response_control_taken_reg <= result_control_taken;
            response_next_pc_reg <= result_next_pc;
        end else if (response_fire) begin
            response_valid_reg <= 1'b0;
        end
    end

endmodule
