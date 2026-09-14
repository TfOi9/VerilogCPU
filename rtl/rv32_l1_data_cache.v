`timescale 1ns/1ps

module rv32_l1_data_cache (
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
    localparam RUN = 3'd0;
    localparam WRITEBACK_REQUEST = 3'd1;
    localparam WRITEBACK_WAIT = 3'd2;
    localparam REFILL_REQUEST = 3'd3;
    localparam REFILL_WAIT = 3'd4;
    localparam DELIVER = 3'd5;
    localparam REPLAY = 3'd6;

    reg [127:0] line_data [0:255];
    reg [19:0] line_tag [0:255];
    reg line_valid [0:255];
    reg line_dirty [0:255];

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
    reg [127:0] s1_line;
    reg [19:0] s1_tag;
    reg s1_line_valid;
    reg s1_line_dirty;
    reg s2_valid;
    reg s2_write;
    reg [31:0] s2_address;
    reg [31:0] s2_write_data;
    reg [3:0] s2_byte_enable;
    reg [127:0] s2_line;
    reg [19:0] s2_tag;
    reg s2_line_valid;
    reg s2_line_dirty;
    reg s2_hit;
    wire s2_bad_address;

    reg r_valid;
    reg [31:0] r_data;
    reg r_error;

    reg [7:0] miss_index;
    reg [19:0] miss_tag;
    reg [31:0] miss_line_address;
    reg [31:0] victim_address;
    reg [127:0] victim_line;
    reg [31:0] miss_data;
    reg miss_error;
    integer index;

    wire r_ready;
    wire s2_miss;
    wire s2_ready;
    wire s1_ready;
    wire s0_ready;
    wire store_commit;
    wire [127:0] store_line;
    wire [127:0] effective_s1_line;
    wire effective_s1_dirty;
    wire [127:0] refill_result;
    wire memory_response_fire;

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

    assign r_ready = !r_valid || response_ready_i;
    assign s2_bad_address = s2_address[1:0] != 0 ||
        s2_address > 32'h000ffffc;
    assign s2_miss = s2_valid && !s2_bad_address && !s2_hit;
    assign s2_ready = !s2_valid ||
        ((mode == RUN) && !s2_miss && r_ready);
    assign s1_ready = !s1_valid || s2_ready;
    assign s0_ready = !s0_valid || s1_ready;
    assign request_ready_o = !reset_i && (mode == RUN) &&
        !s2_miss && s0_ready;
    assign response_valid_o = !reset_i && r_valid;
    assign response_read_data_o = r_data;
    assign response_error_o = r_error;

    assign store_commit = (mode == RUN) && s2_valid &&
        !s2_bad_address && s2_hit && s2_write && r_ready;
    assign store_line = merge_word(s2_line, s2_address[3:2],
        s2_write_data, s2_byte_enable);
    assign effective_s1_line = store_commit &&
        (s2_address[11:4] == s1_address[11:4]) ?
        store_line : s1_line;
    assign effective_s1_dirty = store_commit &&
        (s2_address[11:4] == s1_address[11:4]) ?
        1'b1 : s1_line_dirty;
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

    always @(posedge clk_i) begin
        if (reset_i) begin
            mode <= RUN;
            s0_valid <= 1'b0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            r_valid <= 1'b0;
            s0_write <= 1'b0;
            s0_address <= 0;
            s0_write_data <= 0;
            s0_byte_enable <= 0;
            s1_write <= 1'b0;
            s1_address <= 0;
            s1_write_data <= 0;
            s1_byte_enable <= 0;
            s1_line <= 0;
            s1_tag <= 0;
            s1_line_valid <= 1'b0;
            s1_line_dirty <= 1'b0;
            s2_write <= 1'b0;
            s2_address <= 0;
            s2_write_data <= 0;
            s2_byte_enable <= 0;
            s2_line <= 0;
            s2_tag <= 0;
            s2_line_valid <= 1'b0;
            s2_line_dirty <= 1'b0;
            s2_hit <= 1'b0;
            r_data <= 0;
            r_error <= 1'b0;
            miss_index <= 0;
            miss_tag <= 0;
            miss_line_address <= 0;
            victim_address <= 0;
            victim_line <= 0;
            miss_data <= 0;
            miss_error <= 1'b0;
            hit_event_o <= 1'b0;
            miss_event_o <= 1'b0;
            for (index = 0; index < 256; index = index + 1) begin
                line_valid[index] <= 1'b0;
                line_dirty[index] <= 1'b0;
            end
        end else begin
            hit_event_o <= 1'b0;
            miss_event_o <= 1'b0;

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

            if (store_commit) begin
                line_data[s2_address[11:4]] <= store_line;
                line_dirty[s2_address[11:4]] <= 1'b1;
            end

            case (mode)
                RUN: begin
                    if (s2_miss) begin
                        miss_index <= s2_address[11:4];
                        miss_tag <= s2_address[31:12];
                        miss_line_address <=
                            {s2_address[31:4], 4'b0000};
                        victim_address <=
                            {s2_tag, s2_address[11:4], 4'b0000};
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
                                s2_line <= effective_s1_line;
                                s2_tag <= s1_tag;
                                s2_line_valid <= s1_line_valid;
                                s2_line_dirty <= effective_s1_dirty;
                                s2_hit <= s1_line_valid &&
                                    s1_tag == s1_address[31:12];
                                if (s1_address[1:0] == 0 &&
                                        s1_address <= 32'h000ffffc) begin
                                    hit_event_o <= s1_line_valid &&
                                        s1_tag == s1_address[31:12];
                                    miss_event_o <= !s1_line_valid ||
                                        s1_tag != s1_address[31:12];
                                end
                            end
                        end
                        if (s1_ready) begin
                            s1_valid <= s0_valid;
                            if (s0_valid) begin
                                s1_write <= s0_write;
                                s1_address <= s0_address;
                                s1_write_data <= s0_write_data;
                                s1_byte_enable <= s0_byte_enable;
                                s1_line <= store_commit &&
                                    s2_address[11:4] == s0_address[11:4] ?
                                    store_line : line_data[s0_address[11:4]];
                                s1_tag <= line_tag[s0_address[11:4]];
                                s1_line_valid <=
                                    line_valid[s0_address[11:4]];
                                s1_line_dirty <= store_commit &&
                                    s2_address[11:4] == s0_address[11:4] ?
                                    1'b1 : line_dirty[s0_address[11:4]];
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
                            miss_data <= 0;
                            miss_error <= 1'b1;
                            mode <= DELIVER;
                        end else begin
                            line_dirty[miss_index] <= 1'b0;
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
                        if (!memory_response_error_i) begin
                            line_data[miss_index] <= refill_result;
                            line_tag[miss_index] <= miss_tag;
                            line_valid[miss_index] <= 1'b1;
                            line_dirty[miss_index] <= s2_write;
                        end
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
                    if (s1_valid) begin
                        s1_line <= line_data[s1_address[11:4]];
                        s1_tag <= line_tag[s1_address[11:4]];
                        s1_line_valid <= line_valid[s1_address[11:4]];
                        s1_line_dirty <= line_dirty[s1_address[11:4]];
                    end
                    mode <= RUN;
                end
                default: mode <= RUN;
            endcase
        end
    end
endmodule
