`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_mdu_reservation_stations_tb;

    parameter RS_ENTRIES = 4;
    parameter RS_INDEX_WIDTH = 2;
    parameter BE_WIDTH = 1;
    parameter PHYS_REGS = 64;
    parameter PHYS_REG_ADDR_WIDTH = 6;
    parameter ROB_ENTRIES = 32;
    parameter ROB_INDEX_WIDTH = 5;
    parameter ROB_TAG_WIDTH = ROB_INDEX_WIDTH + 2;

    reg clk_i;
    reg reset_i;
    reg flush_i;
    reg recover_i;

    reg [BE_WIDTH-1:0] mul_dispatch_valid_i;
    reg mul_dispatch_fire_i;
    reg [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] mul_dispatch_op_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] mul_dispatch_rob_tag_i;
    reg [BE_WIDTH-1:0] mul_dispatch_lhs_ready_i;
    reg [(BE_WIDTH*32)-1:0] mul_dispatch_lhs_value_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] mul_dispatch_lhs_phys_i;
    reg [BE_WIDTH-1:0] mul_dispatch_rhs_ready_i;
    reg [(BE_WIDTH*32)-1:0] mul_dispatch_rhs_value_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] mul_dispatch_rhs_phys_i;
    wire mul_dispatch_ready_o;
    wire [RS_INDEX_WIDTH:0] mul_occupancy_o;
    wire mul_response_valid_o;
    reg mul_response_ready_i;
    wire [31:0] mul_response_value_o;
    wire [ROB_TAG_WIDTH-1:0] mul_response_rob_tag_o;

    reg [BE_WIDTH-1:0] div_dispatch_valid_i;
    reg div_dispatch_fire_i;
    reg [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] div_dispatch_op_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] div_dispatch_rob_tag_i;
    reg [BE_WIDTH-1:0] div_dispatch_lhs_ready_i;
    reg [(BE_WIDTH*32)-1:0] div_dispatch_lhs_value_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] div_dispatch_lhs_phys_i;
    reg [BE_WIDTH-1:0] div_dispatch_rhs_ready_i;
    reg [(BE_WIDTH*32)-1:0] div_dispatch_rhs_value_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] div_dispatch_rhs_phys_i;
    wire div_dispatch_ready_o;
    wire [RS_INDEX_WIDTH:0] div_occupancy_o;
    wire div_response_valid_o;
    reg div_response_ready_i;
    wire [31:0] div_response_value_o;
    wire [ROB_TAG_WIDTH-1:0] div_response_rob_tag_o;

    reg [BE_WIDTH-1:0] broadcast_valid_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] broadcast_phys_i;
    reg [(BE_WIDTH*32)-1:0] broadcast_value_i;
    reg [ROB_INDEX_WIDTH-1:0] rob_head_index_i;
    reg [BE_WIDTH-1:0] rollback_valid_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_tag_i;

    integer test_count;
    integer vector_file;
    integer vector_result;
    integer vector_count;
    integer vector_class;
    reg [`RV32_OP_WIDTH-1:0] vector_op;
    reg [1:0] vector_ready_mask;
    integer vector_delay;
    integer vector_stall;
    integer wait_count;
    integer fill_index;
    integer selected_lane;
    reg [31:0] vector_lhs;
    reg [31:0] vector_rhs;
    reg [31:0] vector_expected;
    reg [ROB_TAG_WIDTH-1:0] vector_tag;
    reg [1023:0] vector_path;
    reg [ROB_TAG_WIDTH-1:0] first_tag;
    reg [31:0] first_value;

    rv32_multiply_reservation_station #(
        .MUL_RS_ENTRIES(RS_ENTRIES),
        .MUL_RS_INDEX_WIDTH(RS_INDEX_WIDTH),
        .BE_WIDTH(BE_WIDTH),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES),
        .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) multiply_station (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .recover_i(recover_i),
        .dispatch_valid_i(mul_dispatch_valid_i),
        .dispatch_fire_i(mul_dispatch_fire_i),
        .dispatch_op_i(mul_dispatch_op_i),
        .dispatch_rob_tag_i(mul_dispatch_rob_tag_i),
        .dispatch_lhs_ready_i(mul_dispatch_lhs_ready_i),
        .dispatch_lhs_value_i(mul_dispatch_lhs_value_i),
        .dispatch_lhs_phys_i(mul_dispatch_lhs_phys_i),
        .dispatch_rhs_ready_i(mul_dispatch_rhs_ready_i),
        .dispatch_rhs_value_i(mul_dispatch_rhs_value_i),
        .dispatch_rhs_phys_i(mul_dispatch_rhs_phys_i),
        .dispatch_ready_o(mul_dispatch_ready_o),
        .occupancy_o(mul_occupancy_o),
        .broadcast_valid_i(broadcast_valid_i),
        .broadcast_phys_i(broadcast_phys_i),
        .broadcast_value_i(broadcast_value_i),
        .rob_head_index_i(rob_head_index_i),
        .rollback_valid_i(rollback_valid_i),
        .rollback_tag_i(rollback_tag_i),
        .response_valid_o(mul_response_valid_o),
        .response_ready_i(mul_response_ready_i),
        .response_value_o(mul_response_value_o),
        .response_rob_tag_o(mul_response_rob_tag_o)
    );

    rv32_divide_reservation_station #(
        .DIV_RS_ENTRIES(RS_ENTRIES),
        .DIV_RS_INDEX_WIDTH(RS_INDEX_WIDTH),
        .BE_WIDTH(BE_WIDTH),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES),
        .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) divide_station (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .recover_i(recover_i),
        .dispatch_valid_i(div_dispatch_valid_i),
        .dispatch_fire_i(div_dispatch_fire_i),
        .dispatch_op_i(div_dispatch_op_i),
        .dispatch_rob_tag_i(div_dispatch_rob_tag_i),
        .dispatch_lhs_ready_i(div_dispatch_lhs_ready_i),
        .dispatch_lhs_value_i(div_dispatch_lhs_value_i),
        .dispatch_lhs_phys_i(div_dispatch_lhs_phys_i),
        .dispatch_rhs_ready_i(div_dispatch_rhs_ready_i),
        .dispatch_rhs_value_i(div_dispatch_rhs_value_i),
        .dispatch_rhs_phys_i(div_dispatch_rhs_phys_i),
        .dispatch_ready_o(div_dispatch_ready_o),
        .occupancy_o(div_occupancy_o),
        .broadcast_valid_i(broadcast_valid_i),
        .broadcast_phys_i(broadcast_phys_i),
        .broadcast_value_i(broadcast_value_i),
        .rob_head_index_i(rob_head_index_i),
        .rollback_valid_i(rollback_valid_i),
        .rollback_tag_i(rollback_tag_i),
        .response_valid_o(div_response_valid_o),
        .response_ready_i(div_response_ready_i),
        .response_value_o(div_response_value_o),
        .response_rob_tag_o(div_response_rob_tag_o)
    );

    task check;
        input condition;
        input integer code;
        begin
            test_count = test_count + 1;
            if (!condition) begin
                $display("FAIL rv32_mdu_reservation_stations code=%0d entries=%0d width=%0d time=%0t",
                    code, RS_ENTRIES, BE_WIDTH, $time);
                $finish(1);
            end
        end
    endtask

    task clock_edge;
        begin
            #4;
            clk_i = 1'b1;
            #1;
            clk_i = 1'b0;
            #5;
        end
    endtask

    task clear_inputs;
        begin
            flush_i = 1'b0;
            recover_i = 1'b0;
            mul_dispatch_valid_i = {BE_WIDTH{1'b0}};
            mul_dispatch_fire_i = 1'b0;
            mul_dispatch_op_i = {(BE_WIDTH*`RV32_OP_WIDTH){1'b0}};
            mul_dispatch_rob_tag_i =
                {(BE_WIDTH*ROB_TAG_WIDTH){1'b0}};
            mul_dispatch_lhs_ready_i = {BE_WIDTH{1'b1}};
            mul_dispatch_lhs_value_i = {(BE_WIDTH*32){1'b0}};
            mul_dispatch_lhs_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            mul_dispatch_rhs_ready_i = {BE_WIDTH{1'b1}};
            mul_dispatch_rhs_value_i = {(BE_WIDTH*32){1'b0}};
            mul_dispatch_rhs_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            div_dispatch_valid_i = {BE_WIDTH{1'b0}};
            div_dispatch_fire_i = 1'b0;
            div_dispatch_op_i = {(BE_WIDTH*`RV32_OP_WIDTH){1'b0}};
            div_dispatch_rob_tag_i =
                {(BE_WIDTH*ROB_TAG_WIDTH){1'b0}};
            div_dispatch_lhs_ready_i = {BE_WIDTH{1'b1}};
            div_dispatch_lhs_value_i = {(BE_WIDTH*32){1'b0}};
            div_dispatch_lhs_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            div_dispatch_rhs_ready_i = {BE_WIDTH{1'b1}};
            div_dispatch_rhs_value_i = {(BE_WIDTH*32){1'b0}};
            div_dispatch_rhs_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            broadcast_valid_i = {BE_WIDTH{1'b0}};
            broadcast_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            broadcast_value_i = {(BE_WIDTH*32){1'b0}};
            rollback_valid_i = {BE_WIDTH{1'b0}};
            rollback_tag_i = {(BE_WIDTH*ROB_TAG_WIDTH){1'b0}};
            mul_response_ready_i = 1'b0;
            div_response_ready_i = 1'b0;
        end
    endtask

    task reset_dut;
        begin
            clear_inputs;
            rob_head_index_i = {ROB_INDEX_WIDTH{1'b0}};
            reset_i = 1'b1;
            clock_edge;
            reset_i = 1'b0;
            #1;
            check(mul_occupancy_o == 0, 1);
            check(div_occupancy_o == 0, 2);
            check(!mul_response_valid_o, 3);
            check(!div_response_valid_o, 4);
        end
    endtask

    task set_mul_lane;
        input integer lane;
        input [`RV32_OP_WIDTH-1:0] op_value;
        input [31:0] lhs_value;
        input [31:0] rhs_value;
        input [ROB_TAG_WIDTH-1:0] tag_value;
        input lhs_ready_value;
        input rhs_ready_value;
        input [PHYS_REG_ADDR_WIDTH-1:0] lhs_phys_value;
        input [PHYS_REG_ADDR_WIDTH-1:0] rhs_phys_value;
        begin
            mul_dispatch_valid_i[lane] = 1'b1;
            mul_dispatch_op_i[lane*`RV32_OP_WIDTH +:
                `RV32_OP_WIDTH] = op_value;
            mul_dispatch_rob_tag_i[lane*ROB_TAG_WIDTH +:
                ROB_TAG_WIDTH] = tag_value;
            mul_dispatch_lhs_ready_i[lane] = lhs_ready_value;
            mul_dispatch_lhs_value_i[lane*32 +: 32] = lhs_value;
            mul_dispatch_lhs_phys_i[lane*PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH] = lhs_phys_value;
            mul_dispatch_rhs_ready_i[lane] = rhs_ready_value;
            mul_dispatch_rhs_value_i[lane*32 +: 32] = rhs_value;
            mul_dispatch_rhs_phys_i[lane*PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH] = rhs_phys_value;
        end
    endtask

    task set_div_lane;
        input integer lane;
        input [`RV32_OP_WIDTH-1:0] op_value;
        input [31:0] lhs_value;
        input [31:0] rhs_value;
        input [ROB_TAG_WIDTH-1:0] tag_value;
        input lhs_ready_value;
        input rhs_ready_value;
        input [PHYS_REG_ADDR_WIDTH-1:0] lhs_phys_value;
        input [PHYS_REG_ADDR_WIDTH-1:0] rhs_phys_value;
        begin
            div_dispatch_valid_i[lane] = 1'b1;
            div_dispatch_op_i[lane*`RV32_OP_WIDTH +:
                `RV32_OP_WIDTH] = op_value;
            div_dispatch_rob_tag_i[lane*ROB_TAG_WIDTH +:
                ROB_TAG_WIDTH] = tag_value;
            div_dispatch_lhs_ready_i[lane] = lhs_ready_value;
            div_dispatch_lhs_value_i[lane*32 +: 32] = lhs_value;
            div_dispatch_lhs_phys_i[lane*PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH] = lhs_phys_value;
            div_dispatch_rhs_ready_i[lane] = rhs_ready_value;
            div_dispatch_rhs_value_i[lane*32 +: 32] = rhs_value;
            div_dispatch_rhs_phys_i[lane*PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH] = rhs_phys_value;
        end
    endtask

    task dispatch_mul;
        input integer lane;
        input [`RV32_OP_WIDTH-1:0] op_value;
        input [31:0] lhs_value;
        input [31:0] rhs_value;
        input [ROB_TAG_WIDTH-1:0] tag_value;
        input lhs_ready_value;
        input rhs_ready_value;
        input [PHYS_REG_ADDR_WIDTH-1:0] lhs_phys_value;
        input [PHYS_REG_ADDR_WIDTH-1:0] rhs_phys_value;
        begin
            clear_inputs;
            set_mul_lane(lane, op_value, lhs_value, rhs_value, tag_value,
                lhs_ready_value, rhs_ready_value,
                lhs_phys_value, rhs_phys_value);
            #1;
            check(mul_dispatch_ready_o, 10);
            mul_dispatch_fire_i = 1'b1;
            clock_edge;
            clear_inputs;
        end
    endtask

    task dispatch_div;
        input integer lane;
        input [`RV32_OP_WIDTH-1:0] op_value;
        input [31:0] lhs_value;
        input [31:0] rhs_value;
        input [ROB_TAG_WIDTH-1:0] tag_value;
        input lhs_ready_value;
        input rhs_ready_value;
        input [PHYS_REG_ADDR_WIDTH-1:0] lhs_phys_value;
        input [PHYS_REG_ADDR_WIDTH-1:0] rhs_phys_value;
        begin
            clear_inputs;
            set_div_lane(lane, op_value, lhs_value, rhs_value, tag_value,
                lhs_ready_value, rhs_ready_value,
                lhs_phys_value, rhs_phys_value);
            #1;
            check(div_dispatch_ready_o, 11);
            div_dispatch_fire_i = 1'b1;
            clock_edge;
            clear_inputs;
        end
    endtask

    task wait_mul_response;
        input [ROB_TAG_WIDTH-1:0] expected_tag;
        input [31:0] expected_value;
        input integer code;
        begin
            wait_count = 0;
            while (!mul_response_valid_o && (wait_count < 50)) begin
                clock_edge;
                wait_count = wait_count + 1;
            end
            check(mul_response_valid_o, code);
            check(mul_response_rob_tag_o == expected_tag, code + 1);
            check(mul_response_value_o == expected_value, code + 2);
        end
    endtask

    task wait_div_response;
        input [ROB_TAG_WIDTH-1:0] expected_tag;
        input [31:0] expected_value;
        input integer code;
        begin
            wait_count = 0;
            while (!div_response_valid_o && (wait_count < 50)) begin
                clock_edge;
                wait_count = wait_count + 1;
            end
            check(div_response_valid_o, code);
            check(div_response_rob_tag_o == expected_tag, code + 1);
            check(div_response_value_o == expected_value, code + 2);
        end
    endtask

    task consume_mul;
        begin
            mul_response_ready_i = 1'b1;
            clock_edge;
            mul_response_ready_i = 1'b0;
        end
    endtask

    task consume_div;
        begin
            div_response_ready_i = 1'b1;
            clock_edge;
            div_response_ready_i = 1'b0;
        end
    endtask

    task test_oldest_and_reuse;
        reg [ROB_TAG_WIDTH-1:0] tag_near;
        reg [ROB_TAG_WIDTH-1:0] tag_far;
        begin
            reset_dut;
            clear_inputs;
            for (fill_index = 0; fill_index < BE_WIDTH;
                    fill_index = fill_index + 1) begin
                set_mul_lane(fill_index, `RV32_OP_MUL,
                    32'd0, fill_index + 1,
                    fill_index[ROB_TAG_WIDTH-1:0],
                    1'b0, 1'b1, 6, 0);
            end
            #1;
            check(mul_dispatch_ready_o, 19);
            mul_dispatch_fire_i = 1'b1;
            clock_edge;
            clear_inputs;
            #1;
            check(mul_occupancy_o == BE_WIDTH, 20);
            flush_i = 1'b1;
            clock_edge;
            clear_inputs;

            rob_head_index_i = {ROB_INDEX_WIDTH{1'b1}} - 1'b1;
            tag_far = 1;
            tag_near = ROB_ENTRIES - 1;
            dispatch_mul(0, `RV32_OP_MUL, 32'd0, 32'd5,
                tag_far, 1'b0, 1'b1, 7, 0);
            dispatch_mul(BE_WIDTH-1, `RV32_OP_MUL, 32'd0, 32'd9,
                tag_near, 1'b0, 1'b1, 7, 0);
            broadcast_valid_i[0] = 1'b1;
            broadcast_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = 7;
            broadcast_value_i[31:0] = 32'd6;
            clock_edge;
            clear_inputs;
            wait_mul_response(tag_near, 32'd54, 21);
            consume_mul;
            wait_mul_response(tag_far, 32'd30, 24);
            consume_mul;

            reset_dut;
            for (fill_index = 0; fill_index < RS_ENTRIES;
                    fill_index = fill_index + 1) begin
                dispatch_mul(fill_index % BE_WIDTH, `RV32_OP_MUL,
                    32'd0, fill_index + 1,
                    fill_index[ROB_TAG_WIDTH-1:0],
                    1'b0, 1'b1, 8, 0);
            end
            #1;
            check(mul_occupancy_o == RS_ENTRIES, 30);
            broadcast_valid_i[0] = 1'b1;
            broadcast_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = 8;
            broadcast_value_i[31:0] = 32'd2;
            set_mul_lane(BE_WIDTH-1, `RV32_OP_MUL, 32'd3, 32'd4,
                ROB_ENTRIES, 1'b1, 1'b1, 0, 0);
            #1;
            check(mul_dispatch_ready_o, 31);
            mul_dispatch_fire_i = 1'b1;
            clock_edge;
            clear_inputs;
            #1;
            check(mul_occupancy_o == RS_ENTRIES, 32);
            flush_i = 1'b1;
            clock_edge;
            clear_inputs;
        end
    endtask

    task test_divider_turnaround;
        begin
            reset_dut;
            dispatch_div(0, `RV32_OP_DIVU, 32'd100, 32'd5,
                30, 1'b1, 1'b1, 0, 0);
            dispatch_div(BE_WIDTH-1, `RV32_OP_REMU, 32'd77, 32'd6,
                31, 1'b1, 1'b1, 0, 0);
            wait_div_response(30, 32'd20, 70);
            #1;
            check(div_occupancy_o == 1, 73);
            div_response_ready_i = 1'b1;
            clock_edge;
            div_response_ready_i = 1'b0;
            #1;
            check(div_occupancy_o == 0, 74);
            wait_div_response(31, 32'd5, 75);
            consume_div;
        end
    endtask

    task test_recovery_and_flush;
        reg [ROB_TAG_WIDTH-1:0] saved_tag;
        reg [31:0] saved_value;
        begin
            reset_dut;
            dispatch_div(0, `RV32_OP_DIVU, 32'd100, 32'd4,
                6, 1'b0, 1'b1, 9, 0);
            dispatch_div(BE_WIDTH-1, `RV32_OP_REMU, 32'd101, 32'd4,
                7, 1'b0, 1'b1, 10, 0);
            #1;
            check(div_occupancy_o == 2, 40);
            recover_i = 1'b1;
            rollback_valid_i[0] = 1'b1;
            rollback_tag_i[ROB_TAG_WIDTH-1:0] = 7;
            #1;
            check(!div_dispatch_ready_o, 41);
            clock_edge;
            clear_inputs;
            #1;
            check(div_occupancy_o == 1, 42);
            flush_i = 1'b1;
            clock_edge;
            clear_inputs;

            reset_dut;
            dispatch_mul(0, `RV32_OP_MUL, 32'd13, 32'd17,
                11, 1'b1, 1'b1, 0, 0);
            wait_mul_response(11, 32'd221, 43);
            saved_tag = mul_response_rob_tag_o;
            saved_value = mul_response_value_o;
            recover_i = 1'b1;
            mul_response_ready_i = 1'b1;
            #1;
            check(!mul_response_valid_o, 46);
            clock_edge;
            recover_i = 1'b0;
            mul_response_ready_i = 1'b0;
            #1;
            check(mul_response_valid_o, 47);
            check(mul_response_rob_tag_o == saved_tag, 48);
            check(mul_response_value_o == saved_value, 49);
            consume_mul;

            reset_dut;
            dispatch_div(0, `RV32_OP_DIV, 32'h80000000, 32'hffffffff,
                12, 1'b1, 1'b1, 0, 0);
            repeat (4) clock_edge;
            flush_i = 1'b1;
            clock_edge;
            clear_inputs;
            for (wait_count = 0; wait_count < 40;
                    wait_count = wait_count + 1) begin
                clock_edge;
                check(!div_response_valid_o, 50);
            end
        end
    endtask

    task test_completion_collision;
        begin
            reset_dut;
            dispatch_div(0, `RV32_OP_DIVU, 32'd100, 32'd7,
                20, 1'b1, 1'b1, 0, 0);
            repeat (5) clock_edge;
            dispatch_mul(BE_WIDTH-1, `RV32_OP_MUL, 32'd20, 32'd30,
                21, 1'b1, 1'b1, 0, 0);
            wait_count = 0;
            while (!(mul_response_valid_o && div_response_valid_o) &&
                    (wait_count < 50)) begin
                clock_edge;
                wait_count = wait_count + 1;
            end
            check(mul_response_valid_o && div_response_valid_o, 60);
            check(mul_response_rob_tag_o == 21, 61);
            check(mul_response_value_o == 32'd600, 62);
            check(div_response_rob_tag_o == 20, 63);
            check(div_response_value_o == 32'd14, 64);
            mul_response_ready_i = 1'b1;
            div_response_ready_i = 1'b0;
            clock_edge;
            mul_response_ready_i = 1'b0;
            #1;
            check(!mul_response_valid_o, 65);
            check(div_response_valid_o, 66);
            check(div_response_rob_tag_o == 20, 67);
            check(div_response_value_o == 32'd14, 68);
            consume_div;
        end
    endtask

    task run_vectors;
        begin
            reset_dut;
            vector_count = 0;
            while (!$feof(vector_file)) begin
                vector_result = $fscanf(vector_file,
                    "%d %d %h %h %h %h %d %d %d\n",
                    vector_class, vector_op, vector_lhs, vector_rhs,
                    vector_expected, vector_tag, vector_ready_mask,
                    vector_delay, vector_stall);
                if (vector_result == 9) begin
                    selected_lane = vector_count % BE_WIDTH;
                    if (vector_class == 0) begin
                        dispatch_mul(selected_lane, vector_op,
                            vector_lhs, vector_rhs, vector_tag,
                            vector_ready_mask[0], vector_ready_mask[1],
                            13, 14);
                    end else begin
                        dispatch_div(selected_lane, vector_op,
                            vector_lhs, vector_rhs, vector_tag,
                            vector_ready_mask[0], vector_ready_mask[1],
                            13, 14);
                    end
                    repeat (vector_delay) clock_edge;
                    if (!vector_ready_mask[0]) begin
                        broadcast_valid_i[0] = 1'b1;
                        broadcast_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = 13;
                        broadcast_value_i[31:0] = vector_lhs;
                        clock_edge;
                        broadcast_valid_i = {BE_WIDTH{1'b0}};
                    end
                    if (!vector_ready_mask[1]) begin
                        broadcast_valid_i[0] = 1'b1;
                        broadcast_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = 14;
                        broadcast_value_i[31:0] = vector_rhs;
                        clock_edge;
                        broadcast_valid_i = {BE_WIDTH{1'b0}};
                    end
                    if (vector_class == 0) begin
                        wait_mul_response(vector_tag, vector_expected, 100);
                        first_tag = mul_response_rob_tag_o;
                        first_value = mul_response_value_o;
                        repeat (vector_stall) begin
                            clock_edge;
                            check(mul_response_valid_o, 103);
                            check(mul_response_rob_tag_o == first_tag, 104);
                            check(mul_response_value_o == first_value, 105);
                        end
                        consume_mul;
                    end else begin
                        wait_div_response(vector_tag, vector_expected, 110);
                        first_tag = div_response_rob_tag_o;
                        first_value = div_response_value_o;
                        repeat (vector_stall) begin
                            clock_edge;
                            check(div_response_valid_o, 113);
                            check(div_response_rob_tag_o == first_tag, 114);
                            check(div_response_value_o == first_value, 115);
                        end
                        consume_div;
                    end
                    vector_count = vector_count + 1;
                end
            end
            check(vector_count > 100, 120);
        end
    endtask

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b0;
        test_count = 0;
        vector_count = 0;
        vector_path = "build/mdu_rs_vectors.txt";
        if ($value$plusargs("VECTOR_FILE=%s", vector_path)) begin
            vector_path = vector_path;
        end
        vector_file = $fopen(vector_path, "r");
        if (vector_file == 0) begin
            $display("FAIL rv32_mdu_reservation_stations cannot open vector file");
            $finish(1);
        end

        clear_inputs;
        test_oldest_and_reuse;
        test_recovery_and_flush;
        test_completion_collision;
        test_divider_turnaround;
        run_vectors;
        $fclose(vector_file);
        $display("PASS rv32_mdu_reservation_stations tests=%0d vectors=%0d entries=%0d width=%0d",
            test_count, vector_count, RS_ENTRIES, BE_WIDTH);
        $finish(0);
    end

endmodule

/* verilator lint_off DECLFILENAME */

module rv32_mdu_reservation_station_bad_op_tb;

    reg clk_i;
    reg reset_i;
    reg dispatch_valid_i;
    reg dispatch_fire_i;
    wire dispatch_ready;
    wire [2:0] occupancy;
    wire request_valid;
    wire [`RV32_OP_WIDTH-1:0] request_op;
    wire [31:0] request_lhs;
    wire [31:0] request_rhs;
    wire [6:0] request_rob_tag;

    rv32_mdu_reservation_station_core #(
        .RS_ENTRIES(4),
        .RS_INDEX_WIDTH(2),
        .BE_WIDTH(1),
        .PHYS_REGS(64),
        .PHYS_REG_ADDR_WIDTH(6),
        .ROB_ENTRIES(32),
        .ROB_INDEX_WIDTH(5),
        .ROB_TAG_WIDTH(7),
        .OP_CLASS(0)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(1'b0),
        .recover_i(1'b0),
        .dispatch_valid_i(dispatch_valid_i),
        .dispatch_fire_i(dispatch_fire_i),
        .dispatch_op_i(`RV32_OP_DIV),
        .dispatch_rob_tag_i(7'd1),
        .dispatch_lhs_ready_i(1'b1),
        .dispatch_lhs_value_i(32'd8),
        .dispatch_lhs_phys_i(6'd0),
        .dispatch_rhs_ready_i(1'b1),
        .dispatch_rhs_value_i(32'd2),
        .dispatch_rhs_phys_i(6'd0),
        .dispatch_ready_o(dispatch_ready),
        .occupancy_o(occupancy),
        .broadcast_valid_i(1'b0),
        .broadcast_phys_i(6'd0),
        .broadcast_value_i(32'd0),
        .rob_head_index_i(5'd0),
        .rollback_valid_i(1'b0),
        .rollback_tag_i(7'd0),
        .request_valid_o(request_valid),
        .request_ready_i(1'b0),
        .request_op_o(request_op),
        .request_lhs_o(request_lhs),
        .request_rhs_o(request_rhs),
        .request_rob_tag_o(request_rob_tag)
    );

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b1;
        dispatch_valid_i = 1'b0;
        dispatch_fire_i = 1'b0;
        #5;
        clk_i = 1'b1;
        #5;
        clk_i = 1'b0;
        reset_i = 1'b0;
        dispatch_valid_i = 1'b1;
        dispatch_fire_i = 1'b1;
        #5;
        clk_i = 1'b1;
        #5;
        $display("FAIL rv32_mdu_reservation_station_bad_op_tb accepted bad op");
        $finish(1);
    end

endmodule

/* verilator lint_on DECLFILENAME */
