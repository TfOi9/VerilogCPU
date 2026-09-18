`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_branch_predictor #(
    parameter FE_WIDTH = 1,
    parameter BE_WIDTH = 1
) (
    input  wire                                         clk_i,
    input  wire                                         reset_i,

    input  wire [FE_WIDTH-1:0]                          query_valid_i,
    input  wire [(FE_WIDTH*`RV32_OP_WIDTH)-1:0]         query_op_i,
    input  wire [(FE_WIDTH*32)-1:0]                     query_pc_i,
    input  wire [(FE_WIDTH*32)-1:0]                     query_immediate_i,
    output reg  [FE_WIDTH-1:0]                          prediction_valid_o,
    output reg  [FE_WIDTH-1:0]                          prediction_taken_o,
    output reg  [FE_WIDTH-1:0]                          prediction_btb_hit_o,
    output reg  [(FE_WIDTH*32)-1:0]                     prediction_next_pc_o,

    input  wire [BE_WIDTH-1:0]                          update_valid_i,
    input  wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0]         update_op_i,
    input  wire [(BE_WIDTH*32)-1:0]                     update_pc_i,
    input  wire [(BE_WIDTH*32)-1:0]                     update_predicted_next_pc_i,
    input  wire [(BE_WIDTH*32)-1:0]                     update_actual_next_pc_i,
    input  wire [BE_WIDTH-1:0]                          update_actual_taken_i,

    output wire [31:0]                                  conditional_correct_o,
    output wire [31:0]                                  conditional_total_o,
    output wire [31:0]                                  jal_correct_o,
    output wire [31:0]                                  jal_total_o,
    output wire [31:0]                                  jalr_correct_o,
    output wire [31:0]                                  jalr_total_o,
    output wire [31:0]                                  control_correct_o,
    output wire [31:0]                                  control_total_o
);

    reg [1:0] bht [0:63];
    reg [1:0] bht_next [0:63];
    reg       btb_valid [0:15];
    reg [31:0] btb_pc [0:15];
    reg [31:0] btb_target [0:15];

    reg [31:0] conditional_correct_reg;
    reg [31:0] conditional_total_reg;
    reg [31:0] jal_correct_reg;
    reg [31:0] jal_total_reg;
    reg [31:0] jalr_correct_reg;
    reg [31:0] jalr_total_reg;
    reg [31:0] control_correct_reg;
    reg [31:0] control_total_reg;

    reg [31:0] conditional_correct_increment;
    reg [31:0] conditional_total_increment;
    reg [31:0] jal_correct_increment;
    reg [31:0] jal_total_increment;
    reg [31:0] jalr_correct_increment;
    reg [31:0] jalr_total_increment;
    reg [31:0] control_correct_increment;
    reg [31:0] control_total_increment;

    reg [`RV32_OP_WIDTH-1:0] query_op_value;
    reg [31:0] query_pc_value;
    reg [31:0] query_immediate_value;
    reg [3:0] query_btb_index;
    reg [`RV32_OP_WIDTH-1:0] update_op_value;
    reg [31:0] update_predicted_next_pc_value;
    reg [31:0] update_actual_next_pc_value;
    reg [5:0] update_bht_index;
    reg       update_correct;

    integer query_lane_index;
    integer update_lane_index;
    integer bht_comb_index;
    integer sequential_state_index;
    integer sequential_update_lane_index;
    integer assertion_lane_index;

    function is_conditional_branch;
        input [`RV32_OP_WIDTH-1:0] op;
        begin
            is_conditional_branch =
                (op == `RV32_OP_BEQ) ||
                (op == `RV32_OP_BNE) ||
                (op == `RV32_OP_BLT) ||
                (op == `RV32_OP_BGE) ||
                (op == `RV32_OP_BLTU) ||
                (op == `RV32_OP_BGEU);
        end
    endfunction

    function is_control;
        input [`RV32_OP_WIDTH-1:0] op;
        begin
            is_control = is_conditional_branch(op) ||
                (op == `RV32_OP_JAL) || (op == `RV32_OP_JALR);
        end
    endfunction

    function [1:0] next_counter;
        input [1:0] counter;
        input       taken;
        begin
            if (taken)
                next_counter = (counter == 2'b11) ? 2'b11 : counter + 1'b1;
            else
                next_counter = (counter == 2'b00) ? 2'b00 : counter - 1'b1;
        end
    endfunction

    assign conditional_correct_o = reset_i ? 32'd0 :
        conditional_correct_reg;
    assign conditional_total_o = reset_i ? 32'd0 : conditional_total_reg;
    assign jal_correct_o = reset_i ? 32'd0 : jal_correct_reg;
    assign jal_total_o = reset_i ? 32'd0 : jal_total_reg;
    assign jalr_correct_o = reset_i ? 32'd0 : jalr_correct_reg;
    assign jalr_total_o = reset_i ? 32'd0 : jalr_total_reg;
    assign control_correct_o = reset_i ? 32'd0 : control_correct_reg;
    assign control_total_o = reset_i ? 32'd0 : control_total_reg;

    initial begin
        if ((FE_WIDTH != 1) && (FE_WIDTH != 2) && (FE_WIDTH != 4)) begin
            $display("ERROR rv32_branch_predictor invalid FE_WIDTH=%0d",
                FE_WIDTH);
            $finish(1);
        end
        if ((BE_WIDTH != 1) && (BE_WIDTH != 2) && (BE_WIDTH != 4)) begin
            $display("ERROR rv32_branch_predictor invalid BE_WIDTH=%0d",
                BE_WIDTH);
            $finish(1);
        end
    end

    always @* begin
        prediction_valid_o = {FE_WIDTH{1'b0}};
        prediction_taken_o = {FE_WIDTH{1'b0}};
        prediction_btb_hit_o = {FE_WIDTH{1'b0}};
        prediction_next_pc_o = {(FE_WIDTH*32){1'b0}};
        query_op_value = `RV32_OP_INVALID;
        query_pc_value = 32'd0;
        query_immediate_value = 32'd0;
        query_btb_index = 4'd0;

        for (query_lane_index = 0; query_lane_index < FE_WIDTH;
                query_lane_index = query_lane_index + 1) begin
            query_op_value = query_op_i[
                query_lane_index*`RV32_OP_WIDTH +: `RV32_OP_WIDTH];
            query_pc_value = query_pc_i[query_lane_index*32 +: 32];
            query_immediate_value = query_immediate_i[
                query_lane_index*32 +: 32];
            query_btb_index = query_pc_value[5:2];

            if (!reset_i && query_valid_i[query_lane_index] &&
                    is_control(query_op_value)) begin
                prediction_valid_o[query_lane_index] = 1'b1;
                if (is_conditional_branch(query_op_value)) begin
                    prediction_taken_o[query_lane_index] =
                        bht[query_pc_value[7:2]][1];
                    prediction_next_pc_o[query_lane_index*32 +: 32] =
                        bht[query_pc_value[7:2]][1] ?
                            query_pc_value + query_immediate_value :
                            query_pc_value + 32'd4;
                end else if (query_op_value == `RV32_OP_JAL) begin
                    prediction_taken_o[query_lane_index] = 1'b1;
                    prediction_next_pc_o[query_lane_index*32 +: 32] =
                        query_pc_value + query_immediate_value;
                end else if (btb_valid[query_btb_index] &&
                        (btb_pc[query_btb_index] == query_pc_value)) begin
                    prediction_taken_o[query_lane_index] = 1'b1;
                    prediction_btb_hit_o[query_lane_index] = 1'b1;
                    prediction_next_pc_o[query_lane_index*32 +: 32] =
                        btb_target[query_btb_index];
                end else begin
                    prediction_next_pc_o[query_lane_index*32 +: 32] =
                        query_pc_value + 32'd4;
                end
            end
        end
    end

    always @* begin
        for (bht_comb_index = 0; bht_comb_index < 64;
                bht_comb_index = bht_comb_index + 1)
            bht_next[bht_comb_index] = bht[bht_comb_index];

        conditional_correct_increment = 32'd0;
        conditional_total_increment = 32'd0;
        jal_correct_increment = 32'd0;
        jal_total_increment = 32'd0;
        jalr_correct_increment = 32'd0;
        jalr_total_increment = 32'd0;
        control_correct_increment = 32'd0;
        control_total_increment = 32'd0;
        update_op_value = `RV32_OP_INVALID;
        update_predicted_next_pc_value = 32'd0;
        update_actual_next_pc_value = 32'd0;
        update_bht_index = 6'd0;
        update_correct = 1'b0;

        for (update_lane_index = 0; update_lane_index < BE_WIDTH;
                update_lane_index = update_lane_index + 1) begin
            update_op_value = update_op_i[
                update_lane_index*`RV32_OP_WIDTH +: `RV32_OP_WIDTH];
            update_predicted_next_pc_value = update_predicted_next_pc_i[
                update_lane_index*32 +: 32];
            update_actual_next_pc_value = update_actual_next_pc_i[
                update_lane_index*32 +: 32];
            update_bht_index = update_pc_i[
                update_lane_index*32 + 2 +: 6];
            update_correct = update_predicted_next_pc_value ==
                update_actual_next_pc_value;

            if (update_valid_i[update_lane_index]) begin
                control_total_increment = control_total_increment + 1'b1;
                if (update_correct)
                    control_correct_increment =
                        control_correct_increment + 1'b1;

                if (is_conditional_branch(update_op_value)) begin
                    bht_next[update_bht_index] = next_counter(
                        bht_next[update_bht_index],
                        update_actual_taken_i[update_lane_index]);
                    conditional_total_increment =
                        conditional_total_increment + 1'b1;
                    if (update_correct)
                        conditional_correct_increment =
                            conditional_correct_increment + 1'b1;
                end else if (update_op_value == `RV32_OP_JAL) begin
                    jal_total_increment = jal_total_increment + 1'b1;
                    if (update_correct)
                        jal_correct_increment = jal_correct_increment + 1'b1;
                end else if (update_op_value == `RV32_OP_JALR) begin
                    jalr_total_increment = jalr_total_increment + 1'b1;
                    if (update_correct)
                        jalr_correct_increment = jalr_correct_increment + 1'b1;
                end
            end
        end
    end

    always @(posedge clk_i) begin
        if (reset_i) begin
            for (sequential_state_index = 0; sequential_state_index < 64;
                    sequential_state_index = sequential_state_index + 1)
                bht[sequential_state_index] <= 2'b00;
            for (sequential_state_index = 0; sequential_state_index < 16;
                    sequential_state_index = sequential_state_index + 1) begin
                btb_valid[sequential_state_index] <= 1'b0;
                btb_pc[sequential_state_index] <= 32'd0;
                btb_target[sequential_state_index] <= 32'd0;
            end
            conditional_correct_reg <= 32'd0;
            conditional_total_reg <= 32'd0;
            jal_correct_reg <= 32'd0;
            jal_total_reg <= 32'd0;
            jalr_correct_reg <= 32'd0;
            jalr_total_reg <= 32'd0;
            control_correct_reg <= 32'd0;
            control_total_reg <= 32'd0;
        end else begin
            for (sequential_state_index = 0; sequential_state_index < 64;
                    sequential_state_index = sequential_state_index + 1)
                bht[sequential_state_index] <=
                    bht_next[sequential_state_index];

            for (sequential_update_lane_index = 0;
                    sequential_update_lane_index < BE_WIDTH;
                    sequential_update_lane_index =
                        sequential_update_lane_index + 1) begin
                if (update_valid_i[sequential_update_lane_index] &&
                        (update_op_i[
                            sequential_update_lane_index*`RV32_OP_WIDTH +:
                            `RV32_OP_WIDTH] == `RV32_OP_JALR)) begin
                    btb_valid[update_pc_i[
                        sequential_update_lane_index*32 + 2 +: 4]] <= 1'b1;
                    btb_pc[update_pc_i[
                        sequential_update_lane_index*32 + 2 +: 4]] <=
                        update_pc_i[
                            sequential_update_lane_index*32 +: 32];
                    btb_target[update_pc_i[
                        sequential_update_lane_index*32 + 2 +: 4]] <=
                        update_actual_next_pc_i[
                            sequential_update_lane_index*32 +: 32];
                end
            end

            conditional_correct_reg <= conditional_correct_reg +
                conditional_correct_increment;
            conditional_total_reg <= conditional_total_reg +
                conditional_total_increment;
            jal_correct_reg <= jal_correct_reg + jal_correct_increment;
            jal_total_reg <= jal_total_reg + jal_total_increment;
            jalr_correct_reg <= jalr_correct_reg + jalr_correct_increment;
            jalr_total_reg <= jalr_total_reg + jalr_total_increment;
            control_correct_reg <= control_correct_reg +
                control_correct_increment;
            control_total_reg <= control_total_reg +
                control_total_increment;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (!reset_i) begin
            for (assertion_lane_index = 0;
                    assertion_lane_index < BE_WIDTH;
                    assertion_lane_index = assertion_lane_index + 1) begin
                if (update_valid_i[assertion_lane_index] &&
                        !is_control(update_op_i[
                            assertion_lane_index*`RV32_OP_WIDTH +:
                            `RV32_OP_WIDTH])) begin
                    $display("ERROR rv32_branch_predictor non-control update");
                    $finish(1);
                end
                if (update_valid_i[assertion_lane_index] &&
                        ((update_op_i[
                            assertion_lane_index*`RV32_OP_WIDTH +:
                            `RV32_OP_WIDTH] == `RV32_OP_JAL) ||
                         (update_op_i[
                            assertion_lane_index*`RV32_OP_WIDTH +:
                            `RV32_OP_WIDTH] == `RV32_OP_JALR)) &&
                        !update_actual_taken_i[assertion_lane_index]) begin
                    $display("ERROR rv32_branch_predictor jump not taken");
                    $finish(1);
                end
            end
        end
    end
`endif

endmodule
