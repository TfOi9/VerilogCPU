`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_load_store_queue #(
    parameter LSQ_ENTRIES = 8,
    parameter LSQ_INDEX_WIDTH = 3,
    parameter LSQ_GENERATION_WIDTH = 2,
    parameter LSQ_TAG_WIDTH = 5,
    parameter BE_WIDTH = 1,
    parameter RECOVERY_WIDTH = BE_WIDTH,
    parameter ROB_ENTRIES = 32,
    parameter ROB_INDEX_WIDTH = 5,
    parameter ROB_TAG_WIDTH = 7,
    parameter MEMORY_BYTES = 268435456,
    parameter MAX_INFLIGHT = 4,
    parameter TAGGED_RESPONSES = 0,
    parameter ECHO_ROB_TAG = 0,
    parameter FAST_RETURN = ECHO_ROB_TAG && TAGGED_RESPONSES,
    parameter POSTED_STORES = 0,
    parameter LATE_STORE_CONFIRM = 0,
    parameter LOAD_VALUE_ENTRIES = 0,
    parameter LOAD_FALLTHROUGH = 0
) (
    input  wire clk_i,
    input  wire reset_i,
    input  wire flush_i,
    input  wire recover_i,
    input  wire [BE_WIDTH-1:0] alloc_valid_i,
    input  wire alloc_fire_i,
    input  wire [BE_WIDTH-1:0] alloc_store_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] alloc_rob_tag_i,
    input  wire [(BE_WIDTH*`RV32_MEMORY_WIDTH)-1:0] alloc_width_i,
    input  wire [BE_WIDTH-1:0] alloc_unsigned_i,
    output reg alloc_ready_o,
    output reg [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] alloc_lsq_tag_o,
    output reg [LSQ_INDEX_WIDTH:0] occupancy_o,
    input  wire load_address_valid_i,
    output reg load_address_ready_o,
    input  wire [ROB_TAG_WIDTH-1:0] load_address_rob_tag_i,
    input  wire [LSQ_TAG_WIDTH-1:0] load_address_lsq_tag_i,
    input  wire [31:0] load_address_i,
    input  wire store_address_valid_i,
    output reg store_address_ready_o,
    input  wire [ROB_TAG_WIDTH-1:0] store_address_rob_tag_i,
    input  wire [LSQ_TAG_WIDTH-1:0] store_address_lsq_tag_i,
    input  wire [31:0] store_address_i,
    input  wire store_data_valid_i,
    output wire store_data_ready_o,
    input  wire [ROB_TAG_WIDTH-1:0] store_data_rob_tag_i,
    input  wire [LSQ_TAG_WIDTH-1:0] store_data_lsq_tag_i,
    input  wire [31:0] store_data_i,
    input  wire [ROB_INDEX_WIDTH-1:0] rob_head_index_i,
    input  wire [RECOVERY_WIDTH-1:0] rollback_valid_i,
    input  wire [(RECOVERY_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_rob_tag_i,
    input  wire [(RECOVERY_WIDTH*LSQ_TAG_WIDTH)-1:0] rollback_lsq_tag_i,
    output wire completion_valid_o,
    input  wire completion_ready_i,
    output wire [ROB_TAG_WIDTH-1:0] completion_rob_tag_o,
    output wire [31:0] completion_value_o,
    output wire completion_exception_valid_o,
    output wire [3:0] completion_exception_cause_o,
    output wire [31:0] completion_exception_tval_o,
    input  wire [BE_WIDTH-1:0] commit_valid_i,
    input  wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] commit_op_i,
    input  wire [BE_WIDTH-1:0] commit_lsq_valid_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] commit_rob_tag_i,
    input  wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] commit_lsq_tag_i,
    input  wire [BE_WIDTH-1:0] commit_exception_valid_i,
    input  wire [BE_WIDTH-1:0] commit_fire_i,
    output reg [BE_WIDTH-1:0] commit_ready_o,
    output wire cache_request_valid_o,
    input  wire cache_request_ready_i,
    output wire [((MAX_INFLIGHT > 1) ? index_width_for_count(MAX_INFLIGHT) : 1)-1:0] cache_request_id_o,
    input wire [((MAX_INFLIGHT > 1) ? index_width_for_count(MAX_INFLIGHT) : 1)-1:0] cache_response_id_i,
    output wire [ROB_TAG_WIDTH-1:0] cache_request_rob_tag_o,
    input wire [ROB_TAG_WIDTH-1:0] cache_response_rob_tag_i,
    input  wire cache_request_irrevocable_i,
    input wire cache_store_confirm_valid_i,
    input wire [((MAX_INFLIGHT > 1) ? index_width_for_count(MAX_INFLIGHT) : 1)-1:0] cache_store_confirm_id_i,
    input wire [ROB_TAG_WIDTH-1:0] cache_store_confirm_rob_tag_i,
    output wire cache_request_write_o,
    output wire [31:0] cache_request_address_o,
    output wire [31:0] cache_request_write_data_o,
    output wire [3:0] cache_request_byte_enable_o,
    output wire cache_request_mmio_o,
    input  wire cache_response_valid_i,
    output wire cache_response_ready_o,
    input  wire [31:0] cache_response_read_data_i,
    input  wire cache_response_error_i
);

    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */
    /* verilator lint_off BLKSEQ */
    /* verilator lint_off UNUSEDSIGNAL */

    reg busy [0:LSQ_ENTRIES-1];
    reg [LSQ_GENERATION_WIDTH-1:0] generation [0:LSQ_ENTRIES-1];
    reg [LSQ_GENERATION_WIDTH-1:0] next_generation [0:LSQ_ENTRIES-1];
    reg is_store [0:LSQ_ENTRIES-1];
    reg [ROB_TAG_WIDTH-1:0] rob_tag [0:LSQ_ENTRIES-1];
    reg [`RV32_MEMORY_WIDTH-1:0] width [0:LSQ_ENTRIES-1];
    reg load_unsigned [0:LSQ_ENTRIES-1];
    reg address_valid [0:LSQ_ENTRIES-1];
    reg [31:0] address [0:LSQ_ENTRIES-1];
    reg data_valid [0:LSQ_ENTRIES-1];
    reg [31:0] store_data [0:LSQ_ENTRIES-1];
    reg fault_valid [0:LSQ_ENTRIES-1];
    reg [3:0] fault_cause [0:LSQ_ENTRIES-1];
    reg started [0:LSQ_ENTRIES-1];
    reg report_sent [0:LSQ_ENTRIES-1];
    reg write_requested [0:LSQ_ENTRIES-1];
    reg write_done [0:LSQ_ENTRIES-1];
    reg late_error [0:LSQ_ENTRIES-1];
    reg late_error_sent [0:LSQ_ENTRIES-1];

    wire response_bypass;
    wire response_payload;
    wire [31:0] response_value;
    reg source_valid;
    reg [ROB_TAG_WIDTH-1:0] source_rob_tag;
    reg [LSQ_TAG_WIDTH-1:0] source_lsq_tag;
    reg [31:0] source_value;
    reg source_exception_valid;
    reg [3:0] source_exception_cause;
    reg [31:0] source_exception_tval;

    reg request_valid;
    reg request_write;
    reg [ROB_TAG_WIDTH-1:0] request_rob_tag;
    reg [LSQ_TAG_WIDTH-1:0] request_lsq_tag;
    reg [31:0] request_address;
    reg [31:0] request_write_data;
    reg [3:0] request_byte_enable;
    reg request_mmio;
    reg request_prepared;
    reg prepared_store_authorized;
    reg store_authorize_prefix;
    integer store_authorize_lane;
    always @* begin
        prepared_store_authorized = 1'b0;
        store_authorize_prefix = 1'b1;
        for (store_authorize_lane = 0; store_authorize_lane < BE_WIDTH;
                store_authorize_lane = store_authorize_lane + 1) begin
            if (store_authorize_prefix && commit_valid_i[store_authorize_lane] &&
                    commit_lsq_valid_i[store_authorize_lane] &&
                    !commit_exception_valid_i[store_authorize_lane] &&
                    commit_rob_tag_i[store_authorize_lane*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] == request_rob_tag &&
                    commit_lsq_tag_i[store_authorize_lane*LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] == request_lsq_tag &&
                    (store_authorize_lane == 0 || !request_mmio))
                prepared_store_authorized = 1'b1;
            store_authorize_prefix = store_authorize_prefix &&
                commit_fire_i[store_authorize_lane] && !commit_exception_valid_i[store_authorize_lane];
        end
    end
    wire prepared_store_waiting = FAST_RETURN != 0 && request_valid && request_prepared &&
        !prepared_store_authorized;

    localparam INFLIGHT_INDEX_WIDTH = (MAX_INFLIGHT > 1) ?
        index_width_for_count(MAX_INFLIGHT) : 1;
    reg [INFLIGHT_INDEX_WIDTH-1:0] inflight_head;
    reg [INFLIGHT_INDEX_WIDTH-1:0] inflight_tail;
    reg [INFLIGHT_INDEX_WIDTH:0] inflight_count;
    reg pending_valid [0:MAX_INFLIGHT-1];
    reg [INFLIGHT_INDEX_WIDTH-1:0] request_id;
    wire [INFLIGHT_INDEX_WIDTH-1:0] response_slot = TAGGED_RESPONSES != 0 ?
        cache_response_id_i : inflight_head;
    wire [INFLIGHT_INDEX_WIDTH-1:0] accepted_slot = TAGGED_RESPONSES != 0 ?
        cache_request_id_o : inflight_tail;
    integer free_pending_index;
    reg free_pending_found;
    reg [INFLIGHT_INDEX_WIDTH-1:0] free_pending_slot;
    reg pending_write [0:MAX_INFLIGHT-1];
    reg pending_posted [0:MAX_INFLIGHT-1];
    reg pending_mmio [0:MAX_INFLIGHT-1];
    reg pending_discard [0:MAX_INFLIGHT-1];
    reg [ROB_TAG_WIDTH-1:0] pending_rob_tag [0:MAX_INFLIGHT-1];
    reg [LSQ_TAG_WIDTH-1:0] pending_lsq_tag [0:MAX_INFLIGHT-1];
    reg [31:0] pending_address [0:MAX_INFLIGHT-1];
    wire [INFLIGHT_INDEX_WIDTH-1:0] confirm_slot = cache_store_confirm_id_i;
    wire [LSQ_TAG_WIDTH-1:0] confirm_lsq_tag = pending_lsq_tag[confirm_slot];
    wire [LSQ_INDEX_WIDTH-1:0] confirm_lsq_slot = confirm_lsq_tag[LSQ_INDEX_WIDTH-1:0];
    wire confirm_match = POSTED_STORES != 0 && LATE_STORE_CONFIRM != 0 &&
        !reset_i && !flush_i && !recover_i &&
        cache_store_confirm_valid_i && pending_valid[confirm_slot] &&
        pending_write[confirm_slot] && !pending_mmio[confirm_slot] &&
        !pending_discard[confirm_slot] && !pending_posted[confirm_slot] &&
        pending_rob_tag[confirm_slot] == cache_store_confirm_rob_tag_i;
    wire confirm_live = confirm_match && busy[confirm_lsq_slot] &&
        is_store[confirm_lsq_slot] &&
        {generation[confirm_lsq_slot], confirm_lsq_slot} == confirm_lsq_tag &&
        rob_tag[confirm_lsq_slot] == cache_store_confirm_rob_tag_i;
    wire inflight = inflight_count != 0;
    wire inflight_write = pending_write[response_slot];
    reg pending_mmio_any;
    integer mmio_pending_index;
    wire inflight_mmio = TAGGED_RESPONSES != 0 ? pending_mmio_any : pending_mmio[response_slot];
    always @* begin
        pending_mmio_any = 1'b0;
        for (mmio_pending_index = 0; mmio_pending_index < MAX_INFLIGHT;
                mmio_pending_index = mmio_pending_index + 1)
            pending_mmio_any = pending_mmio_any ||
                (pending_valid[mmio_pending_index] && pending_mmio[mmio_pending_index]);
    end
    wire inflight_discard = pending_discard[response_slot];
    wire [ROB_TAG_WIDTH-1:0] inflight_rob_tag = ECHO_ROB_TAG != 0 ?
        cache_response_rob_tag_i : pending_rob_tag[response_slot];
    wire [LSQ_TAG_WIDTH-1:0] inflight_lsq_tag = pending_lsq_tag[response_slot];
    wire [31:0] inflight_address = pending_address[response_slot];
    reg direct_store_barrier;
    integer direct_store_lane;
    wire direct_load;
    wire direct_payload = FAST_RETURN != 0 && !request_valid;
    reg [INFLIGHT_INDEX_WIDTH-1:0] direct_id;
    reg direct_id_found;
    integer direct_id_index;
    wire [LSQ_TAG_WIDTH-1:0] accepted_lsq_tag = direct_payload ?
        load_address_lsq_tag_i : request_lsq_tag;
    wire [ROB_TAG_WIDTH-1:0] accepted_rob_tag = direct_payload ?
        load_address_rob_tag_i : request_rob_tag;
    wire request_fire = cache_request_valid_o && cache_request_ready_i;
    wire response_fire = cache_response_valid_i && cache_response_ready_o;
    integer pending_index;
    integer pending_lane;

    reg [LSQ_ENTRIES-1:0] reserved_slots;
    reg [LSQ_INDEX_WIDTH-1:0] alloc_slot [0:BE_WIDTH-1];
    reg [3:0] forwarding_mask [0:LSQ_ENTRIES-1];
    reg [31:0] forwarding_value [0:LSQ_ENTRIES-1];
    reg load_blocked [0:LSQ_ENTRIES-1];
    reg [ROB_INDEX_WIDTH:0] entry_distance [0:LSQ_ENTRIES-1];
    reg [2:0] entry_size [0:LSQ_ENTRIES-1];
    reg load_match;
    reg store_match;
    reg data_match;
    reg inflight_match;
    reg inflight_identity_match;
    reg [1:0] pending_width [0:MAX_INFLIGHT-1];
    reg pending_unsigned [0:MAX_INFLIGHT-1];
    reg [LSQ_INDEX_WIDTH-1:0] load_slot;
    reg [LSQ_INDEX_WIDTH-1:0] store_slot;
    reg [LSQ_INDEX_WIDTH-1:0] data_slot;
    reg [LSQ_INDEX_WIDTH-1:0] inflight_slot;
    reg [LSQ_INDEX_WIDTH-1:0] commit_slot;
    reg [LSQ_INDEX_WIDTH-1:0] sequential_commit_slot;
    reg incoming_load_blocked;
    integer incoming_store_index;
    integer incoming_load_index;
    reg [LSQ_ENTRIES-1:0] older_store_mask [0:LSQ_ENTRIES-1];
    reg [LSQ_ENTRIES-1:0] incoming_store_conflict;
    wire [3:0] incoming_byte_mask = access_mask(width[load_slot], load_address_i[1:0]);
    localparam LOAD_VALUE_STORAGE = LOAD_VALUE_ENTRIES > 0 ? LOAD_VALUE_ENTRIES : 1;
    localparam LOAD_VALUE_INDEX_WIDTH = LOAD_VALUE_STORAGE > 1 ? index_width_for_count(LOAD_VALUE_STORAGE) : 1;
    localparam LOAD_VALUE_TAG_LOW = LOAD_VALUE_STORAGE > 1 ? 2 + LOAD_VALUE_INDEX_WIDTH : 2;
    localparam LOAD_VALUE_ADDRESS_WIDTH = index_width_for_count(MEMORY_BYTES);
    localparam LOAD_VALUE_TAG_HIGH = LOAD_VALUE_ADDRESS_WIDTH > LOAD_VALUE_TAG_LOW ?
        LOAD_VALUE_ADDRESS_WIDTH - 1 : LOAD_VALUE_TAG_LOW;
    localparam LOAD_VALUE_TAG_WIDTH = LOAD_VALUE_TAG_HIGH - LOAD_VALUE_TAG_LOW + 1;
    // The hash and tag reconstruct every legal RAM word address.
    // Only validity resets; each fill supplies a complete word and tag.
    reg lv_valid [0:LOAD_VALUE_STORAGE-1];
    reg [LOAD_VALUE_TAG_WIDTH-1:0] lv_tag [0:LOAD_VALUE_STORAGE-1];
    reg [31:0] lv_data [0:LOAD_VALUE_STORAGE-1];
    wire [LOAD_VALUE_INDEX_WIDTH-1:0] lv_lookup_index = LOAD_VALUE_ENTRIES == 1 ? 0 :
        (load_address_i[2 +: LOAD_VALUE_INDEX_WIDTH] ^
         load_address_i[2+LOAD_VALUE_INDEX_WIDTH +: LOAD_VALUE_INDEX_WIDTH]);
    wire [LOAD_VALUE_INDEX_WIDTH-1:0] lv_fill_index = LOAD_VALUE_ENTRIES == 1 ? 0 :
        (inflight_address[2 +: LOAD_VALUE_INDEX_WIDTH] ^
         inflight_address[2+LOAD_VALUE_INDEX_WIDTH +: LOAD_VALUE_INDEX_WIDTH]);
    wire [LOAD_VALUE_INDEX_WIDTH-1:0] lv_store_index = LOAD_VALUE_ENTRIES == 1 ? 0 :
        (store_address_i[2 +: LOAD_VALUE_INDEX_WIDTH] ^
         store_address_i[2+LOAD_VALUE_INDEX_WIDTH +: LOAD_VALUE_INDEX_WIDTH]);
    wire [LOAD_VALUE_INDEX_WIDTH-1:0] lv_request_index = LOAD_VALUE_ENTRIES == 1 ? 0 :
        (cache_request_address_o[2 +: LOAD_VALUE_INDEX_WIDTH] ^
         cache_request_address_o[2+LOAD_VALUE_INDEX_WIDTH +: LOAD_VALUE_INDEX_WIDTH]);
    wire [LOAD_VALUE_TAG_WIDTH+31:0] lv_lookup_tree [0:2*LOAD_VALUE_STORAGE-2];
    wire [LOAD_VALUE_TAG_WIDTH-1:0] lv_lookup_tag = lv_lookup_tree[0][LOAD_VALUE_TAG_WIDTH+31:32];
    wire [31:0] lv_lookup_data = lv_lookup_tree[0][31:0];
    genvar lv_read_leaf, lv_read_node;
    generate
        for (lv_read_leaf = 0; lv_read_leaf < LOAD_VALUE_STORAGE;
                lv_read_leaf = lv_read_leaf + 1) begin: value_read_leaf
            assign lv_lookup_tree[LOAD_VALUE_STORAGE-1+lv_read_leaf] =
                lv_lookup_index == lv_read_leaf && lv_valid[lv_read_leaf] ?
                {lv_tag[lv_read_leaf], lv_data[lv_read_leaf]} : 0;
        end
        for (lv_read_node = 0; lv_read_node < LOAD_VALUE_STORAGE-1;
                lv_read_node = lv_read_node + 1) begin: value_read_node
            assign lv_lookup_tree[lv_read_node] =
                lv_lookup_tree[2*lv_read_node+1] | lv_lookup_tree[2*lv_read_node+2];
        end
    endgenerate
    wire lv_hit = LOAD_VALUE_ENTRIES != 0 && lv_valid[lv_lookup_index] &&
        lv_lookup_tag == load_address_i[LOAD_VALUE_TAG_HIGH:LOAD_VALUE_TAG_LOW];
    wire lv_capture = load_address_valid_i && load_address_ready_o && lv_hit &&
        !incoming_load_blocked && !address_fault(load_address_i, width[load_slot], 1'b0);
    integer lv_reset, lv_commit;
    reg [LSQ_INDEX_WIDTH-1:0] lv_commit_slot;
    reg [LOAD_VALUE_INDEX_WIDTH-1:0] lv_commit_index;
    always @(posedge clk_i) begin
        if (reset_i || flush_i) begin
            for (lv_reset = 0; lv_reset < LOAD_VALUE_STORAGE; lv_reset = lv_reset + 1) begin
                lv_valid[lv_reset] <= 1'b0;
            end
        end else if (LOAD_VALUE_ENTRIES != 0) begin
            if (response_fire && !inflight_write && !inflight_discard && inflight_match &&
                    !cache_response_error_i && !recover_i &&
                    pending_width[response_slot] == `RV32_MEMORY_WORD &&
                    !(store_address_valid_i && store_address_ready_o &&
                        store_address_i[31:2] == inflight_address[31:2]) &&
                    !(request_fire && cache_request_write_o &&
                        cache_request_address_o[31:2] == inflight_address[31:2])) begin
                lv_valid[lv_fill_index] <= 1'b1;
                lv_tag[lv_fill_index] <= inflight_address[LOAD_VALUE_TAG_HIGH:LOAD_VALUE_TAG_LOW];
                lv_data[lv_fill_index] <= cache_response_read_data_i;
            end
            if (store_address_valid_i && store_address_ready_o)
                lv_valid[lv_store_index] <= 1'b0;
            if (request_fire && cache_request_write_o)
                lv_valid[lv_request_index] <= 1'b0;
            // Store retirement is restricted to commit slot zero.
            for (lv_commit = 0; lv_commit < 1; lv_commit = lv_commit + 1) begin
                lv_commit_slot = commit_lsq_tag_i[lv_commit*LSQ_TAG_WIDTH +: LSQ_INDEX_WIDTH];
                lv_commit_index = LOAD_VALUE_ENTRIES == 1 ? 0 :
                    ((address[lv_commit_slot] >> 2) ^
                     (address[lv_commit_slot] >> (2+LOAD_VALUE_INDEX_WIDTH))) & (LOAD_VALUE_STORAGE - 1);
                if (commit_fire_i[lv_commit] && commit_lsq_valid_i[lv_commit] &&
                        is_store_op(commit_op_i[lv_commit*`RV32_OP_WIDTH +: `RV32_OP_WIDTH]) &&
                        busy[lv_commit_slot] && is_store[lv_commit_slot] && !fault_valid[lv_commit_slot] &&
                        {generation[lv_commit_slot], lv_commit_slot} ==
                            commit_lsq_tag_i[lv_commit*LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] &&
                        rob_tag[lv_commit_slot] == commit_rob_tag_i[lv_commit*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] &&
                        !is_mmio_store(address[lv_commit_slot], width[lv_commit_slot])) begin
                    if (width[lv_commit_slot] == `RV32_MEMORY_WORD) begin
                        lv_valid[lv_commit_index] <= 1'b1;
                        lv_tag[lv_commit_index] <= address[lv_commit_slot][LOAD_VALUE_TAG_HIGH:LOAD_VALUE_TAG_LOW];
                        lv_data[lv_commit_index] <= store_data[lv_commit_slot];
                    end else begin
                        // Partial Stores conservatively discard the cached word.
                        lv_valid[lv_commit_index] <= 1'b0;
                    end
                end
            end
        end
    end
    wire incoming_load_request = load_address_valid_i && load_address_ready_o &&
        !incoming_load_blocked && !lv_hit && !address_fault(load_address_i, width[load_slot], 1'b0);
    wire [3:0] parallel_forward_mask [0:LSQ_ENTRIES];
    wire [31:0] parallel_forward_value [0:LSQ_ENTRIES];
    wire parallel_load_blocked [0:LSQ_ENTRIES];
    wire [LSQ_ENTRIES-1:0] forward_byte_selected [0:LSQ_ENTRIES][0:3];
    wire [3:0] forward_wanted [0:LSQ_ENTRIES];
    integer source_candidate;
    wire [31:0] selected_forward_word;
    wire [LSQ_INDEX_WIDTH-1:0] selected_forward_slot =
        source_candidate < 0 ? 0 : source_candidate[LSQ_INDEX_WIDTH-1:0];
    wire [31:0] selected_forward_value = unalign_word(selected_forward_word,
        address[selected_forward_slot][1:0]);
    wire [31:0] aligned_store_data [0:LSQ_ENTRIES-1];
    wire [3:0] store_byte_mask [0:LSQ_ENTRIES-1];
    wire [LSQ_ENTRIES-1:0] newer_store_mask [0:LSQ_ENTRIES-1];
    wire [LSQ_ENTRIES-1:0] unknown_store_mask;
    wire fast_store_address = FAST_RETURN != 0 && store_address_valid_i &&
        store_address_ready_o && !report_sent[store_slot] &&
        !address_fault(store_address_i, width[store_slot], 1'b1) &&
        (data_valid[store_slot] || (store_data_valid_i && store_data_ready_o &&
            data_slot == store_slot));
    wire fast_store_data = FAST_RETURN != 0 && store_data_valid_i &&
        store_data_ready_o && !report_sent[data_slot] &&
        address_valid[data_slot] && !fault_valid[data_slot];
    wire [LSQ_INDEX_WIDTH-1:0] fast_store_slot = fast_store_address ?
        store_slot : data_slot;
    wire [31:0] fast_store_tval = fast_store_address ?
        store_address_i : address[data_slot];
    wire [LSQ_ENTRIES-1:0] source_eligible;
    wire [LSQ_ENTRIES-1:0] request_eligible;
    wire [LSQ_ENTRIES-1:0] prepare_eligible;
    wire [LSQ_ENTRIES-1:0] source_selected;
    wire [LSQ_ENTRIES-1:0] request_selected;
    wire [LSQ_ENTRIES-1:0] prepare_selected;
    wire [LSQ_ENTRIES-1:0] older_entry [0:LSQ_ENTRIES-1];
    integer request_candidate;
    integer store_request_candidate;
    integer store_prepare_candidate;
    integer store_prepare_oldest;
    integer store_prepare_index;
    integer store_prepare_distance;
    integer selected_store_candidate;
    wire replace_prepared_store = prepared_store_waiting &&
        (store_request_candidate >= 0 || request_candidate >= 0 || incoming_load_request);

    integer store_request_lane;
    reg store_request_prefix;
    reg [LSQ_INDEX_WIDTH-1:0] store_request_slot;
    integer candidate_distance;
    integer best_distance;
    integer i;
    integer j;
    integer occupancy_index;
    integer alloc_choice;
    integer precompute_index;
    integer sequential_index;
    integer sequential_lane;
    integer assertion_lane;
    reg [LSQ_INDEX_WIDTH-1:0] assertion_slot;
    reg [1:0] byte_offset;
    reg [31:0] raw_value;

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

    function integer size_bytes;
        input [`RV32_MEMORY_WIDTH-1:0] code;
        begin
            case (code)
                `RV32_MEMORY_BYTE: size_bytes = 1;
                `RV32_MEMORY_HALF: size_bytes = 2;
                `RV32_MEMORY_WORD: size_bytes = 4;
                default: size_bytes = 0;
            endcase
        end
    endfunction

    function [3:0] access_mask;
        input [`RV32_MEMORY_WIDTH-1:0] code;
        input [1:0] offset;
        begin
            case (code)
                `RV32_MEMORY_BYTE: access_mask = 4'b0001 << offset;
                `RV32_MEMORY_HALF: access_mask = 4'b0011 << offset;
                `RV32_MEMORY_WORD: access_mask = 4'b1111;
                default: access_mask = 4'b0000;
            endcase
        end
    endfunction

    function integer distance_from_head;
        input [ROB_TAG_WIDTH-1:0] tag_value;
        input [ROB_INDEX_WIDTH-1:0] head_value;
        reg [ROB_INDEX_WIDTH-1:0] delta;
        begin
            delta = tag_value[ROB_INDEX_WIDTH-1:0] - head_value;
            distance_from_head = delta;
        end
    endfunction

    function [31:0] align_store_word;
        input [31:0] value;
        input [1:0] offset;
        begin
            case (offset)
                2'd0: align_store_word = value;
                2'd1: align_store_word = {value[23:0], 8'd0};
                2'd2: align_store_word = {value[15:0], 16'd0};
                default: align_store_word = {value[7:0], 24'd0};
            endcase
        end
    endfunction

    function [31:0] unalign_word;
        input [31:0] value;
        input [1:0] offset;
        begin
            case (offset)
                2'd0: unalign_word = value;
                2'd1: unalign_word = {8'd0, value[31:8]};
                2'd2: unalign_word = {16'd0, value[31:16]};
                default: unalign_word = {24'd0, value[31:24]};
            endcase
        end
    endfunction

    function [3:0] unalign_mask;
        input [3:0] value;
        input [1:0] offset;
        begin
            case (offset)
                2'd0: unalign_mask = value;
                2'd1: unalign_mask = {1'd0, value[3:1]};
                2'd2: unalign_mask = {2'd0, value[3:2]};
                default: unalign_mask = {3'd0, value[3]};
            endcase
        end
    endfunction

    function [31:0] extend_value;
        input [31:0] value;
        input [`RV32_MEMORY_WIDTH-1:0] code;
        input unsigned_value;
        begin
            case (code)
                `RV32_MEMORY_BYTE: extend_value = unsigned_value ?
                    {24'd0, value[7:0]} : {{24{value[7]}}, value[7:0]};
                `RV32_MEMORY_HALF: extend_value = unsigned_value ?
                    {16'd0, value[15:0]} : {{16{value[15]}}, value[15:0]};
                default: extend_value = value;
            endcase
        end
    endfunction

    function address_fault;
        input [31:0] addr;
        input [`RV32_MEMORY_WIDTH-1:0] code;
        input store_value;
        integer bytes;
        begin
            bytes = size_bytes(code);
            if (bytes == 0 || (addr & (bytes-1)) != 0)
                address_fault = 1'b1;
            else if (addr == 32'h80000000)
                address_fault = !store_value ||
                    code != `RV32_MEMORY_WORD;
            else
                address_fault = addr > MEMORY_BYTES - bytes;
        end
    endfunction

    function is_mmio_store;
        input [31:0] addr;
        input [`RV32_MEMORY_WIDTH-1:0] code;
        begin
            is_mmio_store = addr == 32'h80000000 &&
                code == `RV32_MEMORY_WORD;
        end
    endfunction

    function [3:0] address_fault_cause;
        input [31:0] addr;
        input [`RV32_MEMORY_WIDTH-1:0] code;
        input store_value;
        integer bytes;
        begin
            bytes = size_bytes(code);
            if (bytes == 0 || (addr & (bytes-1)) != 0)
                address_fault_cause = store_value ? 4'd6 : 4'd4;
            else
                address_fault_cause = store_value ? 4'd7 : 4'd5;
        end
    endfunction

    function is_store_op;
        input [`RV32_OP_WIDTH-1:0] code;
        begin
            is_store_op = code == `RV32_OP_SB || code == `RV32_OP_SH ||
                code == `RV32_OP_SW;
        end
    endfunction

    initial begin
        if ((BE_WIDTH != 1 && BE_WIDTH != 2 && BE_WIDTH != 4) ||
                LSQ_ENTRIES < BE_WIDTH || LSQ_ENTRIES < 2 ||
                (LSQ_ENTRIES & (LSQ_ENTRIES-1)) != 0 ||
                LSQ_INDEX_WIDTH != index_width_for_count(LSQ_ENTRIES) ||
                LSQ_GENERATION_WIDTH < 1 ||
                LSQ_TAG_WIDTH != LSQ_INDEX_WIDTH + LSQ_GENERATION_WIDTH ||
                ROB_INDEX_WIDTH != index_width_for_count(ROB_ENTRIES) ||
                ROB_TAG_WIDTH <= ROB_INDEX_WIDTH ||
                (ROB_ENTRIES & (ROB_ENTRIES-1)) != 0 ||
                MEMORY_BYTES < 4 || (MEMORY_BYTES & 3) != 0 ||
                MAX_INFLIGHT < 1 ||
                (MAX_INFLIGHT & (MAX_INFLIGHT-1)) != 0) begin
            $display("ERROR rv32_load_store_queue invalid parameters");
            $finish(1);
        end
    end

    assign response_payload = LOAD_FALLTHROUGH != 0 && !source_valid;
    assign response_bypass = LOAD_FALLTHROUGH != 0 && !source_valid &&
        inflight && !inflight_write && !inflight_discard && inflight_match &&
        cache_response_valid_i;
    assign response_value = cache_response_error_i ? 32'd0 :
        extend_value(cache_response_read_data_i >> (inflight_address[1:0]*8),
            FAST_RETURN != 0 ? pending_width[response_slot] : width[inflight_slot],
            FAST_RETURN != 0 ? pending_unsigned[response_slot] : load_unsigned[inflight_slot]);

    assign direct_load = FAST_RETURN != 0 && !request_valid &&
        incoming_load_request && request_candidate < 0 &&
        !direct_store_barrier && !inflight_mmio;
    always @* begin
        direct_store_barrier = 1'b0;
        for (direct_store_lane = 0; direct_store_lane < BE_WIDTH;
                direct_store_lane = direct_store_lane + 1) begin
            if (commit_valid_i[direct_store_lane] &&
                    is_store_op(commit_op_i[direct_store_lane*`RV32_OP_WIDTH +: `RV32_OP_WIDTH]) &&
                    !write_requested[commit_lsq_tag_i[
                        direct_store_lane*LSQ_TAG_WIDTH +: LSQ_INDEX_WIDTH]] &&
                    is_mmio_store(address[commit_lsq_tag_i[
                        direct_store_lane*LSQ_TAG_WIDTH +: LSQ_INDEX_WIDTH]],
                        width[commit_lsq_tag_i[
                        direct_store_lane*LSQ_TAG_WIDTH +: LSQ_INDEX_WIDTH]]))
                direct_store_barrier = 1'b1;
        end
    end
    always @* begin
        direct_id = 0;
        direct_id_found = 1'b0;
        for (direct_id_index = 0; direct_id_index < MAX_INFLIGHT;
                direct_id_index = direct_id_index + 1) begin
            if ((!pending_valid[direct_id_index] ||
                    (response_fire && response_slot == direct_id_index)) &&
                    !direct_id_found) begin
                direct_id = direct_id_index[INFLIGHT_INDEX_WIDTH-1:0];
                direct_id_found = 1'b1;
            end
        end
    end
    assign cache_request_rob_tag_o = ECHO_ROB_TAG != 0 ? accepted_rob_tag : 0;
    assign cache_request_id_o = TAGGED_RESPONSES != 0 ?
        (direct_payload ? direct_id :
            (inflight_count == MAX_INFLIGHT && response_fire) ? response_slot : request_id) : 0;
    always @* begin
        free_pending_found = 1'b0;
        free_pending_slot = 0;
        for (free_pending_index = 0; free_pending_index < MAX_INFLIGHT;
                free_pending_index = free_pending_index + 1) begin
            if ((!pending_valid[free_pending_index] ||
                    (response_fire && response_slot == free_pending_index)) &&
                    !(request_fire && accepted_slot == free_pending_index) &&
                    !free_pending_found) begin
                free_pending_found = 1'b1;
                free_pending_slot = free_pending_index[INFLIGHT_INDEX_WIDTH-1:0];
            end
        end
    end

    assign completion_valid_o = !reset_i && !flush_i && !recover_i &&
        (source_valid || response_bypass);
    assign completion_rob_tag_o = response_payload ? inflight_rob_tag : source_rob_tag;
    assign completion_value_o = response_payload ? response_value : source_value;
    assign completion_exception_valid_o = response_payload ?
        cache_response_error_i : source_exception_valid;
    assign completion_exception_cause_o = response_payload ?
        (cache_response_error_i ? 4'd5 : 4'd0) : source_exception_cause;
    assign completion_exception_tval_o = response_payload ?
        (cache_response_error_i ? inflight_address : 32'd0) : source_exception_tval;
    assign cache_request_valid_o = !reset_i && !flush_i && !recover_i &&
        ((request_valid && !prepared_store_waiting) || direct_load) &&
        (inflight_count < MAX_INFLIGHT || response_fire) &&
        ((request_valid && request_mmio) ? !inflight : !(inflight && inflight_mmio));
    assign cache_request_write_o = request_valid && request_write;
    assign cache_request_address_o = direct_payload ?
        {load_address_i[31:2], 2'b00} : request_address;
    assign cache_request_write_data_o = direct_payload ? 32'd0 : request_write_data;
    assign cache_request_byte_enable_o = direct_payload ? 4'd0 : request_byte_enable;
    assign cache_request_mmio_o = request_valid && request_mmio;
    assign store_data_ready_o = !reset_i && !flush_i && !recover_i &&
        store_data_valid_i && data_match && !data_valid[data_slot];
    assign cache_response_ready_o = !reset_i && !flush_i &&
        !recover_i && inflight &&
        (inflight_write || inflight_discard || !inflight_match ||
            !source_valid || completion_ready_i);

    always @* begin
        for (precompute_index = 0; precompute_index < LSQ_ENTRIES;
                precompute_index = precompute_index + 1) begin
            entry_distance[precompute_index] = distance_from_head(
                rob_tag[precompute_index], rob_head_index_i);
            entry_size[precompute_index] = size_bytes(
                width[precompute_index]);
        end
    end

    always @* begin
        alloc_choice = -1;
        j = 0;
        source_candidate = -1;
        request_candidate = -1;
        candidate_distance = ROB_ENTRIES;
        best_distance = ROB_ENTRIES;
        commit_slot = 0;
        reserved_slots = 0;
        alloc_ready_o = !reset_i && !flush_i && !recover_i;
        alloc_lsq_tag_o = 0;
        for (i = 0; i < BE_WIDTH; i = i + 1) begin
            alloc_slot[i] = 0;
            if (alloc_valid_i[i]) begin
                alloc_choice = -1;
                for (j = 0; j < LSQ_ENTRIES; j = j + 1)
                    if (!busy[j] && !reserved_slots[j] && alloc_choice < 0)
                        alloc_choice = j;
                if (alloc_choice < 0) alloc_ready_o = 1'b0;
                else begin
                    alloc_slot[i] = alloc_choice;
                    reserved_slots[alloc_choice] = 1'b1;
                    alloc_lsq_tag_o[i*LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] =
                        {next_generation[alloc_choice],
                            alloc_slot[i]};
                end
            end
        end

        load_slot = load_address_lsq_tag_i[LSQ_INDEX_WIDTH-1:0];
        store_slot = store_address_lsq_tag_i[LSQ_INDEX_WIDTH-1:0];
        data_slot = store_data_lsq_tag_i[LSQ_INDEX_WIDTH-1:0];
        inflight_slot = inflight_lsq_tag[LSQ_INDEX_WIDTH-1:0];
        load_match = load_address_valid_i && busy[load_slot] &&
            !is_store[load_slot] && !address_valid[load_slot] &&
            {generation[load_slot], load_slot} == load_address_lsq_tag_i &&
            rob_tag[load_slot] == load_address_rob_tag_i;
        store_match = store_address_valid_i && busy[store_slot] &&
            is_store[store_slot] && !address_valid[store_slot] &&
            {generation[store_slot], store_slot} == store_address_lsq_tag_i &&
            rob_tag[store_slot] == store_address_rob_tag_i;
        data_match = store_data_valid_i && busy[data_slot] &&
            is_store[data_slot] &&
            {generation[data_slot], data_slot} == store_data_lsq_tag_i &&
            rob_tag[data_slot] == store_data_rob_tag_i;
        inflight_identity_match = busy[inflight_slot] &&
            {generation[inflight_slot], inflight_slot} == inflight_lsq_tag &&
            rob_tag[inflight_slot] == inflight_rob_tag;
        // Non-discarded requests retain their LSQ entry until this reply.
        inflight_match = FAST_RETURN != 0 ? pending_valid[response_slot] : inflight_identity_match;
        load_address_ready_o = 1'b0;
        store_address_ready_o = 1'b0;
        if (!reset_i && !flush_i && !recover_i) begin
            if (load_match && store_match) begin
                if (distance_from_head(load_address_rob_tag_i,
                        rob_head_index_i) <=
                        distance_from_head(store_address_rob_tag_i,
                            rob_head_index_i))
                    load_address_ready_o = 1'b1;
                else
                    store_address_ready_o = 1'b1;
            end else begin
                load_address_ready_o = load_match;
                store_address_ready_o = store_match;
            end
        end

        for (i = 0; i < LSQ_ENTRIES; i = i + 1) begin
            forwarding_mask[i] = parallel_forward_mask[i];
            forwarding_value[i] = parallel_forward_value[i];
            load_blocked[i] = parallel_load_blocked[i];
        end

        source_candidate = -1;
        request_candidate = -1;
        if (|source_selected) begin
            source_candidate = 0;
            for (i = 0; i < LSQ_ENTRIES; i = i + 1)
                if (source_selected[i]) source_candidate = source_candidate | i;
        end
        if (|request_selected) begin
            request_candidate = 0;
            for (i = 0; i < LSQ_ENTRIES; i = i + 1)
                if (request_selected[i]) request_candidate = request_candidate | i;
        end

        commit_ready_o = {BE_WIDTH{1'b1}};
        if (reset_i || flush_i || recover_i)
            commit_ready_o = 0;
        else begin
            for (i = 0; i < BE_WIDTH; i = i + 1) begin
                if (commit_valid_i[i] && is_store_op(commit_op_i[
                        i*`RV32_OP_WIDTH +: `RV32_OP_WIDTH])) begin
                    commit_ready_o[i] = 1'b0;
                    commit_slot = commit_lsq_tag_i[
                        i*LSQ_TAG_WIDTH +: LSQ_INDEX_WIDTH];
                    if (commit_lsq_valid_i[i] && busy[commit_slot] &&
                            is_store[commit_slot] &&
                            {generation[commit_slot], commit_slot} ==
                                commit_lsq_tag_i[
                                    i*LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] &&
                            rob_tag[commit_slot] == commit_rob_tag_i[
                                i*ROB_TAG_WIDTH +: ROB_TAG_WIDTH]) begin
                        commit_ready_o[i] = i == 0 &&
                            (fault_valid[commit_slot] ||
                                write_done[commit_slot] ||
                                (confirm_match && confirm_lsq_tag == commit_lsq_tag_i[
                                    i*LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] &&
                                    cache_store_confirm_rob_tag_i == commit_rob_tag_i[
                                    i*ROB_TAG_WIDTH +: ROB_TAG_WIDTH]) ||
                                ((FAST_RETURN == 0 || BE_WIDTH == 1) && POSTED_STORES != 0 && request_fire &&
                                    request_write && !request_mmio &&
                                    cache_request_irrevocable_i &&
                                    request_lsq_tag == commit_lsq_tag_i[
                                        i*LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] &&
                                    request_rob_tag == commit_rob_tag_i[
                                        i*ROB_TAG_WIDTH +: ROB_TAG_WIDTH]) ||
                                ((FAST_RETURN == 0 || BE_WIDTH == 1) && response_fire && inflight_write &&
                                    !pending_posted[response_slot] && !inflight_mmio && !inflight_discard &&
                                    inflight_match && !cache_response_error_i &&
                                    inflight_slot == commit_slot) ||
                                (late_error[commit_slot] &&
                                    commit_exception_valid_i[i]));
                    end
                end
            end
        end
    end

    genvar rank_entry, rank_other;
    generate
        for (rank_entry = 0; rank_entry < LSQ_ENTRIES; rank_entry = rank_entry + 1) begin: rank_ready
            assign source_eligible[rank_entry] = busy[rank_entry] &&
                ((!report_sent[rank_entry] && address_valid[rank_entry] &&
                    (is_store[rank_entry] ? (data_valid[rank_entry] || fault_valid[rank_entry]) :
                        (fault_valid[rank_entry] || data_valid[rank_entry] || (!started[rank_entry] &&
                            !load_blocked[rank_entry] && forwarding_mask[rank_entry] != 0)))) ||
                    (is_store[rank_entry] && late_error[rank_entry] && !late_error_sent[rank_entry]));
            assign request_eligible[rank_entry] = busy[rank_entry] && !is_store[rank_entry] &&
                address_valid[rank_entry] && !fault_valid[rank_entry] &&
                !report_sent[rank_entry] && !started[rank_entry] &&
                !data_valid[rank_entry] && !load_blocked[rank_entry] && forwarding_mask[rank_entry] == 0;
            assign prepare_eligible[rank_entry] = busy[rank_entry] && is_store[rank_entry] &&
                !write_requested[rank_entry];
            for (rank_other = 0; rank_other < LSQ_ENTRIES; rank_other = rank_other + 1) begin: compare_age
                assign older_entry[rank_entry][rank_other] =
                    entry_distance[rank_other] < entry_distance[rank_entry] ||
                    (entry_distance[rank_other] == entry_distance[rank_entry] && rank_other < rank_entry);
            end
            assign source_selected[rank_entry] = source_eligible[rank_entry] &&
                !(|(older_entry[rank_entry] & source_eligible));
            assign request_selected[rank_entry] = request_eligible[rank_entry] &&
                !(|(older_entry[rank_entry] & request_eligible));
            assign prepare_selected[rank_entry] = prepare_eligible[rank_entry] &&
                !(|(older_entry[rank_entry] & prepare_eligible));
        end
    endgenerate

    genvar forward_store, forward_newer, forward_load, forward_byte;
    generate
        for (forward_store = 0; forward_store < LSQ_ENTRIES;
                forward_store = forward_store + 1) begin: forward_store_data
            assign aligned_store_data[forward_store] =
                align_store_word(store_data[forward_store], address[forward_store][1:0]);
            assign store_byte_mask[forward_store] = access_mask(
                width[forward_store], address[forward_store][1:0]);
            assign unknown_store_mask[forward_store] = !address_valid[forward_store];
            for (forward_newer = 0; forward_newer < LSQ_ENTRIES;
                    forward_newer = forward_newer + 1) begin: compare_store_age
                assign newer_store_mask[forward_store][forward_newer] =
                    entry_distance[forward_newer] > entry_distance[forward_store] ||
                    (entry_distance[forward_newer] == entry_distance[forward_store] &&
                        forward_newer < forward_store);
            end
        end
        for (forward_load = 0; forward_load <= LSQ_ENTRIES;
                forward_load = forward_load + 1) begin: forward_load_data
            wire [31:0] lookup_address;
            wire [`RV32_MEMORY_WIDTH-1:0] lookup_width;
            wire [LSQ_ENTRIES-1:0] older;
            wire lookup_enable;
            wire [3:0] wanted;
            wire [3:0] covered;
            wire [3:0] missing;
            wire [31:0] word_value;
            if (forward_load == LSQ_ENTRIES) begin: incoming
                assign lookup_address = load_address_i;
                assign lookup_width = width[load_slot];
                assign older = older_store_mask[load_slot];
                assign lookup_enable = FAST_RETURN != 0 && load_match &&
                    !address_fault(load_address_i, width[load_slot], 1'b0);
            end else begin: resident
                assign lookup_address = address[forward_load];
                assign lookup_width = width[forward_load];
                assign older = older_store_mask[forward_load];
                assign lookup_enable = busy[forward_load] && !is_store[forward_load] &&
                    address_valid[forward_load] && !fault_valid[forward_load];
            end
            assign wanted = access_mask(lookup_width, lookup_address[1:0]);
            assign forward_wanted[forward_load] = wanted;
            for (forward_byte = 0; forward_byte < 4;
                    forward_byte = forward_byte + 1) begin: select_byte
                wire [LSQ_ENTRIES-1:0] eligible;
                wire [LSQ_ENTRIES-1:0] selected;
                wire [LSQ_ENTRIES-1:0] unready;
                wire [7:0] value_tree [1:2*LSQ_ENTRIES-1];
                for (forward_store = 0; forward_store < LSQ_ENTRIES;
                        forward_store = forward_store + 1) begin: select_store
                    assign eligible[forward_store] = older[forward_store] &&
                        address_valid[forward_store] && !fault_valid[forward_store] &&
                        lookup_address[31:2] == address[forward_store][31:2] &&
                        store_byte_mask[forward_store][forward_byte];
                    assign selected[forward_store] = eligible[forward_store] &&
                        !(|(eligible & newer_store_mask[forward_store]));
                    assign unready[forward_store] = selected[forward_store] &&
                        !data_valid[forward_store];
                    if (forward_load == LSQ_ENTRIES) begin: incoming_value
                        assign value_tree[LSQ_ENTRIES+forward_store] =
                            {8{selected[forward_store] && wanted[forward_byte]}} &
                            aligned_store_data[forward_store][forward_byte*8 +: 8];
                    end else begin: shared_value
                        assign value_tree[LSQ_ENTRIES+forward_store] = 8'd0;
                    end
                end
                for (forward_store = 1; forward_store < LSQ_ENTRIES;
                        forward_store = forward_store + 1) begin: merge_byte
                    assign value_tree[forward_store] = value_tree[2*forward_store] |
                        value_tree[2*forward_store+1];
                end
                assign forward_byte_selected[forward_load][forward_byte] = selected;
                assign covered[forward_byte] = wanted[forward_byte] && (|eligible);
                assign missing[forward_byte] = wanted[forward_byte] && (|unready);
                assign word_value[forward_byte*8 +: 8] = value_tree[1];
            end
            assign parallel_forward_mask[forward_load] = lookup_enable ?
                unalign_mask(covered, lookup_address[1:0]) : 4'd0;
            assign parallel_forward_value[forward_load] = lookup_enable ?
                unalign_word(word_value, lookup_address[1:0]) : 32'd0;
            if (forward_load == LSQ_ENTRIES) begin: incoming_blocked
                assign parallel_load_blocked[forward_load] = !lookup_enable ||
                    (|(older & unknown_store_mask)) || (|missing) ||
                    (covered != 0 && covered != wanted);
            end else begin: resident_blocked
                assign parallel_load_blocked[forward_load] =
                    !address_valid[forward_load] || fault_valid[forward_load] ||
                    (lookup_enable && ((|(older & unknown_store_mask)) ||
                        (|missing) || (covered != 0 && covered != wanted)));
            end
        end
    endgenerate

    genvar shared_byte, shared_store;
    generate
        for (shared_byte = 0; shared_byte < 4; shared_byte = shared_byte + 1) begin: shared_forward_byte
            wire [LSQ_ENTRIES-1:0] selected = forward_byte_selected[selected_forward_slot][shared_byte];
            wire wanted = forward_wanted[selected_forward_slot][shared_byte];
            wire [7:0] tree [1:2*LSQ_ENTRIES-1];
            for (shared_store = 0; shared_store < LSQ_ENTRIES;
                    shared_store = shared_store + 1) begin: select_store
                assign tree[LSQ_ENTRIES+shared_store] =
                    {8{selected[shared_store] && wanted}} &
                    aligned_store_data[shared_store][shared_byte*8 +: 8];
            end
            for (shared_store = 1; shared_store < LSQ_ENTRIES;
                    shared_store = shared_store + 1) begin: merge_store
                assign tree[shared_store] = tree[2*shared_store] | tree[2*shared_store+1];
            end
            assign selected_forward_word[shared_byte*8 +: 8] = tree[1];
        end
    endgenerate

    always @* begin
        incoming_store_conflict = 0;
        for (incoming_store_index = 0; incoming_store_index < LSQ_ENTRIES;
                incoming_store_index = incoming_store_index + 1) begin
            incoming_store_conflict[incoming_store_index] =
                !address_valid[incoming_store_index] || fault_valid[incoming_store_index] ||
                is_mmio_store(address[incoming_store_index], width[incoming_store_index]) ||
                (load_address_i[31:2] == address[incoming_store_index][31:2] &&
                    (incoming_byte_mask & access_mask(width[incoming_store_index],
                        address[incoming_store_index][1:0])) != 0);
        end
        for (incoming_load_index = 0; incoming_load_index < LSQ_ENTRIES;
                incoming_load_index = incoming_load_index + 1) begin
            older_store_mask[incoming_load_index] = 0;
            for (incoming_store_index = 0; incoming_store_index < LSQ_ENTRIES;
                    incoming_store_index = incoming_store_index + 1) begin
                if (busy[incoming_store_index] && is_store[incoming_store_index] &&
                        entry_distance[incoming_store_index] < entry_distance[incoming_load_index])
                    older_store_mask[incoming_load_index][incoming_store_index] = 1'b1;
            end
        end
        incoming_load_blocked = |(older_store_mask[load_slot] & incoming_store_conflict);
    end

    always @* begin
        store_request_candidate = -1;
        store_request_prefix = 1'b1;
        store_request_slot = 0;
        for (store_request_lane = 0; store_request_lane < BE_WIDTH;
                store_request_lane = store_request_lane + 1) begin
            store_request_slot = commit_lsq_tag_i[
                store_request_lane*LSQ_TAG_WIDTH +: LSQ_INDEX_WIDTH];
            if (store_request_prefix && commit_valid_i[store_request_lane] &&
                    commit_lsq_valid_i[store_request_lane] &&
                    !commit_exception_valid_i[store_request_lane] &&
                    is_store_op(commit_op_i[
                        store_request_lane*`RV32_OP_WIDTH +: `RV32_OP_WIDTH]) &&
                    busy[store_request_slot] && is_store[store_request_slot] &&
                    {generation[store_request_slot], store_request_slot} ==
                        commit_lsq_tag_i[store_request_lane*LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] &&
                    rob_tag[store_request_slot] ==
                        commit_rob_tag_i[store_request_lane*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] &&
                    address_valid[store_request_slot] && data_valid[store_request_slot] &&
                    !fault_valid[store_request_slot] && !write_requested[store_request_slot] &&
                    (store_request_lane == 0 || !is_mmio_store(
                        address[store_request_slot], width[store_request_slot])))
                store_request_candidate = store_request_slot;
            // A later store is prepared only when every older lane retires now.
            store_request_prefix = store_request_prefix &&
                commit_fire_i[store_request_lane] &&
                !commit_exception_valid_i[store_request_lane];
        end
    end

    always @* begin
        store_prepare_oldest = -1;
        if (|prepare_selected) begin
            store_prepare_oldest = 0;
            for (store_prepare_index = 0; store_prepare_index < LSQ_ENTRIES;
                    store_prepare_index = store_prepare_index + 1)
                if (prepare_selected[store_prepare_index])
                    store_prepare_oldest = store_prepare_oldest | store_prepare_index;
        end
        store_prepare_candidate = -1;
        if (FAST_RETURN != 0 && store_prepare_oldest >= 0 &&
                address_valid[store_prepare_oldest] && data_valid[store_prepare_oldest] &&
                !fault_valid[store_prepare_oldest] &&
                !is_mmio_store(address[store_prepare_oldest], width[store_prepare_oldest]))
            store_prepare_candidate = store_prepare_oldest;
        selected_store_candidate = store_request_candidate;
        if (selected_store_candidate < 0 && request_candidate < 0 &&
                !incoming_load_request)
            selected_store_candidate = store_prepare_candidate;
    end

    always @* begin
        occupancy_o = 0;
        for (occupancy_index = 0; occupancy_index < LSQ_ENTRIES;
                occupancy_index = occupancy_index + 1)
            if (busy[occupancy_index]) occupancy_o = occupancy_o + 1'b1;
    end

    always @(posedge clk_i) begin
        if (reset_i) begin
            inflight_head <= 0;
            inflight_tail <= 0;
            inflight_count <= 0;
            for (pending_index = 0; pending_index < MAX_INFLIGHT;
                    pending_index = pending_index + 1) begin
                pending_valid[pending_index] <= 1'b0;
                pending_width[pending_index] <= 0;
                pending_unsigned[pending_index] <= 0;
                pending_write[pending_index] <= 1'b0;
                pending_posted[pending_index] <= 1'b0;
                pending_mmio[pending_index] <= 1'b0;
                pending_discard[pending_index] <= 1'b0;
                pending_rob_tag[pending_index] <= 0;
                pending_lsq_tag[pending_index] <= 0;
                pending_address[pending_index] <= 0;
            end
        end else begin
            if (confirm_match)
                pending_posted[confirm_slot] <= 1'b1;
            if (response_fire) pending_valid[response_slot] <= 1'b0;
            if (request_fire) pending_valid[accepted_slot] <= 1'b1;
            case ({request_fire, response_fire})
                2'b10: inflight_count <= inflight_count + 1'b1;
                2'b01: inflight_count <= inflight_count - 1'b1;
                default: inflight_count <= inflight_count;
            endcase
            if (request_fire) begin
                inflight_tail <= (MAX_INFLIGHT == 1) ? 0 :
                    inflight_tail + 1'b1;
                pending_width[accepted_slot] <= width[accepted_lsq_tag[LSQ_INDEX_WIDTH-1:0]];
                pending_unsigned[accepted_slot] <= load_unsigned[accepted_lsq_tag[LSQ_INDEX_WIDTH-1:0]];
                pending_write[accepted_slot] <= cache_request_write_o;
                pending_posted[accepted_slot] <= POSTED_STORES != 0 &&
                    cache_request_write_o && !cache_request_mmio_o && cache_request_irrevocable_i;
                pending_mmio[accepted_slot] <= cache_request_mmio_o;
                pending_discard[accepted_slot] <= 1'b0;
                pending_rob_tag[accepted_slot] <= accepted_rob_tag;
                pending_lsq_tag[accepted_slot] <= accepted_lsq_tag;
                pending_address[accepted_slot] <=
                    direct_payload ? load_address_i :
                    address[request_lsq_tag[LSQ_INDEX_WIDTH-1:0]];
            end
            if (response_fire)
                inflight_head <= (MAX_INFLIGHT == 1) ? 0 :
                    inflight_head + 1'b1;
            // Accepted requests survive flush until their ordered responses drain.
            for (pending_index = 0; pending_index < MAX_INFLIGHT;
                    pending_index = pending_index + 1) begin
                if (flush_i)
                    pending_discard[pending_index] <= 1'b1;
                else if (recover_i)
                    for (pending_lane = 0; pending_lane < RECOVERY_WIDTH;
                            pending_lane = pending_lane + 1)
                        if (rollback_valid_i[pending_lane] &&
                                pending_lsq_tag[pending_index] == rollback_lsq_tag_i[
                                    pending_lane*LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] &&
                                pending_rob_tag[pending_index] == rollback_rob_tag_i[
                                    pending_lane*ROB_TAG_WIDTH +: ROB_TAG_WIDTH])
                            pending_discard[pending_index] <= 1'b1;
            end
        end
    end

    always @(posedge clk_i) begin
        if (reset_i || flush_i) begin
            for (sequential_index = 0; sequential_index < LSQ_ENTRIES;
                    sequential_index = sequential_index + 1) begin
                busy[sequential_index] <= 1'b0;
                generation[sequential_index] <= 0;
                next_generation[sequential_index] <= 0;
                is_store[sequential_index] <= 1'b0;
                rob_tag[sequential_index] <= 0;
                width[sequential_index] <= `RV32_MEMORY_NONE;
                load_unsigned[sequential_index] <= 1'b0;
                address_valid[sequential_index] <= 1'b0;
                address[sequential_index] <= 0;
                data_valid[sequential_index] <= 1'b0;
                store_data[sequential_index] <= 0;
                fault_valid[sequential_index] <= 1'b0;
                fault_cause[sequential_index] <= 0;
                started[sequential_index] <= 1'b0;
                report_sent[sequential_index] <= 1'b0;
                write_requested[sequential_index] <= 1'b0;
                write_done[sequential_index] <= 1'b0;
                late_error[sequential_index] <= 1'b0;
                late_error_sent[sequential_index] <= 1'b0;
            end
            source_valid <= 1'b0;
            source_rob_tag <= 0;
            source_lsq_tag <= 0;
            source_value <= 0;
            source_exception_valid <= 1'b0;
            source_exception_cause <= 0;
            source_exception_tval <= 0;
            request_valid <= 1'b0;
            request_id <= 0;
            request_write <= 1'b0;
            request_rob_tag <= 0;
            request_lsq_tag <= 0;
            request_address <= 0;
            request_write_data <= 0;
            request_byte_enable <= 0;
            request_mmio <= 1'b0;
            request_prepared <= 1'b0;
        end else begin
            if (recover_i) begin
                for (sequential_index = 0; sequential_index < LSQ_ENTRIES;
                        sequential_index = sequential_index + 1) begin
                    for (sequential_lane = 0; sequential_lane < RECOVERY_WIDTH;
                            sequential_lane = sequential_lane + 1) begin
                        if (rollback_valid_i[sequential_lane] &&
                                busy[sequential_index] &&
                                rob_tag[sequential_index] == rollback_rob_tag_i[
                                    sequential_lane*ROB_TAG_WIDTH +:
                                    ROB_TAG_WIDTH] &&
                                {generation[sequential_index],
                                    sequential_index[LSQ_INDEX_WIDTH-1:0]} ==
                                    rollback_lsq_tag_i[
                                        sequential_lane*LSQ_TAG_WIDTH +:
                                        LSQ_TAG_WIDTH]) begin
                            busy[sequential_index] <= 1'b0;
                            if (source_valid && source_lsq_tag ==
                                    {generation[sequential_index],
                                        sequential_index[LSQ_INDEX_WIDTH-1:0]})
                                source_valid <= 1'b0;
                            if (request_valid && request_lsq_tag ==
                                    {generation[sequential_index],
                                        sequential_index[LSQ_INDEX_WIDTH-1:0]})
                                request_valid <= 1'b0;
                        end
                    end
                end
            end else begin
                if (confirm_live)
                    write_done[confirm_lsq_slot] <= 1'b1;
                if (FAST_RETURN != 0 && BE_WIDTH > 1 && POSTED_STORES != 0 &&
                        request_fire && cache_request_write_o &&
                        !cache_request_mmio_o && cache_request_irrevocable_i)
                    write_done[request_lsq_tag[LSQ_INDEX_WIDTH-1:0]] <= 1'b1;
                if (source_valid && completion_ready_i) begin
                    source_valid <= 1'b0;
                    if (busy[source_lsq_tag[LSQ_INDEX_WIDTH-1:0]] &&
                            !is_store[source_lsq_tag[LSQ_INDEX_WIDTH-1:0]] &&
                            {generation[source_lsq_tag[LSQ_INDEX_WIDTH-1:0]],
                                source_lsq_tag[LSQ_INDEX_WIDTH-1:0]} ==
                                source_lsq_tag)
                        busy[source_lsq_tag[LSQ_INDEX_WIDTH-1:0]] <= 1'b0;
                end
                if (request_fire)
                    request_valid <= 1'b0;
                if (TAGGED_RESPONSES != 0 && request_valid &&
                        inflight_count == MAX_INFLIGHT && response_fire && !request_fire)
                    request_id <= response_slot;
                if (cache_response_valid_i && cache_response_ready_o) begin
                    if (!inflight_discard && inflight_match) begin
                        if (inflight_write) begin
                            // A retired write cannot authorize a reused slot.
                            if (!pending_posted[response_slot]) begin
                                if (cache_response_error_i)
                                    late_error[inflight_slot] <= 1'b1;
                                else
                                    write_done[inflight_slot] <= 1'b1;
                            end
                        end else begin
                            source_valid <= !(response_bypass && completion_ready_i);
                            if (response_bypass && completion_ready_i)
                                busy[inflight_slot] <= 1'b0;
                            source_rob_tag <= inflight_rob_tag;
                            source_lsq_tag <= inflight_lsq_tag;
                            raw_value = cache_response_read_data_i >>
                                (inflight_address[1:0]*8);
                            source_value <= cache_response_error_i ? 32'd0 :
                                extend_value(raw_value, width[inflight_slot],
                                    load_unsigned[inflight_slot]);
                            source_exception_valid <= cache_response_error_i;
                            source_exception_cause <= cache_response_error_i ?
                                4'd5 : 4'd0;
                            source_exception_tval <= cache_response_error_i ?
                                inflight_address : 32'd0;
                            report_sent[inflight_slot] <= 1'b1;
                        end
                    end
                end
                // Store acknowledgments do not consume the completion register.
                if (!(response_fire && !inflight_write &&
                        !inflight_discard && inflight_match) &&
                        (!source_valid || completion_ready_i) &&
                        source_candidate >= 0) begin
                    source_valid <= 1'b1;
                    source_rob_tag <= rob_tag[source_candidate];
                    source_lsq_tag <= {generation[source_candidate],
                        source_candidate[LSQ_INDEX_WIDTH-1:0]};
                    source_exception_tval <= address[source_candidate];
                    if (late_error[source_candidate]) begin
                        source_value <= 0;
                        source_exception_valid <= 1'b1;
                        source_exception_cause <= 4'd7;
                        late_error_sent[source_candidate] <= 1'b1;
                    end else begin
                        source_exception_valid <= fault_valid[source_candidate];
                        source_exception_cause <= fault_valid[source_candidate] ?
                            fault_cause[source_candidate] : 4'd0;
                        source_value <= is_store[source_candidate] ||
                            fault_valid[source_candidate] ? 32'd0 :
                            extend_value(data_valid[source_candidate] ? store_data[source_candidate] : selected_forward_value,
                                width[source_candidate],
                                load_unsigned[source_candidate]);
                        report_sent[source_candidate] <= 1'b1;
                    end
                end else if (!(response_fire && !inflight_write &&
                        !inflight_discard && inflight_match) &&
                        (!source_valid || completion_ready_i) &&
                        (fast_store_address || fast_store_data)) begin
                    source_valid <= 1'b1;
                    source_rob_tag <= rob_tag[fast_store_slot];
                    source_lsq_tag <= {generation[fast_store_slot], fast_store_slot};
                    source_value <= 0;
                    source_exception_valid <= 1'b0;
                    source_exception_cause <= 0;
                    source_exception_tval <= fast_store_tval;
                    report_sent[fast_store_slot] <= 1'b1;
                end else if (FAST_RETURN != 0 &&
                        !(response_fire && !inflight_write &&
                            !inflight_discard && inflight_match) &&
                        (!source_valid || completion_ready_i) &&
                        load_address_valid_i && load_address_ready_o &&
                        (lv_capture || (!parallel_load_blocked[LSQ_ENTRIES] &&
                        parallel_forward_mask[LSQ_ENTRIES] != 0))) begin
                    source_valid <= 1'b1;
                    source_rob_tag <= load_address_rob_tag_i;
                    source_lsq_tag <= load_address_lsq_tag_i;
                    source_value <= extend_value(lv_capture ? (lv_lookup_data >> (load_address_i[1:0]*8)) : parallel_forward_value[LSQ_ENTRIES],
                        width[load_slot], load_unsigned[load_slot]);
                    source_exception_valid <= 1'b0;
                    source_exception_cause <= 0;
                    source_exception_tval <= load_address_i;
                    report_sent[load_slot] <= 1'b1;
                end

                if (replace_prepared_store)
                    write_requested[request_lsq_tag[LSQ_INDEX_WIDTH-1:0]] <= 1'b0;
                if ((!request_valid || request_fire || replace_prepared_store) &&
                        !(request_valid && request_mmio) &&
                        !(inflight && inflight_mmio)) begin
                    if (selected_store_candidate >= 0) begin
                        request_valid <= 1'b1;
                        request_prepared <= store_request_candidate < 0;
                        request_id <= free_pending_slot;
                        request_write <= 1'b1;
                        request_rob_tag <= rob_tag[selected_store_candidate];
                        request_lsq_tag <= {generation[selected_store_candidate],
                            selected_store_candidate[LSQ_INDEX_WIDTH-1:0]};
                        request_address <= {address[selected_store_candidate][31:2], 2'b00};
                        request_write_data <= store_data[selected_store_candidate] <<
                            (address[selected_store_candidate][1:0]*8);
                        request_byte_enable <= (4'b1111 >>
                            (4-size_bytes(width[selected_store_candidate]))) <<
                            address[selected_store_candidate][1:0];
                        request_mmio <= is_mmio_store(address[selected_store_candidate],
                            width[selected_store_candidate]);
                        write_requested[selected_store_candidate] <= 1'b1;
                    end else if (request_candidate >= 0) begin
                        request_valid <= 1'b1;
                        request_prepared <= 1'b0;
                        request_id <= free_pending_slot;
                        request_write <= 1'b0;
                        request_rob_tag <= rob_tag[request_candidate];
                        request_lsq_tag <= {generation[request_candidate],
                            request_candidate[LSQ_INDEX_WIDTH-1:0]};
                        request_address <= {address[request_candidate][31:2], 2'b00};
                        request_write_data <= 0;
                        request_byte_enable <= 0;
                        request_mmio <= 1'b0;
                        started[request_candidate] <= 1'b1;
                    end else if (incoming_load_request) begin
                        request_valid <= !(direct_load && request_fire);
                        request_prepared <= 1'b0;
                        request_id <= free_pending_slot;
                        request_write <= 1'b0;
                        request_rob_tag <= load_address_rob_tag_i;
                        request_lsq_tag <= load_address_lsq_tag_i;
                        request_address <= {load_address_i[31:2], 2'b00};
                        request_write_data <= 0;
                        request_byte_enable <= 0;
                        request_mmio <= 1'b0;
                        started[load_slot] <= 1'b1;
                    end
                end

                if (direct_load && request_fire)
                    started[load_slot] <= 1'b1;
                if (lv_capture) begin
                    data_valid[load_slot] <= 1'b1;
                    store_data[load_slot] <= lv_lookup_data >> (load_address_i[1:0]*8);
                end
                if (load_address_valid_i && load_address_ready_o) begin
                    address_valid[load_slot] <= 1'b1;
                    address[load_slot] <= load_address_i;
                    fault_valid[load_slot] <= address_fault(load_address_i,
                        width[load_slot], 1'b0);
                    fault_cause[load_slot] <= address_fault_cause(
                        load_address_i, width[load_slot], 1'b0);
                end
                if (store_address_valid_i && store_address_ready_o) begin
                    address_valid[store_slot] <= 1'b1;
                    address[store_slot] <= store_address_i;
                    fault_valid[store_slot] <= address_fault(store_address_i,
                        width[store_slot], 1'b1);
                    fault_cause[store_slot] <= address_fault_cause(
                        store_address_i, width[store_slot], 1'b1);
                end
                if (store_data_valid_i && store_data_ready_o) begin
                    data_valid[data_slot] <= 1'b1;
                    store_data[data_slot] <= store_data_i;
                end
                for (sequential_lane = 0; sequential_lane < BE_WIDTH;
                        sequential_lane = sequential_lane + 1) begin
                    if (commit_fire_i[sequential_lane] &&
                            commit_lsq_valid_i[sequential_lane]) begin
                        sequential_commit_slot = commit_lsq_tag_i[
                            sequential_lane*LSQ_TAG_WIDTH +: LSQ_INDEX_WIDTH];
                        if (busy[sequential_commit_slot] &&
                                is_store[sequential_commit_slot] &&
                                {generation[sequential_commit_slot],
                                    sequential_commit_slot} ==
                                    commit_lsq_tag_i[
                                        sequential_lane*LSQ_TAG_WIDTH +:
                                        LSQ_TAG_WIDTH] &&
                                rob_tag[sequential_commit_slot] ==
                                    commit_rob_tag_i[
                                    sequential_lane*ROB_TAG_WIDTH +:
                                    ROB_TAG_WIDTH])
                            busy[sequential_commit_slot] <= 1'b0;
                    end
                end
                if (alloc_fire_i && alloc_ready_o) begin
                    for (sequential_lane = 0; sequential_lane < BE_WIDTH;
                            sequential_lane = sequential_lane + 1) begin
                        if (alloc_valid_i[sequential_lane]) begin
                            busy[alloc_slot[sequential_lane]] <= 1'b1;
                            generation[alloc_slot[sequential_lane]] <=
                                next_generation[alloc_slot[sequential_lane]];
                            next_generation[alloc_slot[sequential_lane]] <=
                                next_generation[alloc_slot[sequential_lane]] +
                                1'b1;
                            is_store[alloc_slot[sequential_lane]] <=
                                alloc_store_i[sequential_lane];
                            rob_tag[alloc_slot[sequential_lane]] <=
                                alloc_rob_tag_i[
                                    sequential_lane*ROB_TAG_WIDTH +:
                                    ROB_TAG_WIDTH];
                            width[alloc_slot[sequential_lane]] <=
                                alloc_width_i[
                                    sequential_lane*`RV32_MEMORY_WIDTH +:
                                    `RV32_MEMORY_WIDTH];
                            load_unsigned[alloc_slot[sequential_lane]] <=
                                alloc_unsigned_i[sequential_lane];
                            address_valid[alloc_slot[sequential_lane]] <= 1'b0;
                            data_valid[alloc_slot[sequential_lane]] <= 1'b0;
                            fault_valid[alloc_slot[sequential_lane]] <= 1'b0;
                            started[alloc_slot[sequential_lane]] <= 1'b0;
                            report_sent[alloc_slot[sequential_lane]] <= 1'b0;
                            write_requested[alloc_slot[sequential_lane]] <= 1'b0;
                            write_done[alloc_slot[sequential_lane]] <= 1'b0;
                            late_error[alloc_slot[sequential_lane]] <= 1'b0;
                            late_error_sent[alloc_slot[sequential_lane]] <= 1'b0;
                        end
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (confirm_match && !confirm_live) begin
            $display("ERROR rv32_load_store_queue live confirmation lost its LSQ entry");
            $stop;
        end
        if (!reset_i && FAST_RETURN != 0 && cache_response_valid_i &&
                pending_valid[response_slot] && !inflight_discard &&
                !pending_posted[response_slot] && !inflight_identity_match) begin
            $display("ERROR rv32_load_store_queue live response lost its LSQ entry");
            $stop;
        end
        if (!reset_i && ECHO_ROB_TAG != 0 && cache_response_valid_i &&
                pending_valid[response_slot] &&
                cache_response_rob_tag_i != pending_rob_tag[response_slot]) begin
            $display("ERROR rv32_load_store_queue response ROB tag mismatch");
            $stop;
        end
        if (!reset_i && TAGGED_RESPONSES != 0 && cache_response_valid_i &&
                !pending_valid[response_slot]) begin
            $display("ERROR rv32_load_store_queue unknown response ID");
            $stop;
        end
        if (!reset_i && response_fire && pending_posted[response_slot] &&
                cache_response_error_i) begin
            $display("ERROR rv32_load_store_queue posted store returned an error");
            $stop;
        end
        if (!reset_i && alloc_fire_i && !alloc_ready_o) begin
            $display("ERROR rv32_load_store_queue allocation without ready");
            $finish(1);
        end
        if (!reset_i && !flush_i && !recover_i) begin
            for (assertion_lane = 0; assertion_lane < BE_WIDTH;
                    assertion_lane = assertion_lane + 1) begin
                if (alloc_fire_i && alloc_valid_i[assertion_lane] &&
                        size_bytes(alloc_width_i[
                            assertion_lane*`RV32_MEMORY_WIDTH +:
                            `RV32_MEMORY_WIDTH]) == 0) begin
                    $display("ERROR rv32_load_store_queue invalid access width");
                    $finish(1);
                end
                if (commit_valid_i[assertion_lane] &&
                        is_store_op(commit_op_i[
                            assertion_lane*`RV32_OP_WIDTH +:
                            `RV32_OP_WIDTH])) begin
                    assertion_slot = commit_lsq_tag_i[
                        assertion_lane*LSQ_TAG_WIDTH +: LSQ_INDEX_WIDTH];
                    if (!commit_lsq_valid_i[assertion_lane] ||
                            !busy[assertion_slot] || !is_store[assertion_slot] ||
                            {generation[assertion_slot], assertion_slot} !=
                                commit_lsq_tag_i[
                                    assertion_lane*LSQ_TAG_WIDTH +:
                                    LSQ_TAG_WIDTH] ||
                            rob_tag[assertion_slot] != commit_rob_tag_i[
                                assertion_lane*ROB_TAG_WIDTH +:
                                ROB_TAG_WIDTH]) begin
                        $display("ERROR rv32_load_store_queue missing commit store");
                        $finish(1);
                    end
                end
            end
        end
    end
`endif
endmodule
