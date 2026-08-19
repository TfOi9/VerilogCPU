`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32m_divider #(
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
    input  wire [ROB_TAG_WIDTH-1:0] request_rob_tag_i,

    output wire                     response_valid_o,
    input  wire                     response_ready_i,
    output wire [31:0]              response_value_o,
    output wire [ROB_TAG_WIDTH-1:0] response_rob_tag_o
);

    reg                     busy_reg;
    /* verilator lint_off UNUSEDSIGNAL */
    reg [32:0]              remainder_reg;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [31:0]              quotient_reg;
    reg [31:0]              divisor_reg;
    reg [5:0]               iteration_count_reg;
    reg                     quotient_negative_reg;
    reg                     remainder_negative_reg;
    reg                     select_remainder_reg;
    reg                     divide_by_zero_reg;
    reg                     operation_valid_reg;
    reg [ROB_TAG_WIDTH-1:0] request_rob_tag_reg;

    reg                     response_valid_reg;
    reg [31:0]              response_value_reg;
    reg [ROB_TAG_WIDTH-1:0] response_rob_tag_reg;

    wire request_operation_valid;
    wire request_signed;
    wire request_select_remainder;
    wire [31:0] request_lhs_magnitude;
    wire [31:0] request_rhs_magnitude;
    wire [32:0] request_first_trial;
    wire request_first_subtract;
    wire [32:0] request_first_remainder;
    wire [31:0] request_first_quotient;

    wire [32:0] iteration_trial;
    wire iteration_subtract;
    wire [32:0] iteration_remainder;
    wire [31:0] iteration_quotient;
    wire [31:0] signed_quotient;
    wire [31:0] signed_remainder;
    wire [31:0] iteration_result;
    wire request_fire;

    assign request_operation_valid =
        (request_op_i == `RV32_OP_DIV) ||
        (request_op_i == `RV32_OP_DIVU) ||
        (request_op_i == `RV32_OP_REM) ||
        (request_op_i == `RV32_OP_REMU);
    assign request_signed =
        (request_op_i == `RV32_OP_DIV) ||
        (request_op_i == `RV32_OP_REM);
    assign request_select_remainder =
        (request_op_i == `RV32_OP_REM) ||
        (request_op_i == `RV32_OP_REMU);

    assign request_lhs_magnitude = request_signed && request_lhs_i[31] ?
        (~request_lhs_i) + 32'd1 : request_lhs_i;
    assign request_rhs_magnitude = request_signed && request_rhs_i[31] ?
        (~request_rhs_i) + 32'd1 : request_rhs_i;

    assign request_first_trial = {32'd0, request_lhs_magnitude[31]};
    assign request_first_subtract =
        request_first_trial >= {1'b0, request_rhs_magnitude};
    assign request_first_remainder = request_first_subtract ?
        request_first_trial - {1'b0, request_rhs_magnitude} :
        request_first_trial;
    assign request_first_quotient =
        {request_lhs_magnitude[30:0], request_first_subtract};

    assign iteration_trial =
        {remainder_reg[31:0], quotient_reg[31]};
    assign iteration_subtract =
        iteration_trial >= {1'b0, divisor_reg};
    assign iteration_remainder = iteration_subtract ?
        iteration_trial - {1'b0, divisor_reg} : iteration_trial;
    assign iteration_quotient =
        {quotient_reg[30:0], iteration_subtract};

    assign signed_quotient = quotient_negative_reg ?
        (~iteration_quotient) + 32'd1 : iteration_quotient;
    assign signed_remainder = remainder_negative_reg ?
        (~iteration_remainder[31:0]) + 32'd1 :
        iteration_remainder[31:0];
    assign iteration_result = !operation_valid_reg ? 32'd0 :
        (select_remainder_reg ? signed_remainder :
        (divide_by_zero_reg ? 32'hffffffff : signed_quotient));

    assign request_ready_o = !reset_i && !flush_i && !busy_reg &&
        (!response_valid_reg || response_ready_i);
    assign request_fire = request_valid_i && request_ready_o;

    assign response_valid_o =
        !reset_i && !flush_i && response_valid_reg;
    assign response_value_o = (!reset_i && !flush_i) ?
        response_value_reg : 32'd0;
    assign response_rob_tag_o = (!reset_i && !flush_i) ?
        response_rob_tag_reg : {ROB_TAG_WIDTH{1'b0}};

    always @(posedge clk_i) begin
        if (reset_i) begin
            busy_reg <= 1'b0;
            remainder_reg <= 33'd0;
            quotient_reg <= 32'd0;
            divisor_reg <= 32'd0;
            iteration_count_reg <= 6'd0;
            quotient_negative_reg <= 1'b0;
            remainder_negative_reg <= 1'b0;
            select_remainder_reg <= 1'b0;
            divide_by_zero_reg <= 1'b0;
            operation_valid_reg <= 1'b0;
            request_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
            response_valid_reg <= 1'b0;
            response_value_reg <= 32'd0;
            response_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
        end else if (flush_i) begin
            busy_reg <= 1'b0;
            remainder_reg <= 33'd0;
            quotient_reg <= 32'd0;
            divisor_reg <= 32'd0;
            iteration_count_reg <= 6'd0;
            quotient_negative_reg <= 1'b0;
            remainder_negative_reg <= 1'b0;
            select_remainder_reg <= 1'b0;
            divide_by_zero_reg <= 1'b0;
            operation_valid_reg <= 1'b0;
            request_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
            response_valid_reg <= 1'b0;
            response_value_reg <= 32'd0;
            response_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
        end else begin
            if (response_valid_reg && response_ready_i) begin
                response_valid_reg <= 1'b0;
                response_value_reg <= 32'd0;
                response_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
            end

            if (request_fire) begin
                busy_reg <= 1'b1;
                remainder_reg <= request_first_remainder;
                quotient_reg <= request_first_quotient;
                divisor_reg <= request_rhs_magnitude;
                iteration_count_reg <= 6'd1;
                quotient_negative_reg <= request_signed &&
                    (request_lhs_i[31] ^ request_rhs_i[31]);
                remainder_negative_reg <=
                    request_signed && request_lhs_i[31];
                select_remainder_reg <= request_select_remainder;
                divide_by_zero_reg <= request_rhs_magnitude == 32'd0;
                operation_valid_reg <= request_operation_valid;
                request_rob_tag_reg <= request_rob_tag_i;
            end else if (busy_reg) begin
                remainder_reg <= iteration_remainder;
                quotient_reg <= iteration_quotient;
                if (iteration_count_reg == 6'd31) begin
                    busy_reg <= 1'b0;
                    iteration_count_reg <= 6'd0;
                    response_valid_reg <= 1'b1;
                    response_value_reg <= iteration_result;
                    response_rob_tag_reg <= request_rob_tag_reg;
                end else begin
                    iteration_count_reg <= iteration_count_reg + 6'd1;
                end
            end
        end
    end

endmodule
