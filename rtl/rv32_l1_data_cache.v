`timescale 1ns/1ps

module rv32_l1_data_cache #(
    parameter integer CACHE_SIZE_BYTES = 4096,
    parameter integer NUM_SETS = 256,
    parameter integer NUM_WAYS = 1
) (
    input  wire clk_i,
    input  wire reset_i,
    input  wire request_valid_i,
    output wire request_ready_o,
    input  wire request_write_i,
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
    output wire [31:0] memory_request_address_o,
    output wire [127:0] memory_request_write_data_o,
    output wire [15:0] memory_request_byte_enable_o,
    input  wire memory_response_valid_i,
    output wire memory_response_ready_o,
    input  wire [127:0] memory_response_read_data_i,
    input  wire memory_response_error_i,
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

    reg [2:0] mode;
    reg s0_valid;
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

    reg r_valid;
    reg [31:0] r_data;
    reg r_error;

    reg [INDEX_WIDTH-1:0] miss_index;
    reg [TAG_WIDTH-1:0] miss_tag;
    reg [WAY_WIDTH-1:0] miss_way;
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
    assign r_ready = !r_valid || response_ready_i;
    assign s2_bad_address = s2_address[1:0] != 0 ||
        s2_address > 32'h0ffffffc;
    assign s2_miss = s2_valid && !s2_bad_address && !s2_hit;
    assign s2_ready = !s2_valid ||
        ((mode == RUN) && !s2_miss && r_ready);
    assign s1_can_advance = !s1_valid || s2_ready;
    assign array_read_conflict = store_commit && s0_valid &&
        (s0_set != s2_set);
    assign pipeline_read_accept = (mode == RUN) && !s2_miss &&
        s1_can_advance && s0_valid && !array_read_conflict;
    assign array_read_enable = !reset_i &&
        ((mode == RUN) || ((mode == REPLAY) && s1_valid));
    assign s0_ready = !s0_valid ||
        (s1_can_advance && !array_read_conflict);
    assign request_ready_o = !reset_i && (mode == RUN) &&
        !s2_miss && s0_ready;
    assign response_valid_o = !reset_i && r_valid;
    assign response_read_data_o = r_data;
    assign response_error_o = r_error;

    assign store_commit = (mode == RUN) && s2_valid &&
        !s2_bad_address && s2_hit && s2_write && r_ready;
    assign store_line = merge_word(s2_line, s2_address[3:2],
        s2_write_data, s2_byte_enable);
    assign refill_result = s2_write ?
        merge_word(memory_response_read_data_i, s2_address[3:2],
            s2_write_data, s2_byte_enable) :
        memory_response_read_data_i;

    assign memory_request_valid_o = !reset_i &&
        ((mode == WRITEBACK_REQUEST) || (mode == REFILL_REQUEST));
    assign memory_request_write_o = mode == WRITEBACK_REQUEST;
    assign memory_request_address_o = mode == WRITEBACK_REQUEST ?
        victim_address : miss_line_address;
    assign memory_request_write_data_o = mode == WRITEBACK_REQUEST ?
        victim_line : 128'd0;
    assign memory_request_byte_enable_o = mode == WRITEBACK_REQUEST ?
        16'hffff : 16'd0;
    assign memory_response_ready_o = !reset_i &&
        ((mode == WRITEBACK_WAIT) || (mode == REFILL_WAIT));
    assign memory_response_fire = memory_response_valid_i &&
        memory_response_ready_o;
    assign refill_install = !reset_i && (mode == REFILL_WAIT) &&
        memory_response_fire && !memory_response_error_i;

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

    genvar way_gen;
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
    endgenerate

    always @(posedge clk_i) begin
        if (reset_i) begin
            mode <= RUN;
            s0_valid <= 1'b0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
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
            miss_index <= {INDEX_WIDTH{1'b0}};
            miss_tag <= {TAG_WIDTH{1'b0}};
            miss_way <= {WAY_WIDTH{1'b0}};
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
            hit_event_o <= 1'b0;
            miss_event_o <= 1'b0;

            if (store_commit)
                line_dirty[s2_way][s2_set] <= 1'b1;
            if (refill_install) begin
                line_valid[miss_way][miss_index] <= 1'b1;
                line_dirty[miss_way][miss_index] <= s2_write;
                if (miss_way == LAST_WAY_INDEX[WAY_WIDTH-1:0])
                    replacement_way[miss_index] <= {WAY_WIDTH{1'b0}};
                else
                    replacement_way[miss_index] <= miss_way + 1'b1;
            end

            if (r_ready) begin
                r_valid <= 1'b0;
                if ((mode == RUN) && s2_valid && !s2_miss) begin
                    r_valid <= 1'b1;
                    r_data <= s2_bad_address || s2_write ? 32'd0 :
                        s2_line[s2_address[3:2]*32 +: 32];
                    r_error <= s2_bad_address;
                end else if ((mode == DELIVER) && s2_valid) begin
                    r_valid <= 1'b1;
                    r_data <= miss_data;
                    r_error <= miss_error;
                end
            end

            case (mode)
                RUN: begin
                    if (s2_miss) begin
                        miss_index <= s2_set;
                        miss_tag <= s2_address[31:INDEX_WIDTH+4];
                        miss_way <= s2_way;
                        miss_line_address <=
                            {s2_address[31:4], 4'b0000};
                        victim_address <=
                            {s2_tag, s2_set, 4'b0000};
                        victim_line <= s2_line;
                        mode <= s2_line_valid && s2_line_dirty ?
                            WRITEBACK_REQUEST : REFILL_REQUEST;
                    end else begin
                        if (s2_ready) begin
                            s2_valid <= s1_valid;
                            if (s1_valid) begin
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
                                s0_write <= request_write_i;
                                s0_address <= request_address_i;
                                s0_write_data <= request_write_data_i;
                                s0_byte_enable <= request_byte_enable_i;
                            end
                        end
                    end
                end
                WRITEBACK_REQUEST: begin
                    if (memory_request_valid_o && memory_request_ready_i)
                        mode <= WRITEBACK_WAIT;
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
                    if (memory_request_valid_o && memory_request_ready_i)
                        mode <= REFILL_WAIT;
                end
                REFILL_WAIT: begin
                    if (memory_response_fire) begin
                        miss_error <= memory_response_error_i;
                        miss_data <= memory_response_error_i || s2_write ?
                            32'd0 : memory_response_read_data_i[
                                s2_address[3:2]*32 +: 32];
                        mode <= DELIVER;
                    end
                end
                DELIVER: begin
                    if (r_ready) begin
                        s2_valid <= 1'b0;
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

    initial begin
        if (NUM_SETS < 2 || (NUM_SETS & (NUM_SETS - 1)) != 0 ||
                NUM_WAYS < 1 || CACHE_SIZE_BYTES !=
                NUM_SETS * NUM_WAYS * LINE_BYTES)
            $display("ERROR invalid data cache parameters");
    end
endmodule
