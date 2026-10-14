`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_int_rs_reuse_tb;
    parameter BE_WIDTH = 1;
    parameter ROB_ENTRIES = 32;
    parameter ROB_INDEX_WIDTH = 5;
    localparam ROB_TAG_WIDTH = ROB_INDEX_WIDTH + 2;
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
    reg [(BE_WIDTH*6)-1:0] dispatch_lhs_phys_i;
    reg [BE_WIDTH-1:0] dispatch_rhs_ready_i;
    reg [(BE_WIDTH*32)-1:0] dispatch_rhs_value_i;
    reg [(BE_WIDTH*6)-1:0] dispatch_rhs_phys_i;
    wire dispatch_ready_o;
    wire [3:0] occupancy_o;
    reg [BE_WIDTH-1:0] broadcast_valid_i;
    reg [(BE_WIDTH*6)-1:0] broadcast_phys_i;
    reg [(BE_WIDTH*32)-1:0] broadcast_value_i;
    reg [ROB_INDEX_WIDTH-1:0] rob_head_index_i;
    reg [BE_WIDTH-1:0] rollback_valid_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_tag_i;
    reg [BE_WIDTH-1:0] issue_ready_i;
    wire [BE_WIDTH-1:0] issue_valid_o;
    wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] issue_op_o;
    wire [(BE_WIDTH*32)-1:0] issue_lhs_o;
    wire [(BE_WIDTH*32)-1:0] issue_rhs_o;
    wire [(BE_WIDTH*32)-1:0] issue_pc_o;
    wire [(BE_WIDTH*32)-1:0] issue_immediate_o;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] issue_rob_tag_o;
    integer iteration;
    integer checks;
    reg [ROB_TAG_WIDTH-1:0] current_tag;
    reg [31:0] first_value;
    reg [31:0] second_value;

    rv32_integer_reservation_station #(
        .BE_WIDTH(BE_WIDTH), .ROB_ENTRIES(ROB_ENTRIES),
        .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH), .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) dut (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(flush_i), .recover_i(recover_i),
        .dispatch_valid_i(dispatch_valid_i), .dispatch_fire_i(dispatch_fire_i),
        .dispatch_op_i(dispatch_op_i), .dispatch_pc_i(dispatch_pc_i),
        .dispatch_immediate_i(dispatch_immediate_i), .dispatch_rob_tag_i(dispatch_rob_tag_i),
        .dispatch_lhs_ready_i(dispatch_lhs_ready_i), .dispatch_lhs_value_i(dispatch_lhs_value_i),
        .dispatch_lhs_phys_i(dispatch_lhs_phys_i), .dispatch_rhs_ready_i(dispatch_rhs_ready_i),
        .dispatch_rhs_value_i(dispatch_rhs_value_i), .dispatch_rhs_phys_i(dispatch_rhs_phys_i),
        .dispatch_ready_o(dispatch_ready_o), .occupancy_o(occupancy_o),
        .broadcast_valid_i(broadcast_valid_i), .broadcast_phys_i(broadcast_phys_i),
        .broadcast_value_i(broadcast_value_i), .rob_head_index_i(rob_head_index_i),
        .rollback_valid_i(rollback_valid_i), .rollback_tag_i(rollback_tag_i),
        .issue_valid_o(issue_valid_o), .issue_ready_i(issue_ready_i), .issue_op_o(issue_op_o),
        .issue_lhs_o(issue_lhs_o), .issue_rhs_o(issue_rhs_o), .issue_pc_o(issue_pc_o),
        .issue_immediate_o(issue_immediate_o), .issue_rob_tag_o(issue_rob_tag_o)
    );

    task tick;
        begin
            #5; clk_i = 1; #1; clk_i = 0; #1;
        end
    endtask

    task check;
        input condition;
        input [255:0] message;
        begin
            checks = checks + 1;
            if (!condition) begin
                $display("FAIL RS reuse %0s width=%0d iteration=%0d", message, BE_WIDTH, iteration);
                $stop;
            end
        end
    endtask

    task allocate;
        input lhs_ready;
        input rhs_ready;
        input [5:0] lhs_phys;
        input [5:0] rhs_phys;
        begin
            current_tag = current_tag + 1'b1;
            rob_head_index_i = current_tag[ROB_INDEX_WIDTH-1:0];
            dispatch_valid_i = 1;
            dispatch_op_i[0 +: `RV32_OP_WIDTH] = `RV32_OP_ADD;
            dispatch_pc_i[0 +: 32] = 32'h1000 + iteration*4;
            dispatch_immediate_i[0 +: 32] = iteration;
            dispatch_rob_tag_i[0 +: ROB_TAG_WIDTH] = current_tag;
            dispatch_lhs_ready_i = lhs_ready;
            dispatch_lhs_value_i[0 +: 32] = 32'h11111111;
            dispatch_lhs_phys_i[0 +: 6] = lhs_phys;
            dispatch_rhs_ready_i = rhs_ready;
            dispatch_rhs_value_i[0 +: 32] = 32'h22222222;
            dispatch_rhs_phys_i[0 +: 6] = rhs_phys;
            #1; check(dispatch_ready_o, "allocation ready");
            dispatch_fire_i = 1;
            tick(); dispatch_fire_i = 0; dispatch_valid_i = 0;
        end
    endtask

    initial begin
        clk_i = 0; checks = 0; current_tag = 0;
        reset_i = 1; flush_i = 0; recover_i = 0;
        dispatch_valid_i = 0; dispatch_fire_i = 0; dispatch_op_i = 0;
        dispatch_pc_i = 0; dispatch_immediate_i = 0; dispatch_rob_tag_i = 0;
        dispatch_lhs_ready_i = 0; dispatch_lhs_value_i = 0; dispatch_lhs_phys_i = 0;
        dispatch_rhs_ready_i = 0; dispatch_rhs_value_i = 0; dispatch_rhs_phys_i = 0;
        broadcast_valid_i = 0; broadcast_phys_i = 0; broadcast_value_i = 0;
        rob_head_index_i = 0; rollback_valid_i = 0; rollback_tag_i = 0; issue_ready_i = 0;
        tick(); reset_i = 0;
        for (iteration = 0; iteration < 256; iteration = iteration + 1) begin
            first_value = 32'h81abcdef ^ (iteration*32'h01010101);
            second_value = 32'h76543210 ^ (iteration*32'h00110011);
            allocate(0, 1, 7, 8);
            broadcast_phys_i[0 +: 6] = 7;
            broadcast_value_i[0 +: 32] = 32'hdeadbeef;
            #1; check(issue_valid_o == 0, "invalid payload cannot wake");
            tick(); check(issue_valid_o == 0, "invalid payload cannot latch");
            broadcast_valid_i = 1; broadcast_value_i[0 +: 32] = first_value;
            issue_ready_i = 1;
            #1; check(issue_valid_o[0] && issue_lhs_o[0 +: 32] == first_value &&
                issue_rhs_o[0 +: 32] == 32'h22222222 &&
                issue_rob_tag_o[0 +: ROB_TAG_WIDTH] == current_tag, "same cycle wake and issue");
            tick(); broadcast_valid_i = 0; issue_ready_i = 0;
            #1; check(issue_valid_o == 0 && occupancy_o == 0, "pop removes live entry");

            allocate(0, 0, 9, 10);
            broadcast_valid_i = 1;
            #1; check(issue_valid_o == 0, "reused slot rejects old phys");
            tick();
            broadcast_phys_i[0 +: 6] = 9; broadcast_value_i[0 +: 32] = first_value;
            tick();
            broadcast_valid_i = 0; broadcast_phys_i[0 +: 6] = 10;
            broadcast_value_i[0 +: 32] = 32'hdeadbeef;
            #1; check(issue_valid_o == 0, "second operand still waiting");
            tick();
            broadcast_valid_i = 1; broadcast_value_i[0 +: 32] = second_value;
            #1; check(issue_valid_o[0] && issue_lhs_o[0 +: 32] == first_value &&
                issue_rhs_o[0 +: 32] == second_value, "fresh operands in reused slot");
            tick(); broadcast_valid_i = 0;
            #1; check(issue_valid_o[0] && issue_lhs_o[0 +: 32] == first_value &&
                issue_rhs_o[0 +: 32] == second_value, "locked output stable");
            recover_i = 1; rollback_valid_i = 1;
            rollback_tag_i[0 +: ROB_TAG_WIDTH] = current_tag;
            issue_ready_i = 1;
            #1; check(issue_valid_o == 0, "recovery suppresses locked issue");
            tick(); recover_i = 0; rollback_valid_i = 0; issue_ready_i = 0;
            #1; check(issue_valid_o == 0 && occupancy_o == 0, "recovery releases reused slot");

            allocate(1, 1, 11, 12);
            #1; check(issue_valid_o[0] && issue_lhs_o[0 +: 32] == 32'h11111111 &&
                issue_rhs_o[0 +: 32] == 32'h22222222 &&
                issue_pc_o[0 +: 32] == 32'h1000 + iteration*4, "allocation overwrites old payload");
            flush_i = 1;
            #1; check(issue_valid_o == 0, "flush suppresses ready issue");
            tick(); flush_i = 0;
            #1; check(issue_valid_o == 0 && occupancy_o == 0, "flush removes live payload");
        end
        $display("PASS RS reuse width=%0d rob=%0d checks=%0d", BE_WIDTH, ROB_ENTRIES, checks);
        $finish;
    end
endmodule
