`timescale 1ns/1ps
`include "rv32im_defs.vh"

/* verilator lint_off DECLFILENAME */

module rv32_mdu_reservation_station_core #(
    parameter RS_ENTRIES = 4,
    parameter RS_INDEX_WIDTH = 2,
    parameter BE_WIDTH = 1,
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter ROB_ENTRIES = 32,
    parameter ROB_INDEX_WIDTH = 5,
    parameter ROB_TAG_WIDTH = 7,
    parameter OP_CLASS = 0
) (
    input  wire                                             clk_i,
    input  wire                                             reset_i,
    input  wire                                             flush_i,
    input  wire                                             recover_i,

    input  wire [BE_WIDTH-1:0]                              dispatch_valid_i,
    input  wire                                             dispatch_fire_i,
    input  wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0]             dispatch_op_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              dispatch_rob_tag_i,
    input  wire [BE_WIDTH-1:0]                              dispatch_lhs_ready_i,
    input  wire [(BE_WIDTH*32)-1:0]                         dispatch_lhs_value_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        dispatch_lhs_phys_i,
    input  wire [BE_WIDTH-1:0]                              dispatch_rhs_ready_i,
    input  wire [(BE_WIDTH*32)-1:0]                         dispatch_rhs_value_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        dispatch_rhs_phys_i,
    output wire                                             dispatch_ready_o,
    output wire [RS_INDEX_WIDTH:0]                          occupancy_o,

    input  wire [BE_WIDTH-1:0]                              broadcast_valid_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        broadcast_phys_i,
    input  wire [(BE_WIDTH*32)-1:0]                         broadcast_value_i,

    input  wire [ROB_INDEX_WIDTH-1:0]                       rob_head_index_i,
    input  wire [BE_WIDTH-1:0]                              rollback_valid_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              rollback_tag_i,

    output wire                                             request_valid_o,
    input  wire                                             request_ready_i,
    output wire [`RV32_OP_WIDTH-1:0]                        request_op_o,
    output wire [31:0]                                      request_lhs_o,
    output wire [31:0]                                      request_rhs_o,
    output wire [ROB_TAG_WIDTH-1:0]                         request_rob_tag_o
);

    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */

    reg entry_busy [0:RS_ENTRIES-1];
    reg [`RV32_OP_WIDTH-1:0] entry_op [0:RS_ENTRIES-1];
    reg [ROB_TAG_WIDTH-1:0] entry_rob_tag [0:RS_ENTRIES-1];
    reg entry_lhs_ready [0:RS_ENTRIES-1];
    reg [31:0] entry_lhs_value [0:RS_ENTRIES-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0] entry_lhs_phys [0:RS_ENTRIES-1];
    reg entry_rhs_ready [0:RS_ENTRIES-1];
    reg [31:0] entry_rhs_value [0:RS_ENTRIES-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0] entry_rhs_phys [0:RS_ENTRIES-1];

    reg request_locked;
    reg [RS_INDEX_WIDTH-1:0] request_locked_slot;
    reg [RS_INDEX_WIDTH:0] occupancy_reg;

    reg effective_lhs_ready [0:RS_ENTRIES-1];
    reg [31:0] effective_lhs_value [0:RS_ENTRIES-1];
    reg effective_rhs_ready [0:RS_ENTRIES-1];
    reg [31:0] effective_rhs_value [0:RS_ENTRIES-1];
    reg dispatch_lhs_captured_ready [0:BE_WIDTH-1];
    reg [31:0] dispatch_lhs_captured_value [0:BE_WIDTH-1];
    reg dispatch_rhs_captured_ready [0:BE_WIDTH-1];
    reg [31:0] dispatch_rhs_captured_value [0:BE_WIDTH-1];

    reg request_valid_reg;
    reg [`RV32_OP_WIDTH-1:0] request_op_reg;
    reg [31:0] request_lhs_reg;
    reg [31:0] request_rhs_reg;
    reg [ROB_TAG_WIDTH-1:0] request_rob_tag_reg;
    reg request_slot_valid_reg;
    reg [RS_INDEX_WIDTH-1:0] request_slot_reg;
    reg [RS_ENTRIES-1:0] issue_remove_mask_reg;

    reg dispatch_ready_reg;
    reg allocation_slot_valid_reg [0:BE_WIDTH-1];
    reg [RS_INDEX_WIDTH-1:0] allocation_slot_reg [0:BE_WIDTH-1];
    reg entry_allocate_valid_reg [0:RS_ENTRIES-1];
    reg [RS_ENTRIES-1:0] available_slot_mask_reg;
    reg [RS_ENTRIES-1:0] allocated_slot_mask_reg;
    reg [RS_ENTRIES-1:0] rollback_remove_mask_reg;

    integer effective_entry_index;
    integer effective_broadcast_index;
    integer capture_lane_index;
    integer capture_broadcast_index;
    integer selection_entry_index;
    integer dispatch_lane_index;
    integer allocation_entry_index;
    integer allocation_winner_slot;
    integer available_count;
    integer dispatch_count;
    integer issue_count;
    integer rollback_entry_index;
    integer rollback_lane_index;
    integer rollback_remove_count;
    integer selection_winner_slot;
    integer selection_winner_distance;
    integer selection_candidate_distance;
    integer busy_entry_index;
    integer busy_count;
    integer sequential_entry_index;
    integer sequential_lane_index;
    integer assertion_lane_index;
    integer assertion_broadcast_index;

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

    function integer rob_distance;
        input [ROB_INDEX_WIDTH-1:0] tag_index_value;
        input [ROB_INDEX_WIDTH-1:0] head_value;
        integer tag_index;
        integer head_index;
        begin
            tag_index = tag_index_value;
            head_index = head_value;
            if (tag_index >= head_index) begin
                rob_distance = tag_index - head_index;
            end else begin
                rob_distance = tag_index + ROB_ENTRIES - head_index;
            end
        end
    endfunction

    function supported_op;
        input [`RV32_OP_WIDTH-1:0] op_value;
        begin
            if (OP_CLASS == 0) begin
                supported_op =
                    (op_value == `RV32_OP_MUL) ||
                    (op_value == `RV32_OP_MULH) ||
                    (op_value == `RV32_OP_MULHSU) ||
                    (op_value == `RV32_OP_MULHU);
            end else begin
                supported_op =
                    (op_value == `RV32_OP_DIV) ||
                    (op_value == `RV32_OP_DIVU) ||
                    (op_value == `RV32_OP_REM) ||
                    (op_value == `RV32_OP_REMU);
            end
        end
    endfunction

    assign dispatch_ready_o = dispatch_ready_reg;
    assign occupancy_o = (reset_i || flush_i) ?
        {(RS_INDEX_WIDTH+1){1'b0}} : occupancy_reg;
    assign request_valid_o = request_valid_reg;
    assign request_op_o = request_op_reg;
    assign request_lhs_o = request_lhs_reg;
    assign request_rhs_o = request_rhs_reg;
    assign request_rob_tag_o = request_rob_tag_reg;

    initial begin
        if ((OP_CLASS != 0) && (OP_CLASS != 1)) begin
            $display("ERROR rv32_mdu_reservation_station_core invalid OP_CLASS=%0d",
                OP_CLASS);
            $finish(1);
        end
        if ((BE_WIDTH != 1) && (BE_WIDTH != 2) && (BE_WIDTH != 4)) begin
            $display("ERROR rv32_mdu_reservation_station_core invalid BE_WIDTH=%0d",
                BE_WIDTH);
            $finish(1);
        end
        if ((RS_ENTRIES < BE_WIDTH) || (RS_ENTRIES < 2)) begin
            $display("ERROR rv32_mdu_reservation_station_core invalid RS_ENTRIES=%0d",
                RS_ENTRIES);
            $finish(1);
        end
        if ((RS_ENTRIES & (RS_ENTRIES - 1)) != 0) begin
            $display("ERROR rv32_mdu_reservation_station_core RS_ENTRIES not power of two=%0d",
                RS_ENTRIES);
            $finish(1);
        end
        if (RS_INDEX_WIDTH != address_width_for_count(RS_ENTRIES)) begin
            $display("ERROR rv32_mdu_reservation_station_core index width=%0d expected=%0d",
                RS_INDEX_WIDTH, address_width_for_count(RS_ENTRIES));
            $finish(1);
        end
        if ((ROB_ENTRIES < BE_WIDTH) || (ROB_ENTRIES < 2) ||
                ((ROB_ENTRIES & (ROB_ENTRIES - 1)) != 0)) begin
            $display("ERROR rv32_mdu_reservation_station_core invalid ROB_ENTRIES=%0d",
                ROB_ENTRIES);
            $finish(1);
        end
        if (ROB_INDEX_WIDTH != address_width_for_count(ROB_ENTRIES)) begin
            $display("ERROR rv32_mdu_reservation_station_core ROB index width=%0d expected=%0d",
                ROB_INDEX_WIDTH, address_width_for_count(ROB_ENTRIES));
            $finish(1);
        end
        if (ROB_TAG_WIDTH <= ROB_INDEX_WIDTH) begin
            $display("ERROR rv32_mdu_reservation_station_core invalid ROB_TAG_WIDTH=%0d",
                ROB_TAG_WIDTH);
            $finish(1);
        end
        if (PHYS_REGS < 33) begin
            $display("ERROR rv32_mdu_reservation_station_core PHYS_REGS=%0d is below 33",
                PHYS_REGS);
            $finish(1);
        end
        if (PHYS_REG_ADDR_WIDTH != address_width_for_count(PHYS_REGS)) begin
            $display("ERROR rv32_mdu_reservation_station_core physical address width=%0d expected=%0d",
                PHYS_REG_ADDR_WIDTH, address_width_for_count(PHYS_REGS));
            $finish(1);
        end
    end

    always @* begin
        effective_entry_index = 0;
        effective_broadcast_index = 0;
        for (effective_entry_index = 0;
                effective_entry_index < RS_ENTRIES;
                effective_entry_index = effective_entry_index + 1) begin
            effective_lhs_ready[effective_entry_index] =
                entry_lhs_ready[effective_entry_index];
            effective_lhs_value[effective_entry_index] =
                entry_lhs_value[effective_entry_index];
            effective_rhs_ready[effective_entry_index] =
                entry_rhs_ready[effective_entry_index];
            effective_rhs_value[effective_entry_index] =
                entry_rhs_value[effective_entry_index];
            if (!reset_i && !flush_i && !recover_i &&
                    entry_busy[effective_entry_index]) begin
                for (effective_broadcast_index = 0;
                        effective_broadcast_index < BE_WIDTH;
                        effective_broadcast_index =
                            effective_broadcast_index + 1) begin
                    if (!effective_lhs_ready[effective_entry_index] &&
                            broadcast_valid_i[effective_broadcast_index] &&
                            (broadcast_phys_i[
                                effective_broadcast_index*
                                    PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                             entry_lhs_phys[effective_entry_index])) begin
                        effective_lhs_ready[effective_entry_index] = 1'b1;
                        effective_lhs_value[effective_entry_index] =
                            broadcast_value_i[
                                effective_broadcast_index*32 +: 32];
                    end
                    if (!effective_rhs_ready[effective_entry_index] &&
                            broadcast_valid_i[effective_broadcast_index] &&
                            (broadcast_phys_i[
                                effective_broadcast_index*
                                    PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                             entry_rhs_phys[effective_entry_index])) begin
                        effective_rhs_ready[effective_entry_index] = 1'b1;
                        effective_rhs_value[effective_entry_index] =
                            broadcast_value_i[
                                effective_broadcast_index*32 +: 32];
                    end
                end
            end
        end
    end

    always @* begin
        capture_lane_index = 0;
        capture_broadcast_index = 0;
        for (capture_lane_index = 0; capture_lane_index < BE_WIDTH;
                capture_lane_index = capture_lane_index + 1) begin
            dispatch_lhs_captured_ready[capture_lane_index] =
                dispatch_lhs_ready_i[capture_lane_index];
            dispatch_lhs_captured_value[capture_lane_index] =
                dispatch_lhs_value_i[capture_lane_index*32 +: 32];
            dispatch_rhs_captured_ready[capture_lane_index] =
                dispatch_rhs_ready_i[capture_lane_index];
            dispatch_rhs_captured_value[capture_lane_index] =
                dispatch_rhs_value_i[capture_lane_index*32 +: 32];
            if (!reset_i && !flush_i && !recover_i) begin
                for (capture_broadcast_index = 0;
                        capture_broadcast_index < BE_WIDTH;
                        capture_broadcast_index =
                            capture_broadcast_index + 1) begin
                    if (!dispatch_lhs_captured_ready[capture_lane_index] &&
                            broadcast_valid_i[capture_broadcast_index] &&
                            (broadcast_phys_i[
                                capture_broadcast_index*
                                    PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                             dispatch_lhs_phys_i[
                                capture_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH])) begin
                        dispatch_lhs_captured_ready[capture_lane_index] =
                            1'b1;
                        dispatch_lhs_captured_value[capture_lane_index] =
                            broadcast_value_i[
                                capture_broadcast_index*32 +: 32];
                    end
                    if (!dispatch_rhs_captured_ready[capture_lane_index] &&
                            broadcast_valid_i[capture_broadcast_index] &&
                            (broadcast_phys_i[
                                capture_broadcast_index*
                                    PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                             dispatch_rhs_phys_i[
                                capture_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH])) begin
                        dispatch_rhs_captured_ready[capture_lane_index] =
                            1'b1;
                        dispatch_rhs_captured_value[capture_lane_index] =
                            broadcast_value_i[
                                capture_broadcast_index*32 +: 32];
                    end
                end
            end
        end
    end

    always @* begin
        selection_entry_index = 0;
        request_valid_reg = 1'b0;
        request_op_reg = `RV32_OP_INVALID;
        request_lhs_reg = 32'd0;
        request_rhs_reg = 32'd0;
        request_rob_tag_reg = {ROB_TAG_WIDTH{1'b0}};
        request_slot_valid_reg = 1'b0;
        request_slot_reg = {RS_INDEX_WIDTH{1'b0}};
        issue_remove_mask_reg = {RS_ENTRIES{1'b0}};
        issue_count = 0;
        selection_winner_slot = 0;
        selection_winner_distance = ROB_ENTRIES;
        selection_candidate_distance = ROB_ENTRIES;

        if (!reset_i && !flush_i && !recover_i) begin
            if (request_locked) begin
                request_slot_valid_reg = 1'b1;
                request_slot_reg = request_locked_slot;
            end else begin
                for (selection_entry_index = 0;
                        selection_entry_index < RS_ENTRIES;
                        selection_entry_index = selection_entry_index + 1) begin
                    selection_candidate_distance = rob_distance(
                        entry_rob_tag[selection_entry_index][
                            ROB_INDEX_WIDTH-1:0],
                        rob_head_index_i);
                    if (entry_busy[selection_entry_index] &&
                            effective_lhs_ready[selection_entry_index] &&
                            effective_rhs_ready[selection_entry_index] &&
                            ((selection_winner_distance == ROB_ENTRIES) ||
                             (selection_candidate_distance <
                                selection_winner_distance) ||
                             ((selection_candidate_distance ==
                                selection_winner_distance) &&
                              (selection_entry_index <
                                selection_winner_slot)))) begin
                        selection_winner_slot = selection_entry_index;
                        selection_winner_distance =
                            selection_candidate_distance;
                    end
                end
                if (selection_winner_distance != ROB_ENTRIES) begin
                    request_slot_valid_reg = 1'b1;
                    request_slot_reg =
                        selection_winner_slot[RS_INDEX_WIDTH-1:0];
                end
            end

            if (request_slot_valid_reg) begin
                request_valid_reg = 1'b1;
                request_op_reg = entry_op[request_slot_reg];
                request_lhs_reg = effective_lhs_value[request_slot_reg];
                request_rhs_reg = effective_rhs_value[request_slot_reg];
                request_rob_tag_reg = entry_rob_tag[request_slot_reg];
                if (request_ready_i) begin
                    issue_remove_mask_reg[request_slot_reg] = 1'b1;
                    issue_count = 1;
                end
            end
        end
    end

    always @* begin
        dispatch_lane_index = 0;
        allocation_entry_index = 0;
        dispatch_count = 0;
        available_count = 0;
        available_slot_mask_reg = {RS_ENTRIES{1'b0}};
        allocated_slot_mask_reg = {RS_ENTRIES{1'b0}};
        dispatch_ready_reg = 1'b0;
        allocation_winner_slot = RS_ENTRIES;
        for (dispatch_lane_index = 0; dispatch_lane_index < BE_WIDTH;
                dispatch_lane_index = dispatch_lane_index + 1) begin
            allocation_slot_valid_reg[dispatch_lane_index] = 1'b0;
            allocation_slot_reg[dispatch_lane_index] =
                {RS_INDEX_WIDTH{1'b0}};
            if (dispatch_valid_i[dispatch_lane_index]) begin
                dispatch_count = dispatch_count + 1;
            end
        end
        for (allocation_entry_index = 0;
                allocation_entry_index < RS_ENTRIES;
                allocation_entry_index = allocation_entry_index + 1) begin
            entry_allocate_valid_reg[allocation_entry_index] = 1'b0;
            if (!entry_busy[allocation_entry_index] ||
                    issue_remove_mask_reg[allocation_entry_index]) begin
                available_slot_mask_reg[allocation_entry_index] = 1'b1;
                available_count = available_count + 1;
            end
        end
        if (!reset_i && !flush_i && !recover_i &&
                (available_count >= dispatch_count)) begin
            dispatch_ready_reg = 1'b1;
            for (dispatch_lane_index = 0;
                    dispatch_lane_index < BE_WIDTH;
                    dispatch_lane_index = dispatch_lane_index + 1) begin
                if (dispatch_valid_i[dispatch_lane_index]) begin
                    allocation_winner_slot = RS_ENTRIES;
                    for (allocation_entry_index = 0;
                            allocation_entry_index < RS_ENTRIES;
                            allocation_entry_index =
                                allocation_entry_index + 1) begin
                        if ((allocation_winner_slot == RS_ENTRIES) &&
                                available_slot_mask_reg[
                                    allocation_entry_index] &&
                                !allocated_slot_mask_reg[
                                    allocation_entry_index]) begin
                            allocation_winner_slot = allocation_entry_index;
                        end
                    end
                    allocation_slot_valid_reg[dispatch_lane_index] = 1'b1;
                    allocation_slot_reg[dispatch_lane_index] =
                        allocation_winner_slot[RS_INDEX_WIDTH-1:0];
                    allocated_slot_mask_reg[allocation_winner_slot] = 1'b1;
                    entry_allocate_valid_reg[allocation_winner_slot] = 1'b1;
                end
            end
        end
    end

    always @* begin
        rollback_entry_index = 0;
        rollback_lane_index = 0;
        rollback_remove_mask_reg = {RS_ENTRIES{1'b0}};
        rollback_remove_count = 0;
        if (!reset_i && !flush_i && recover_i) begin
            for (rollback_entry_index = 0;
                    rollback_entry_index < RS_ENTRIES;
                    rollback_entry_index = rollback_entry_index + 1) begin
                for (rollback_lane_index = 0;
                        rollback_lane_index < BE_WIDTH;
                        rollback_lane_index = rollback_lane_index + 1) begin
                    if (entry_busy[rollback_entry_index] &&
                            rollback_valid_i[rollback_lane_index] &&
                            (entry_rob_tag[rollback_entry_index] ==
                             rollback_tag_i[
                                rollback_lane_index*ROB_TAG_WIDTH +:
                                ROB_TAG_WIDTH])) begin
                        rollback_remove_mask_reg[rollback_entry_index] = 1'b1;
                    end
                end
                if (rollback_remove_mask_reg[rollback_entry_index]) begin
                    rollback_remove_count = rollback_remove_count + 1;
                end
            end
        end
    end

    always @* begin
        busy_entry_index = 0;
        busy_count = 0;
        for (busy_entry_index = 0; busy_entry_index < RS_ENTRIES;
                busy_entry_index = busy_entry_index + 1) begin
            if (entry_busy[busy_entry_index]) begin
                busy_count = busy_count + 1;
            end
        end
    end

    always @(posedge clk_i) begin
        if (reset_i || flush_i) begin
            occupancy_reg <= {(RS_INDEX_WIDTH+1){1'b0}};
            request_locked <= 1'b0;
            request_locked_slot <= {RS_INDEX_WIDTH{1'b0}};
            for (sequential_entry_index = 0;
                    sequential_entry_index < RS_ENTRIES;
                    sequential_entry_index = sequential_entry_index + 1) begin
                entry_busy[sequential_entry_index] <= 1'b0;
                entry_op[sequential_entry_index] <= `RV32_OP_INVALID;
                entry_rob_tag[sequential_entry_index] <=
                    {ROB_TAG_WIDTH{1'b0}};
                entry_lhs_ready[sequential_entry_index] <= 1'b0;
                entry_lhs_value[sequential_entry_index] <= 32'd0;
                entry_lhs_phys[sequential_entry_index] <=
                    {PHYS_REG_ADDR_WIDTH{1'b0}};
                entry_rhs_ready[sequential_entry_index] <= 1'b0;
                entry_rhs_value[sequential_entry_index] <= 32'd0;
                entry_rhs_phys[sequential_entry_index] <=
                    {PHYS_REG_ADDR_WIDTH{1'b0}};
            end
        end else if (recover_i) begin
            occupancy_reg <= occupancy_reg - rollback_remove_count;
            if (request_locked &&
                    rollback_remove_mask_reg[request_locked_slot]) begin
                request_locked <= 1'b0;
                request_locked_slot <= {RS_INDEX_WIDTH{1'b0}};
            end
            for (sequential_entry_index = 0;
                    sequential_entry_index < RS_ENTRIES;
                    sequential_entry_index = sequential_entry_index + 1) begin
                if (rollback_remove_mask_reg[sequential_entry_index]) begin
                    entry_busy[sequential_entry_index] <= 1'b0;
                    entry_op[sequential_entry_index] <= `RV32_OP_INVALID;
                    entry_rob_tag[sequential_entry_index] <=
                        {ROB_TAG_WIDTH{1'b0}};
                    entry_lhs_ready[sequential_entry_index] <= 1'b0;
                    entry_lhs_value[sequential_entry_index] <= 32'd0;
                    entry_lhs_phys[sequential_entry_index] <=
                        {PHYS_REG_ADDR_WIDTH{1'b0}};
                    entry_rhs_ready[sequential_entry_index] <= 1'b0;
                    entry_rhs_value[sequential_entry_index] <= 32'd0;
                    entry_rhs_phys[sequential_entry_index] <=
                        {PHYS_REG_ADDR_WIDTH{1'b0}};
                end
            end
        end else begin
            occupancy_reg <= occupancy_reg - issue_count +
                ((dispatch_fire_i && dispatch_ready_reg) ?
                    dispatch_count : 0);

            if (request_locked) begin
                if (request_valid_reg && request_ready_i) begin
                    request_locked <= 1'b0;
                    request_locked_slot <= {RS_INDEX_WIDTH{1'b0}};
                end
            end else if (request_valid_reg && !request_ready_i) begin
                request_locked <= 1'b1;
                request_locked_slot <= request_slot_reg;
            end

            for (sequential_entry_index = 0;
                    sequential_entry_index < RS_ENTRIES;
                    sequential_entry_index = sequential_entry_index + 1) begin
                if (entry_allocate_valid_reg[sequential_entry_index] &&
                        dispatch_fire_i && dispatch_ready_reg) begin
                    for (sequential_lane_index = 0;
                            sequential_lane_index < BE_WIDTH;
                            sequential_lane_index =
                                sequential_lane_index + 1) begin
                        if (allocation_slot_valid_reg[
                                sequential_lane_index] &&
                                (allocation_slot_reg[
                                    sequential_lane_index] ==
                                 sequential_entry_index)) begin
                            entry_busy[sequential_entry_index] <= 1'b1;
                            entry_op[sequential_entry_index] <= dispatch_op_i[
                                sequential_lane_index*`RV32_OP_WIDTH +:
                                `RV32_OP_WIDTH];
                            entry_rob_tag[sequential_entry_index] <=
                                dispatch_rob_tag_i[
                                    sequential_lane_index*ROB_TAG_WIDTH +:
                                    ROB_TAG_WIDTH];
                            entry_lhs_ready[sequential_entry_index] <=
                                dispatch_lhs_captured_ready[
                                    sequential_lane_index];
                            entry_lhs_value[sequential_entry_index] <=
                                dispatch_lhs_captured_value[
                                    sequential_lane_index];
                            entry_lhs_phys[sequential_entry_index] <=
                                dispatch_lhs_phys_i[
                                    sequential_lane_index*
                                        PHYS_REG_ADDR_WIDTH +:
                                    PHYS_REG_ADDR_WIDTH];
                            entry_rhs_ready[sequential_entry_index] <=
                                dispatch_rhs_captured_ready[
                                    sequential_lane_index];
                            entry_rhs_value[sequential_entry_index] <=
                                dispatch_rhs_captured_value[
                                    sequential_lane_index];
                            entry_rhs_phys[sequential_entry_index] <=
                                dispatch_rhs_phys_i[
                                    sequential_lane_index*
                                        PHYS_REG_ADDR_WIDTH +:
                                    PHYS_REG_ADDR_WIDTH];
                        end
                    end
                end else if (issue_remove_mask_reg[
                        sequential_entry_index]) begin
                    entry_busy[sequential_entry_index] <= 1'b0;
                    entry_op[sequential_entry_index] <= `RV32_OP_INVALID;
                    entry_rob_tag[sequential_entry_index] <=
                        {ROB_TAG_WIDTH{1'b0}};
                    entry_lhs_ready[sequential_entry_index] <= 1'b0;
                    entry_lhs_value[sequential_entry_index] <= 32'd0;
                    entry_lhs_phys[sequential_entry_index] <=
                        {PHYS_REG_ADDR_WIDTH{1'b0}};
                    entry_rhs_ready[sequential_entry_index] <= 1'b0;
                    entry_rhs_value[sequential_entry_index] <= 32'd0;
                    entry_rhs_phys[sequential_entry_index] <=
                        {PHYS_REG_ADDR_WIDTH{1'b0}};
                end else if (entry_busy[sequential_entry_index]) begin
                    entry_lhs_ready[sequential_entry_index] <=
                        effective_lhs_ready[sequential_entry_index];
                    entry_lhs_value[sequential_entry_index] <=
                        effective_lhs_value[sequential_entry_index];
                    entry_rhs_ready[sequential_entry_index] <=
                        effective_rhs_ready[sequential_entry_index];
                    entry_rhs_value[sequential_entry_index] <=
                        effective_rhs_value[sequential_entry_index];
                end
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (!reset_i && !flush_i) begin
            if (busy_count != occupancy_reg) begin
                $display("ERROR rv32_mdu_reservation_station_core occupancy mismatch busy=%0d occupancy=%0d",
                    busy_count, occupancy_reg);
                $finish(1);
            end
            if (dispatch_fire_i && !dispatch_ready_reg) begin
                $display("ERROR rv32_mdu_reservation_station_core dispatch fired without ready");
                $finish(1);
            end
            for (assertion_lane_index = 0;
                    assertion_lane_index < BE_WIDTH;
                    assertion_lane_index = assertion_lane_index + 1) begin
                if (dispatch_fire_i &&
                        dispatch_valid_i[assertion_lane_index] &&
                        !supported_op(dispatch_op_i[
                            assertion_lane_index*`RV32_OP_WIDTH +:
                            `RV32_OP_WIDTH])) begin
                    $display("ERROR rv32_mdu_reservation_station_core unsupported op=%0d class=%0d",
                        dispatch_op_i[
                            assertion_lane_index*`RV32_OP_WIDTH +:
                            `RV32_OP_WIDTH], OP_CLASS);
                    $finish(1);
                end
                if (dispatch_fire_i &&
                        dispatch_valid_i[assertion_lane_index] &&
                        ((!dispatch_lhs_ready_i[assertion_lane_index] &&
                          (dispatch_lhs_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] == 0 ||
                           dispatch_lhs_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] >= PHYS_REGS)) ||
                         (!dispatch_rhs_ready_i[assertion_lane_index] &&
                          (dispatch_rhs_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] == 0 ||
                           dispatch_rhs_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] >= PHYS_REGS)))) begin
                    $display("ERROR rv32_mdu_reservation_station_core invalid unready physical register");
                    $finish(1);
                end
                if (broadcast_valid_i[assertion_lane_index] &&
                        ((broadcast_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] == 0) ||
                         (broadcast_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] >= PHYS_REGS))) begin
                    $display("ERROR rv32_mdu_reservation_station_core invalid broadcast physical register");
                    $finish(1);
                end
                for (assertion_broadcast_index =
                        assertion_lane_index + 1;
                        assertion_broadcast_index < BE_WIDTH;
                        assertion_broadcast_index =
                            assertion_broadcast_index + 1) begin
                    if (broadcast_valid_i[assertion_lane_index] &&
                            broadcast_valid_i[assertion_broadcast_index] &&
                            (broadcast_phys_i[
                                assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                             broadcast_phys_i[
                                assertion_broadcast_index*
                                    PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH])) begin
                        $display("ERROR rv32_mdu_reservation_station_core duplicate broadcast physical register");
                        $finish(1);
                    end
                end
            end
            if (request_locked && !entry_busy[request_locked_slot]) begin
                $display("ERROR rv32_mdu_reservation_station_core invalid request lock");
                $finish(1);
            end
        end
    end
`endif

    /* verilator lint_on WIDTHTRUNC */
    /* verilator lint_on WIDTHEXPAND */

endmodule

module rv32_multiply_reservation_station #(
    parameter MUL_RS_ENTRIES = 4,
    parameter MUL_RS_INDEX_WIDTH = 2,
    parameter BE_WIDTH = 1,
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter ROB_ENTRIES = 32,
    parameter ROB_INDEX_WIDTH = 5,
    parameter ROB_TAG_WIDTH = 7
) (
    input  wire                                             clk_i,
    input  wire                                             reset_i,
    input  wire                                             flush_i,
    input  wire                                             recover_i,
    input  wire [BE_WIDTH-1:0]                              dispatch_valid_i,
    input  wire                                             dispatch_fire_i,
    input  wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0]             dispatch_op_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              dispatch_rob_tag_i,
    input  wire [BE_WIDTH-1:0]                              dispatch_lhs_ready_i,
    input  wire [(BE_WIDTH*32)-1:0]                         dispatch_lhs_value_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        dispatch_lhs_phys_i,
    input  wire [BE_WIDTH-1:0]                              dispatch_rhs_ready_i,
    input  wire [(BE_WIDTH*32)-1:0]                         dispatch_rhs_value_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        dispatch_rhs_phys_i,
    output wire                                             dispatch_ready_o,
    output wire [MUL_RS_INDEX_WIDTH:0]                      occupancy_o,
    input  wire [BE_WIDTH-1:0]                              broadcast_valid_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        broadcast_phys_i,
    input  wire [(BE_WIDTH*32)-1:0]                         broadcast_value_i,
    input  wire [ROB_INDEX_WIDTH-1:0]                       rob_head_index_i,
    input  wire [BE_WIDTH-1:0]                              rollback_valid_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              rollback_tag_i,
    output wire                                             response_valid_o,
    input  wire                                             response_ready_i,
    output wire [31:0]                                      response_value_o,
    output wire [ROB_TAG_WIDTH-1:0]                         response_rob_tag_o
);

    wire request_valid;
    wire request_ready;
    wire [`RV32_OP_WIDTH-1:0] request_op;
    wire [31:0] request_lhs;
    wire [31:0] request_rhs;
    wire [ROB_TAG_WIDTH-1:0] request_rob_tag;
    wire unit_response_valid;
    wire [31:0] unit_response_value;
    wire [ROB_TAG_WIDTH-1:0] unit_response_rob_tag;

    assign response_valid_o = !recover_i && unit_response_valid;
    assign response_value_o = (!recover_i && unit_response_valid) ?
        unit_response_value : 32'd0;
    assign response_rob_tag_o = (!recover_i && unit_response_valid) ?
        unit_response_rob_tag : {ROB_TAG_WIDTH{1'b0}};

    rv32_mdu_reservation_station_core #(
        .RS_ENTRIES(MUL_RS_ENTRIES),
        .RS_INDEX_WIDTH(MUL_RS_INDEX_WIDTH),
        .BE_WIDTH(BE_WIDTH),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES),
        .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH),
        .OP_CLASS(0)
    ) reservation_station (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .recover_i(recover_i),
        .dispatch_valid_i(dispatch_valid_i),
        .dispatch_fire_i(dispatch_fire_i),
        .dispatch_op_i(dispatch_op_i),
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
        .request_valid_o(request_valid),
        .request_ready_i(request_ready),
        .request_op_o(request_op),
        .request_lhs_o(request_lhs),
        .request_rhs_o(request_rhs),
        .request_rob_tag_o(request_rob_tag)
    );

    rv32m_multiplier #(
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) multiplier (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .request_valid_i(request_valid),
        .request_ready_o(request_ready),
        .request_op_i(request_op),
        .request_lhs_i(request_lhs),
        .request_rhs_i(request_rhs),
        .request_rob_tag_i(request_rob_tag),
        .response_valid_o(unit_response_valid),
        .response_ready_i(response_ready_i && !recover_i),
        .response_value_o(unit_response_value),
        .response_rob_tag_o(unit_response_rob_tag)
    );

endmodule

module rv32_divide_reservation_station #(
    parameter DIV_RS_ENTRIES = 4,
    parameter DIV_RS_INDEX_WIDTH = 2,
    parameter BE_WIDTH = 1,
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter ROB_ENTRIES = 32,
    parameter ROB_INDEX_WIDTH = 5,
    parameter ROB_TAG_WIDTH = 7
) (
    input  wire                                             clk_i,
    input  wire                                             reset_i,
    input  wire                                             flush_i,
    input  wire                                             recover_i,
    input  wire [BE_WIDTH-1:0]                              dispatch_valid_i,
    input  wire                                             dispatch_fire_i,
    input  wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0]             dispatch_op_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              dispatch_rob_tag_i,
    input  wire [BE_WIDTH-1:0]                              dispatch_lhs_ready_i,
    input  wire [(BE_WIDTH*32)-1:0]                         dispatch_lhs_value_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        dispatch_lhs_phys_i,
    input  wire [BE_WIDTH-1:0]                              dispatch_rhs_ready_i,
    input  wire [(BE_WIDTH*32)-1:0]                         dispatch_rhs_value_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        dispatch_rhs_phys_i,
    output wire                                             dispatch_ready_o,
    output wire [DIV_RS_INDEX_WIDTH:0]                      occupancy_o,
    input  wire [BE_WIDTH-1:0]                              broadcast_valid_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        broadcast_phys_i,
    input  wire [(BE_WIDTH*32)-1:0]                         broadcast_value_i,
    input  wire [ROB_INDEX_WIDTH-1:0]                       rob_head_index_i,
    input  wire [BE_WIDTH-1:0]                              rollback_valid_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              rollback_tag_i,
    output wire                                             response_valid_o,
    input  wire                                             response_ready_i,
    output wire [31:0]                                      response_value_o,
    output wire [ROB_TAG_WIDTH-1:0]                         response_rob_tag_o
);

    wire request_valid;
    wire request_ready;
    wire [`RV32_OP_WIDTH-1:0] request_op;
    wire [31:0] request_lhs;
    wire [31:0] request_rhs;
    wire [ROB_TAG_WIDTH-1:0] request_rob_tag;
    wire unit_response_valid;
    wire [31:0] unit_response_value;
    wire [ROB_TAG_WIDTH-1:0] unit_response_rob_tag;

    assign response_valid_o = !recover_i && unit_response_valid;
    assign response_value_o = (!recover_i && unit_response_valid) ?
        unit_response_value : 32'd0;
    assign response_rob_tag_o = (!recover_i && unit_response_valid) ?
        unit_response_rob_tag : {ROB_TAG_WIDTH{1'b0}};

    rv32_mdu_reservation_station_core #(
        .RS_ENTRIES(DIV_RS_ENTRIES),
        .RS_INDEX_WIDTH(DIV_RS_INDEX_WIDTH),
        .BE_WIDTH(BE_WIDTH),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES),
        .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH),
        .OP_CLASS(1)
    ) reservation_station (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .recover_i(recover_i),
        .dispatch_valid_i(dispatch_valid_i),
        .dispatch_fire_i(dispatch_fire_i),
        .dispatch_op_i(dispatch_op_i),
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
        .request_valid_o(request_valid),
        .request_ready_i(request_ready),
        .request_op_o(request_op),
        .request_lhs_o(request_lhs),
        .request_rhs_o(request_rhs),
        .request_rob_tag_o(request_rob_tag)
    );

    rv32m_divider #(
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) divider (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .request_valid_i(request_valid),
        .request_ready_o(request_ready),
        .request_op_i(request_op),
        .request_lhs_i(request_lhs),
        .request_rhs_i(request_rhs),
        .request_rob_tag_i(request_rob_tag),
        .response_valid_o(unit_response_valid),
        .response_ready_i(response_ready_i && !recover_i),
        .response_value_o(unit_response_value),
        .response_rob_tag_o(unit_response_rob_tag)
    );

endmodule

/* verilator lint_on DECLFILENAME */
