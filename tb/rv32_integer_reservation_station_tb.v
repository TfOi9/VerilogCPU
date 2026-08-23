`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_integer_reservation_station_tb;

    parameter INT_RS_ENTRIES = 8;
    parameter INT_RS_INDEX_WIDTH = 3;
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
    reg [BE_WIDTH-1:0] dispatch_valid_i;
    reg dispatch_fire_i;
    reg [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] dispatch_op_i;
    reg [(BE_WIDTH*32)-1:0] dispatch_pc_i;
    reg [(BE_WIDTH*32)-1:0] dispatch_immediate_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] dispatch_rob_tag_i;
    reg [BE_WIDTH-1:0] dispatch_lhs_ready_i;
    reg [(BE_WIDTH*32)-1:0] dispatch_lhs_value_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] dispatch_lhs_phys_i;
    reg [BE_WIDTH-1:0] dispatch_rhs_ready_i;
    reg [(BE_WIDTH*32)-1:0] dispatch_rhs_value_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] dispatch_rhs_phys_i;
    wire dispatch_ready_o;
    wire [INT_RS_INDEX_WIDTH:0] occupancy_o;
    reg [BE_WIDTH-1:0] broadcast_valid_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] broadcast_phys_i;
    reg [(BE_WIDTH*32)-1:0] broadcast_value_i;
    reg [ROB_INDEX_WIDTH-1:0] rob_head_index_i;
    reg [BE_WIDTH-1:0] rollback_valid_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_tag_i;
    wire [BE_WIDTH-1:0] issue_valid_o;
    reg [BE_WIDTH-1:0] issue_ready_i;
    wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] issue_op_o;
    wire [(BE_WIDTH*32)-1:0] issue_lhs_o;
    wire [(BE_WIDTH*32)-1:0] issue_rhs_o;
    wire [(BE_WIDTH*32)-1:0] issue_pc_o;
    wire [(BE_WIDTH*32)-1:0] issue_immediate_o;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] issue_rob_tag_o;

    integer test_count;
    integer fill_index;
    integer fill_lane;
    integer batch_count;
    integer lane_index;
    integer vector_file;
    integer vector_result;
    integer vector_count;
    reg [1023:0] vector_path;

    reg expected_dispatch_ready;
    reg [INT_RS_INDEX_WIDTH:0] expected_occupancy;
    reg [BE_WIDTH-1:0] expected_issue_valid;
    reg [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] expected_issue_op;
    reg [(BE_WIDTH*32)-1:0] expected_issue_lhs;
    reg [(BE_WIDTH*32)-1:0] expected_issue_rhs;
    reg [(BE_WIDTH*32)-1:0] expected_issue_pc;
    reg [(BE_WIDTH*32)-1:0] expected_issue_immediate;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] expected_issue_rob_tag;

    reg [ROB_TAG_WIDTH-1:0] locked_tag;
    reg [31:0] locked_lhs;
    reg [31:0] locked_rhs;

    rv32_integer_reservation_station #(
        .INT_RS_ENTRIES(INT_RS_ENTRIES),
        .INT_RS_INDEX_WIDTH(INT_RS_INDEX_WIDTH),
        .BE_WIDTH(BE_WIDTH),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES),
        .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .recover_i(recover_i),
        .dispatch_valid_i(dispatch_valid_i),
        .dispatch_fire_i(dispatch_fire_i),
        .dispatch_op_i(dispatch_op_i),
        .dispatch_pc_i(dispatch_pc_i),
        .dispatch_immediate_i(dispatch_immediate_i),
        .dispatch_rob_tag_i(dispatch_rob_tag_i),
        .dispatch_lhs_ready_i(dispatch_lhs_ready_i),
        .dispatch_lhs_value_i(dispatch_lhs_value_i),
        .dispatch_lhs_phys_i(dispatch_lhs_phys_i),
        .dispatch_rhs_ready_i(dispatch_rhs_ready_i),
        .dispatch_rhs_value_i(dispatch_rhs_value_i),
        .dispatch_rhs_phys_i(dispatch_rhs_phys_i),
        .dispatch_ready_o(dispatch_ready_o),
        .occupancy_o(occupancy_o),
        .broadcast_valid_i(broadcast_valid_i),
        .broadcast_phys_i(broadcast_phys_i),
        .broadcast_value_i(broadcast_value_i),
        .rob_head_index_i(rob_head_index_i),
        .rollback_valid_i(rollback_valid_i),
        .rollback_tag_i(rollback_tag_i),
        .issue_valid_o(issue_valid_o),
        .issue_ready_i(issue_ready_i),
        .issue_op_o(issue_op_o),
        .issue_lhs_o(issue_lhs_o),
        .issue_rhs_o(issue_rhs_o),
        .issue_pc_o(issue_pc_o),
        .issue_immediate_o(issue_immediate_o),
        .issue_rob_tag_o(issue_rob_tag_o)
    );

    function [ROB_TAG_WIDTH-1:0] make_tag;
        input integer generation;
        input integer index_value;
        begin
            make_tag = (generation << ROB_INDEX_WIDTH) | index_value;
        end
    endfunction

    task check;
        input condition;
        input integer code;
        begin
            test_count = test_count + 1;
            if (!condition) begin
                $display("FAIL rv32_integer_reservation_station code=%0d entries=%0d width=%0d time=%0t",
                    code, INT_RS_ENTRIES, BE_WIDTH, $time);
                $finish(1);
            end
        end
    endtask

    task clear_inputs;
        begin
            flush_i = 1'b0;
            recover_i = 1'b0;
            dispatch_valid_i = {BE_WIDTH{1'b0}};
            dispatch_fire_i = 1'b0;
            dispatch_op_i = {(BE_WIDTH*`RV32_OP_WIDTH){1'b0}};
            dispatch_pc_i = {(BE_WIDTH*32){1'b0}};
            dispatch_immediate_i = {(BE_WIDTH*32){1'b0}};
            dispatch_rob_tag_i = {(BE_WIDTH*ROB_TAG_WIDTH){1'b0}};
            dispatch_lhs_ready_i = {BE_WIDTH{1'b1}};
            dispatch_lhs_value_i = {(BE_WIDTH*32){1'b0}};
            dispatch_lhs_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            dispatch_rhs_ready_i = {BE_WIDTH{1'b1}};
            dispatch_rhs_value_i = {(BE_WIDTH*32){1'b0}};
            dispatch_rhs_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            broadcast_valid_i = {BE_WIDTH{1'b0}};
            broadcast_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            broadcast_value_i = {(BE_WIDTH*32){1'b0}};
            rob_head_index_i = {ROB_INDEX_WIDTH{1'b0}};
            rollback_valid_i = {BE_WIDTH{1'b0}};
            rollback_tag_i = {(BE_WIDTH*ROB_TAG_WIDTH){1'b0}};
            issue_ready_i = {BE_WIDTH{1'b0}};
        end
    endtask

    task set_dispatch_lane;
        input integer lane;
        input [`RV32_OP_WIDTH-1:0] op_value;
        input [ROB_TAG_WIDTH-1:0] tag_value;
        input lhs_ready_value;
        input [31:0] lhs_value;
        input [PHYS_REG_ADDR_WIDTH-1:0] lhs_phys_value;
        input rhs_ready_value;
        input [31:0] rhs_value;
        input [PHYS_REG_ADDR_WIDTH-1:0] rhs_phys_value;
        input [31:0] pc_value;
        input [31:0] immediate_value;
        begin
            dispatch_valid_i[lane] = 1'b1;
            dispatch_op_i[lane*`RV32_OP_WIDTH +: `RV32_OP_WIDTH] =
                op_value;
            dispatch_pc_i[lane*32 +: 32] = pc_value;
            dispatch_immediate_i[lane*32 +: 32] = immediate_value;
            dispatch_rob_tag_i[lane*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] =
                tag_value;
            dispatch_lhs_ready_i[lane] = lhs_ready_value;
            dispatch_lhs_value_i[lane*32 +: 32] = lhs_value;
            dispatch_lhs_phys_i[
                lane*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] =
                lhs_phys_value;
            dispatch_rhs_ready_i[lane] = rhs_ready_value;
            dispatch_rhs_value_i[lane*32 +: 32] = rhs_value;
            dispatch_rhs_phys_i[
                lane*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] =
                rhs_phys_value;
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

    task reset_dut;
        begin
            clear_inputs;
            reset_i = 1'b1;
            clock_edge;
            reset_i = 1'b0;
            #1;
            check(occupancy_o == 0, 1);
        end
    endtask

    task test_sparse_and_wakeup;
        integer sparse_lane;
        begin
            reset_dut;
            sparse_lane = BE_WIDTH - 1;
            clear_inputs;
            set_dispatch_lane(sparse_lane, `RV32_OP_ADD,
                make_tag(0, 1), 1'b0, 32'd0, 5,
                1'b1, 32'h00000022, 6,
                32'h00001000, 32'h00000044);
            dispatch_fire_i = 1'b1;
            #1;
            check(dispatch_ready_o, 10);
            clock_edge;
            clear_inputs;
            #1;
            check(occupancy_o == 1, 11);
            check(issue_valid_o == 0, 12);

            broadcast_valid_i[0] = 1'b1;
            broadcast_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = 7;
            broadcast_value_i[31:0] = 32'hdeadbeef;
            #1;
            check(issue_valid_o == 0, 13);

            broadcast_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = 5;
            broadcast_value_i[31:0] = 32'h12345678;
            issue_ready_i[0] = 1'b1;
            #1;
            check(issue_valid_o[0], 14);
            check(issue_lhs_o[31:0] == 32'h12345678, 15);
            check(issue_rhs_o[31:0] == 32'h00000022, 16);
            check(issue_rob_tag_o[ROB_TAG_WIDTH-1:0] ==
                make_tag(0, 1), 17);
            clock_edge;
            clear_inputs;
            #1;
            check(occupancy_o == 0, 18);

            set_dispatch_lane(0, `RV32_OP_ADDI,
                make_tag(0, 2), 1'b0, 32'd0, 8,
                1'b1, 32'd0, 0,
                32'h00002000, 32'hfffffffc);
            dispatch_fire_i = 1'b1;
            broadcast_valid_i[0] = 1'b1;
            broadcast_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = 8;
            broadcast_value_i[31:0] = 32'h87654321;
            clock_edge;
            clear_inputs;
            #1;
            check(issue_valid_o[0], 19);
            check(issue_lhs_o[31:0] == 32'h87654321, 20);
            check(issue_immediate_o[31:0] == 32'hfffffffc, 21);
        end
    endtask

    task test_oldest_ready;
        begin
            reset_dut;
            clear_inputs;
            rob_head_index_i = ROB_ENTRIES - 2;
            set_dispatch_lane(0, `RV32_OP_ADD,
                make_tag(0, 1), 1'b0, 32'd0, 9,
                1'b1, 32'h11, 1,
                32'h100, 32'd0);
            dispatch_fire_i = 1'b1;
            clock_edge;

            clear_inputs;
            rob_head_index_i = ROB_ENTRIES - 2;
            set_dispatch_lane(0, `RV32_OP_ADD,
                make_tag(0, ROB_ENTRIES - 1), 1'b0, 32'd0, 9,
                1'b1, 32'h22, 2,
                32'h200, 32'd0);
            dispatch_fire_i = 1'b1;
            clock_edge;

            clear_inputs;
            rob_head_index_i = ROB_ENTRIES - 2;
            broadcast_valid_i[0] = 1'b1;
            broadcast_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = 9;
            broadcast_value_i[31:0] = 32'habcdef01;
            #1;
            check(issue_valid_o[0], 30);
            check(issue_rob_tag_o[ROB_TAG_WIDTH-1:0] ==
                make_tag(0, ROB_ENTRIES - 1), 31);
            if (BE_WIDTH > 1) begin
                check(issue_valid_o[1], 32);
                check(issue_rob_tag_o[ROB_TAG_WIDTH +: ROB_TAG_WIDTH] ==
                    make_tag(0, 1), 33);
            end
        end
    endtask

    task test_port_locking;
        begin
            if (BE_WIDTH > 1) begin
                reset_dut;
                clear_inputs;
                set_dispatch_lane(0, `RV32_OP_ADD,
                    make_tag(0, 0), 1'b1, 32'h11111111, 1,
                    1'b1, 32'h22222222, 2,
                    32'h1000, 32'd0);
                set_dispatch_lane(1, `RV32_OP_ADD,
                    make_tag(0, 1), 1'b1, 32'h33333333, 3,
                    1'b1, 32'h44444444, 4,
                    32'h1004, 32'd0);
                dispatch_fire_i = 1'b1;
                clock_edge;

                clear_inputs;
                issue_ready_i[0] = 1'b0;
                issue_ready_i[1] = 1'b1;
                #1;
                locked_tag = issue_rob_tag_o[ROB_TAG_WIDTH-1:0];
                locked_lhs = issue_lhs_o[31:0];
                locked_rhs = issue_rhs_o[31:0];
                check(locked_tag == make_tag(0, 0), 40);
                clock_edge;

                clear_inputs;
                issue_ready_i[0] = 1'b0;
                set_dispatch_lane(BE_WIDTH - 1, `RV32_OP_ADD,
                    make_tag(0, 2), 1'b1, 32'haaaaaaaa, 5,
                    1'b1, 32'hbbbbbbbb, 6,
                    32'h2000, 32'd0);
                dispatch_fire_i = 1'b1;
                clock_edge;
                clear_inputs;
                issue_ready_i[0] = 1'b0;
                issue_ready_i[1] = 1'b1;
                #1;
                check(issue_valid_o[0] && issue_valid_o[1], 41);
                check(issue_rob_tag_o[ROB_TAG_WIDTH-1:0] == locked_tag,
                    42);
                check(issue_lhs_o[31:0] == locked_lhs, 43);
                check(issue_rhs_o[31:0] == locked_rhs, 44);
                check(issue_rob_tag_o[ROB_TAG_WIDTH +: ROB_TAG_WIDTH] ==
                    make_tag(0, 2), 45);
                clock_edge;
                clear_inputs;
                #1;
                check(issue_valid_o[0], 46);
                check(issue_rob_tag_o[ROB_TAG_WIDTH-1:0] == locked_tag,
                    47);
                check(occupancy_o == 1, 48);
            end
        end
    endtask

    task test_full_pop_push;
        begin
            reset_dut;
            fill_index = 0;
            while (fill_index < INT_RS_ENTRIES) begin
                clear_inputs;
                batch_count = INT_RS_ENTRIES - fill_index;
                if (batch_count > BE_WIDTH) begin
                    batch_count = BE_WIDTH;
                end
                for (fill_lane = 0; fill_lane < batch_count;
                        fill_lane = fill_lane + 1) begin
                    set_dispatch_lane(fill_lane, `RV32_OP_ADD,
                        make_tag(0, fill_index + fill_lane),
                        1'b0, 32'd0, 10,
                        1'b1, fill_index + fill_lane, 1,
                        32'h3000 + (fill_index + fill_lane)*4, 32'd0);
                end
                dispatch_fire_i = 1'b1;
                #1;
                check(dispatch_ready_o, 50);
                clock_edge;
                fill_index = fill_index + batch_count;
            end
            clear_inputs;
            set_dispatch_lane(0, `RV32_OP_ADD,
                make_tag(1, INT_RS_ENTRIES),
                1'b1, 32'h1, 1, 1'b1, 32'h2, 2,
                32'h4000, 32'd0);
            #1;
            check(occupancy_o == INT_RS_ENTRIES, 51);
            check(!dispatch_ready_o, 52);

            clear_inputs;
            for (lane_index = 0; lane_index < BE_WIDTH;
                    lane_index = lane_index + 1) begin
                set_dispatch_lane(lane_index, `RV32_OP_ADD,
                    make_tag(1, INT_RS_ENTRIES + lane_index),
                    1'b1, 32'h100 + lane_index, 1,
                    1'b1, 32'h200 + lane_index, 2,
                    32'h4000 + lane_index*4, 32'd0);
            end
            dispatch_fire_i = 1'b1;
            broadcast_valid_i[0] = 1'b1;
            broadcast_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = 10;
            broadcast_value_i[31:0] = 32'hfeedface;
            issue_ready_i = {BE_WIDTH{1'b1}};
            #1;
            check(issue_valid_o == {BE_WIDTH{1'b1}}, 53);
            check(dispatch_ready_o, 54);
            clock_edge;
            clear_inputs;
            #1;
            check(occupancy_o == INT_RS_ENTRIES, 55);
        end
    endtask

    task test_recovery_and_flush;
        begin
            reset_dut;
            clear_inputs;
            set_dispatch_lane(0, `RV32_OP_ADD,
                make_tag(2, 3), 1'b1, 32'h12, 1,
                1'b1, 32'h34, 2, 32'h5000, 32'd0);
            dispatch_fire_i = 1'b1;
            clock_edge;
            clear_inputs;
            clock_edge;
            clear_inputs;
            recover_i = 1'b1;
            rollback_valid_i[0] = 1'b1;
            rollback_tag_i[ROB_TAG_WIDTH-1:0] = make_tag(2, 3);
            dispatch_valid_i[0] = 1'b1;
            #1;
            check(issue_valid_o == 0, 60);
            check(!dispatch_ready_o, 61);
            clock_edge;
            clear_inputs;
            #1;
            check(occupancy_o == 0, 62);
            check(issue_valid_o == 0, 63);

            for (fill_index = 4; fill_index < 7;
                    fill_index = fill_index + 1) begin
                clear_inputs;
                set_dispatch_lane(0, `RV32_OP_ADD,
                    make_tag(1, fill_index), 1'b0, 32'd0, 11,
                    1'b1, fill_index, 1,
                    32'h6000 + fill_index*4, 32'd0);
                dispatch_fire_i = 1'b1;
                clock_edge;
            end

            clear_inputs;
            recover_i = 1'b1;
            rollback_valid_i[0] = 1'b1;
            rollback_tag_i[ROB_TAG_WIDTH-1:0] = make_tag(1, 6);
            clock_edge;
            clear_inputs;
            recover_i = 1'b1;
            rollback_valid_i[0] = 1'b1;
            rollback_tag_i[ROB_TAG_WIDTH-1:0] = make_tag(1, 5);
            clock_edge;
            clear_inputs;
            recover_i = 1'b1;
            rollback_valid_i[0] = 1'b1;
            rollback_tag_i[ROB_TAG_WIDTH-1:0] = make_tag(3, 9);
            clock_edge;
            clear_inputs;
            broadcast_valid_i[0] = 1'b1;
            broadcast_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = 11;
            broadcast_value_i[31:0] = 32'hcafebabe;
            #1;
            check(occupancy_o == 1, 64);
            check(issue_valid_o[0], 65);
            check(issue_rob_tag_o[ROB_TAG_WIDTH-1:0] ==
                make_tag(1, 4), 66);

            flush_i = 1'b1;
            #1;
            check(issue_valid_o == 0, 67);
            check(occupancy_o == 0, 68);
            clock_edge;
            clear_inputs;
            #1;
            check(occupancy_o == 0, 69);
        end
    endtask

    task run_reference_vectors;
        begin
            if (!$value$plusargs("VECTOR_FILE=%s", vector_path)) begin
                $display("FAIL rv32_integer_reservation_station missing VECTOR_FILE");
                $finish(1);
            end
            vector_file = $fopen(vector_path, "r");
            if (vector_file == 0) begin
                $display("FAIL rv32_integer_reservation_station cannot open vectors");
                $finish(1);
            end
            reset_dut;
            vector_count = 0;
            while (!$feof(vector_file)) begin
                vector_result = $fscanf(vector_file,
                    "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                    reset_i, flush_i, recover_i,
                    dispatch_valid_i, dispatch_fire_i,
                    dispatch_op_i, dispatch_pc_i, dispatch_immediate_i,
                    dispatch_rob_tag_i,
                    dispatch_lhs_ready_i, dispatch_lhs_value_i,
                    dispatch_lhs_phys_i,
                    dispatch_rhs_ready_i, dispatch_rhs_value_i,
                    dispatch_rhs_phys_i,
                    broadcast_valid_i, broadcast_phys_i, broadcast_value_i,
                    rob_head_index_i, rollback_valid_i, rollback_tag_i,
                    issue_ready_i,
                    expected_dispatch_ready, expected_occupancy,
                    expected_issue_valid, expected_issue_op,
                    expected_issue_lhs, expected_issue_rhs,
                    expected_issue_pc, expected_issue_immediate,
                    expected_issue_rob_tag);
                if (vector_result == 31) begin
                    #1;
                    check(dispatch_ready_o === expected_dispatch_ready,
                        1000 + vector_count*10);
                    check(occupancy_o === expected_occupancy,
                        1001 + vector_count*10);
                    check(issue_valid_o === expected_issue_valid,
                        1002 + vector_count*10);
                    check(issue_op_o === expected_issue_op,
                        1003 + vector_count*10);
                    check(issue_lhs_o === expected_issue_lhs,
                        1004 + vector_count*10);
                    check(issue_rhs_o === expected_issue_rhs,
                        1005 + vector_count*10);
                    check(issue_pc_o === expected_issue_pc,
                        1006 + vector_count*10);
                    check(issue_immediate_o === expected_issue_immediate,
                        1007 + vector_count*10);
                    check(issue_rob_tag_o === expected_issue_rob_tag,
                        1008 + vector_count*10);
                    clock_edge;
                    vector_count = vector_count + 1;
                end else if (vector_result != -1) begin
                    $display("FAIL rv32_integer_reservation_station malformed vector result=%0d line=%0d",
                        vector_result, vector_count);
                    $finish(1);
                end
            end
            $fclose(vector_file);
            check(vector_count > 0, 9000);
        end
    endtask

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b0;
        test_count = 0;
        clear_inputs;

        test_sparse_and_wakeup;
        test_oldest_ready;
        test_port_locking;
        test_full_pop_push;
        test_recovery_and_flush;
        run_reference_vectors;

        $display("PASS rv32_integer_reservation_station entries=%0d width=%0d vectors=%0d tests=%0d",
            INT_RS_ENTRIES, BE_WIDTH, vector_count, test_count);
        $finish;
    end

endmodule
