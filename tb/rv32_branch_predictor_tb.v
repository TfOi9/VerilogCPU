`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_branch_predictor_tb;

    parameter FE_WIDTH = 1;
    parameter BE_WIDTH = 1;

    reg clk_i;
    reg reset_i;
    reg [FE_WIDTH-1:0] query_valid_i;
    reg [(FE_WIDTH*`RV32_OP_WIDTH)-1:0] query_op_i;
    reg [(FE_WIDTH*32)-1:0] query_pc_i;
    reg [(FE_WIDTH*32)-1:0] query_immediate_i;
    wire [FE_WIDTH-1:0] prediction_valid_o;
    wire [FE_WIDTH-1:0] prediction_taken_o;
    wire [FE_WIDTH-1:0] prediction_btb_hit_o;
    wire [(FE_WIDTH*32)-1:0] prediction_next_pc_o;
    reg [BE_WIDTH-1:0] update_valid_i;
    reg [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] update_op_i;
    reg [(BE_WIDTH*32)-1:0] update_pc_i;
    reg [(BE_WIDTH*32)-1:0] update_predicted_next_pc_i;
    reg [(BE_WIDTH*32)-1:0] update_actual_next_pc_i;
    reg [BE_WIDTH-1:0] update_actual_taken_i;
    wire [31:0] conditional_correct_o;
    wire [31:0] conditional_total_o;
    wire [31:0] jal_correct_o;
    wire [31:0] jal_total_o;
    wire [31:0] jalr_correct_o;
    wire [31:0] jalr_total_o;
    wire [31:0] control_correct_o;
    wire [31:0] control_total_o;

    integer checks;
    integer errors;
    integer lane;
    reg [`RV32_OP_WIDTH-1:0] branch_ops [0:5];

    rv32_branch_predictor #(
        .FE_WIDTH(FE_WIDTH),
        .BE_WIDTH(BE_WIDTH)
    ) predictor (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .query_valid_i(query_valid_i),
        .query_op_i(query_op_i),
        .query_pc_i(query_pc_i),
        .query_immediate_i(query_immediate_i),
        .prediction_valid_o(prediction_valid_o),
        .prediction_taken_o(prediction_taken_o),
        .prediction_btb_hit_o(prediction_btb_hit_o),
        .prediction_next_pc_o(prediction_next_pc_o),
        .update_valid_i(update_valid_i),
        .update_op_i(update_op_i),
        .update_pc_i(update_pc_i),
        .update_predicted_next_pc_i(update_predicted_next_pc_i),
        .update_actual_next_pc_i(update_actual_next_pc_i),
        .update_actual_taken_i(update_actual_taken_i),
        .conditional_correct_o(conditional_correct_o),
        .conditional_total_o(conditional_total_o),
        .jal_correct_o(jal_correct_o),
        .jal_total_o(jal_total_o),
        .jalr_correct_o(jalr_correct_o),
        .jalr_total_o(jalr_total_o),
        .control_correct_o(control_correct_o),
        .control_total_o(control_total_o)
    );

    always #5 clk_i = ~clk_i;

    task clear_queries;
        begin
            query_valid_i = {FE_WIDTH{1'b0}};
            query_op_i = {(FE_WIDTH*`RV32_OP_WIDTH){1'b0}};
            query_pc_i = {(FE_WIDTH*32){1'b0}};
            query_immediate_i = {(FE_WIDTH*32){1'b0}};
        end
    endtask

    task clear_updates;
        begin
            update_valid_i = {BE_WIDTH{1'b0}};
            update_op_i = {(BE_WIDTH*`RV32_OP_WIDTH){1'b0}};
            update_pc_i = {(BE_WIDTH*32){1'b0}};
            update_predicted_next_pc_i = {(BE_WIDTH*32){1'b0}};
            update_actual_next_pc_i = {(BE_WIDTH*32){1'b0}};
            update_actual_taken_i = {BE_WIDTH{1'b0}};
        end
    endtask

    task tick;
        begin
            @(posedge clk_i);
            #1;
        end
    endtask

    task reset_predictor;
        begin
            reset_i = 1'b1;
            clear_queries;
            clear_updates;
            tick;
            tick;
            reset_i = 1'b0;
            #1;
        end
    endtask

    task set_query;
        input integer query_lane;
        input [`RV32_OP_WIDTH-1:0] op;
        input [31:0] pc;
        input [31:0] immediate;
        begin
            query_valid_i[query_lane] = 1'b1;
            query_op_i[query_lane*`RV32_OP_WIDTH +: `RV32_OP_WIDTH] = op;
            query_pc_i[query_lane*32 +: 32] = pc;
            query_immediate_i[query_lane*32 +: 32] = immediate;
            #1;
        end
    endtask

    task set_update;
        input integer update_lane;
        input [`RV32_OP_WIDTH-1:0] op;
        input [31:0] pc;
        input [31:0] predicted_next_pc;
        input [31:0] actual_next_pc;
        input actual_taken;
        begin
            update_valid_i[update_lane] = 1'b1;
            update_op_i[update_lane*`RV32_OP_WIDTH +: `RV32_OP_WIDTH] = op;
            update_pc_i[update_lane*32 +: 32] = pc;
            update_predicted_next_pc_i[update_lane*32 +: 32] =
                predicted_next_pc;
            update_actual_next_pc_i[update_lane*32 +: 32] =
                actual_next_pc;
            update_actual_taken_i[update_lane] = actual_taken;
        end
    endtask

    task apply_update;
        input [`RV32_OP_WIDTH-1:0] op;
        input [31:0] pc;
        input [31:0] predicted_next_pc;
        input [31:0] actual_next_pc;
        input actual_taken;
        begin
            clear_updates;
            set_update(0, op, pc, predicted_next_pc,
                actual_next_pc, actual_taken);
            tick;
            clear_updates;
            #1;
        end
    endtask

    task expect_prediction;
        input integer query_lane;
        input expected_valid;
        input expected_taken;
        input expected_btb_hit;
        input [31:0] expected_next_pc;
        begin
            checks = checks + 1;
            if ((prediction_valid_o[query_lane] !== expected_valid) ||
                    (prediction_taken_o[query_lane] !== expected_taken) ||
                    (prediction_btb_hit_o[query_lane] !==
                        expected_btb_hit) ||
                    (prediction_next_pc_o[query_lane*32 +: 32] !==
                        expected_next_pc)) begin
                errors = errors + 1;
                $display("ERROR prediction lane=%0d got=%b/%b/%b/%h expected=%b/%b/%b/%h",
                    query_lane, prediction_valid_o[query_lane],
                    prediction_taken_o[query_lane],
                    prediction_btb_hit_o[query_lane],
                    prediction_next_pc_o[query_lane*32 +: 32],
                    expected_valid, expected_taken, expected_btb_hit,
                    expected_next_pc);
            end
        end
    endtask

    task expect_stats;
        input [31:0] conditional_correct;
        input [31:0] conditional_total;
        input [31:0] jal_correct;
        input [31:0] jal_total;
        input [31:0] jalr_correct;
        input [31:0] jalr_total;
        input [31:0] control_correct;
        input [31:0] control_total;
        begin
            checks = checks + 1;
            if ((conditional_correct_o !== conditional_correct) ||
                    (conditional_total_o !== conditional_total) ||
                    (jal_correct_o !== jal_correct) ||
                    (jal_total_o !== jal_total) ||
                    (jalr_correct_o !== jalr_correct) ||
                    (jalr_total_o !== jalr_total) ||
                    (control_correct_o !== control_correct) ||
                    (control_total_o !== control_total)) begin
                errors = errors + 1;
                $display("ERROR stats cond=%0d/%0d jal=%0d/%0d jalr=%0d/%0d control=%0d/%0d",
                    conditional_correct_o, conditional_total_o,
                    jal_correct_o, jal_total_o,
                    jalr_correct_o, jalr_total_o,
                    control_correct_o, control_total_o);
            end
        end
    endtask

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b1;
        checks = 0;
        errors = 0;
        branch_ops[0] = `RV32_OP_BEQ;
        branch_ops[1] = `RV32_OP_BNE;
        branch_ops[2] = `RV32_OP_BLT;
        branch_ops[3] = `RV32_OP_BGE;
        branch_ops[4] = `RV32_OP_BLTU;
        branch_ops[5] = `RV32_OP_BGEU;
        clear_queries;
        clear_updates;

        reset_predictor;
        expect_stats(0, 0, 0, 0, 0, 0, 0, 0);
        expect_prediction(0, 0, 0, 0, 0);

        set_query(0, `RV32_OP_ADD, 32'h00001000, 32'd8);
        expect_prediction(0, 0, 0, 0, 0);
        clear_queries;
        set_query(0, `RV32_OP_BEQ, 32'h00001000, 32'd16);
        expect_prediction(0, 1, 0, 0, 32'h00001004);

        apply_update(`RV32_OP_BEQ, 32'h00001000,
            32'h00001004, 32'h00001010, 1'b1);
        expect_prediction(0, 1, 0, 0, 32'h00001004);
        apply_update(`RV32_OP_BEQ, 32'h00001000,
            32'h00001004, 32'h00001010, 1'b1);
        expect_prediction(0, 1, 1, 0, 32'h00001010);

        for (lane = 0; lane < 6; lane = lane + 1) begin
            clear_queries;
            set_query(0, branch_ops[lane], 32'h00001100, 32'd16);
            expect_prediction(0, 1, 1, 0, 32'h00001110);
        end

        apply_update(`RV32_OP_BEQ, 32'h00001000,
            32'h00001010, 32'h00001010, 1'b1);
        apply_update(`RV32_OP_BEQ, 32'h00001000,
            32'h00001010, 32'h00001010, 1'b1);
        apply_update(`RV32_OP_BEQ, 32'h00001000,
            32'h00001010, 32'h00001004, 1'b0);
        expect_prediction(0, 1, 1, 0, 32'h00001110);
        apply_update(`RV32_OP_BEQ, 32'h00001000,
            32'h00001010, 32'h00001004, 1'b0);
        expect_prediction(0, 1, 0, 0, 32'h00001104);
        apply_update(`RV32_OP_BEQ, 32'h00001000,
            32'h00001010, 32'h00001004, 1'b0);
        apply_update(`RV32_OP_BEQ, 32'h00001000,
            32'h00001010, 32'h00001004, 1'b0);
        expect_prediction(0, 1, 0, 0, 32'h00001104);

        reset_predictor;
        clear_queries;
        set_query(0, `RV32_OP_JAL, 32'h00001000, 32'd256);
        expect_prediction(0, 1, 1, 0, 32'h00001100);
        set_query(0, `RV32_OP_JAL, 32'h00001000, 32'hfffffffc);
        expect_prediction(0, 1, 1, 0, 32'h00000ffc);
        set_query(0, `RV32_OP_JAL, 32'hfffffff8, 32'd16);
        expect_prediction(0, 1, 1, 0, 32'h00000008);

        clear_queries;
        set_query(0, `RV32_OP_JALR, 32'h00002000, 32'd0);
        expect_prediction(0, 1, 0, 0, 32'h00002004);
        clear_updates;
        set_update(0, `RV32_OP_JALR, 32'h00002000,
            32'h00002004, 32'h00008000, 1'b1);
        #1;
        expect_prediction(0, 1, 0, 0, 32'h00002004);
        tick;
        clear_updates;
        #1;
        expect_prediction(0, 1, 1, 1, 32'h00008000);

        clear_queries;
        set_query(0, `RV32_OP_JALR, 32'h00002400, 32'd0);
        expect_prediction(0, 1, 0, 0, 32'h00002404);
        apply_update(`RV32_OP_JALR, 32'h00002400,
            32'h00002404, 32'h00009998, 1'b1);
        expect_prediction(0, 1, 1, 1, 32'h00009998);
        clear_queries;
        set_query(0, `RV32_OP_JALR, 32'h00002000, 32'd0);
        expect_prediction(0, 1, 0, 0, 32'h00002004);

        reset_predictor;
        apply_update(`RV32_OP_JAL, 32'h00001000,
            32'h00001100, 32'h00001100, 1'b1);
        clear_queries;
        set_query(0, `RV32_OP_BEQ, 32'h00001000, 32'd8);
        expect_prediction(0, 1, 0, 0, 32'h00001004);
        apply_update(`RV32_OP_JALR, 32'h00001000,
            32'h00001004, 32'h00008000, 1'b1);
        expect_prediction(0, 1, 0, 0, 32'h00001004);

        reset_predictor;
        apply_update(`RV32_OP_BEQ, 32'h00001000,
            32'h00001008, 32'h00001008, 1'b1);
        apply_update(`RV32_OP_BNE, 32'h00002000,
            32'h00002004, 32'h00003000, 1'b1);
        apply_update(`RV32_OP_JAL, 32'h00003000,
            32'h00004000, 32'h00004000, 1'b1);
        apply_update(`RV32_OP_JALR, 32'h00004000,
            32'h00004004, 32'h00009000, 1'b1);
        expect_stats(1, 2, 1, 1, 0, 1, 2, 4);
        clear_queries;
        set_query(0, `RV32_OP_BEQ, 32'h00005000, 32'd8);
        tick;
        expect_stats(1, 2, 1, 1, 0, 1, 2, 4);

        reset_predictor;
        clear_updates;
        for (lane = 0; lane < BE_WIDTH; lane = lane + 1)
            set_update(lane, `RV32_OP_BEQ, 32'h00001000,
                32'h00001004, 32'h00001008, 1'b1);
        tick;
        clear_updates;
        clear_queries;
        set_query(0, `RV32_OP_BEQ, 32'h00001000, 32'd8);
        expect_prediction(0, 1, (BE_WIDTH >= 2), 0,
            (BE_WIDTH >= 2) ? 32'h00001008 : 32'h00001004);
        expect_stats(0, BE_WIDTH, 0, 0, 0, 0, 0, BE_WIDTH);

        if (BE_WIDTH >= 2) begin
            reset_predictor;
            clear_updates;
            set_update(0, `RV32_OP_JALR, 32'h00002000,
                32'h00002004, 32'h00008000, 1'b1);
            set_update(BE_WIDTH-1, `RV32_OP_JALR, 32'h00002400,
                32'h00002404, 32'h00009000, 1'b1);
            tick;
            clear_updates;
            clear_queries;
            set_query(0, `RV32_OP_JALR, 32'h00002400, 32'd0);
            expect_prediction(0, 1, 1, 1, 32'h00009000);
            clear_queries;
            set_query(0, `RV32_OP_JALR, 32'h00002000, 32'd0);
            expect_prediction(0, 1, 0, 0, 32'h00002004);
        end

        if (FE_WIDTH >= 2) begin
            clear_queries;
            set_query(0, `RV32_OP_JAL, 32'h00001000, 32'd32);
            set_query(FE_WIDTH-1, `RV32_OP_BEQ,
                32'h00003004, 32'd12);
            expect_prediction(0, 1, 1, 0, 32'h00001020);
            expect_prediction(FE_WIDTH-1, 1, 0, 0, 32'h00003008);
        end

        reset_predictor;
        if ((prediction_valid_o !== {FE_WIDTH{1'b0}}) ||
                (prediction_taken_o !== {FE_WIDTH{1'b0}}) ||
                (prediction_btb_hit_o !== {FE_WIDTH{1'b0}}) ||
                (prediction_next_pc_o !== {(FE_WIDTH*32){1'b0}})) begin
            errors = errors + 1;
            $display("ERROR reset did not clear prediction outputs");
        end
        expect_stats(0, 0, 0, 0, 0, 0, 0, 0);

        if (errors != 0) begin
            $display("FAIL rv32_branch_predictor checks=%0d errors=%0d",
                checks, errors);
            $finish(1);
        end
        $display("PASS rv32_branch_predictor FE_WIDTH=%0d BE_WIDTH=%0d checks=%0d",
            FE_WIDTH, BE_WIDTH, checks);
        $finish(0);
    end

endmodule

module rv32_branch_predictor_protocol_tb;

    parameter VIOLATION = 0;

    reg clk_i;
    reg reset_i;
    reg update_valid_i;
    reg [`RV32_OP_WIDTH-1:0] update_op_i;
    reg update_actual_taken_i;

    rv32_branch_predictor predictor (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .query_valid_i(1'b0),
        .query_op_i({`RV32_OP_WIDTH{1'b0}}),
        .query_pc_i(32'd0),
        .query_immediate_i(32'd0),
        .prediction_valid_o(),
        .prediction_taken_o(),
        .prediction_btb_hit_o(),
        .prediction_next_pc_o(),
        .update_valid_i(update_valid_i),
        .update_op_i(update_op_i),
        .update_pc_i(32'h00001000),
        .update_predicted_next_pc_i(32'h00001004),
        .update_actual_next_pc_i(32'h00001008),
        .update_actual_taken_i(update_actual_taken_i),
        .conditional_correct_o(),
        .conditional_total_o(),
        .jal_correct_o(),
        .jal_total_o(),
        .jalr_correct_o(),
        .jalr_total_o(),
        .control_correct_o(),
        .control_total_o()
    );

    always #5 clk_i = ~clk_i;

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b1;
        update_valid_i = 1'b0;
        update_op_i = `RV32_OP_INVALID;
        update_actual_taken_i = 1'b0;
        @(posedge clk_i);
        @(negedge clk_i);
        reset_i = 1'b0;
        update_valid_i = 1'b1;
        if (VIOLATION == 1) begin
            update_op_i = `RV32_OP_ADD;
            update_actual_taken_i = 1'b0;
        end else begin
            update_op_i = `RV32_OP_JALR;
            update_actual_taken_i = 1'b0;
        end
        @(posedge clk_i);
        #1;
        $display("ERROR protocol violation was not rejected");
        $finish(1);
    end

endmodule
