`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32m_multiplier #(
    parameter ROB_TAG_WIDTH = 7
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

    reg                     stage1_valid_reg;
    reg [65:0]              stage1_partial_product [0:16];
    reg                     stage1_select_high_reg;
    reg                     stage1_operation_valid_reg;
    reg [ROB_TAG_WIDTH-1:0] stage1_rob_tag_reg;

    reg                     stage2_valid_reg;
    reg [65:0]              stage2_row0_reg;
    reg [65:0]              stage2_row1_reg;
    reg                     stage2_select_high_reg;
    reg                     stage2_operation_valid_reg;
    reg [ROB_TAG_WIDTH-1:0] stage2_rob_tag_reg;

    reg                     stage3_valid_reg;
    reg [31:0]              stage3_value_reg;
    reg [ROB_TAG_WIDTH-1:0] stage3_rob_tag_reg;

    wire request_lhs_signed;
    wire request_rhs_signed;
    wire request_operation_valid;
    wire request_select_high;
    wire [32:0] request_multiplicand;
    wire [32:0] request_multiplier;
    wire [34:0] request_booth_bits;

    wire stage1_ready;
    wire stage2_ready;
    wire stage3_ready;
    wire request_fire;

    wire [65:0] wallace_l1_0;
    wire [65:0] wallace_l1_1;
    wire [65:0] wallace_l1_2;
    wire [65:0] wallace_l1_3;
    wire [65:0] wallace_l1_4;
    wire [65:0] wallace_l1_5;
    wire [65:0] wallace_l1_6;
    wire [65:0] wallace_l1_7;
    wire [65:0] wallace_l1_8;
    wire [65:0] wallace_l1_9;
    wire [65:0] wallace_l1_10;
    wire [65:0] wallace_l1_11;

    wire [65:0] wallace_l2_0;
    wire [65:0] wallace_l2_1;
    wire [65:0] wallace_l2_2;
    wire [65:0] wallace_l2_3;
    wire [65:0] wallace_l2_4;
    wire [65:0] wallace_l2_5;
    wire [65:0] wallace_l2_6;
    wire [65:0] wallace_l2_7;

    wire [65:0] wallace_l3_0;
    wire [65:0] wallace_l3_1;
    wire [65:0] wallace_l3_2;
    wire [65:0] wallace_l3_3;
    wire [65:0] wallace_l3_4;
    wire [65:0] wallace_l3_5;

    wire [65:0] wallace_l4_0;
    wire [65:0] wallace_l4_1;
    wire [65:0] wallace_l4_2;
    wire [65:0] wallace_l4_3;

    wire [65:0] wallace_l5_0;
    wire [65:0] wallace_l5_1;
    wire [65:0] wallace_l5_2;

    wire [65:0] wallace_row0;
    wire [65:0] wallace_row1;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [65:0] final_product;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] final_value;

    integer partial_index;

    function [65:0] booth_partial_product;
        input [2:0] booth_code;
        input [32:0] multiplicand;
        input integer shift_amount;
        reg signed [65:0] extended_multiplicand;
        reg signed [65:0] selected_multiple;
        begin
            extended_multiplicand =
                {{33{multiplicand[32]}}, multiplicand};
            case (booth_code)
                3'b001,
                3'b010: selected_multiple = extended_multiplicand;
                3'b011: selected_multiple =
                    extended_multiplicand <<< 1;
                3'b100: selected_multiple =
                    -(extended_multiplicand <<< 1);
                3'b101,
                3'b110: selected_multiple = -extended_multiplicand;
                default: selected_multiple = 66'sd0;
            endcase
            booth_partial_product = selected_multiple <<< shift_amount;
        end
    endfunction

    function [65:0] csa_sum;
        input [65:0] operand0;
        input [65:0] operand1;
        input [65:0] operand2;
        begin
            csa_sum = operand0 ^ operand1 ^ operand2;
        end
    endfunction

    function [65:0] csa_carry;
        input [65:0] operand0;
        input [65:0] operand1;
        input [65:0] operand2;
        /* verilator lint_off UNUSEDSIGNAL */
        reg [65:0] unshifted_carry;
        /* verilator lint_on UNUSEDSIGNAL */
        begin
            unshifted_carry = (operand0 & operand1) |
                (operand0 & operand2) | (operand1 & operand2);
            csa_carry = {unshifted_carry[64:0], 1'b0};
        end
    endfunction

    assign request_operation_valid =
        (request_op_i == `RV32_OP_MUL) ||
        (request_op_i == `RV32_OP_MULH) ||
        (request_op_i == `RV32_OP_MULHSU) ||
        (request_op_i == `RV32_OP_MULHU);
    assign request_lhs_signed =
        (request_op_i == `RV32_OP_MULH) ||
        (request_op_i == `RV32_OP_MULHSU);
    assign request_rhs_signed = request_op_i == `RV32_OP_MULH;
    assign request_select_high = request_op_i != `RV32_OP_MUL;

    assign request_multiplicand =
        {request_lhs_signed && request_lhs_i[31], request_lhs_i};
    assign request_multiplier =
        {request_rhs_signed && request_rhs_i[31], request_rhs_i};
    assign request_booth_bits =
        {request_multiplier[32], request_multiplier, 1'b0};

    assign stage3_ready = !stage3_valid_reg || response_ready_i;
    assign stage2_ready = !stage2_valid_reg || stage3_ready;
    assign stage1_ready = !stage1_valid_reg || stage2_ready;

    assign request_ready_o = !reset_i && !flush_i && stage1_ready;
    assign request_fire = request_valid_i && request_ready_o;

    assign response_valid_o =
        !reset_i && !flush_i && stage3_valid_reg;
    assign response_value_o = (!reset_i && !flush_i) ?
        stage3_value_reg : 32'd0;
    assign response_rob_tag_o = (!reset_i && !flush_i) ?
        stage3_rob_tag_reg : {ROB_TAG_WIDTH{1'b0}};

    assign wallace_l1_0 = csa_sum(stage1_partial_product[0],
        stage1_partial_product[1], stage1_partial_product[2]);
    assign wallace_l1_1 = csa_carry(stage1_partial_product[0],
        stage1_partial_product[1], stage1_partial_product[2]);
    assign wallace_l1_2 = csa_sum(stage1_partial_product[3],
        stage1_partial_product[4], stage1_partial_product[5]);
    assign wallace_l1_3 = csa_carry(stage1_partial_product[3],
        stage1_partial_product[4], stage1_partial_product[5]);
    assign wallace_l1_4 = csa_sum(stage1_partial_product[6],
        stage1_partial_product[7], stage1_partial_product[8]);
    assign wallace_l1_5 = csa_carry(stage1_partial_product[6],
        stage1_partial_product[7], stage1_partial_product[8]);
    assign wallace_l1_6 = csa_sum(stage1_partial_product[9],
        stage1_partial_product[10], stage1_partial_product[11]);
    assign wallace_l1_7 = csa_carry(stage1_partial_product[9],
        stage1_partial_product[10], stage1_partial_product[11]);
    assign wallace_l1_8 = csa_sum(stage1_partial_product[12],
        stage1_partial_product[13], stage1_partial_product[14]);
    assign wallace_l1_9 = csa_carry(stage1_partial_product[12],
        stage1_partial_product[13], stage1_partial_product[14]);
    assign wallace_l1_10 = stage1_partial_product[15];
    assign wallace_l1_11 = stage1_partial_product[16];

    assign wallace_l2_0 = csa_sum(
        wallace_l1_0, wallace_l1_1, wallace_l1_2);
    assign wallace_l2_1 = csa_carry(
        wallace_l1_0, wallace_l1_1, wallace_l1_2);
    assign wallace_l2_2 = csa_sum(
        wallace_l1_3, wallace_l1_4, wallace_l1_5);
    assign wallace_l2_3 = csa_carry(
        wallace_l1_3, wallace_l1_4, wallace_l1_5);
    assign wallace_l2_4 = csa_sum(
        wallace_l1_6, wallace_l1_7, wallace_l1_8);
    assign wallace_l2_5 = csa_carry(
        wallace_l1_6, wallace_l1_7, wallace_l1_8);
    assign wallace_l2_6 = csa_sum(
        wallace_l1_9, wallace_l1_10, wallace_l1_11);
    assign wallace_l2_7 = csa_carry(
        wallace_l1_9, wallace_l1_10, wallace_l1_11);

    assign wallace_l3_0 = csa_sum(
        wallace_l2_0, wallace_l2_1, wallace_l2_2);
    assign wallace_l3_1 = csa_carry(
        wallace_l2_0, wallace_l2_1, wallace_l2_2);
    assign wallace_l3_2 = csa_sum(
        wallace_l2_3, wallace_l2_4, wallace_l2_5);
    assign wallace_l3_3 = csa_carry(
        wallace_l2_3, wallace_l2_4, wallace_l2_5);
    assign wallace_l3_4 = wallace_l2_6;
    assign wallace_l3_5 = wallace_l2_7;

    assign wallace_l4_0 = csa_sum(
        wallace_l3_0, wallace_l3_1, wallace_l3_2);
    assign wallace_l4_1 = csa_carry(
        wallace_l3_0, wallace_l3_1, wallace_l3_2);
    assign wallace_l4_2 = csa_sum(
        wallace_l3_3, wallace_l3_4, wallace_l3_5);
    assign wallace_l4_3 = csa_carry(
        wallace_l3_3, wallace_l3_4, wallace_l3_5);

    assign wallace_l5_0 = csa_sum(
        wallace_l4_0, wallace_l4_1, wallace_l4_2);
    assign wallace_l5_1 = csa_carry(
        wallace_l4_0, wallace_l4_1, wallace_l4_2);
    assign wallace_l5_2 = wallace_l4_3;

    assign wallace_row0 = csa_sum(
        wallace_l5_0, wallace_l5_1, wallace_l5_2);
    assign wallace_row1 = csa_carry(
        wallace_l5_0, wallace_l5_1, wallace_l5_2);

    assign final_product = stage2_row0_reg + stage2_row1_reg;
    assign final_value = !stage2_operation_valid_reg ? 32'd0 :
        (stage2_select_high_reg ? final_product[63:32] :
        final_product[31:0]);

    always @(posedge clk_i) begin
        if (reset_i) begin
            stage1_valid_reg <= 1'b0;
            stage1_select_high_reg <= 1'b0;
            stage1_operation_valid_reg <= 1'b0;
            stage1_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
            for (partial_index = 0; partial_index < 17;
                    partial_index = partial_index + 1) begin
                stage1_partial_product[partial_index] <= 66'd0;
            end

            stage2_valid_reg <= 1'b0;
            stage2_row0_reg <= 66'd0;
            stage2_row1_reg <= 66'd0;
            stage2_select_high_reg <= 1'b0;
            stage2_operation_valid_reg <= 1'b0;
            stage2_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};

            stage3_valid_reg <= 1'b0;
            stage3_value_reg <= 32'd0;
            stage3_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
        end else if (flush_i) begin
            stage1_valid_reg <= 1'b0;
            stage1_select_high_reg <= 1'b0;
            stage1_operation_valid_reg <= 1'b0;
            stage1_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
            for (partial_index = 0; partial_index < 17;
                    partial_index = partial_index + 1) begin
                stage1_partial_product[partial_index] <= 66'd0;
            end

            stage2_valid_reg <= 1'b0;
            stage2_row0_reg <= 66'd0;
            stage2_row1_reg <= 66'd0;
            stage2_select_high_reg <= 1'b0;
            stage2_operation_valid_reg <= 1'b0;
            stage2_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};

            stage3_valid_reg <= 1'b0;
            stage3_value_reg <= 32'd0;
            stage3_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
        end else begin
            if (stage3_ready) begin
                stage3_valid_reg <= stage2_valid_reg;
                if (stage2_valid_reg) begin
                    stage3_value_reg <= final_value;
                    stage3_rob_tag_reg <= stage2_rob_tag_reg;
                end else begin
                    stage3_value_reg <= 32'd0;
                    stage3_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
                end
            end

            if (stage2_ready) begin
                stage2_valid_reg <= stage1_valid_reg;
                if (stage1_valid_reg) begin
                    stage2_row0_reg <= wallace_row0;
                    stage2_row1_reg <= wallace_row1;
                    stage2_select_high_reg <= stage1_select_high_reg;
                    stage2_operation_valid_reg <=
                        stage1_operation_valid_reg;
                    stage2_rob_tag_reg <= stage1_rob_tag_reg;
                end else begin
                    stage2_row0_reg <= 66'd0;
                    stage2_row1_reg <= 66'd0;
                    stage2_select_high_reg <= 1'b0;
                    stage2_operation_valid_reg <= 1'b0;
                    stage2_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
                end
            end

            if (stage1_ready) begin
                stage1_valid_reg <= request_fire;
                if (request_fire) begin
                    stage1_partial_product[0] <= booth_partial_product(
                        request_booth_bits[2:0], request_multiplicand, 0);
                    stage1_partial_product[1] <= booth_partial_product(
                        request_booth_bits[4:2], request_multiplicand, 2);
                    stage1_partial_product[2] <= booth_partial_product(
                        request_booth_bits[6:4], request_multiplicand, 4);
                    stage1_partial_product[3] <= booth_partial_product(
                        request_booth_bits[8:6], request_multiplicand, 6);
                    stage1_partial_product[4] <= booth_partial_product(
                        request_booth_bits[10:8], request_multiplicand, 8);
                    stage1_partial_product[5] <= booth_partial_product(
                        request_booth_bits[12:10], request_multiplicand, 10);
                    stage1_partial_product[6] <= booth_partial_product(
                        request_booth_bits[14:12], request_multiplicand, 12);
                    stage1_partial_product[7] <= booth_partial_product(
                        request_booth_bits[16:14], request_multiplicand, 14);
                    stage1_partial_product[8] <= booth_partial_product(
                        request_booth_bits[18:16], request_multiplicand, 16);
                    stage1_partial_product[9] <= booth_partial_product(
                        request_booth_bits[20:18], request_multiplicand, 18);
                    stage1_partial_product[10] <= booth_partial_product(
                        request_booth_bits[22:20], request_multiplicand, 20);
                    stage1_partial_product[11] <= booth_partial_product(
                        request_booth_bits[24:22], request_multiplicand, 22);
                    stage1_partial_product[12] <= booth_partial_product(
                        request_booth_bits[26:24], request_multiplicand, 24);
                    stage1_partial_product[13] <= booth_partial_product(
                        request_booth_bits[28:26], request_multiplicand, 26);
                    stage1_partial_product[14] <= booth_partial_product(
                        request_booth_bits[30:28], request_multiplicand, 28);
                    stage1_partial_product[15] <= booth_partial_product(
                        request_booth_bits[32:30], request_multiplicand, 30);
                    stage1_partial_product[16] <= booth_partial_product(
                        request_booth_bits[34:32], request_multiplicand, 32);
                    stage1_select_high_reg <= request_select_high;
                    stage1_operation_valid_reg <= request_operation_valid;
                    stage1_rob_tag_reg <= request_rob_tag_i;
                end else begin
                    for (partial_index = 0; partial_index < 17;
                            partial_index = partial_index + 1) begin
                        stage1_partial_product[partial_index] <= 66'd0;
                    end
                    stage1_select_high_reg <= 1'b0;
                    stage1_operation_valid_reg <= 1'b0;
                    stage1_rob_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
                end
            end
        end
    end

endmodule
