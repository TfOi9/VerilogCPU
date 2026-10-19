`timescale 1ns/1ps

module rv32_l1_data_cache #(
    parameter integer CACHE_SIZE_BYTES = 4096,
    parameter integer ROB_TAG_WIDTH = 7,
    parameter integer NUM_SETS = 256,
    parameter integer NUM_WAYS = 1,
    parameter integer STORE_HINTS = 4,
    parameter integer STORE_DIRECTORY_ENTRIES = 0,
    parameter integer LATE_STORE_CONFIRM = 0,
    parameter integer AUX_RETURNS = 0,
    parameter integer NONBLOCKING = 0,
    parameter integer MSHR_ENTRIES = 1,
    parameter integer HIT_UNDER_MISS = NONBLOCKING,
    parameter integer RESPONSE_QUEUE = NONBLOCKING
) (
    input  wire clk_i,
    input  wire reset_i,
    input  wire request_valid_i,
    output wire request_ready_o,
    output wire request_irrevocable_o,
    output reg store_confirm_valid_o,
    output reg [1:0] store_confirm_id_o,
    output reg [ROB_TAG_WIDTH-1:0] store_confirm_rob_tag_o,
    input wire aux_response_valid_i,
    output wire aux_response_ready_o,
    input wire [1:0] aux_response_id_i,
    input wire [ROB_TAG_WIDTH-1:0] aux_response_rob_tag_i,
    input wire aux_response_error_i,
    input  wire request_write_i,
    input wire [ROB_TAG_WIDTH-1:0] request_rob_tag_i,
    output wire [ROB_TAG_WIDTH-1:0] response_rob_tag_o,
    input wire [1:0] request_id_i,
    output wire [1:0] response_id_o,
    input  wire [31:0] request_address_i,
    input  wire [31:0] request_write_data_i,
    input  wire [3:0] request_byte_enable_i,
    output wire response_valid_o,
    input  wire response_ready_i,
    output wire [31:0] response_read_data_o,
    output wire response_error_o,
    output wire memory_request_valid_o,
    input  wire memory_request_ready_i,
    output wire memory_request_write_o,
    output wire memory_request_id_o,
    output wire [31:0] memory_request_address_o,
    output wire [127:0] memory_request_write_data_o,
    output wire [15:0] memory_request_byte_enable_o,
    input  wire memory_response_valid_i,
    output wire memory_response_ready_o,
    input  wire [127:0] memory_response_read_data_i,
    input  wire memory_response_error_i,
    input wire memory_response_write_i,
    input wire memory_response_id_i,
    output reg hit_event_o,
    output reg miss_event_o
);
    function integer cache_clog2;
        input integer value;
        integer remaining;
        begin
            remaining = value - 1;
            cache_clog2 = 0;
            while (remaining > 0) begin
                remaining = remaining >> 1;
                cache_clog2 = cache_clog2 + 1;
            end
        end
    endfunction

    localparam integer LINE_BYTES = 16;
    localparam integer INDEX_WIDTH = cache_clog2(NUM_SETS);
    localparam integer WAY_WIDTH = (NUM_WAYS > 1) ?
        cache_clog2(NUM_WAYS) : 1;
    localparam integer TAG_WIDTH = 28 - INDEX_WIDTH;
    localparam integer LAST_WAY_INDEX = NUM_WAYS - 1;

    localparam RUN = 3'd0;
    localparam WRITEBACK_REQUEST = 3'd1;
    localparam WRITEBACK_WAIT = 3'd2;
    localparam REFILL_REQUEST = 3'd3;
    localparam REFILL_WAIT = 3'd4;
    localparam DELIVER = 3'd5;
    localparam REPLAY = 3'd6;

    reg line_valid [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg line_dirty [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg [WAY_WIDTH-1:0] replacement_way [0:NUM_SETS-1];
    wire [127:0] data_ram_read [0:NUM_WAYS-1];
    wire [TAG_WIDTH-1:0] tag_ram_read [0:NUM_WAYS-1];
    wire [INDEX_WIDTH-1:0] data_ram_address [0:NUM_WAYS-1];
    wire data_ram_enable [0:NUM_WAYS-1];
    wire data_ram_write [0:NUM_WAYS-1];
    wire [127:0] data_ram_write_data [0:NUM_WAYS-1];
    wire tag_ram_enable [0:NUM_WAYS-1];
    wire tag_ram_write [0:NUM_WAYS-1];
    wire [TAG_WIDTH-1:0] tag_ram_write_data [0:NUM_WAYS-1];

    reg hint_match;
    wire older_conflict;

    reg [ROB_TAG_WIDTH-1:0] s0_rob_tag;
    reg [ROB_TAG_WIDTH-1:0] s1_rob_tag;
    reg [ROB_TAG_WIDTH-1:0] s2_rob_tag;
    reg [ROB_TAG_WIDTH-1:0] r_rob_tag;
    reg [ROB_TAG_WIDTH-1:0] skid_rob_tag;
    reg [ROB_TAG_WIDTH-1:0] miss_rob_tag;
    wire [ROB_TAG_WIDTH-1:0] response_packet_rob_tag;
    reg legacy_miss_active;
    wire miss_active;
    reg [31:2] miss_address;
    reg miss_write;
    reg [31:0] miss_write_data;
    reg [3:0] miss_byte_enable;
    reg [1:0] miss_id;
    reg wb_valid;
    reg wb_sent;
    reg wb_done;
    reg wb_error;
    reg read_sent;
    reg read_done;
    reg read_error;
    reg [127:0] refill_line;
    reg [1:0] s0_id;
    reg [1:0] s1_id;
    reg [1:0] s2_id;
    reg [1:0] r_id;
    wire pipeline_run;
    wire s1_locked;
    wire miss_complete_event;
    wire miss_all_error;
    wire [127:0] current_refill_line;
    wire [31:2] refill_address;
    wire refill_write;
    wire [31:0] refill_write_data;
    wire [3:0] refill_byte_enable;
    reg [2:0] mode;
    reg s0_valid;
    reg s0_irrevocable;
    reg s1_irrevocable;
    reg s2_irrevocable;
    reg s0_write;
    reg [31:0] s0_address;
    reg [31:0] s0_write_data;
    reg [3:0] s0_byte_enable;
    reg s1_valid;
    reg s1_write;
    reg [31:0] s1_address;
    reg [31:0] s1_write_data;
    reg [3:0] s1_byte_enable;
    reg s1_way_valid [0:NUM_WAYS-1];
    reg s1_way_dirty [0:NUM_WAYS-1];
    reg s1_forward_valid;
    reg [WAY_WIDTH-1:0] s1_forward_way;
    reg [127:0] s1_forward_line;
    reg s2_valid;
    reg s2_write;
    reg [31:0] s2_address;
    reg [31:0] s2_write_data;
    reg [3:0] s2_byte_enable;
    reg [127:0] s2_line;
    reg [TAG_WIDTH-1:0] s2_tag;
    reg s2_line_valid;
    reg s2_line_dirty;
    reg [WAY_WIDTH-1:0] s2_way;
    reg s2_hit;

    reg skid_valid;
    reg [31:0] skid_data;
    reg skid_error;
    reg [1:0] skid_id;
    wire response_push;
    wire cache_response_push;
    wire confirm_hit;
    wire [31:0] response_packet_data;
    wire response_packet_error;
    wire [1:0] response_packet_id;
    reg r_valid;
    reg [31:0] r_data;
    reg r_error;

    reg [INDEX_WIDTH-1:0] legacy_miss_index;
    reg [TAG_WIDTH-1:0] legacy_miss_tag;
    reg [WAY_WIDTH-1:0] legacy_miss_way;
    wire [INDEX_WIDTH-1:0] miss_index;
    wire [TAG_WIDTH-1:0] miss_tag;
    wire [WAY_WIDTH-1:0] miss_way;
    reg [31:0] miss_line_address;
    reg [31:0] victim_address;
    reg [127:0] victim_line;
    reg [31:0] miss_data;
    reg miss_error;

    integer set_index;
    integer way_index;
    integer scan_way;

    reg s1_hit;
    reg s1_invalid_found;
    reg [WAY_WIDTH-1:0] s1_hit_way;
    reg [WAY_WIDTH-1:0] s1_invalid_way;
    reg [WAY_WIDTH-1:0] s1_selected_way;
    reg [127:0] s1_selected_line;
    reg [TAG_WIDTH-1:0] s1_selected_tag;
    reg s1_selected_valid;
    reg s1_selected_dirty;

    wire r_ready;
    wire s2_miss;
    wire s2_ready;
    wire s1_can_advance;
    wire pipeline_read_accept;
    wire array_read_conflict;
    wire array_read_enable;
    wire s0_ready;
    wire store_commit;
    wire [127:0] store_line;
    wire [127:0] refill_result;
    wire refill_install;
    wire memory_response_fire;
    wire s2_bad_address;
    wire [INDEX_WIDTH-1:0] s0_set;
    wire [INDEX_WIDTH-1:0] s1_set;
    wire [INDEX_WIDTH-1:0] s2_set;

    reg [1:0] m_valid;
    reg [27:0] m_line [0:1];
    reg [WAY_WIDTH-1:0] m_way [0:1];
    reg [31:0] m_victim_address [0:1];
    reg [127:0] m_victim_data [0:1];
    reg [1:0] m_wb_valid, m_wb_sent, m_wb_done, m_wb_error;
    reg [1:0] m_read_sent, m_read_done, m_read_error, m_dirty;
    reg [127:0] m_data [0:1];
    reg [2:0] m_count [0:1];
    reg [1:0] m_head [0:1];
    reg [1:0] m_tail [0:1];
    reg [1:0] m_wait_id [0:1][0:3];
    reg [ROB_TAG_WIDTH-1:0] m_wait_tag [0:1][0:3];
    reg [1:0] m_wait_word [0:1][0:3];
    reg m_wait_write [0:1][0:3];
    reg [31:0] m_wait_data [0:1][0:3];
    reg [3:0] m_wait_mask [0:1][0:3];
    reg m_replay;
    reg m_delivery_next;
    reg m_request_locked;
    reg m_locked_slot, m_locked_write;
    reg m_request_valid, m_request_slot, m_request_write;
    reg m_match, m_match_slot, m_free, m_free_slot;
    reg m_s1_locked, m_s1_reserved, m_s2_conflict, m_request_conflict;
    wire [1:0] m_complete;
    wire m_delivery_valid = |m_complete;
    wire m_delivery_slot = m_complete[m_delivery_next] ? m_delivery_next : !m_delivery_next;
    wire m_delivery = MSHR_ENTRIES == 2 && !m_replay && m_delivery_valid && r_ready;
    wire m_join = MSHR_ENTRIES == 2 && s2_miss && m_match &&
        (m_count[m_match_slot] < 4 || (m_delivery && m_delivery_slot == m_match_slot));
    wire m_allocate = MSHR_ENTRIES == 2 && !m_replay && s2_miss &&
        !m_match && !m_s2_conflict && m_free;
    wire m_accept = m_join || m_allocate;
    wire m_accept_slot = m_match ? m_match_slot : m_free_slot;
    wire m_last = m_count[m_delivery_slot] == 1 &&
        !(m_join && m_match_slot == m_delivery_slot);
    wire m_delivery_error = m_wb_error[m_delivery_slot] || m_read_error[m_delivery_slot] ||
        (memory_response_fire && memory_response_id_i == m_delivery_slot && memory_response_error_i);
    wire [127:0] m_delivery_line = memory_response_fire && !memory_response_write_i &&
        memory_response_id_i == m_delivery_slot ? memory_response_read_data_i : m_data[m_delivery_slot];
    wire m_delivery_write = m_wait_write[m_delivery_slot][m_head[m_delivery_slot]];
    wire [1:0] m_delivery_word = m_wait_word[m_delivery_slot][m_head[m_delivery_slot]];
    wire [127:0] m_result = m_delivery_write ? merge_word(m_delivery_line, m_delivery_word,
        m_wait_data[m_delivery_slot][m_head[m_delivery_slot]],
        m_wait_mask[m_delivery_slot][m_head[m_delivery_slot]]) : m_delivery_line;
    wire miss_allocate = MSHR_ENTRIES == 2 ? m_allocate : mode == RUN && s2_miss;
    wire refill_dirty = MSHR_ENTRIES == 2 ? m_dirty[m_delivery_slot] || m_delivery_write : refill_write;
    integer m_scan;
    integer m_index;
    integer m_wait;

    genvar m_gen;
    generate
        for (m_gen = 0; m_gen < 2; m_gen = m_gen + 1) begin: complete_mshr
            assign m_complete[m_gen] = m_valid[m_gen] &&
                (m_read_done[m_gen] || (memory_response_fire && !memory_response_write_i &&
                    memory_response_id_i == m_gen)) &&
                (!m_wb_valid[m_gen] || m_wb_done[m_gen] ||
                    (memory_response_fire && memory_response_write_i && memory_response_id_i == m_gen));
        end
    endgenerate

    always @* begin
        m_match = 1'b0;
        m_match_slot = 1'b0;
        m_free = 1'b0;
        m_free_slot = 1'b0;
        m_s1_locked = 1'b0;
        m_s1_reserved = 1'b0;
        m_s2_conflict = 1'b0;
        m_request_conflict = 1'b0;
        m_request_valid = 1'b0;
        m_request_slot = 1'b0;
        m_request_write = 1'b0;
        for (m_scan = 0; m_scan < 2; m_scan = m_scan + 1) begin
            if (m_valid[m_scan]) begin
                if (m_line[m_scan] == s2_address[31:4]) begin
                    m_match = 1'b1;
                    m_match_slot = m_scan != 0;
                end
                if (m_line[m_scan][INDEX_WIDTH-1:0] == s1_set) begin
                    m_s1_reserved = 1'b1;
                    if (m_line[m_scan] != s1_address[31:4]) m_s1_locked = 1'b1;
                end
                if (m_line[m_scan][INDEX_WIDTH-1:0] == s2_set) m_s2_conflict = 1'b1;
                if (m_line[m_scan][INDEX_WIDTH-1:0] == request_address_i[4 +: INDEX_WIDTH] &&
                        m_line[m_scan] != request_address_i[31:4]) m_request_conflict = 1'b1;
            end else if (!m_free) begin
                m_free = 1'b1;
                m_free_slot = m_scan != 0;
            end
            if (!m_request_valid && m_valid[m_scan] && !m_read_sent[m_scan] &&
                    (!m_wb_valid[m_scan] || m_wb_sent[m_scan])) begin
                m_request_valid = 1'b1;
                m_request_slot = m_scan != 0;
            end
        end
        for (m_scan = 0; m_scan < 2; m_scan = m_scan + 1)
            if (!m_request_valid && m_valid[m_scan] && m_wb_valid[m_scan] && !m_wb_sent[m_scan]) begin
                m_request_valid = 1'b1;
                m_request_slot = m_scan != 0;
                m_request_write = 1'b1;
            end
        if (m_request_locked) begin
            m_request_valid = 1'b1;
            m_request_slot = m_locked_slot;
            m_request_write = m_locked_write;
        end
    end

    assign miss_active = MSHR_ENTRIES == 2 ? |m_valid : legacy_miss_active;
    assign miss_index = MSHR_ENTRIES == 2 ? m_line[m_delivery_slot][INDEX_WIDTH-1:0] : legacy_miss_index;
    assign miss_tag = MSHR_ENTRIES == 2 ? m_line[m_delivery_slot][27:INDEX_WIDTH] : legacy_miss_tag;
    assign miss_way = MSHR_ENTRIES == 2 ? m_way[m_delivery_slot] : legacy_miss_way;

    function [127:0] merge_word;
        input [127:0] old_line;
        input [1:0] word_index;
        input [31:0] write_data;
        input [3:0] byte_enable;
        integer byte_index;
        begin
            merge_word = old_line;
            for (byte_index = 0; byte_index < 4;
                    byte_index = byte_index + 1)
                if (byte_enable[byte_index])
                    merge_word[(word_index*32)+(byte_index*8) +: 8] =
                        write_data[byte_index*8 +: 8];
        end
    endfunction

    assign s0_set = s0_address[4 +: INDEX_WIDTH];
    assign s1_set = s1_address[4 +: INDEX_WIDTH];
    assign s2_set = s2_address[4 +: INDEX_WIDTH];
    assign r_ready = NONBLOCKING != 0 && RESPONSE_QUEUE != 0 ?
        !skid_valid : !r_valid || response_ready_i;
    assign s2_bad_address = s2_address[1:0] != 0 ||
        s2_address > 32'h0ffffffc;
    assign s2_miss = s2_valid && !s2_bad_address && !s2_hit;
    assign pipeline_run = MSHR_ENTRIES == 2 ? !m_replay :
        mode == RUN || (NONBLOCKING != 0 && HIT_UNDER_MISS != 0 && mode != DELIVER && mode != REPLAY);
    assign s1_locked = MSHR_ENTRIES == 2 ? m_s1_locked :
        NONBLOCKING != 0 && miss_active && s1_set == miss_index;
    assign s2_ready = !s2_valid ||
        (pipeline_run && !m_delivery && !s2_miss && r_ready && !refill_install);
    assign s1_can_advance = (!s1_valid || s2_ready) && !s1_locked;
    assign array_read_conflict = store_commit && s0_valid &&
        (s0_set != s2_set) && (NUM_SETS < 4 || s0_set[BANK_BITS-1:0] == s2_set[BANK_BITS-1:0]);
    assign pipeline_read_accept = pipeline_run && !refill_install && !s2_miss &&
        s1_can_advance && s0_valid && !array_read_conflict;
    assign array_read_enable = !reset_i &&
        (MSHR_ENTRIES == 2 ? !refill_install : (pipeline_run && !refill_install) ||
            (((MSHR_ENTRIES == 2 && m_replay) || mode == REPLAY) && s1_valid));
    assign s0_ready = !s0_valid ||
        (s1_can_advance && !array_read_conflict);
    assign request_ready_o = !reset_i && pipeline_run && !refill_install &&
        !s2_miss && s0_ready && !(MSHR_ENTRIES == 2 ? m_request_conflict :
            NONBLOCKING != 0 && miss_active && request_address_i[4 +: INDEX_WIDTH] == miss_index);
    // FIFO ownership protects an accepted hit from younger replacements.
    assign older_conflict =
        (s0_valid && s0_set == request_address_i[4 +: INDEX_WIDTH] &&
            s0_address[31:4] != request_address_i[31:4]) ||
        (s1_valid && s1_set == request_address_i[4 +: INDEX_WIDTH] &&
            s1_address[31:4] != request_address_i[31:4]) ||
        (s2_valid && s2_set == request_address_i[4 +: INDEX_WIDTH] &&
            s2_address[31:4] != request_address_i[31:4]);
    assign request_irrevocable_o = request_ready_o && request_write_i &&
        request_address_i[1:0] == 0 && request_address_i <= 32'h0ffffffc &&
        hint_match && !older_conflict;

    assign cache_response_push = r_ready &&
        (m_delivery || (pipeline_run && !refill_install && s2_valid && !s2_miss) ||
            (mode == DELIVER && (NONBLOCKING != 0 || s2_valid)));
    assign aux_response_ready_o = AUX_RETURNS != 0 && !reset_i &&
        r_ready && !cache_response_push;
    assign response_push = cache_response_push ||
        (AUX_RETURNS != 0 && aux_response_valid_i && aux_response_ready_o);
    assign response_packet_data = !cache_response_push ? 32'd0 : m_delivery ?
        (m_delivery_error || m_delivery_write ? 32'd0 : m_delivery_line[m_delivery_word*32 +: 32]) :
        mode == DELIVER ? miss_data :
        (s2_bad_address || s2_write ? 32'd0 : s2_line[s2_address[3:2]*32 +: 32]);
    assign response_packet_error = !cache_response_push ? aux_response_error_i :
        m_delivery ? m_delivery_error : mode == DELIVER ? miss_error : s2_bad_address;
    assign response_packet_id = !cache_response_push ? aux_response_id_i :
        m_delivery ? m_wait_id[m_delivery_slot][m_head[m_delivery_slot]] :
        mode == DELIVER && NONBLOCKING != 0 ? miss_id : s2_id;
    assign response_valid_o = !reset_i && r_valid;
    assign response_read_data_o = r_data;
    assign response_error_o = r_error;
    assign response_id_o = r_id;
    assign response_rob_tag_o = r_rob_tag;
    assign response_packet_rob_tag = !cache_response_push ? aux_response_rob_tag_i :
        m_delivery ? m_wait_tag[m_delivery_slot][m_head[m_delivery_slot]] :
        mode == DELIVER && NONBLOCKING != 0 ? miss_rob_tag : s2_rob_tag;
    assign confirm_hit = LATE_STORE_CONFIRM != 0 && pipeline_run &&
        !refill_install && !s2_miss && s2_ready && s1_valid && !s1_locked &&
        s1_write && s1_hit && !s1_irrevocable &&
        s1_address[1:0] == 0 && s1_address <= 32'h0ffffffc;

    assign store_commit = pipeline_run && !m_delivery && !refill_install && s2_valid &&
        !s2_bad_address && s2_hit && s2_write && r_ready;
    assign store_line = merge_word(s2_line, s2_address[3:2],
        s2_write_data, s2_byte_enable);
    assign refill_address = MSHR_ENTRIES == 2 ? {m_line[m_delivery_slot], m_delivery_word} :
        NONBLOCKING != 0 ? miss_address : s2_address[31:2];
    assign refill_write = NONBLOCKING != 0 ? miss_write : s2_write;
    assign refill_write_data = NONBLOCKING != 0 ? miss_write_data : s2_write_data;
    assign refill_byte_enable = NONBLOCKING != 0 ? miss_byte_enable : s2_byte_enable;
    assign current_refill_line = NONBLOCKING != 0 ?
        ((memory_response_fire && !memory_response_write_i) ?
            memory_response_read_data_i : refill_line) : memory_response_read_data_i;
    assign refill_result = MSHR_ENTRIES == 2 ? m_result : refill_write ?
        merge_word(current_refill_line, refill_address[3:2],
            refill_write_data, refill_byte_enable) : current_refill_line;

    assign memory_request_valid_o = !reset_i &&
        (MSHR_ENTRIES == 2 ? m_request_valid : (mode == WRITEBACK_REQUEST) || (mode == REFILL_REQUEST));
    assign memory_request_write_o = MSHR_ENTRIES == 2 ? m_request_write : mode == WRITEBACK_REQUEST;
    assign memory_request_id_o = MSHR_ENTRIES == 2 && m_request_slot;
    assign memory_request_address_o = MSHR_ENTRIES == 2 ?
        (m_request_write ? m_victim_address[m_request_slot] : {m_line[m_request_slot], 4'b0000}) :
        mode == WRITEBACK_REQUEST ?
        victim_address : miss_line_address;
    assign memory_request_write_data_o = MSHR_ENTRIES == 2 ?
        (m_request_write ? m_victim_data[m_request_slot] : 128'd0) : mode == WRITEBACK_REQUEST ?
        victim_line : 128'd0;
    assign memory_request_byte_enable_o = MSHR_ENTRIES == 2 ?
        (m_request_write ? 16'hffff : 16'd0) : mode == WRITEBACK_REQUEST ?
        16'hffff : 16'd0;
    assign memory_response_ready_o = !reset_i && (MSHR_ENTRIES == 2 ?
        (m_valid[memory_response_id_i] && (memory_response_write_i ?
            m_wb_sent[memory_response_id_i] && !m_wb_done[memory_response_id_i] :
            m_read_sent[memory_response_id_i] && !m_read_done[memory_response_id_i])) : NONBLOCKING != 0 ?
        (miss_active && (memory_response_write_i ? wb_sent && !wb_done :
            read_sent && !read_done)) :
        ((mode == WRITEBACK_WAIT) || (mode == REFILL_WAIT)));
    assign memory_response_fire = memory_response_valid_i &&
        memory_response_ready_o;
    assign miss_complete_event = NONBLOCKING != 0 && mode == REFILL_WAIT &&
        (read_done || (memory_response_fire && !memory_response_write_i)) &&
        (!wb_valid || wb_done || (memory_response_fire && memory_response_write_i));
    assign miss_all_error = read_error || wb_error ||
        (memory_response_fire && memory_response_error_i);
    assign refill_install = !reset_i && (MSHR_ENTRIES == 2 ?
        m_delivery && m_last && !m_delivery_error : NONBLOCKING != 0 ?
        (miss_complete_event && !miss_all_error) :
        ((mode == REFILL_WAIT) && memory_response_fire && !memory_response_error_i));

    always @* begin
        s1_hit = 1'b0;
        s1_invalid_found = 1'b0;
        s1_hit_way = {WAY_WIDTH{1'b0}};
        s1_invalid_way = {WAY_WIDTH{1'b0}};
        s1_selected_way = {WAY_WIDTH{1'b0}};
        for (scan_way = 0; scan_way < NUM_WAYS;
                scan_way = scan_way + 1) begin
            if (!s1_hit && s1_way_valid[scan_way] &&
                    tag_ram_read[scan_way] ==
                    s1_address[31:INDEX_WIDTH+4]) begin
                s1_hit = 1'b1;
                s1_hit_way = scan_way[WAY_WIDTH-1:0];
            end
            if (!s1_invalid_found && !s1_way_valid[scan_way]) begin
                s1_invalid_found = 1'b1;
                s1_invalid_way = scan_way[WAY_WIDTH-1:0];
            end
        end
        if (MSHR_ENTRIES == 2 && m_s1_reserved) s1_hit = 1'b0;
        if (s1_hit)
            s1_selected_way = s1_hit_way;
        else if (s1_invalid_found)
            s1_selected_way = s1_invalid_way;
        else
            s1_selected_way = replacement_way[s1_set];

        s1_selected_line = data_ram_read[s1_selected_way];
        if (s1_forward_valid &&
                s1_forward_way == s1_selected_way)
            s1_selected_line = s1_forward_line;
        if (store_commit && s1_valid && s1_set == s2_set &&
                s1_selected_way == s2_way)
            s1_selected_line = store_line;
        s1_selected_tag = tag_ram_read[s1_selected_way];
        s1_selected_valid = s1_way_valid[s1_selected_way];
        s1_selected_dirty = s1_way_dirty[s1_selected_way];
        if (s1_forward_valid &&
                s1_forward_way == s1_selected_way)
            s1_selected_dirty = 1'b1;
        if (store_commit && s1_valid && s1_set == s2_set &&
                s1_selected_way == s2_way)
            s1_selected_dirty = 1'b1;
    end

    localparam BANK_BITS = NUM_SETS >= 8 ? 2 : 1;
    localparam BANK_COUNT = 1 << BANK_BITS;
    genvar way_gen, bank_gen;
    generate
        for (way_gen = 0; way_gen < NUM_WAYS;
                way_gen = way_gen + 1) begin : cache_way
            wire store_this_way;
            wire refill_this_way;

            assign store_this_way = store_commit && (s2_way == way_gen);
            assign refill_this_way = refill_install &&
                (miss_way == way_gen);
            assign data_ram_address[way_gen] = refill_this_way ?
                miss_index : (store_this_way ? s2_set :
                (pipeline_read_accept ? s0_set : s1_set));
            assign data_ram_enable[way_gen] = array_read_enable ||
                store_this_way || refill_this_way;
            assign data_ram_write[way_gen] = store_this_way ||
                refill_this_way;
            assign data_ram_write_data[way_gen] = refill_this_way ?
                refill_result : store_line;
            assign tag_ram_enable[way_gen] = array_read_enable ||
                refill_this_way;
            assign tag_ram_write[way_gen] = refill_this_way;
            assign tag_ram_write_data[way_gen] = miss_tag;

            if (NUM_SETS >= 4) begin: banked_arrays
                wire [INDEX_WIDTH-1:0] read_set = pipeline_read_accept ? s0_set : s1_set;
                reg [BANK_BITS-1:0] read_bank;
                wire [127:0] data_read [0:BANK_COUNT-1];
                wire [TAG_WIDTH-1:0] tag_read [0:BANK_COUNT-1];
                always @(posedge clk_i) begin
                    if (reset_i) read_bank <= {BANK_BITS{1'b0}};
                    else if (array_read_enable) read_bank <= read_set[BANK_BITS-1:0];
                end
                assign data_ram_read[way_gen] = data_read[read_bank];
                assign tag_ram_read[way_gen] = tag_read[read_bank];
                for (bank_gen = 0; bank_gen < BANK_COUNT; bank_gen = bank_gen + 1) begin: bank
                    wire write_store = store_this_way && s2_set[BANK_BITS-1:0] == bank_gen;
                    wire write_refill = refill_this_way && miss_index[BANK_BITS-1:0] == bank_gen;
                    wire read_enable = array_read_enable && read_set[BANK_BITS-1:0] == bank_gen;
                    wire [INDEX_WIDTH-BANK_BITS-1:0] data_index = write_refill ?
                        miss_index[INDEX_WIDTH-1:BANK_BITS] : write_store ?
                        s2_set[INDEX_WIDTH-1:BANK_BITS] : read_set[INDEX_WIDTH-1:BANK_BITS];
                    wire [INDEX_WIDTH-BANK_BITS-1:0] tag_index = write_refill ?
                        miss_index[INDEX_WIDTH-1:BANK_BITS] : read_set[INDEX_WIDTH-1:BANK_BITS];
                    sram_fakeram #(.DEPTH(NUM_SETS/BANK_COUNT), .WIDTH(128),
                        .WRITE_GRANULARITY(8)) data_array (
                        .clk(clk_i), .en(read_enable || write_store || write_refill),
                        .we(write_store || write_refill),
                        .wmask((write_store || write_refill) ? 16'hffff : 16'd0),
                        .addr(data_index), .wdata(data_ram_write_data[way_gen]),
                        .rdata(data_read[bank_gen]));
                    sram_fakeram #(.DEPTH(NUM_SETS/BANK_COUNT), .WIDTH(TAG_WIDTH)) tag_array (
                        .clk(clk_i), .en(read_enable || write_refill), .we(write_refill),
                        .wmask(1'b1), .addr(tag_index), .wdata(tag_ram_write_data[way_gen]),
                        .rdata(tag_read[bank_gen]));
                end
            end else begin: single_arrays
            sram_fakeram #(
                .DEPTH(NUM_SETS),
                .WIDTH(128),
                .WRITE_GRANULARITY(8)
            ) data_array (
                .clk(clk_i),
                .en(data_ram_enable[way_gen]),
                .we(data_ram_write[way_gen]),
                .wmask(data_ram_write[way_gen] ? 16'hffff : 16'd0),
                .addr(data_ram_address[way_gen]),
                .wdata(data_ram_write_data[way_gen]),
                .rdata(data_ram_read[way_gen])
            );

            sram_fakeram #(
                .DEPTH(NUM_SETS),
                .WIDTH(TAG_WIDTH)
            ) tag_array (
                .clk(clk_i),
                .en(tag_ram_enable[way_gen]),
                .we(tag_ram_write[way_gen]),
                .wmask(1'b1),
                .addr(data_ram_address[way_gen]),
                .wdata(tag_ram_write_data[way_gen]),
                .rdata(tag_ram_read[way_gen])
            );
            end
        end
    endgenerate

    generate
        if (STORE_DIRECTORY_ENTRIES > 0) begin : store_directory
            localparam integer DIRECTORY_SETS = STORE_DIRECTORY_ENTRIES < NUM_SETS ?
                STORE_DIRECTORY_ENTRIES : NUM_SETS;
            localparam integer DIRECTORY_INDEX_BITS = cache_clog2(DIRECTORY_SETS);
            localparam integer DIRECTORY_INDEX_WIDTH = DIRECTORY_INDEX_BITS > 0 ?
                DIRECTORY_INDEX_BITS : 1;
            localparam integer DIRECTORY_TAG_WIDTH = 28 - DIRECTORY_INDEX_BITS;
            reg valid [0:NUM_WAYS-1][0:DIRECTORY_SETS-1];
            reg [DIRECTORY_TAG_WIDTH-1:0] tag [0:NUM_WAYS-1][0:DIRECTORY_SETS-1];
            wire [DIRECTORY_INDEX_WIDTH-1:0] request_index;
            wire [DIRECTORY_INDEX_WIDTH-1:0] hit_index;
            wire [DIRECTORY_INDEX_WIDTH-1:0] refill_index;
            integer query_way;
            integer reset_way;
            integer reset_index;
            if (DIRECTORY_SETS > 1) begin : indexed
                assign request_index = request_address_i[4 +: DIRECTORY_INDEX_BITS];
                assign hit_index = s2_address[4 +: DIRECTORY_INDEX_BITS];
                assign refill_index = refill_address[4 +: DIRECTORY_INDEX_BITS];
            end else begin : single
                assign request_index = 0;
                assign hit_index = 0;
                assign refill_index = 0;
            end
            // The index and tag together retain every line address bit.
            always @* begin
                hint_match = 1'b0;
                for (query_way = 0; query_way < NUM_WAYS; query_way = query_way + 1)
                    if (valid[query_way][request_index] && tag[query_way][request_index] ==
                            request_address_i[31:4+DIRECTORY_INDEX_BITS])
                        hint_match = 1'b1;
            end
            always @(posedge clk_i) begin
                if (reset_i) begin
                    for (reset_way = 0; reset_way < NUM_WAYS; reset_way = reset_way + 1)
                        for (reset_index = 0; reset_index < DIRECTORY_SETS;
                                reset_index = reset_index + 1)
                            valid[reset_way][reset_index] <= 1'b0;
                end else begin
                    // A replacement revokes only the selected victim way.
                    if (miss_allocate)
                        valid[s2_way][hit_index] <= 1'b0;
                    if (refill_install) begin
                        valid[miss_way][refill_index] <= 1'b1;
                        tag[miss_way][refill_index] <=
                            refill_address[31:4+DIRECTORY_INDEX_BITS];
                    end else if (pipeline_run && s2_valid && !s2_bad_address && s2_hit && r_ready) begin
                        valid[s2_way][hit_index] <= 1'b1;
                        tag[s2_way][hit_index] <= s2_address[31:4+DIRECTORY_INDEX_BITS];
                    end
                end
            end
        end else begin : legacy_hints
            localparam HINT_WIDTH = (STORE_HINTS > 1) ? cache_clog2(STORE_HINTS) : 1;
            localparam integer LAST_HINT_VALUE = STORE_HINTS-1;
            localparam [HINT_WIDTH-1:0] LAST_HINT = LAST_HINT_VALUE[HINT_WIDTH-1:0];
            reg [STORE_HINTS-1:0] hint_valid;
            reg [27:0] hint_line [0:STORE_HINTS-1];
            reg [HINT_WIDTH-1:0] hint_next;
            reg hint_update_match;
            integer hint_index;
            integer hint_update;
            always @* begin
                hint_match = 1'b0;
                hint_update_match = 1'b0;
                for (hint_index = 0; hint_index < STORE_HINTS; hint_index = hint_index + 1) begin
                    if (hint_valid[hint_index] && hint_line[hint_index] == request_address_i[31:4])
                        hint_match = 1'b1;
                    if (hint_valid[hint_index] && hint_line[hint_index] == s2_address[31:4])
                        hint_update_match = 1'b1;
                end
            end
            always @(posedge clk_i) begin
                if (reset_i) begin
                    hint_valid <= 0;
                    hint_next <= 0;
                    for (hint_update = 0; hint_update < STORE_HINTS; hint_update = hint_update + 1)
                        hint_line[hint_update] <= 0;
                end else begin
                    if (miss_allocate)
                        for (hint_update = 0; hint_update < STORE_HINTS; hint_update = hint_update + 1)
                            if (hint_line[hint_update][INDEX_WIDTH-1:0] == s2_set)
                                hint_valid[hint_update] <= 1'b0;
                    if ((pipeline_run && !refill_install && s2_valid && !s2_bad_address && s2_hit && r_ready) ||
                            refill_install) begin
                        if (!hint_update_match || refill_install) begin
                            hint_valid[hint_next] <= 1'b1;
                            hint_line[hint_next] <= refill_install ? refill_address[31:4] : s2_address[31:4];
                            hint_next <= hint_next == LAST_HINT ? {HINT_WIDTH{1'b0}} : hint_next + 1'b1;
                        end
                    end
                end
            end
        end
    endgenerate

    always @(posedge clk_i) begin
        if (reset_i) begin
            store_confirm_valid_o <= 1'b0;
            store_confirm_id_o <= 0;
            store_confirm_rob_tag_o <= 0;
            s0_rob_tag <= 0;
            s1_rob_tag <= 0;
            s2_rob_tag <= 0;
            r_rob_tag <= 0;
            skid_rob_tag <= 0;
            miss_rob_tag <= 0;
            legacy_miss_active <= 1'b0;
            miss_address <= 0;
            miss_write <= 0;
            miss_write_data <= 0;
            miss_byte_enable <= 0;
            miss_id <= 0;
            wb_valid <= 0;
            wb_sent <= 0;
            wb_done <= 0;
            wb_error <= 0;
            read_sent <= 0;
            read_done <= 0;
            read_error <= 0;
            refill_line <= 0;
            s0_id <= 0;
            s1_id <= 0;
            s2_id <= 0;
            r_id <= 0;
            mode <= RUN;
            s0_valid <= 1'b0;
            s0_irrevocable <= 1'b0;
            s1_irrevocable <= 1'b0;
            s2_irrevocable <= 1'b0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            skid_valid <= 1'b0;
            skid_data <= 0;
            skid_error <= 0;
            skid_id <= 0;
            r_valid <= 1'b0;
            s0_write <= 1'b0;
            s0_address <= 32'd0;
            s0_write_data <= 32'd0;
            s0_byte_enable <= 4'd0;
            s1_write <= 1'b0;
            s1_address <= 32'd0;
            s1_write_data <= 32'd0;
            s1_byte_enable <= 4'd0;
            s1_forward_valid <= 1'b0;
            s1_forward_way <= {WAY_WIDTH{1'b0}};
            s1_forward_line <= 128'd0;
            s2_write <= 1'b0;
            s2_address <= 32'd0;
            s2_write_data <= 32'd0;
            s2_byte_enable <= 4'd0;
            s2_line <= 128'd0;
            s2_tag <= {TAG_WIDTH{1'b0}};
            s2_line_valid <= 1'b0;
            s2_line_dirty <= 1'b0;
            s2_way <= {WAY_WIDTH{1'b0}};
            s2_hit <= 1'b0;
            r_data <= 32'd0;
            r_error <= 1'b0;
            legacy_miss_index <= {INDEX_WIDTH{1'b0}};
            legacy_miss_tag <= {TAG_WIDTH{1'b0}};
            legacy_miss_way <= {WAY_WIDTH{1'b0}};
            miss_line_address <= 32'd0;
            victim_address <= 32'd0;
            victim_line <= 128'd0;
            miss_data <= 32'd0;
            miss_error <= 1'b0;
            hit_event_o <= 1'b0;
            miss_event_o <= 1'b0;
            for (set_index = 0; set_index < NUM_SETS;
                    set_index = set_index + 1) begin
                replacement_way[set_index] <= {WAY_WIDTH{1'b0}};
                for (way_index = 0; way_index < NUM_WAYS;
                        way_index = way_index + 1) begin
                    line_valid[way_index][set_index] <= 1'b0;
                    line_dirty[way_index][set_index] <= 1'b0;
                end
            end
            for (way_index = 0; way_index < NUM_WAYS;
                    way_index = way_index + 1) begin
                s1_way_valid[way_index] <= 1'b0;
                s1_way_dirty[way_index] <= 1'b0;
            end
        end else begin
            store_confirm_valid_o <= confirm_hit;
            if (confirm_hit) begin
                store_confirm_id_o <= s1_id;
                store_confirm_rob_tag_o <= s1_rob_tag;
            end
            hit_event_o <= 1'b0;
            miss_event_o <= 1'b0;

            if (store_commit)
                line_dirty[s2_way][s2_set] <= 1'b1;
            if (refill_install) begin
                line_valid[miss_way][miss_index] <= 1'b1;
                line_dirty[miss_way][miss_index] <= refill_dirty;
                if (miss_way == LAST_WAY_INDEX[WAY_WIDTH-1:0])
                    replacement_way[miss_index] <= {WAY_WIDTH{1'b0}};
                else
                    replacement_way[miss_index] <= miss_way + 1'b1;
            end

            if (NONBLOCKING != 0 && RESPONSE_QUEUE != 0) begin
                if (r_valid && response_ready_i) begin
                    r_valid <= skid_valid;
                    if (skid_valid) begin
                        r_data <= skid_data;
                        r_error <= skid_error;
                        r_id <= skid_id;
                        r_rob_tag <= skid_rob_tag;
                    end
                    skid_valid <= 1'b0;
                end
                if (response_push) begin
                    if (r_valid && !response_ready_i) begin
                        skid_valid <= 1'b1;
                        skid_data <= response_packet_data;
                        skid_error <= response_packet_error;
                        skid_id <= response_packet_id;
                        skid_rob_tag <= response_packet_rob_tag;
                    end else begin
                        r_valid <= 1'b1;
                        r_data <= response_packet_data;
                        r_error <= response_packet_error;
                        r_id <= response_packet_id;
                        r_rob_tag <= response_packet_rob_tag;
                    end
                end
            end else if (r_ready) begin
                r_valid <= response_push;
                if (response_push) begin
                    r_data <= response_packet_data;
                    r_error <= response_packet_error;
                    r_id <= response_packet_id;
                    r_rob_tag <= response_packet_rob_tag;
                end
            end

            if (MSHR_ENTRIES == 1 && NONBLOCKING != 0 && memory_response_fire) begin
                if (memory_response_write_i) begin
                    wb_done <= 1'b1;
                    wb_error <= memory_response_error_i;
                    if (!memory_response_error_i && !refill_install)
                        line_dirty[miss_way][miss_index] <= 1'b0;
                end else begin
                    read_done <= 1'b1;
                    read_error <= memory_response_error_i;
                    refill_line <= memory_response_read_data_i;
                end
            end
            if (pipeline_run && !s2_miss && !refill_install) begin
                        if (s2_ready) begin
                            s2_valid <= s1_valid && !s1_locked;
                            if (s1_valid && !s1_locked) begin
                                s2_id <= s1_id;
                                s2_rob_tag <= s1_rob_tag;
                                s2_irrevocable <= s1_irrevocable || confirm_hit;
                                s2_write <= s1_write;
                                s2_address <= s1_address;
                                s2_write_data <= s1_write_data;
                                s2_byte_enable <= s1_byte_enable;
                                s2_line <= s1_selected_line;
                                s2_tag <= s1_selected_tag;
                                s2_line_valid <= s1_selected_valid;
                                s2_line_dirty <= s1_selected_dirty;
                                s2_way <= s1_selected_way;
                                s2_hit <= s1_hit;
                                if (s1_address[1:0] == 0 &&
                                        s1_address <= 32'h0ffffffc) begin
                                    hit_event_o <= s1_hit;
                                    miss_event_o <= !s1_hit;
                                end
                            end
                        end
                        if (s1_can_advance) begin
                            s1_valid <= s0_valid &&
                                !array_read_conflict;
                            if (s0_valid && !array_read_conflict) begin
                                s1_id <= s0_id;
                                s1_rob_tag <= s0_rob_tag;
                                s1_irrevocable <= s0_irrevocable;
                                s1_address <= s0_address;
                                s1_write <= s0_write;
                                s1_write_data <= s0_write_data;
                                s1_byte_enable <= s0_byte_enable;
                                s1_forward_valid <= store_commit &&
                                    (s0_set == s2_set);
                                if (store_commit && s0_set == s2_set) begin
                                    s1_forward_way <= s2_way;
                                    s1_forward_line <= store_line;
                                end
                                for (way_index = 0; way_index < NUM_WAYS;
                                        way_index = way_index + 1) begin
                                    s1_way_valid[way_index] <=
                                        line_valid[way_index][s0_set];
                                    if (store_commit &&
                                            s0_set == s2_set &&
                                            s2_way == way_index[WAY_WIDTH-1:0])
                                        s1_way_dirty[way_index] <= 1'b1;
                                    else
                                        s1_way_dirty[way_index] <=
                                            line_dirty[way_index][s0_set];
                                end
                            end else begin
                                s1_forward_valid <= 1'b0;
                            end
                        end
                        if (s0_ready) begin
                            s0_valid <= request_valid_i && request_ready_o;
                            if (request_valid_i && request_ready_o) begin
                                s0_id <= request_id_i;
                                s0_rob_tag <= request_rob_tag_i;
                                s0_irrevocable <= request_irrevocable_o;
                                s0_write <= request_write_i;
                                s0_address <= request_address_i;
                                s0_write_data <= request_write_data_i;
                                s0_byte_enable <= request_byte_enable_i;
                            end
                        end
            end

            if (MSHR_ENTRIES == 2) begin
                if (m_accept) s2_valid <= 1'b0;
                if (memory_response_fire && memory_response_write_i && !memory_response_error_i &&
                        (!refill_install || memory_response_id_i != m_delivery_slot))
                    line_dirty[m_way[memory_response_id_i]][m_line[memory_response_id_i][INDEX_WIDTH-1:0]] <= 1'b0;
                if (m_replay && s1_valid) begin
                    for (way_index = 0; way_index < NUM_WAYS; way_index = way_index + 1) begin
                        s1_way_valid[way_index] <= line_valid[way_index][s1_set];
                        s1_way_dirty[way_index] <= line_dirty[way_index][s1_set];
                    end
                    s1_forward_valid <= 1'b0;
                end
            end else begin
            case (mode)
                RUN: begin
                    if (s2_miss) begin
                        legacy_miss_index <= s2_set;
                        legacy_miss_tag <= s2_address[31:INDEX_WIDTH+4];
                        legacy_miss_way <= s2_way;
                        miss_line_address <=
                            {s2_address[31:4], 4'b0000};
                        victim_address <=
                            {s2_tag, s2_set, 4'b0000};
                        victim_line <= s2_line;
                        mode <= s2_line_valid && s2_line_dirty ?
                            WRITEBACK_REQUEST : REFILL_REQUEST;
                        legacy_miss_active <= 1'b1;
                        miss_address <= s2_address[31:2];
                        miss_write <= s2_write;
                        miss_write_data <= s2_write_data;
                        miss_byte_enable <= s2_byte_enable;
                        miss_id <= s2_id;
                        miss_rob_tag <= s2_rob_tag;
                        wb_valid <= s2_line_valid && s2_line_dirty;
                        wb_sent <= 1'b0;
                        wb_done <= 1'b0;
                        wb_error <= 1'b0;
                        read_sent <= 1'b0;
                        read_done <= 1'b0;
                        read_error <= 1'b0;
                        if (NONBLOCKING != 0) s2_valid <= 1'b0;
                    end
                end
                WRITEBACK_REQUEST: begin
                    if (memory_request_valid_o && memory_request_ready_i) begin
                        wb_sent <= 1'b1;
                        mode <= NONBLOCKING != 0 ? REFILL_REQUEST : WRITEBACK_WAIT;
                    end
                end
                WRITEBACK_WAIT: begin
                    if (memory_response_fire) begin
                        if (memory_response_error_i) begin
                            miss_data <= 32'd0;
                            miss_error <= 1'b1;
                            mode <= DELIVER;
                        end else begin
                            line_dirty[miss_way][miss_index] <= 1'b0;
                            mode <= REFILL_REQUEST;
                        end
                    end
                end
                REFILL_REQUEST: begin
                    if (memory_request_valid_o && memory_request_ready_i) begin
                        read_sent <= 1'b1;
                        mode <= REFILL_WAIT;
                    end
                end
                REFILL_WAIT: begin
                    if (NONBLOCKING != 0) begin
                        if (miss_complete_event) begin
                            miss_error <= miss_all_error;
                            miss_data <= miss_all_error || miss_write ? 32'd0 :
                                current_refill_line[miss_address[3:2]*32 +: 32];
                            mode <= DELIVER;
                        end
                    end else if (memory_response_fire) begin
                        miss_error <= memory_response_error_i;
                        miss_data <= memory_response_error_i || s2_write ?
                            32'd0 : memory_response_read_data_i[
                                s2_address[3:2]*32 +: 32];
                        mode <= DELIVER;
                    end
                end
                DELIVER: begin
                    if (r_ready) begin
                        if (NONBLOCKING == 0) s2_valid <= 1'b0;
                        legacy_miss_active <= 1'b0;
                        mode <= REPLAY;
                    end
                end
                REPLAY: begin
                    if (s1_valid)
                        for (way_index = 0; way_index < NUM_WAYS;
                                way_index = way_index + 1) begin
                            s1_way_valid[way_index] <=
                                line_valid[way_index][s1_set];
                            s1_way_dirty[way_index] <=
                                line_dirty[way_index][s1_set];
                        end
                    s1_forward_valid <= 1'b0;
                    mode <= RUN;
                end
                default: mode <= RUN;
            endcase
            end
        end
    end

    always @(posedge clk_i) begin
        if (reset_i) begin
            m_valid <= 0;
            m_wb_valid <= 0;
            m_wb_sent <= 0;
            m_wb_done <= 0;
            m_wb_error <= 0;
            m_read_sent <= 0;
            m_read_done <= 0;
            m_read_error <= 0;
            m_dirty <= 0;
            m_replay <= 0;
            m_delivery_next <= 0;
            m_request_locked <= 0;
            m_locked_slot <= 0;
            m_locked_write <= 0;
            for (m_index = 0; m_index < 2; m_index = m_index + 1) begin
                m_line[m_index] <= 0;
                m_way[m_index] <= 0;
                m_victim_address[m_index] <= 0;
                m_victim_data[m_index] <= 0;
                m_data[m_index] <= 0;
                m_count[m_index] <= 0;
                m_head[m_index] <= 0;
                m_tail[m_index] <= 0;
                for (m_wait = 0; m_wait < 4; m_wait = m_wait + 1) begin
                    m_wait_id[m_index][m_wait] <= 0;
                    m_wait_tag[m_index][m_wait] <= 0;
                    m_wait_word[m_index][m_wait] <= 0;
                    m_wait_write[m_index][m_wait] <= 0;
                    m_wait_data[m_index][m_wait] <= 0;
                    m_wait_mask[m_index][m_wait] <= 0;
                end
            end
        end else if (MSHR_ENTRIES == 2) begin
            m_replay <= m_delivery && m_last;
            if (m_delivery) m_delivery_next <= !m_delivery_slot;
            if (memory_request_valid_o && memory_request_ready_i) begin
                m_request_locked <= 1'b0;
                if (m_request_write) m_wb_sent[m_request_slot] <= 1'b1;
                else m_read_sent[m_request_slot] <= 1'b1;
            end else if (memory_request_valid_o && !m_request_locked) begin
                m_request_locked <= 1'b1;
                m_locked_slot <= m_request_slot;
                m_locked_write <= m_request_write;
            end
            if (memory_response_fire) begin
                if (memory_response_write_i) begin
                    m_wb_done[memory_response_id_i] <= 1'b1;
                    m_wb_error[memory_response_id_i] <= memory_response_error_i;
                end else begin
                    m_read_done[memory_response_id_i] <= 1'b1;
                    m_read_error[memory_response_id_i] <= memory_response_error_i;
                    m_data[memory_response_id_i] <= memory_response_read_data_i;
                end
            end
            for (m_index = 0; m_index < 2; m_index = m_index + 1) begin
                if (m_allocate && m_accept_slot == m_index[0]) begin
                    m_valid[m_index] <= 1'b1;
                    m_line[m_index] <= s2_address[31:4];
                    m_way[m_index] <= s2_way;
                    m_victim_address[m_index] <= {s2_tag, s2_set, 4'b0000};
                    m_victim_data[m_index] <= s2_line;
                    m_wb_valid[m_index] <= s2_line_valid && s2_line_dirty;
                    m_wb_sent[m_index] <= 1'b0;
                    m_wb_done[m_index] <= 1'b0;
                    m_wb_error[m_index] <= 1'b0;
                    m_read_sent[m_index] <= 1'b0;
                    m_read_done[m_index] <= 1'b0;
                    m_read_error[m_index] <= 1'b0;
                    m_dirty[m_index] <= 1'b0;
                    m_count[m_index] <= 1;
                    m_head[m_index] <= 0;
                    m_tail[m_index] <= 1;
                    m_wait_id[m_index][0] <= s2_id;
                    m_wait_tag[m_index][0] <= s2_rob_tag;
                    m_wait_word[m_index][0] <= s2_address[3:2];
                    m_wait_write[m_index][0] <= s2_write;
                    m_wait_data[m_index][0] <= s2_write_data;
                    m_wait_mask[m_index][0] <= s2_byte_enable;
                end else begin
                    case ({m_join && m_accept_slot == m_index[0], m_delivery && m_delivery_slot == m_index[0]})
                        2'b10: m_count[m_index] <= m_count[m_index] + 1'b1;
                        2'b01: m_count[m_index] <= m_count[m_index] - 1'b1;
                        default: m_count[m_index] <= m_count[m_index];
                    endcase
                    if (m_join && m_accept_slot == m_index[0]) begin
                        m_tail[m_index] <= m_tail[m_index] + 1'b1;
                        m_wait_id[m_index][m_tail[m_index]] <= s2_id;
                        m_wait_tag[m_index][m_tail[m_index]] <= s2_rob_tag;
                        m_wait_word[m_index][m_tail[m_index]] <= s2_address[3:2];
                        m_wait_write[m_index][m_tail[m_index]] <= s2_write;
                        m_wait_data[m_index][m_tail[m_index]] <= s2_write_data;
                        m_wait_mask[m_index][m_tail[m_index]] <= s2_byte_enable;
                    end
                    if (m_delivery && m_delivery_slot == m_index[0]) begin
                        m_head[m_index] <= m_head[m_index] + 1'b1;
                        m_data[m_index] <= m_result;
                        if (m_delivery_write && !m_delivery_error) m_dirty[m_index] <= 1'b1;
                        if (m_last) m_valid[m_index] <= 1'b0;
                    end
                end
            end
        end
    end

    initial begin
        if ((MSHR_ENTRIES != 1 && MSHR_ENTRIES != 2) ||
                (MSHR_ENTRIES == 2 && (NONBLOCKING == 0 || HIT_UNDER_MISS == 0))) begin
            $display("ERROR invalid data cache MSHR parameters");
            $stop;
        end
        if (STORE_DIRECTORY_ENTRIES < 0 || (STORE_DIRECTORY_ENTRIES > 0 &&
                (STORE_DIRECTORY_ENTRIES & (STORE_DIRECTORY_ENTRIES - 1)) != 0)) begin
            $display("ERROR invalid Store directory parameters");
            $stop;
        end
        if (NUM_SETS < 2 || (NUM_SETS & (NUM_SETS - 1)) != 0 ||
                NUM_WAYS < 1 || CACHE_SIZE_BYTES !=
                NUM_SETS * NUM_WAYS * LINE_BYTES)
            $display("ERROR invalid data cache parameters");
    end
`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (!reset_i && MSHR_ENTRIES == 2) begin
            if (m_valid == 2'b11 && m_line[0][INDEX_WIDTH-1:0] == m_line[1][INDEX_WIDTH-1:0]) begin
                $display("ERROR rv32_l1_data_cache duplicate set reservations");
                $stop;
            end
            if (memory_response_valid_i && !memory_response_ready_o) begin
                $display("ERROR rv32_l1_data_cache unknown or duplicate memory response");
                $stop;
            end
            if (m_accept && s2_irrevocable) begin
                $display("ERROR rv32_l1_data_cache proven Store entered an MSHR");
                $stop;
            end
            if ((m_valid[0] && (m_count[0] == 0 || m_count[0] > 4)) ||
                    (m_valid[1] && (m_count[1] == 0 || m_count[1] > 4))) begin
                $display("ERROR rv32_l1_data_cache invalid MSHR waiter count");
                $stop;
            end
        end
        if (!reset_i && store_confirm_valid_o &&
                (!s2_valid || !s2_write || !s2_hit || s2_bad_address ||
                    s2_id != store_confirm_id_o ||
                    s2_rob_tag != store_confirm_rob_tag_o)) begin
            $display("ERROR rv32_l1_data_cache Store confirmation lost its owner");
            $stop;
        end
        if (!reset_i && pipeline_run && s2_valid && s2_irrevocable &&
                (s2_bad_address || !s2_hit)) begin
            $display("ERROR rv32_l1_data_cache irrevocable store lost its line");
            $display("address=%h id=%0d tag=%h s1=%h s0=%h m_valid=%b lines=%h/%h ways=%0d/%0d",
                s2_address, s2_id, s2_rob_tag, s1_address, s0_address,
                m_valid, m_line[0], m_line[1], m_way[0], m_way[1]);
            $stop;
        end
    end
`endif
endmodule
