`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_reorder_buffer #(
    parameter ROB_ENTRIES = 32,
    parameter ROB_INDEX_WIDTH = 5,
    parameter ROB_GENERATION_WIDTH = 2,
    parameter ROB_TAG_WIDTH = 7,
    parameter BE_WIDTH = 1,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter LSQ_TAG_WIDTH = 4
) (
    input  wire                                             clk_i,
    input  wire                                             reset_i,

    input  wire [BE_WIDTH-1:0]                              alloc_valid_i,
    input  wire                                             alloc_fire_i,
    input  wire [(BE_WIDTH*32)-1:0]                         alloc_pc_i,
    input  wire [(BE_WIDTH*32)-1:0]                         alloc_instruction_i,
    input  wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0]             alloc_op_i,
    input  wire [BE_WIDTH-1:0]                              alloc_writes_rd_i,
    input  wire [(BE_WIDTH*5)-1:0]                          alloc_rd_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        alloc_new_phys_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        alloc_old_phys_i,
    input  wire [(BE_WIDTH*32)-1:0]                         alloc_predicted_next_pc_i,
    input  wire [BE_WIDTH-1:0]                              alloc_lsq_valid_i,
    input  wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0]              alloc_lsq_tag_i,
    input  wire [BE_WIDTH-1:0]                              alloc_complete_i,
    input  wire [BE_WIDTH-1:0]                              alloc_exception_valid_i,
    input  wire [(BE_WIDTH*4)-1:0]                          alloc_exception_cause_i,
    input  wire [(BE_WIDTH*32)-1:0]                         alloc_exception_tval_i,
    output wire                                             alloc_ready_o,
    output wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              alloc_tag_o,
    output wire [ROB_INDEX_WIDTH:0]                         occupancy_o,
    output wire [ROB_INDEX_WIDTH-1:0]                       head_index_o,

    input  wire [BE_WIDTH-1:0]                              completion_valid_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              completion_tag_i,
    input  wire [(BE_WIDTH*32)-1:0]                         completion_value_i,
    input  wire [BE_WIDTH-1:0]                              completion_control_valid_i,
    input  wire [BE_WIDTH-1:0]                              completion_control_taken_i,
    input  wire [(BE_WIDTH*32)-1:0]                         completion_next_pc_i,
    input  wire [BE_WIDTH-1:0]                              completion_exception_valid_i,
    input  wire [(BE_WIDTH*4)-1:0]                          completion_exception_cause_i,
    input  wire [(BE_WIDTH*32)-1:0]                         completion_exception_tval_i,
    output wire [BE_WIDTH-1:0]                              completion_ready_o,
    output wire [BE_WIDTH-1:0]                              completion_accept_o,

    input  wire [BE_WIDTH-1:0]                              commit_ready_i,
    output wire [BE_WIDTH-1:0]                              commit_valid_o,
    output wire [BE_WIDTH-1:0]                              commit_fire_o,
    output wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              commit_tag_o,
    output wire [(BE_WIDTH*32)-1:0]                         commit_pc_o,
    output wire [(BE_WIDTH*32)-1:0]                         commit_instruction_o,
    output wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0]             commit_op_o,
    output wire [BE_WIDTH-1:0]                              commit_writes_rd_o,
    output wire [(BE_WIDTH*5)-1:0]                          commit_rd_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        commit_new_phys_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        commit_old_phys_o,
    output wire [(BE_WIDTH*32)-1:0]                         commit_value_o,
    output wire [BE_WIDTH-1:0]                              commit_control_valid_o,
    output wire [BE_WIDTH-1:0]                              commit_control_taken_o,
    output wire [(BE_WIDTH*32)-1:0]                         commit_predicted_next_pc_o,
    output wire [(BE_WIDTH*32)-1:0]                         commit_next_pc_o,
    output wire [BE_WIDTH-1:0]                              commit_lsq_valid_o,
    output wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0]              commit_lsq_tag_o,
    output wire [BE_WIDTH-1:0]                              commit_exception_valid_o,
    output wire [(BE_WIDTH*4)-1:0]                          commit_exception_cause_o,
    output wire [(BE_WIDTH*32)-1:0]                         commit_exception_tval_o,

    output wire                                             recover_busy_o,
    output wire                                             recover_redirect_valid_o,
    output wire [31:0]                                      recover_redirect_pc_o,
    output wire [BE_WIDTH-1:0]                              rollback_valid_o,
    output wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              rollback_tag_o,
    output wire [BE_WIDTH-1:0]                              rollback_writes_rd_o,
    output wire [(BE_WIDTH*5)-1:0]                          rollback_rd_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        rollback_new_phys_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        rollback_old_phys_o,
    output wire [BE_WIDTH-1:0]                              rollback_lsq_valid_o,
    output wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0]              rollback_lsq_tag_o
);

    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */

    reg entry_busy [0:ROB_ENTRIES-1];
    reg [ROB_GENERATION_WIDTH-1:0] entry_generation [0:ROB_ENTRIES-1];
    reg entry_complete [0:ROB_ENTRIES-1];
    reg [31:0] entry_pc [0:ROB_ENTRIES-1];
    reg [31:0] entry_instruction [0:ROB_ENTRIES-1];
    reg [`RV32_OP_WIDTH-1:0] entry_op [0:ROB_ENTRIES-1];
    reg entry_writes_rd [0:ROB_ENTRIES-1];
    reg [4:0] entry_rd [0:ROB_ENTRIES-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0] entry_new_phys [0:ROB_ENTRIES-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0] entry_old_phys [0:ROB_ENTRIES-1];
    reg [31:0] entry_value [0:ROB_ENTRIES-1];
    reg entry_control_valid [0:ROB_ENTRIES-1];
    reg entry_control_taken [0:ROB_ENTRIES-1];
    reg [31:0] entry_predicted_next_pc [0:ROB_ENTRIES-1];
    reg [31:0] entry_next_pc [0:ROB_ENTRIES-1];
    reg entry_lsq_valid [0:ROB_ENTRIES-1];
    reg [LSQ_TAG_WIDTH-1:0] entry_lsq_tag [0:ROB_ENTRIES-1];
    reg entry_exception_valid [0:ROB_ENTRIES-1];
    reg [3:0] entry_exception_cause [0:ROB_ENTRIES-1];
    reg [31:0] entry_exception_tval [0:ROB_ENTRIES-1];
    reg [ROB_GENERATION_WIDTH-1:0] next_generation [0:ROB_ENTRIES-1];

    reg [ROB_INDEX_WIDTH-1:0] head_reg;
    reg [ROB_INDEX_WIDTH-1:0] tail_reg;
    reg [ROB_INDEX_WIDTH:0] occupancy_reg;

    reg recovery_busy_reg;
    reg recovery_redirect_pending_reg;
    reg [31:0] recovery_redirect_pc_reg;
    reg [ROB_TAG_WIDTH-1:0] recovery_branch_tag_reg;

    reg alloc_ready_reg;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] alloc_tag_reg;
    reg [BE_WIDTH-1:0] completion_ready_reg;
    reg [BE_WIDTH-1:0] completion_accept_reg;

    reg [BE_WIDTH-1:0] commit_valid_reg;
    reg [BE_WIDTH-1:0] commit_fire_reg;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] commit_tag_reg;
    reg [(BE_WIDTH*32)-1:0] commit_pc_reg;
    reg [(BE_WIDTH*32)-1:0] commit_instruction_reg;
    reg [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] commit_op_reg;
    reg [BE_WIDTH-1:0] commit_writes_rd_reg;
    reg [(BE_WIDTH*5)-1:0] commit_rd_reg;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] commit_new_phys_reg;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] commit_old_phys_reg;
    reg [(BE_WIDTH*32)-1:0] commit_value_reg;
    reg [BE_WIDTH-1:0] commit_control_valid_reg;
    reg [BE_WIDTH-1:0] commit_control_taken_reg;
    reg [(BE_WIDTH*32)-1:0] commit_predicted_next_pc_reg;
    reg [(BE_WIDTH*32)-1:0] commit_next_pc_reg;
    reg [BE_WIDTH-1:0] commit_lsq_valid_reg;
    reg [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] commit_lsq_tag_reg;
    reg [BE_WIDTH-1:0] commit_exception_valid_reg;
    reg [(BE_WIDTH*4)-1:0] commit_exception_cause_reg;
    reg [(BE_WIDTH*32)-1:0] commit_exception_tval_reg;

    reg [BE_WIDTH-1:0] rollback_valid_reg;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_tag_reg;
    reg [BE_WIDTH-1:0] rollback_writes_rd_reg;
    reg [(BE_WIDTH*5)-1:0] rollback_rd_reg;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rollback_new_phys_reg;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rollback_old_phys_reg;
    reg [BE_WIDTH-1:0] rollback_lsq_valid_reg;
    reg [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] rollback_lsq_tag_reg;
    reg [(BE_WIDTH*ROB_INDEX_WIDTH)-1:0] rollback_slot_reg;

    reg mispredict_found_reg;
    reg [ROB_TAG_WIDTH-1:0] mispredict_tag_reg;
    reg [31:0] mispredict_next_pc_reg;
    integer mispredict_distance_reg;
    integer alloc_count;
    integer commit_count;
    integer rollback_count;
    integer alloc_lane_index;
    integer completion_lane_index;
    integer completion_other_lane_index;
    integer commit_lane_index;
    integer rollback_lane_index;
    integer sequential_entry_index;
    integer sequential_lane_index;
    integer assertion_lane_index;
    integer completion_distance;
    reg commit_prefix_reg;
    reg commit_fire_prefix_reg;
    reg recovery_stop_reg;
    reg recovery_done_reg;
    reg completion_duplicate_reg;
    reg [ROB_TAG_WIDTH-1:0] completion_tag_value_reg;
    reg [ROB_INDEX_WIDTH-1:0] alloc_slot_reg;
    reg [ROB_INDEX_WIDTH-1:0] completion_slot_reg;
    reg [ROB_INDEX_WIDTH-1:0] commit_slot_reg;
    reg [ROB_INDEX_WIDTH-1:0] rollback_scan_slot_reg;
    reg [ROB_INDEX_WIDTH-1:0] recovery_lookahead_slot_reg;
    reg [ROB_INDEX_WIDTH-1:0] sequential_slot_reg;
    reg [ROB_INDEX_WIDTH-1:0] assertion_slot_reg;
    reg assertion_prefix_reg;

    function integer address_width_for_count;
        input integer count;
        integer remaining;
        begin
            remaining = count - 1;
            address_width_for_count = 0;
            while (remaining > 0) begin
                address_width_for_count = address_width_for_count + 1;
                remaining = remaining >> 1;
            end
        end
    endfunction

    function [ROB_INDEX_WIDTH-1:0] rob_index_add;
        input [ROB_INDEX_WIDTH-1:0] base;
        input integer offset;
        integer sum;
        begin
            sum = base + offset;
            if (sum >= ROB_ENTRIES) begin
                sum = sum - ROB_ENTRIES;
            end
            rob_index_add = sum;
        end
    endfunction

    function [ROB_INDEX_WIDTH-1:0] rob_index_sub;
        input [ROB_INDEX_WIDTH-1:0] base;
        input integer offset;
        integer difference;
        begin
            difference = base - offset;
            if (difference < 0) begin
                difference = difference + ROB_ENTRIES;
            end
            if (difference < 0) begin
                difference = difference + ROB_ENTRIES;
            end
            rob_index_sub = difference;
        end
    endfunction

    assign alloc_ready_o = alloc_ready_reg;
    assign alloc_tag_o = alloc_tag_reg;
    assign occupancy_o = reset_i ? {(ROB_INDEX_WIDTH+1){1'b0}} :
        occupancy_reg;
    assign head_index_o = reset_i ? {ROB_INDEX_WIDTH{1'b0}} : head_reg;
    assign completion_ready_o = completion_ready_reg;
    assign completion_accept_o = completion_accept_reg;

    assign commit_valid_o = commit_valid_reg;
    assign commit_fire_o = commit_fire_reg;
    assign commit_tag_o = commit_tag_reg;
    assign commit_pc_o = commit_pc_reg;
    assign commit_instruction_o = commit_instruction_reg;
    assign commit_op_o = commit_op_reg;
    assign commit_writes_rd_o = commit_writes_rd_reg;
    assign commit_rd_o = commit_rd_reg;
    assign commit_new_phys_o = commit_new_phys_reg;
    assign commit_old_phys_o = commit_old_phys_reg;
    assign commit_value_o = commit_value_reg;
    assign commit_control_valid_o = commit_control_valid_reg;
    assign commit_control_taken_o = commit_control_taken_reg;
    assign commit_predicted_next_pc_o = commit_predicted_next_pc_reg;
    assign commit_next_pc_o = commit_next_pc_reg;
    assign commit_lsq_valid_o = commit_lsq_valid_reg;
    assign commit_lsq_tag_o = commit_lsq_tag_reg;
    assign commit_exception_valid_o = commit_exception_valid_reg;
    assign commit_exception_cause_o = commit_exception_cause_reg;
    assign commit_exception_tval_o = commit_exception_tval_reg;

    assign recover_busy_o = !reset_i && recovery_busy_reg;
    assign recover_redirect_valid_o = !reset_i && recovery_busy_reg &&
        recovery_redirect_pending_reg;
    assign recover_redirect_pc_o = (!reset_i && recovery_busy_reg) ?
        recovery_redirect_pc_reg : 32'd0;
    assign rollback_valid_o = rollback_valid_reg;
    assign rollback_tag_o = rollback_tag_reg;
    assign rollback_writes_rd_o = rollback_writes_rd_reg;
    assign rollback_rd_o = rollback_rd_reg;
    assign rollback_new_phys_o = rollback_new_phys_reg;
    assign rollback_old_phys_o = rollback_old_phys_reg;
    assign rollback_lsq_valid_o = rollback_lsq_valid_reg;
    assign rollback_lsq_tag_o = rollback_lsq_tag_reg;

    initial begin
        if ((BE_WIDTH != 1) && (BE_WIDTH != 2) && (BE_WIDTH != 4)) begin
            $display("ERROR rv32_reorder_buffer invalid BE_WIDTH=%0d",
                BE_WIDTH);
            $finish(1);
        end
        if ((ROB_ENTRIES < BE_WIDTH) || (ROB_ENTRIES < 2)) begin
            $display("ERROR rv32_reorder_buffer invalid ROB_ENTRIES=%0d",
                ROB_ENTRIES);
            $finish(1);
        end
        if ((ROB_ENTRIES & (ROB_ENTRIES - 1)) != 0) begin
            $display("ERROR rv32_reorder_buffer ROB_ENTRIES not power of two=%0d",
                ROB_ENTRIES);
            $finish(1);
        end
        if (ROB_INDEX_WIDTH != address_width_for_count(ROB_ENTRIES)) begin
            $display("ERROR rv32_reorder_buffer index width=%0d expected=%0d",
                ROB_INDEX_WIDTH, address_width_for_count(ROB_ENTRIES));
            $finish(1);
        end
        if (ROB_GENERATION_WIDTH < 1) begin
            $display("ERROR rv32_reorder_buffer invalid generation width=%0d",
                ROB_GENERATION_WIDTH);
            $finish(1);
        end
        if (ROB_TAG_WIDTH != ROB_INDEX_WIDTH + ROB_GENERATION_WIDTH) begin
            $display("ERROR rv32_reorder_buffer tag width=%0d expected=%0d",
                ROB_TAG_WIDTH, ROB_INDEX_WIDTH + ROB_GENERATION_WIDTH);
            $finish(1);
        end
        if ((PHYS_REG_ADDR_WIDTH < 1) || (LSQ_TAG_WIDTH < 1)) begin
            $display("ERROR rv32_reorder_buffer invalid payload width");
            $finish(1);
        end
    end

    always @* begin
        alloc_count = 0;
        alloc_slot_reg = {ROB_INDEX_WIDTH{1'b0}};
        for (alloc_lane_index = 0; alloc_lane_index < BE_WIDTH;
                alloc_lane_index = alloc_lane_index + 1) begin
            if (alloc_valid_i[alloc_lane_index]) begin
                alloc_count = alloc_count + 1;
            end
        end

        alloc_ready_reg = !reset_i && !recovery_busy_reg &&
            (occupancy_reg + alloc_count <= ROB_ENTRIES);
        alloc_tag_reg = {(BE_WIDTH*ROB_TAG_WIDTH){1'b0}};
        for (alloc_lane_index = 0; alloc_lane_index < BE_WIDTH;
                alloc_lane_index = alloc_lane_index + 1) begin
            if (alloc_ready_reg && alloc_valid_i[alloc_lane_index]) begin
                alloc_slot_reg = rob_index_add(tail_reg,
                    alloc_lane_index);
                alloc_tag_reg[alloc_lane_index*ROB_TAG_WIDTH +:
                    ROB_TAG_WIDTH] = {
                    next_generation[alloc_slot_reg], alloc_slot_reg};
            end
        end
    end

    always @* begin
        completion_ready_reg = {BE_WIDTH{1'b0}};
        completion_accept_reg = {BE_WIDTH{1'b0}};
        mispredict_found_reg = 1'b0;
        mispredict_tag_reg = {ROB_TAG_WIDTH{1'b0}};
        mispredict_next_pc_reg = 32'd0;
        mispredict_distance_reg = ROB_ENTRIES;
        completion_tag_value_reg = {ROB_TAG_WIDTH{1'b0}};
        completion_slot_reg = {ROB_INDEX_WIDTH{1'b0}};
        completion_distance = 0;
        completion_duplicate_reg = 1'b0;

        if (!reset_i && !recovery_busy_reg) begin
            completion_ready_reg = {BE_WIDTH{1'b1}};
        end

        for (completion_lane_index = 0;
                completion_lane_index < BE_WIDTH;
                completion_lane_index = completion_lane_index + 1) begin
            completion_tag_value_reg = completion_tag_i[
                completion_lane_index*ROB_TAG_WIDTH +: ROB_TAG_WIDTH];
            completion_slot_reg = completion_tag_value_reg[
                ROB_INDEX_WIDTH-1:0];
            completion_duplicate_reg = 1'b0;
            for (completion_other_lane_index = 0;
                    completion_other_lane_index < completion_lane_index;
                    completion_other_lane_index =
                        completion_other_lane_index + 1) begin
                if (completion_valid_i[completion_other_lane_index] &&
                        (completion_tag_i[
                            completion_other_lane_index*ROB_TAG_WIDTH +:
                            ROB_TAG_WIDTH] == completion_tag_value_reg)) begin
                    completion_duplicate_reg = 1'b1;
                end
            end

            if (completion_ready_reg[completion_lane_index] &&
                    completion_valid_i[completion_lane_index] &&
                    !completion_duplicate_reg &&
                    entry_busy[completion_slot_reg] &&
                    !entry_complete[completion_slot_reg] &&
                    (entry_generation[completion_slot_reg] ==
                        completion_tag_value_reg[
                            ROB_TAG_WIDTH-1:ROB_INDEX_WIDTH])) begin
                completion_accept_reg[completion_lane_index] = 1'b1;
                if (completion_control_valid_i[completion_lane_index] &&
                        (entry_predicted_next_pc[completion_slot_reg] !=
                            completion_next_pc_i[
                                completion_lane_index*32 +: 32])) begin
                    if (completion_slot_reg >= head_reg) begin
                        completion_distance = completion_slot_reg - head_reg;
                    end else begin
                        completion_distance = completion_slot_reg +
                            ROB_ENTRIES - head_reg;
                    end
                    if (!mispredict_found_reg ||
                            (completion_distance <
                                mispredict_distance_reg)) begin
                        mispredict_found_reg = 1'b1;
                        mispredict_tag_reg = completion_tag_value_reg;
                        mispredict_next_pc_reg = completion_next_pc_i[
                            completion_lane_index*32 +: 32];
                        mispredict_distance_reg = completion_distance;
                    end
                end
            end
        end
    end

    always @* begin
        commit_valid_reg = {BE_WIDTH{1'b0}};
        commit_fire_reg = {BE_WIDTH{1'b0}};
        commit_tag_reg = {(BE_WIDTH*ROB_TAG_WIDTH){1'b0}};
        commit_pc_reg = {(BE_WIDTH*32){1'b0}};
        commit_instruction_reg = {(BE_WIDTH*32){1'b0}};
        commit_op_reg = {(BE_WIDTH*`RV32_OP_WIDTH){1'b0}};
        commit_writes_rd_reg = {BE_WIDTH{1'b0}};
        commit_rd_reg = {(BE_WIDTH*5){1'b0}};
        commit_new_phys_reg =
            {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        commit_old_phys_reg =
            {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        commit_value_reg = {(BE_WIDTH*32){1'b0}};
        commit_control_valid_reg = {BE_WIDTH{1'b0}};
        commit_control_taken_reg = {BE_WIDTH{1'b0}};
        commit_predicted_next_pc_reg = {(BE_WIDTH*32){1'b0}};
        commit_next_pc_reg = {(BE_WIDTH*32){1'b0}};
        commit_lsq_valid_reg = {BE_WIDTH{1'b0}};
        commit_lsq_tag_reg = {(BE_WIDTH*LSQ_TAG_WIDTH){1'b0}};
        commit_exception_valid_reg = {BE_WIDTH{1'b0}};
        commit_exception_cause_reg = {(BE_WIDTH*4){1'b0}};
        commit_exception_tval_reg = {(BE_WIDTH*32){1'b0}};
        commit_count = 0;
        commit_slot_reg = {ROB_INDEX_WIDTH{1'b0}};
        commit_prefix_reg = !reset_i && !recovery_busy_reg;
        commit_fire_prefix_reg = !reset_i && !recovery_busy_reg;

        for (commit_lane_index = 0; commit_lane_index < BE_WIDTH;
                commit_lane_index = commit_lane_index + 1) begin
            commit_slot_reg = rob_index_add(head_reg, commit_lane_index);
            if (commit_prefix_reg && entry_busy[commit_slot_reg] &&
                    entry_complete[commit_slot_reg]) begin
                commit_valid_reg[commit_lane_index] = 1'b1;
                commit_tag_reg[commit_lane_index*ROB_TAG_WIDTH +:
                    ROB_TAG_WIDTH] = {
                    entry_generation[commit_slot_reg], commit_slot_reg};
                commit_pc_reg[commit_lane_index*32 +: 32] =
                    entry_pc[commit_slot_reg];
                commit_instruction_reg[commit_lane_index*32 +: 32] =
                    entry_instruction[commit_slot_reg];
                commit_op_reg[commit_lane_index*`RV32_OP_WIDTH +:
                    `RV32_OP_WIDTH] = entry_op[commit_slot_reg];
                commit_writes_rd_reg[commit_lane_index] =
                    entry_writes_rd[commit_slot_reg];
                commit_rd_reg[commit_lane_index*5 +: 5] =
                    entry_rd[commit_slot_reg];
                commit_new_phys_reg[
                    commit_lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] =
                    entry_new_phys[commit_slot_reg];
                commit_old_phys_reg[
                    commit_lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] =
                    entry_old_phys[commit_slot_reg];
                commit_value_reg[commit_lane_index*32 +: 32] =
                    entry_value[commit_slot_reg];
                commit_control_valid_reg[commit_lane_index] =
                    entry_control_valid[commit_slot_reg];
                commit_control_taken_reg[commit_lane_index] =
                    entry_control_taken[commit_slot_reg];
                commit_predicted_next_pc_reg[
                    commit_lane_index*32 +: 32] =
                    entry_predicted_next_pc[commit_slot_reg];
                commit_next_pc_reg[commit_lane_index*32 +: 32] =
                    entry_next_pc[commit_slot_reg];
                commit_lsq_valid_reg[commit_lane_index] =
                    entry_lsq_valid[commit_slot_reg];
                commit_lsq_tag_reg[
                    commit_lane_index*LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] =
                    entry_lsq_tag[commit_slot_reg];
                commit_exception_valid_reg[commit_lane_index] =
                    entry_exception_valid[commit_slot_reg];
                commit_exception_cause_reg[commit_lane_index*4 +: 4] =
                    entry_exception_cause[commit_slot_reg];
                commit_exception_tval_reg[
                    commit_lane_index*32 +: 32] =
                    entry_exception_tval[commit_slot_reg];

                if (commit_fire_prefix_reg &&
                        commit_ready_i[commit_lane_index]) begin
                    commit_fire_reg[commit_lane_index] = 1'b1;
                    commit_count = commit_count + 1;
                end else begin
                    commit_fire_prefix_reg = 1'b0;
                end
            end else begin
                commit_prefix_reg = 1'b0;
                commit_fire_prefix_reg = 1'b0;
            end
        end
    end

    always @* begin
        rollback_valid_reg = {BE_WIDTH{1'b0}};
        rollback_tag_reg = {(BE_WIDTH*ROB_TAG_WIDTH){1'b0}};
        rollback_writes_rd_reg = {BE_WIDTH{1'b0}};
        rollback_rd_reg = {(BE_WIDTH*5){1'b0}};
        rollback_new_phys_reg =
            {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        rollback_old_phys_reg =
            {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        rollback_lsq_valid_reg = {BE_WIDTH{1'b0}};
        rollback_lsq_tag_reg = {(BE_WIDTH*LSQ_TAG_WIDTH){1'b0}};
        rollback_slot_reg = {(BE_WIDTH*ROB_INDEX_WIDTH){1'b0}};
        rollback_count = 0;
        recovery_stop_reg = 1'b0;
        recovery_done_reg = 1'b0;
        recovery_lookahead_slot_reg = {ROB_INDEX_WIDTH{1'b0}};
        rollback_scan_slot_reg = {ROB_INDEX_WIDTH{1'b0}};

        for (rollback_lane_index = 0; rollback_lane_index < BE_WIDTH;
                rollback_lane_index = rollback_lane_index + 1) begin
            rollback_scan_slot_reg = rob_index_sub(tail_reg,
                rollback_lane_index + 1);
            if (recovery_busy_reg && !reset_i && !recovery_stop_reg) begin
                if (entry_busy[rollback_scan_slot_reg] &&
                        ({entry_generation[rollback_scan_slot_reg],
                          rollback_scan_slot_reg} ==
                            recovery_branch_tag_reg)) begin
                    recovery_stop_reg = 1'b1;
                    recovery_done_reg = 1'b1;
                end else if (entry_busy[rollback_scan_slot_reg]) begin
                    rollback_valid_reg[rollback_lane_index] = 1'b1;
                    rollback_slot_reg[
                        rollback_lane_index*ROB_INDEX_WIDTH +:
                        ROB_INDEX_WIDTH] = rollback_scan_slot_reg;
                    rollback_tag_reg[
                        rollback_lane_index*ROB_TAG_WIDTH +:
                        ROB_TAG_WIDTH] = {
                        entry_generation[rollback_scan_slot_reg],
                        rollback_scan_slot_reg};
                    rollback_writes_rd_reg[rollback_lane_index] =
                        entry_writes_rd[rollback_scan_slot_reg];
                    rollback_rd_reg[rollback_lane_index*5 +: 5] =
                        entry_rd[rollback_scan_slot_reg];
                    rollback_new_phys_reg[
                        rollback_lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] =
                        entry_new_phys[rollback_scan_slot_reg];
                    rollback_old_phys_reg[
                        rollback_lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] =
                        entry_old_phys[rollback_scan_slot_reg];
                    rollback_lsq_valid_reg[rollback_lane_index] =
                        entry_lsq_valid[rollback_scan_slot_reg];
                    rollback_lsq_tag_reg[
                        rollback_lane_index*LSQ_TAG_WIDTH +:
                        LSQ_TAG_WIDTH] = entry_lsq_tag[rollback_scan_slot_reg];
                    rollback_count = rollback_count + 1;
                end
            end
        end

        recovery_lookahead_slot_reg = rob_index_sub(tail_reg,
            rollback_count + 1);
        if (recovery_busy_reg && !reset_i && !recovery_done_reg &&
                entry_busy[recovery_lookahead_slot_reg] &&
                ({entry_generation[recovery_lookahead_slot_reg],
                  recovery_lookahead_slot_reg} ==
                    recovery_branch_tag_reg)) begin
            recovery_done_reg = 1'b1;
        end
    end

    always @(posedge clk_i) begin
        /* verilator lint_off BLKSEQ */
        if (reset_i) begin
            for (sequential_entry_index = 0;
                    sequential_entry_index < ROB_ENTRIES;
                    sequential_entry_index = sequential_entry_index + 1) begin
                entry_busy[sequential_entry_index] <= 1'b0;
                entry_generation[sequential_entry_index] <=
                    {ROB_GENERATION_WIDTH{1'b0}};
                entry_complete[sequential_entry_index] <= 1'b0;
                entry_pc[sequential_entry_index] <= 32'd0;
                entry_instruction[sequential_entry_index] <= 32'd0;
                entry_op[sequential_entry_index] <=
                    {`RV32_OP_WIDTH{1'b0}};
                entry_writes_rd[sequential_entry_index] <= 1'b0;
                entry_rd[sequential_entry_index] <= 5'd0;
                entry_new_phys[sequential_entry_index] <=
                    {PHYS_REG_ADDR_WIDTH{1'b0}};
                entry_old_phys[sequential_entry_index] <=
                    {PHYS_REG_ADDR_WIDTH{1'b0}};
                entry_value[sequential_entry_index] <= 32'd0;
                entry_control_valid[sequential_entry_index] <= 1'b0;
                entry_control_taken[sequential_entry_index] <= 1'b0;
                entry_predicted_next_pc[sequential_entry_index] <= 32'd0;
                entry_next_pc[sequential_entry_index] <= 32'd0;
                entry_lsq_valid[sequential_entry_index] <= 1'b0;
                entry_lsq_tag[sequential_entry_index] <=
                    {LSQ_TAG_WIDTH{1'b0}};
                entry_exception_valid[sequential_entry_index] <= 1'b0;
                entry_exception_cause[sequential_entry_index] <= 4'd0;
                entry_exception_tval[sequential_entry_index] <= 32'd0;
                next_generation[sequential_entry_index] <=
                    {ROB_GENERATION_WIDTH{1'b0}};
            end
            head_reg <= {ROB_INDEX_WIDTH{1'b0}};
            tail_reg <= {ROB_INDEX_WIDTH{1'b0}};
            occupancy_reg <= {(ROB_INDEX_WIDTH+1){1'b0}};
            recovery_busy_reg <= 1'b0;
            recovery_redirect_pending_reg <= 1'b0;
            recovery_redirect_pc_reg <= 32'd0;
            recovery_branch_tag_reg <= {ROB_TAG_WIDTH{1'b0}};
        end else if (recovery_busy_reg) begin
            recovery_redirect_pending_reg <= 1'b0;
            for (sequential_lane_index = 0;
                    sequential_lane_index < BE_WIDTH;
                    sequential_lane_index = sequential_lane_index + 1) begin
                if (rollback_valid_reg[sequential_lane_index]) begin
                    sequential_slot_reg = rollback_slot_reg[
                        sequential_lane_index*ROB_INDEX_WIDTH +:
                        ROB_INDEX_WIDTH];
                    entry_busy[sequential_slot_reg] <= 1'b0;
                    entry_complete[sequential_slot_reg] <= 1'b0;
                end
            end
            tail_reg <= rob_index_sub(tail_reg, rollback_count);
            occupancy_reg <= occupancy_reg - rollback_count;
            if (recovery_done_reg) begin
                recovery_busy_reg <= 1'b0;
            end
        end else begin
            for (sequential_lane_index = 0;
                    sequential_lane_index < BE_WIDTH;
                    sequential_lane_index = sequential_lane_index + 1) begin
                if (commit_fire_reg[sequential_lane_index]) begin
                    sequential_slot_reg = rob_index_add(head_reg,
                        sequential_lane_index);
                    entry_busy[sequential_slot_reg] <= 1'b0;
                    entry_complete[sequential_slot_reg] <= 1'b0;
                end
            end

            for (sequential_lane_index = 0;
                    sequential_lane_index < BE_WIDTH;
                    sequential_lane_index = sequential_lane_index + 1) begin
                if (completion_accept_reg[sequential_lane_index]) begin
                    sequential_slot_reg = completion_tag_i[
                        sequential_lane_index*ROB_TAG_WIDTH +:
                        ROB_INDEX_WIDTH];
                    entry_complete[sequential_slot_reg] <= 1'b1;
                    entry_value[sequential_slot_reg] <= completion_value_i[
                        sequential_lane_index*32 +: 32];
                    entry_control_valid[sequential_slot_reg] <=
                        completion_control_valid_i[sequential_lane_index];
                    entry_control_taken[sequential_slot_reg] <=
                        completion_control_taken_i[sequential_lane_index];
                    entry_next_pc[sequential_slot_reg] <=
                        completion_control_valid_i[sequential_lane_index] ?
                        completion_next_pc_i[
                            sequential_lane_index*32 +: 32] : 32'd0;
                    if (completion_exception_valid_i[
                            sequential_lane_index]) begin
                        entry_exception_valid[sequential_slot_reg] <= 1'b1;
                        entry_exception_cause[sequential_slot_reg] <=
                            completion_exception_cause_i[
                                sequential_lane_index*4 +: 4];
                        entry_exception_tval[sequential_slot_reg] <=
                            completion_exception_tval_i[
                                sequential_lane_index*32 +: 32];
                    end
                end
            end

            if (alloc_fire_i && alloc_ready_reg) begin
                for (sequential_lane_index = 0;
                        sequential_lane_index < BE_WIDTH;
                        sequential_lane_index = sequential_lane_index + 1) begin
                    if (alloc_valid_i[sequential_lane_index]) begin
                        sequential_slot_reg = rob_index_add(tail_reg,
                            sequential_lane_index);
                        entry_busy[sequential_slot_reg] <= 1'b1;
                        entry_generation[sequential_slot_reg] <=
                            next_generation[sequential_slot_reg];
                        entry_complete[sequential_slot_reg] <=
                            alloc_complete_i[sequential_lane_index];
                        entry_pc[sequential_slot_reg] <= alloc_pc_i[
                            sequential_lane_index*32 +: 32];
                        entry_instruction[sequential_slot_reg] <=
                            alloc_instruction_i[
                                sequential_lane_index*32 +: 32];
                        entry_op[sequential_slot_reg] <= alloc_op_i[
                            sequential_lane_index*`RV32_OP_WIDTH +:
                            `RV32_OP_WIDTH];
                        entry_writes_rd[sequential_slot_reg] <=
                            alloc_writes_rd_i[sequential_lane_index];
                        entry_rd[sequential_slot_reg] <= alloc_rd_i[
                            sequential_lane_index*5 +: 5];
                        entry_new_phys[sequential_slot_reg] <=
                            alloc_new_phys_i[
                                sequential_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH];
                        entry_old_phys[sequential_slot_reg] <=
                            alloc_old_phys_i[
                                sequential_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH];
                        entry_value[sequential_slot_reg] <= 32'd0;
                        entry_control_valid[sequential_slot_reg] <= 1'b0;
                        entry_control_taken[sequential_slot_reg] <= 1'b0;
                        entry_predicted_next_pc[sequential_slot_reg] <=
                            alloc_predicted_next_pc_i[
                                sequential_lane_index*32 +: 32];
                        entry_next_pc[sequential_slot_reg] <= 32'd0;
                        entry_lsq_valid[sequential_slot_reg] <=
                            alloc_lsq_valid_i[sequential_lane_index];
                        entry_lsq_tag[sequential_slot_reg] <= alloc_lsq_tag_i[
                            sequential_lane_index*LSQ_TAG_WIDTH +:
                            LSQ_TAG_WIDTH];
                        entry_exception_valid[sequential_slot_reg] <=
                            alloc_exception_valid_i[sequential_lane_index];
                        entry_exception_cause[sequential_slot_reg] <=
                            alloc_exception_cause_i[
                                sequential_lane_index*4 +: 4];
                        entry_exception_tval[sequential_slot_reg] <=
                            alloc_exception_tval_i[
                                sequential_lane_index*32 +: 32];
                        next_generation[sequential_slot_reg] <=
                            next_generation[sequential_slot_reg] + 1'b1;
                    end
                end
            end

            head_reg <= rob_index_add(head_reg, commit_count);
            tail_reg <= rob_index_add(tail_reg,
                (alloc_fire_i && alloc_ready_reg) ? alloc_count : 0);
            occupancy_reg <= occupancy_reg +
                ((alloc_fire_i && alloc_ready_reg) ? alloc_count : 0) -
                commit_count;

            if (mispredict_found_reg) begin
                recovery_busy_reg <= 1'b1;
                recovery_redirect_pending_reg <= 1'b1;
                recovery_redirect_pc_reg <= mispredict_next_pc_reg;
                recovery_branch_tag_reg <= mispredict_tag_reg;
            end
        end
        /* verilator lint_on BLKSEQ */
    end

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        /* verilator lint_off BLKSEQ */
        if (!reset_i) begin
            if (occupancy_reg > ROB_ENTRIES) begin
                $display("ERROR rv32_reorder_buffer occupancy overflow=%0d",
                    occupancy_reg);
                $finish(1);
            end
            if (alloc_fire_i && !alloc_ready_reg) begin
                $display("ERROR rv32_reorder_buffer allocation without ready");
                $finish(1);
            end
            assertion_prefix_reg = 1'b1;
            for (assertion_lane_index = 0;
                    assertion_lane_index < BE_WIDTH;
                    assertion_lane_index = assertion_lane_index + 1) begin
                if (alloc_valid_i[assertion_lane_index]) begin
                    if (!assertion_prefix_reg) begin
                        $display("ERROR rv32_reorder_buffer sparse allocation bundle");
                        $finish(1);
                    end
                end else begin
                    assertion_prefix_reg = 1'b0;
                end
            end
            if (recovery_busy_reg &&
                    (alloc_fire_i || (|commit_fire_reg) ||
                     (|completion_accept_reg))) begin
                $display("ERROR rv32_reorder_buffer normal traffic during recovery");
                $finish(1);
            end
            if (recovery_busy_reg) begin
                assertion_slot_reg = recovery_branch_tag_reg[
                    ROB_INDEX_WIDTH-1:0];
                if (!entry_busy[assertion_slot_reg] ||
                        (entry_generation[assertion_slot_reg] !=
                            recovery_branch_tag_reg[
                                ROB_TAG_WIDTH-1:ROB_INDEX_WIDTH])) begin
                    $display("ERROR rv32_reorder_buffer lost recovery branch");
                    $finish(1);
                end
            end
        end
        /* verilator lint_on BLKSEQ */
    end
`endif

    /* verilator lint_on WIDTHTRUNC */
    /* verilator lint_on WIDTHEXPAND */

endmodule
