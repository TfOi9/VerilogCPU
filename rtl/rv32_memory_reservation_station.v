`timescale 1ns/1ps

module rv32_memory_reservation_station #(
    parameter IS_STORE = 0,
    parameter RS_ENTRIES = 8,
    parameter RS_INDEX_WIDTH = 3,
    parameter BE_WIDTH = 1,
    parameter RECOVERY_WIDTH = BE_WIDTH,
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
    input  wire [RECOVERY_WIDTH-1:0] rollback_valid_i,
    input  wire [(RECOVERY_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_tag_i,
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

    end

    localparam PAYLOAD_WIDTH = RS_INDEX_WIDTH + ROB_TAG_WIDTH + LSQ_TAG_WIDTH + 32;
    wire select_enable = !reset_i && !flush_i && !recover_i;
    wire [RS_ENTRIES-1:0] address_eligible;
    wire [RS_ENTRIES-1:0] data_eligible;
    wire [RS_ENTRIES-1:0] address_selected;
    wire [RS_ENTRIES-1:0] data_selected;
    wire [ROB_INDEX_WIDTH-1:0] age [0:RS_ENTRIES-1];
    wire [PAYLOAD_WIDTH-1:0] address_tree [1:2*RS_ENTRIES-1];
    wire [PAYLOAD_WIDTH-1:0] data_tree [1:2*RS_ENTRIES-1];
    wire keep_address = address_locked && address_eligible[address_locked_slot];
    wire keep_data = data_locked && data_eligible[data_locked_slot];
    genvar entry_index, older_index, node_index;
    generate
        for (entry_index = 0; entry_index < RS_ENTRIES;
                entry_index = entry_index + 1) begin: select_entry
            localparam [RS_INDEX_WIDTH-1:0] SLOT = entry_index;
            wire [RS_ENTRIES-1:0] older_address;
            wire [RS_ENTRIES-1:0] older_data;
            wire [31:0] entry_address;
            assign age[entry_index] =
                rob_tag[entry_index][ROB_INDEX_WIDTH-1:0] - rob_head_index_i;
            assign address_eligible[entry_index] = busy[entry_index] &&
                !address_sent[entry_index] && effective_base_ready[entry_index];
            assign data_eligible[entry_index] = IS_STORE != 0 && busy[entry_index] &&
                !data_sent[entry_index] && effective_data_ready[entry_index];
            for (older_index = 0; older_index < RS_ENTRIES;
                    older_index = older_index + 1) begin: compare_age
                wire precedes;
                assign precedes = age[older_index] < age[entry_index] ||
                    (age[older_index] == age[entry_index] && older_index < entry_index);
                assign older_address[older_index] =
                    address_eligible[older_index] && precedes;
                assign older_data[older_index] = data_eligible[older_index] && precedes;
            end
            assign address_selected[entry_index] = select_enable &&
                address_eligible[entry_index] && (keep_address ?
                    address_locked_slot == SLOT : !(|older_address));
            assign data_selected[entry_index] = select_enable &&
                data_eligible[entry_index] && (keep_data ?
                    data_locked_slot == SLOT : !(|older_data));
            // Compute addresses in parallel with wakeup and age selection.
            assign entry_address = effective_base_value[entry_index] + immediate[entry_index];
            assign address_tree[RS_ENTRIES+entry_index] =
                {PAYLOAD_WIDTH{address_selected[entry_index]}} &
                {SLOT, rob_tag[entry_index], lsq_tag[entry_index], entry_address};
            assign data_tree[RS_ENTRIES+entry_index] =
                {PAYLOAD_WIDTH{data_selected[entry_index]}} &
                {SLOT, rob_tag[entry_index], lsq_tag[entry_index], effective_data_value[entry_index]};
        end
        for (node_index = 1; node_index < RS_ENTRIES;
                node_index = node_index + 1) begin: select_tree
            assign address_tree[node_index] = address_tree[2*node_index] |
                address_tree[2*node_index+1];
            assign data_tree[node_index] = data_tree[2*node_index] | data_tree[2*node_index+1];
        end
    endgenerate

    always @* begin
        address_valid_o = |address_selected;
        {address_slot, address_rob_tag_o, address_lsq_tag_o, address_o} = address_tree[1];
        data_valid_o = |data_selected;
        {data_slot, data_rob_tag_o, data_lsq_tag_o, data_o} = data_tree[1];
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
                for (sequential_lane = 0; sequential_lane < RECOVERY_WIDTH;
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
