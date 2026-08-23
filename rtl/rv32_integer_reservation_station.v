`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_integer_reservation_station #(
    parameter INT_RS_ENTRIES = 8,
    parameter INT_RS_INDEX_WIDTH = 3,
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
    input  wire [(BE_WIDTH*32)-1:0]                         dispatch_pc_i,
    input  wire [(BE_WIDTH*32)-1:0]                         dispatch_immediate_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              dispatch_rob_tag_i,
    input  wire [BE_WIDTH-1:0]                              dispatch_lhs_ready_i,
    input  wire [(BE_WIDTH*32)-1:0]                         dispatch_lhs_value_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        dispatch_lhs_phys_i,
    input  wire [BE_WIDTH-1:0]                              dispatch_rhs_ready_i,
    input  wire [(BE_WIDTH*32)-1:0]                         dispatch_rhs_value_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        dispatch_rhs_phys_i,
    output wire                                             dispatch_ready_o,
    output wire [INT_RS_INDEX_WIDTH:0]                      occupancy_o,

    input  wire [BE_WIDTH-1:0]                              broadcast_valid_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        broadcast_phys_i,
    input  wire [(BE_WIDTH*32)-1:0]                         broadcast_value_i,

    input  wire [ROB_INDEX_WIDTH-1:0]                       rob_head_index_i,
    input  wire [BE_WIDTH-1:0]                              rollback_valid_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              rollback_tag_i,

    output wire [BE_WIDTH-1:0]                              issue_valid_o,
    input  wire [BE_WIDTH-1:0]                              issue_ready_i,
    output wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0]             issue_op_o,
    output wire [(BE_WIDTH*32)-1:0]                         issue_lhs_o,
    output wire [(BE_WIDTH*32)-1:0]                         issue_rhs_o,
    output wire [(BE_WIDTH*32)-1:0]                         issue_pc_o,
    output wire [(BE_WIDTH*32)-1:0]                         issue_immediate_o,
    output wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              issue_rob_tag_o
);

    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */

    reg entry_busy [0:INT_RS_ENTRIES-1];
    reg [`RV32_OP_WIDTH-1:0] entry_op [0:INT_RS_ENTRIES-1];
    reg [31:0] entry_pc [0:INT_RS_ENTRIES-1];
    reg [31:0] entry_immediate [0:INT_RS_ENTRIES-1];
    reg [ROB_TAG_WIDTH-1:0] entry_rob_tag [0:INT_RS_ENTRIES-1];
    reg entry_lhs_ready [0:INT_RS_ENTRIES-1];
    reg [31:0] entry_lhs_value [0:INT_RS_ENTRIES-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0]
        entry_lhs_phys [0:INT_RS_ENTRIES-1];
    reg entry_rhs_ready [0:INT_RS_ENTRIES-1];
    reg [31:0] entry_rhs_value [0:INT_RS_ENTRIES-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0]
        entry_rhs_phys [0:INT_RS_ENTRIES-1];

    reg issue_locked [0:BE_WIDTH-1];
    reg [INT_RS_INDEX_WIDTH-1:0] issue_locked_slot [0:BE_WIDTH-1];
    reg [INT_RS_INDEX_WIDTH:0] occupancy_reg;

    reg effective_lhs_ready [0:INT_RS_ENTRIES-1];
    reg [31:0] effective_lhs_value [0:INT_RS_ENTRIES-1];
    reg effective_rhs_ready [0:INT_RS_ENTRIES-1];
    reg [31:0] effective_rhs_value [0:INT_RS_ENTRIES-1];

    reg dispatch_lhs_captured_ready [0:BE_WIDTH-1];
    reg [31:0] dispatch_lhs_captured_value [0:BE_WIDTH-1];
    reg dispatch_rhs_captured_ready [0:BE_WIDTH-1];
    reg [31:0] dispatch_rhs_captured_value [0:BE_WIDTH-1];

    reg [BE_WIDTH-1:0] issue_valid_reg;
    reg [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] issue_op_reg;
    reg [(BE_WIDTH*32)-1:0] issue_lhs_reg;
    reg [(BE_WIDTH*32)-1:0] issue_rhs_reg;
    reg [(BE_WIDTH*32)-1:0] issue_pc_reg;
    reg [(BE_WIDTH*32)-1:0] issue_immediate_reg;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] issue_rob_tag_reg;
    reg [BE_WIDTH-1:0] issue_fire_reg;
    reg issue_slot_valid_reg [0:BE_WIDTH-1];
    reg [INT_RS_INDEX_WIDTH-1:0] issue_slot_reg [0:BE_WIDTH-1];
    reg [INT_RS_ENTRIES-1:0] issue_reserved_mask_reg;
    reg [INT_RS_ENTRIES-1:0] issue_remove_mask_reg;

    reg dispatch_ready_reg;
    reg allocation_slot_valid_reg [0:BE_WIDTH-1];
    reg [INT_RS_INDEX_WIDTH-1:0]
        allocation_slot_reg [0:BE_WIDTH-1];
    reg entry_allocate_valid_reg [0:INT_RS_ENTRIES-1];
    reg [INT_RS_ENTRIES-1:0] available_slot_mask_reg;
    reg [INT_RS_ENTRIES-1:0] allocated_slot_mask_reg;

    reg [INT_RS_ENTRIES-1:0] rollback_remove_mask_reg;

    integer effective_entry_index;
    integer effective_broadcast_index;
    integer capture_lane_index;
    integer capture_broadcast_index;
    integer selection_port_index;
    integer selection_entry_index;
    integer selection_locked_index;
    integer selection_winner_slot;
    integer selection_winner_distance;
    integer selection_candidate_distance;
    integer issue_count;
    integer dispatch_lane_index;
    integer allocation_entry_index;
    integer allocation_winner_slot;
    integer dispatch_count;
    integer available_count;
    integer rollback_entry_index;
    integer rollback_lane_index;
    integer rollback_remove_count;
    integer sequential_entry_index;
    integer sequential_dispatch_lane_index;
    integer sequential_port_index;
    integer assertion_entry_index;
    integer assertion_lane_index;
    integer assertion_other_lane_index;
    integer assertion_port_index;
    integer assertion_other_port_index;
    integer busy_count;

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

    function supported_integer_op;
        input [`RV32_OP_WIDTH-1:0] op_value;
        begin
            case (op_value)
                `RV32_OP_LUI,
                `RV32_OP_AUIPC,
                `RV32_OP_JAL,
                `RV32_OP_JALR,
                `RV32_OP_BEQ,
                `RV32_OP_BNE,
                `RV32_OP_BLT,
                `RV32_OP_BGE,
                `RV32_OP_BLTU,
                `RV32_OP_BGEU,
                `RV32_OP_ADDI,
                `RV32_OP_SLTI,
                `RV32_OP_SLTIU,
                `RV32_OP_XORI,
                `RV32_OP_ORI,
                `RV32_OP_ANDI,
                `RV32_OP_SLLI,
                `RV32_OP_SRLI,
                `RV32_OP_SRAI,
                `RV32_OP_ADD,
                `RV32_OP_SUB,
                `RV32_OP_SLL,
                `RV32_OP_SLT,
                `RV32_OP_SLTU,
                `RV32_OP_XOR,
                `RV32_OP_SRL,
                `RV32_OP_SRA,
                `RV32_OP_OR,
                `RV32_OP_AND: supported_integer_op = 1'b1;
                default: supported_integer_op = 1'b0;
            endcase
        end
    endfunction

    assign dispatch_ready_o = dispatch_ready_reg;
    assign occupancy_o = (reset_i || flush_i) ?
        {(INT_RS_INDEX_WIDTH+1){1'b0}} : occupancy_reg;
    assign issue_valid_o = issue_valid_reg;
    assign issue_op_o = issue_op_reg;
    assign issue_lhs_o = issue_lhs_reg;
    assign issue_rhs_o = issue_rhs_reg;
    assign issue_pc_o = issue_pc_reg;
    assign issue_immediate_o = issue_immediate_reg;
    assign issue_rob_tag_o = issue_rob_tag_reg;

    initial begin
        if ((BE_WIDTH != 1) && (BE_WIDTH != 2) && (BE_WIDTH != 4)) begin
            $display("ERROR rv32_integer_reservation_station invalid BE_WIDTH=%0d",
                BE_WIDTH);
            $finish(1);
        end
        if ((INT_RS_ENTRIES < BE_WIDTH) || (INT_RS_ENTRIES < 2)) begin
            $display("ERROR rv32_integer_reservation_station invalid INT_RS_ENTRIES=%0d",
                INT_RS_ENTRIES);
            $finish(1);
        end
        if ((INT_RS_ENTRIES & (INT_RS_ENTRIES - 1)) != 0) begin
            $display("ERROR rv32_integer_reservation_station INT_RS_ENTRIES not power of two=%0d",
                INT_RS_ENTRIES);
            $finish(1);
        end
        if (INT_RS_INDEX_WIDTH != address_width_for_count(INT_RS_ENTRIES)) begin
            $display("ERROR rv32_integer_reservation_station index width=%0d expected=%0d",
                INT_RS_INDEX_WIDTH,
                address_width_for_count(INT_RS_ENTRIES));
            $finish(1);
        end
        if ((ROB_ENTRIES < BE_WIDTH) || (ROB_ENTRIES < 2) ||
                ((ROB_ENTRIES & (ROB_ENTRIES - 1)) != 0)) begin
            $display("ERROR rv32_integer_reservation_station invalid ROB_ENTRIES=%0d",
                ROB_ENTRIES);
            $finish(1);
        end
        if (ROB_INDEX_WIDTH != address_width_for_count(ROB_ENTRIES)) begin
            $display("ERROR rv32_integer_reservation_station ROB index width=%0d expected=%0d",
                ROB_INDEX_WIDTH, address_width_for_count(ROB_ENTRIES));
            $finish(1);
        end
        if (ROB_TAG_WIDTH <= ROB_INDEX_WIDTH) begin
            $display("ERROR rv32_integer_reservation_station invalid ROB_TAG_WIDTH=%0d",
                ROB_TAG_WIDTH);
            $finish(1);
        end
        if (PHYS_REGS < 33) begin
            $display("ERROR rv32_integer_reservation_station PHYS_REGS=%0d is below 33",
                PHYS_REGS);
            $finish(1);
        end
        if (PHYS_REG_ADDR_WIDTH != address_width_for_count(PHYS_REGS)) begin
            $display("ERROR rv32_integer_reservation_station physical address width=%0d expected=%0d",
                PHYS_REG_ADDR_WIDTH, address_width_for_count(PHYS_REGS));
            $finish(1);
        end
    end

    always @* begin
        effective_entry_index = 0;
        effective_broadcast_index = 0;
        for (effective_entry_index = 0;
                effective_entry_index < INT_RS_ENTRIES;
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
                        dispatch_lhs_captured_ready[capture_lane_index] = 1'b1;
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
                        dispatch_rhs_captured_ready[capture_lane_index] = 1'b1;
                        dispatch_rhs_captured_value[capture_lane_index] =
                            broadcast_value_i[
                                capture_broadcast_index*32 +: 32];
                    end
                end
            end
        end
    end

    always @* begin
        selection_port_index = 0;
        selection_entry_index = 0;
        selection_locked_index = 0;
        issue_valid_reg = {BE_WIDTH{1'b0}};
        issue_op_reg = {(BE_WIDTH*`RV32_OP_WIDTH){1'b0}};
        issue_lhs_reg = {(BE_WIDTH*32){1'b0}};
        issue_rhs_reg = {(BE_WIDTH*32){1'b0}};
        issue_pc_reg = {(BE_WIDTH*32){1'b0}};
        issue_immediate_reg = {(BE_WIDTH*32){1'b0}};
        issue_rob_tag_reg = {(BE_WIDTH*ROB_TAG_WIDTH){1'b0}};
        issue_fire_reg = {BE_WIDTH{1'b0}};
        issue_reserved_mask_reg = {INT_RS_ENTRIES{1'b0}};
        issue_remove_mask_reg = {INT_RS_ENTRIES{1'b0}};
        issue_count = 0;
        selection_winner_slot = 0;
        selection_winner_distance = ROB_ENTRIES;
        selection_candidate_distance = ROB_ENTRIES;

        for (selection_port_index = 0;
                selection_port_index < BE_WIDTH;
                selection_port_index = selection_port_index + 1) begin
            issue_slot_valid_reg[selection_port_index] = 1'b0;
            issue_slot_reg[selection_port_index] =
                {INT_RS_INDEX_WIDTH{1'b0}};
        end

        if (!reset_i && !flush_i && !recover_i) begin
            for (selection_locked_index = 0;
                    selection_locked_index < BE_WIDTH;
                    selection_locked_index = selection_locked_index + 1) begin
                if (issue_locked[selection_locked_index]) begin
                    issue_slot_valid_reg[selection_locked_index] = 1'b1;
                    issue_slot_reg[selection_locked_index] =
                        issue_locked_slot[selection_locked_index];
                    issue_reserved_mask_reg[
                        issue_locked_slot[selection_locked_index]] = 1'b1;
                end
            end

            for (selection_port_index = 0;
                    selection_port_index < BE_WIDTH;
                    selection_port_index = selection_port_index + 1) begin
                if (!issue_locked[selection_port_index]) begin
                    selection_winner_slot = 0;
                    selection_winner_distance = ROB_ENTRIES;
                    for (selection_entry_index = 0;
                            selection_entry_index < INT_RS_ENTRIES;
                            selection_entry_index =
                                selection_entry_index + 1) begin
                        selection_candidate_distance = rob_distance(
                            entry_rob_tag[selection_entry_index][
                                ROB_INDEX_WIDTH-1:0],
                            rob_head_index_i);
                        if (entry_busy[selection_entry_index] &&
                                effective_lhs_ready[selection_entry_index] &&
                                effective_rhs_ready[selection_entry_index] &&
                                !issue_reserved_mask_reg[
                                    selection_entry_index] &&
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
                        issue_slot_valid_reg[selection_port_index] = 1'b1;
                        issue_slot_reg[selection_port_index] =
                            selection_winner_slot[
                                INT_RS_INDEX_WIDTH-1:0];
                        issue_reserved_mask_reg[
                            selection_winner_slot] = 1'b1;
                    end
                end

                if (issue_slot_valid_reg[selection_port_index]) begin
                    issue_valid_reg[selection_port_index] = 1'b1;
                    issue_op_reg[
                        selection_port_index*`RV32_OP_WIDTH +:
                        `RV32_OP_WIDTH] =
                        entry_op[issue_slot_reg[selection_port_index]];
                    issue_lhs_reg[selection_port_index*32 +: 32] =
                        effective_lhs_value[
                            issue_slot_reg[selection_port_index]];
                    issue_rhs_reg[selection_port_index*32 +: 32] =
                        effective_rhs_value[
                            issue_slot_reg[selection_port_index]];
                    issue_pc_reg[selection_port_index*32 +: 32] =
                        entry_pc[issue_slot_reg[selection_port_index]];
                    issue_immediate_reg[
                        selection_port_index*32 +: 32] =
                        entry_immediate[
                            issue_slot_reg[selection_port_index]];
                    issue_rob_tag_reg[
                        selection_port_index*ROB_TAG_WIDTH +:
                        ROB_TAG_WIDTH] =
                        entry_rob_tag[
                            issue_slot_reg[selection_port_index]];
                    issue_fire_reg[selection_port_index] =
                        issue_ready_i[selection_port_index];
                    if (issue_ready_i[selection_port_index]) begin
                        issue_remove_mask_reg[
                            issue_slot_reg[selection_port_index]] = 1'b1;
                        issue_count = issue_count + 1;
                    end
                end
            end
        end
    end

    always @* begin
        dispatch_lane_index = 0;
        allocation_entry_index = 0;
        dispatch_count = 0;
        available_count = 0;
        available_slot_mask_reg = {INT_RS_ENTRIES{1'b0}};
        allocated_slot_mask_reg = {INT_RS_ENTRIES{1'b0}};
        dispatch_ready_reg = 1'b0;
        allocation_winner_slot = INT_RS_ENTRIES;

        for (dispatch_lane_index = 0;
                dispatch_lane_index < BE_WIDTH;
                dispatch_lane_index = dispatch_lane_index + 1) begin
            allocation_slot_valid_reg[dispatch_lane_index] = 1'b0;
            allocation_slot_reg[dispatch_lane_index] =
                {INT_RS_INDEX_WIDTH{1'b0}};
            if (dispatch_valid_i[dispatch_lane_index]) begin
                dispatch_count = dispatch_count + 1;
            end
        end
        for (allocation_entry_index = 0;
                allocation_entry_index < INT_RS_ENTRIES;
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
                    allocation_winner_slot = INT_RS_ENTRIES;
                    for (allocation_entry_index = 0;
                            allocation_entry_index < INT_RS_ENTRIES;
                            allocation_entry_index =
                                allocation_entry_index + 1) begin
                        if ((allocation_winner_slot == INT_RS_ENTRIES) &&
                                available_slot_mask_reg[
                                    allocation_entry_index] &&
                                !allocated_slot_mask_reg[
                                    allocation_entry_index]) begin
                            allocation_winner_slot = allocation_entry_index;
                        end
                    end
                    allocation_slot_valid_reg[dispatch_lane_index] = 1'b1;
                    allocation_slot_reg[dispatch_lane_index] =
                        allocation_winner_slot[
                            INT_RS_INDEX_WIDTH-1:0];
                    allocated_slot_mask_reg[allocation_winner_slot] = 1'b1;
                    entry_allocate_valid_reg[allocation_winner_slot] = 1'b1;
                end
            end
        end
    end

    always @* begin
        rollback_entry_index = 0;
        rollback_lane_index = 0;
        rollback_remove_mask_reg = {INT_RS_ENTRIES{1'b0}};
        rollback_remove_count = 0;
        if (!reset_i && !flush_i && recover_i) begin
            for (rollback_entry_index = 0;
                    rollback_entry_index < INT_RS_ENTRIES;
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
                        rollback_remove_mask_reg[
                            rollback_entry_index] = 1'b1;
                    end
                end
                if (rollback_remove_mask_reg[rollback_entry_index]) begin
                    rollback_remove_count = rollback_remove_count + 1;
                end
            end
        end
    end

    always @* begin
        busy_count = 0;
        for (assertion_entry_index = 0;
                assertion_entry_index < INT_RS_ENTRIES;
                assertion_entry_index = assertion_entry_index + 1) begin
            if (entry_busy[assertion_entry_index]) begin
                busy_count = busy_count + 1;
            end
        end
    end

    always @(posedge clk_i) begin
        if (reset_i) begin
            occupancy_reg <= {(INT_RS_INDEX_WIDTH+1){1'b0}};
            for (sequential_entry_index = 0;
                    sequential_entry_index < INT_RS_ENTRIES;
                    sequential_entry_index = sequential_entry_index + 1) begin
                entry_busy[sequential_entry_index] <= 1'b0;
                entry_op[sequential_entry_index] <= `RV32_OP_INVALID;
                entry_pc[sequential_entry_index] <= 32'd0;
                entry_immediate[sequential_entry_index] <= 32'd0;
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
            for (sequential_port_index = 0;
                    sequential_port_index < BE_WIDTH;
                    sequential_port_index = sequential_port_index + 1) begin
                issue_locked[sequential_port_index] <= 1'b0;
                issue_locked_slot[sequential_port_index] <=
                    {INT_RS_INDEX_WIDTH{1'b0}};
            end
        end else if (flush_i) begin
            occupancy_reg <= {(INT_RS_INDEX_WIDTH+1){1'b0}};
            for (sequential_entry_index = 0;
                    sequential_entry_index < INT_RS_ENTRIES;
                    sequential_entry_index = sequential_entry_index + 1) begin
                entry_busy[sequential_entry_index] <= 1'b0;
                entry_op[sequential_entry_index] <= `RV32_OP_INVALID;
                entry_pc[sequential_entry_index] <= 32'd0;
                entry_immediate[sequential_entry_index] <= 32'd0;
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
            for (sequential_port_index = 0;
                    sequential_port_index < BE_WIDTH;
                    sequential_port_index = sequential_port_index + 1) begin
                issue_locked[sequential_port_index] <= 1'b0;
                issue_locked_slot[sequential_port_index] <=
                    {INT_RS_INDEX_WIDTH{1'b0}};
            end
        end else if (recover_i) begin
            occupancy_reg <= occupancy_reg - rollback_remove_count;
            for (sequential_entry_index = 0;
                    sequential_entry_index < INT_RS_ENTRIES;
                    sequential_entry_index = sequential_entry_index + 1) begin
                if (rollback_remove_mask_reg[sequential_entry_index]) begin
                    entry_busy[sequential_entry_index] <= 1'b0;
                    entry_op[sequential_entry_index] <= `RV32_OP_INVALID;
                    entry_pc[sequential_entry_index] <= 32'd0;
                    entry_immediate[sequential_entry_index] <= 32'd0;
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
            for (sequential_port_index = 0;
                    sequential_port_index < BE_WIDTH;
                    sequential_port_index = sequential_port_index + 1) begin
                if (issue_locked[sequential_port_index] &&
                        rollback_remove_mask_reg[
                            issue_locked_slot[sequential_port_index]]) begin
                    issue_locked[sequential_port_index] <= 1'b0;
                    issue_locked_slot[sequential_port_index] <=
                        {INT_RS_INDEX_WIDTH{1'b0}};
                end
            end
        end else begin
            occupancy_reg <= occupancy_reg - issue_count +
                ((dispatch_fire_i && dispatch_ready_reg) ?
                    dispatch_count : 0);

            for (sequential_port_index = 0;
                    sequential_port_index < BE_WIDTH;
                    sequential_port_index = sequential_port_index + 1) begin
                if (issue_locked[sequential_port_index]) begin
                    if (issue_fire_reg[sequential_port_index]) begin
                        issue_locked[sequential_port_index] <= 1'b0;
                        issue_locked_slot[sequential_port_index] <=
                            {INT_RS_INDEX_WIDTH{1'b0}};
                    end
                end else if (issue_valid_reg[sequential_port_index] &&
                        !issue_ready_i[sequential_port_index]) begin
                    issue_locked[sequential_port_index] <= 1'b1;
                    issue_locked_slot[sequential_port_index] <=
                        issue_slot_reg[sequential_port_index];
                end
            end

            for (sequential_entry_index = 0;
                    sequential_entry_index < INT_RS_ENTRIES;
                    sequential_entry_index = sequential_entry_index + 1) begin
                if (entry_allocate_valid_reg[sequential_entry_index] &&
                        dispatch_fire_i && dispatch_ready_reg) begin
                    for (sequential_dispatch_lane_index = 0;
                            sequential_dispatch_lane_index < BE_WIDTH;
                            sequential_dispatch_lane_index =
                                sequential_dispatch_lane_index + 1) begin
                        if (allocation_slot_valid_reg[
                                sequential_dispatch_lane_index] &&
                                (allocation_slot_reg[
                                    sequential_dispatch_lane_index] ==
                                sequential_entry_index)) begin
                            entry_busy[sequential_entry_index] <= 1'b1;
                            entry_op[sequential_entry_index] <=
                                dispatch_op_i[
                                    sequential_dispatch_lane_index*
                                        `RV32_OP_WIDTH +:
                                    `RV32_OP_WIDTH];
                            entry_pc[sequential_entry_index] <=
                                dispatch_pc_i[
                                    sequential_dispatch_lane_index*32 +: 32];
                            entry_immediate[sequential_entry_index] <=
                                dispatch_immediate_i[
                                    sequential_dispatch_lane_index*32 +: 32];
                            entry_rob_tag[sequential_entry_index] <=
                                dispatch_rob_tag_i[
                                    sequential_dispatch_lane_index*
                                        ROB_TAG_WIDTH +:
                                    ROB_TAG_WIDTH];
                            entry_lhs_ready[sequential_entry_index] <=
                                dispatch_lhs_captured_ready[
                                    sequential_dispatch_lane_index];
                            entry_lhs_value[sequential_entry_index] <=
                                dispatch_lhs_captured_value[
                                    sequential_dispatch_lane_index];
                            entry_lhs_phys[sequential_entry_index] <=
                                dispatch_lhs_phys_i[
                                    sequential_dispatch_lane_index*
                                        PHYS_REG_ADDR_WIDTH +:
                                    PHYS_REG_ADDR_WIDTH];
                            entry_rhs_ready[sequential_entry_index] <=
                                dispatch_rhs_captured_ready[
                                    sequential_dispatch_lane_index];
                            entry_rhs_value[sequential_entry_index] <=
                                dispatch_rhs_captured_value[
                                    sequential_dispatch_lane_index];
                            entry_rhs_phys[sequential_entry_index] <=
                                dispatch_rhs_phys_i[
                                    sequential_dispatch_lane_index*
                                        PHYS_REG_ADDR_WIDTH +:
                                    PHYS_REG_ADDR_WIDTH];
                        end
                    end
                end else if (issue_remove_mask_reg[
                        sequential_entry_index]) begin
                    entry_busy[sequential_entry_index] <= 1'b0;
                    entry_op[sequential_entry_index] <= `RV32_OP_INVALID;
                    entry_pc[sequential_entry_index] <= 32'd0;
                    entry_immediate[sequential_entry_index] <= 32'd0;
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
                    if (!entry_lhs_ready[sequential_entry_index] &&
                            effective_lhs_ready[sequential_entry_index]) begin
                        entry_lhs_ready[sequential_entry_index] <= 1'b1;
                        entry_lhs_value[sequential_entry_index] <=
                            effective_lhs_value[sequential_entry_index];
                    end
                    if (!entry_rhs_ready[sequential_entry_index] &&
                            effective_rhs_ready[sequential_entry_index]) begin
                        entry_rhs_ready[sequential_entry_index] <= 1'b1;
                        entry_rhs_value[sequential_entry_index] <=
                            effective_rhs_value[sequential_entry_index];
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (!reset_i) begin
            if (occupancy_reg > INT_RS_ENTRIES) begin
                $display("ERROR rv32_integer_reservation_station occupancy overflow=%0d",
                    occupancy_reg);
                $finish(1);
            end
            if (occupancy_reg != busy_count) begin
                $display("ERROR rv32_integer_reservation_station occupancy mismatch=%0d busy=%0d",
                    occupancy_reg, busy_count);
                $finish(1);
            end
            if (!flush_i && !recover_i && dispatch_fire_i &&
                    !dispatch_ready_reg && (dispatch_count != 0)) begin
                $display("ERROR rv32_integer_reservation_station dispatch fired without capacity");
                $finish(1);
            end
            if (recover_i && (rollback_remove_count > occupancy_reg)) begin
                $display("ERROR rv32_integer_reservation_station rollback underflow");
                $finish(1);
            end
            if (!flush_i && !recover_i && (issue_count > occupancy_reg)) begin
                $display("ERROR rv32_integer_reservation_station issue underflow");
                $finish(1);
            end

            for (assertion_lane_index = 0;
                    assertion_lane_index < BE_WIDTH;
                    assertion_lane_index = assertion_lane_index + 1) begin
                if (broadcast_valid_i[assertion_lane_index] &&
                        ((broadcast_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] ==
                            {PHYS_REG_ADDR_WIDTH{1'b0}}) ||
                         (broadcast_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] >= PHYS_REGS))) begin
                    $display("ERROR rv32_integer_reservation_station invalid broadcast physical register");
                    $finish(1);
                end
                for (assertion_other_lane_index = assertion_lane_index + 1;
                        assertion_other_lane_index < BE_WIDTH;
                        assertion_other_lane_index =
                            assertion_other_lane_index + 1) begin
                    if (broadcast_valid_i[assertion_lane_index] &&
                            broadcast_valid_i[assertion_other_lane_index] &&
                            (broadcast_phys_i[
                                assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                             broadcast_phys_i[
                                assertion_other_lane_index*
                                    PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH])) begin
                        $display("ERROR rv32_integer_reservation_station duplicate broadcast physical register");
                        $finish(1);
                    end
                end

                if (!flush_i && !recover_i && dispatch_fire_i &&
                        dispatch_ready_reg &&
                        dispatch_valid_i[assertion_lane_index]) begin
                    if (!supported_integer_op(dispatch_op_i[
                            assertion_lane_index*`RV32_OP_WIDTH +:
                            `RV32_OP_WIDTH])) begin
                        $display("ERROR rv32_integer_reservation_station unsupported dispatch op");
                        $finish(1);
                    end
                    if ((dispatch_lhs_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] >= PHYS_REGS) ||
                            (dispatch_rhs_phys_i[
                                assertion_lane_index*
                                    PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] >= PHYS_REGS)) begin
                        $display("ERROR rv32_integer_reservation_station invalid dispatch physical register");
                        $finish(1);
                    end
                    if ((!dispatch_lhs_ready_i[assertion_lane_index] &&
                            (dispatch_lhs_phys_i[
                                assertion_lane_index*
                                    PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                                {PHYS_REG_ADDR_WIDTH{1'b0}})) ||
                            (!dispatch_rhs_ready_i[assertion_lane_index] &&
                            (dispatch_rhs_phys_i[
                                assertion_lane_index*
                                    PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                                {PHYS_REG_ADDR_WIDTH{1'b0}}))) begin
                        $display("ERROR rv32_integer_reservation_station p0 operand not ready");
                        $finish(1);
                    end
                end
            end

            if (!flush_i && !recover_i) begin
                for (assertion_port_index = 0;
                        assertion_port_index < BE_WIDTH;
                        assertion_port_index = assertion_port_index + 1) begin
                    if (issue_locked[assertion_port_index] &&
                            (!entry_busy[
                                issue_locked_slot[assertion_port_index]] ||
                             !effective_lhs_ready[
                                issue_locked_slot[assertion_port_index]] ||
                             !effective_rhs_ready[
                                issue_locked_slot[assertion_port_index]])) begin
                        $display("ERROR rv32_integer_reservation_station invalid locked issue slot");
                        $finish(1);
                    end
                    for (assertion_other_port_index =
                            assertion_port_index + 1;
                            assertion_other_port_index < BE_WIDTH;
                            assertion_other_port_index =
                                assertion_other_port_index + 1) begin
                        if (issue_slot_valid_reg[assertion_port_index] &&
                                issue_slot_valid_reg[
                                    assertion_other_port_index] &&
                                (issue_slot_reg[assertion_port_index] ==
                                 issue_slot_reg[
                                    assertion_other_port_index])) begin
                            $display("ERROR rv32_integer_reservation_station duplicate issue selection");
                            $finish(1);
                        end
                    end
                end
            end
        end
    end
`endif

endmodule
