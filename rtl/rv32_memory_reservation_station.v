`timescale 1ns/1ps

module rv32_memory_reservation_station #(
    parameter IS_STORE = 0,
    parameter RS_ENTRIES = 8,
    parameter RS_INDEX_WIDTH = 3,
    parameter BE_WIDTH = 1,
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter ROB_ENTRIES = 32,
    parameter ROB_INDEX_WIDTH = 5,
    parameter ROB_TAG_WIDTH = 7,
    parameter LSQ_TAG_WIDTH = 5
) (
    input  wire clk_i,
    input  wire reset_i,
    input  wire flush_i,
    input  wire recover_i,
    input  wire [BE_WIDTH-1:0] dispatch_valid_i,
    input  wire dispatch_fire_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] dispatch_rob_tag_i,
    input  wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] dispatch_lsq_tag_i,
    input  wire [(BE_WIDTH*32)-1:0] dispatch_immediate_i,
    input  wire [BE_WIDTH-1:0] dispatch_base_ready_i,
    input  wire [(BE_WIDTH*32)-1:0] dispatch_base_value_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] dispatch_base_phys_i,
    input  wire [BE_WIDTH-1:0] dispatch_data_ready_i,
    input  wire [(BE_WIDTH*32)-1:0] dispatch_data_value_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] dispatch_data_phys_i,
    output reg dispatch_ready_o,
    output reg [RS_INDEX_WIDTH:0] occupancy_o,
    input  wire [BE_WIDTH-1:0] broadcast_valid_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] broadcast_phys_i,
    input  wire [(BE_WIDTH*32)-1:0] broadcast_value_i,
    input  wire [ROB_INDEX_WIDTH-1:0] rob_head_index_i,
    input  wire [BE_WIDTH-1:0] rollback_valid_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_tag_i,
    output reg address_valid_o,
    input  wire address_ready_i,
    output reg [31:0] address_o,
    output reg [ROB_TAG_WIDTH-1:0] address_rob_tag_o,
    output reg [LSQ_TAG_WIDTH-1:0] address_lsq_tag_o,
    output reg data_valid_o,
    input  wire data_ready_i,
    output reg [31:0] data_o,
    output reg [ROB_TAG_WIDTH-1:0] data_rob_tag_o,
    output reg [LSQ_TAG_WIDTH-1:0] data_lsq_tag_o
);

    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */
    /* verilator lint_off BLKSEQ */
    /* verilator lint_off UNUSEDSIGNAL */

    reg busy [0:RS_ENTRIES-1];
    reg address_sent [0:RS_ENTRIES-1];
    reg data_sent [0:RS_ENTRIES-1];
    reg [ROB_TAG_WIDTH-1:0] rob_tag [0:RS_ENTRIES-1];
    reg [LSQ_TAG_WIDTH-1:0] lsq_tag [0:RS_ENTRIES-1];
    reg [31:0] immediate [0:RS_ENTRIES-1];
    reg base_ready [0:RS_ENTRIES-1];
    reg [31:0] base_value [0:RS_ENTRIES-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0] base_phys [0:RS_ENTRIES-1];
    reg store_data_ready [0:RS_ENTRIES-1];
    reg [31:0] store_data_value [0:RS_ENTRIES-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0] store_data_phys [0:RS_ENTRIES-1];
    reg address_locked;
    reg [RS_INDEX_WIDTH-1:0] address_locked_slot;
    reg data_locked;
    reg [RS_INDEX_WIDTH-1:0] data_locked_slot;
    reg effective_base_ready [0:RS_ENTRIES-1];
    reg [31:0] effective_base_value [0:RS_ENTRIES-1];
    reg effective_data_ready [0:RS_ENTRIES-1];
    reg [31:0] effective_data_value [0:RS_ENTRIES-1];
    reg captured_base_ready [0:BE_WIDTH-1];
    reg [31:0] captured_base_value [0:BE_WIDTH-1];
    reg captured_data_ready [0:BE_WIDTH-1];
    reg [31:0] captured_data_value [0:BE_WIDTH-1];
    reg [RS_ENTRIES-1:0] reserved_slots;
    reg [RS_INDEX_WIDTH-1:0] alloc_slot [0:BE_WIDTH-1];
    reg [RS_INDEX_WIDTH-1:0] address_slot;
    reg [RS_INDEX_WIDTH-1:0] data_slot;
    integer i;
    integer j;
    integer best;
    integer best_distance;
    integer candidate_distance;
    integer occupancy_index;
    integer sequential_index;
    integer sequential_lane;
    reg address_handshake;
    reg data_handshake;

    function integer index_width_for_count;
        input integer value;
        integer n;
        begin
            n = value - 1;
            index_width_for_count = 0;
            while (n > 0) begin
                index_width_for_count = index_width_for_count + 1;
                n = n >> 1;
            end
        end
    endfunction

    function integer distance_from_head;
        input [ROB_TAG_WIDTH-1:0] tag_value;
        input [ROB_INDEX_WIDTH-1:0] head_value;
        integer index_value;
        begin
            index_value = tag_value[ROB_INDEX_WIDTH-1:0];
            if (index_value >= head_value)
                distance_from_head = index_value - head_value;
            else
                distance_from_head = index_value + ROB_ENTRIES - head_value;
        end
    endfunction

    initial begin
        if ((IS_STORE != 0 && IS_STORE != 1) ||
                (BE_WIDTH != 1 && BE_WIDTH != 2 && BE_WIDTH != 4) ||
                RS_ENTRIES < BE_WIDTH || RS_ENTRIES < 2 ||
                (RS_ENTRIES & (RS_ENTRIES-1)) != 0 ||
                RS_INDEX_WIDTH != index_width_for_count(RS_ENTRIES) ||
                (ROB_ENTRIES & (ROB_ENTRIES-1)) != 0 ||
                ROB_TAG_WIDTH <= ROB_INDEX_WIDTH ||
                ROB_INDEX_WIDTH != index_width_for_count(ROB_ENTRIES) ||
                PHYS_REGS < 33 || PHYS_REG_ADDR_WIDTH !=
                    index_width_for_count(PHYS_REGS) || LSQ_TAG_WIDTH < 2) begin
            $display("ERROR rv32_memory_reservation_station invalid parameters");
            $finish(1);
        end
    end

    always @* begin
        best = -1;
        best_distance = ROB_ENTRIES;
        candidate_distance = ROB_ENTRIES;
        for (i = 0; i < RS_ENTRIES; i = i + 1) begin
            effective_base_ready[i] = base_ready[i];
            effective_base_value[i] = base_value[i];
            effective_data_ready[i] = store_data_ready[i];
            effective_data_value[i] = store_data_value[i];
            for (j = 0; j < BE_WIDTH; j = j + 1) begin
                if (broadcast_valid_i[j] && !effective_base_ready[i] &&
                        base_phys[i] == broadcast_phys_i[
                            j*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH]) begin
                    effective_base_ready[i] = 1'b1;
                    effective_base_value[i] = broadcast_value_i[j*32 +: 32];
                end
                if (broadcast_valid_i[j] && !effective_data_ready[i] &&
                        store_data_phys[i] == broadcast_phys_i[
                            j*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH]) begin
                    effective_data_ready[i] = 1'b1;
                    effective_data_value[i] = broadcast_value_i[j*32 +: 32];
                end
            end
        end
        for (i = 0; i < BE_WIDTH; i = i + 1) begin
            captured_base_ready[i] = dispatch_base_ready_i[i];
            captured_base_value[i] = dispatch_base_value_i[i*32 +: 32];
            captured_data_ready[i] = dispatch_data_ready_i[i];
            captured_data_value[i] = dispatch_data_value_i[i*32 +: 32];
            for (j = 0; j < BE_WIDTH; j = j + 1) begin
                if (broadcast_valid_i[j] && !captured_base_ready[i] &&
                        dispatch_base_phys_i[
                            i*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] ==
                        broadcast_phys_i[
                            j*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH]) begin
                    captured_base_ready[i] = 1'b1;
                    captured_base_value[i] = broadcast_value_i[j*32 +: 32];
                end
                if (broadcast_valid_i[j] && !captured_data_ready[i] &&
                        dispatch_data_phys_i[
                            i*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] ==
                        broadcast_phys_i[
                            j*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH]) begin
                    captured_data_ready[i] = 1'b1;
                    captured_data_value[i] = broadcast_value_i[j*32 +: 32];
                end
            end
        end

        reserved_slots = 0;
        dispatch_ready_o = !reset_i && !flush_i && !recover_i;
        for (i = 0; i < BE_WIDTH; i = i + 1) begin
            alloc_slot[i] = 0;
            if (dispatch_valid_i[i]) begin
                best = -1;
                for (j = 0; j < RS_ENTRIES; j = j + 1)
                    if (!busy[j] && !reserved_slots[j] && best < 0)
                        best = j;
                if (best < 0) dispatch_ready_o = 1'b0;
                else begin
                    alloc_slot[i] = best;
                    reserved_slots[best] = 1'b1;
                end
            end
        end

        address_valid_o = 1'b0;
        address_o = 0;
        address_rob_tag_o = 0;
        address_lsq_tag_o = 0;
        address_slot = 0;
        data_valid_o = 1'b0;
        data_o = 0;
        data_rob_tag_o = 0;
        data_lsq_tag_o = 0;
        data_slot = 0;
        if (!reset_i && !flush_i && !recover_i) begin
            best = -1;
            best_distance = ROB_ENTRIES;
            if (address_locked && busy[address_locked_slot] &&
                    !address_sent[address_locked_slot] &&
                    effective_base_ready[address_locked_slot]) begin
                best = address_locked_slot;
            end else begin
                for (i = 0; i < RS_ENTRIES; i = i + 1) begin
                    if (busy[i] && !address_sent[i] && effective_base_ready[i]) begin
                        candidate_distance = distance_from_head(
                            rob_tag[i], rob_head_index_i);
                        if (candidate_distance < best_distance) begin
                            best = i;
                            best_distance = candidate_distance;
                        end
                    end
                end
            end
            if (best >= 0) begin
                address_valid_o = 1'b1;
                address_slot = best;
                address_o = effective_base_value[best] + immediate[best];
                address_rob_tag_o = rob_tag[best];
                address_lsq_tag_o = lsq_tag[best];
            end
            if (IS_STORE != 0) begin
                best = -1;
                best_distance = ROB_ENTRIES;
                if (data_locked && busy[data_locked_slot] &&
                        !data_sent[data_locked_slot] &&
                        effective_data_ready[data_locked_slot]) begin
                    best = data_locked_slot;
                end else begin
                    for (i = 0; i < RS_ENTRIES; i = i + 1) begin
                        if (busy[i] && !data_sent[i] &&
                                effective_data_ready[i]) begin
                            candidate_distance = distance_from_head(
                                rob_tag[i], rob_head_index_i);
                            if (candidate_distance < best_distance) begin
                                best = i;
                                best_distance = candidate_distance;
                            end
                        end
                    end
                end
                if (best >= 0) begin
                    data_valid_o = 1'b1;
                    data_slot = best;
                    data_o = effective_data_value[best];
                    data_rob_tag_o = rob_tag[best];
                    data_lsq_tag_o = lsq_tag[best];
                end
            end
        end
    end

    always @* begin
        occupancy_o = 0;
        for (occupancy_index = 0; occupancy_index < RS_ENTRIES;
                occupancy_index = occupancy_index + 1)
            if (busy[occupancy_index]) occupancy_o = occupancy_o + 1'b1;
    end

    always @(posedge clk_i) begin
        if (reset_i || flush_i) begin
            for (sequential_index = 0; sequential_index < RS_ENTRIES;
                    sequential_index = sequential_index + 1) begin
                busy[sequential_index] <= 1'b0;
                address_sent[sequential_index] <= 1'b0;
                data_sent[sequential_index] <= 1'b0;
                rob_tag[sequential_index] <= 0;
                lsq_tag[sequential_index] <= 0;
                immediate[sequential_index] <= 0;
                base_ready[sequential_index] <= 1'b0;
                base_value[sequential_index] <= 0;
                base_phys[sequential_index] <= 0;
                store_data_ready[sequential_index] <= 1'b0;
                store_data_value[sequential_index] <= 0;
                store_data_phys[sequential_index] <= 0;
            end
            address_locked <= 1'b0;
            address_locked_slot <= 0;
            data_locked <= 1'b0;
            data_locked_slot <= 0;
        end else if (recover_i) begin
            address_locked <= 1'b0;
            data_locked <= 1'b0;
            for (sequential_index = 0; sequential_index < RS_ENTRIES;
                    sequential_index = sequential_index + 1) begin
                for (sequential_lane = 0; sequential_lane < BE_WIDTH;
                        sequential_lane = sequential_lane + 1) begin
                    if (rollback_valid_i[sequential_lane] &&
                            busy[sequential_index] &&
                            rob_tag[sequential_index] == rollback_tag_i[
                                sequential_lane*ROB_TAG_WIDTH +: ROB_TAG_WIDTH])
                        busy[sequential_index] <= 1'b0;
                end
            end
        end else begin
            address_locked <= address_valid_o && !address_ready_i;
            if (address_valid_o) address_locked_slot <= address_slot;
            data_locked <= data_valid_o && !data_ready_i;
            if (data_valid_o) data_locked_slot <= data_slot;
            for (sequential_index = 0; sequential_index < RS_ENTRIES;
                    sequential_index = sequential_index + 1) begin
                if (busy[sequential_index]) begin
                    base_ready[sequential_index] <=
                        effective_base_ready[sequential_index];
                    base_value[sequential_index] <=
                        effective_base_value[sequential_index];
                    store_data_ready[sequential_index] <=
                        effective_data_ready[sequential_index];
                    store_data_value[sequential_index] <=
                        effective_data_value[sequential_index];
                    address_handshake = address_valid_o && address_ready_i &&
                        address_slot == sequential_index;
                    data_handshake = data_valid_o && data_ready_i &&
                        data_slot == sequential_index;
                    if (address_handshake) address_sent[sequential_index] <= 1'b1;
                    if (data_handshake) data_sent[sequential_index] <= 1'b1;
                    if ((address_sent[sequential_index] || address_handshake) &&
                            (IS_STORE == 0 || data_sent[sequential_index] ||
                                data_handshake))
                        busy[sequential_index] <= 1'b0;
                end
            end
            if (dispatch_fire_i && dispatch_ready_o) begin
                for (sequential_lane = 0; sequential_lane < BE_WIDTH;
                        sequential_lane = sequential_lane + 1) begin
                    if (dispatch_valid_i[sequential_lane]) begin
                        busy[alloc_slot[sequential_lane]] <= 1'b1;
                        address_sent[alloc_slot[sequential_lane]] <= 1'b0;
                        data_sent[alloc_slot[sequential_lane]] <= 1'b0;
                        rob_tag[alloc_slot[sequential_lane]] <=
                            dispatch_rob_tag_i[
                                sequential_lane*ROB_TAG_WIDTH +: ROB_TAG_WIDTH];
                        lsq_tag[alloc_slot[sequential_lane]] <=
                            dispatch_lsq_tag_i[
                                sequential_lane*LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH];
                        immediate[alloc_slot[sequential_lane]] <=
                            dispatch_immediate_i[sequential_lane*32 +: 32];
                        base_ready[alloc_slot[sequential_lane]] <=
                            captured_base_ready[sequential_lane];
                        base_value[alloc_slot[sequential_lane]] <=
                            captured_base_value[sequential_lane];
                        base_phys[alloc_slot[sequential_lane]] <=
                            dispatch_base_phys_i[
                                sequential_lane*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH];
                        store_data_ready[alloc_slot[sequential_lane]] <=
                            captured_data_ready[sequential_lane];
                        store_data_value[alloc_slot[sequential_lane]] <=
                            captured_data_value[sequential_lane];
                        store_data_phys[alloc_slot[sequential_lane]] <=
                            dispatch_data_phys_i[
                                sequential_lane*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH];
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (!reset_i && dispatch_fire_i && !dispatch_ready_o) begin
            $display("ERROR rv32_memory_reservation_station dispatch without ready");
            $finish(1);
        end
    end
`endif
endmodule
