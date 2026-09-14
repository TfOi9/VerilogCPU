`timescale 1ns/1ps

module rv32_l1_instruction_cache (
    input  wire clk_i,
    input  wire reset_i,
    input  wire flush_i,
    input  wire request_valid_i,
    output wire request_ready_o,
    input  wire [31:0] request_pc_i,
    output wire response_valid_o,
    input  wire response_ready_i,
    output wire [31:0] response_pc_o,
    output wire [127:0] response_line_o,
    output wire response_error_o,
    output wire memory_request_valid_o,
    input  wire memory_request_ready_i,
    output wire [31:0] memory_request_address_o,
    input  wire memory_response_valid_i,
    output wire memory_response_ready_o,
    input  wire [127:0] memory_response_read_data_i,
    input  wire memory_response_error_i,
    output reg hit_event_o,
    output reg miss_event_o
);
    localparam MODE_RUN = 3'd0;
    localparam MODE_REQUEST = 3'd1;
    localparam MODE_WAIT = 3'd2;
    localparam MODE_DELIVER = 3'd3;
    localparam MODE_REPLAY = 3'd4;

    reg [127:0] line_data [0:63];
    reg [21:0] line_tag [0:63];
    reg line_valid [0:63];

    reg [2:0] mode;
    reg memory_pending;
    reg memory_orphan;
    reg [127:0] refill_line;
    reg refill_error;

    reg s0_valid;
    reg [31:0] s0_pc;
    reg s1_valid;
    reg [31:0] s1_pc;
    reg [127:0] s1_line;
    reg [21:0] s1_tag;
    reg s1_line_valid;
    reg s2_valid;
    reg [31:0] s2_pc;
    reg [127:0] s2_line;
    reg s2_hit;

    reg r_valid;
    reg [31:0] r_pc;
    reg [127:0] r_line;
    reg r_error;
    integer set_index;

    wire r_ready;
    wire s2_ready;
    wire s1_ready;
    wire s0_ready;
    wire s2_miss;
    wire memory_response_fire;

    assign r_ready = !r_valid || response_ready_i;
    assign s2_miss = s2_valid && !s2_hit;
    assign s2_ready = !s2_valid || (s2_hit && r_ready);
    assign s1_ready = !s1_valid || s2_ready;
    assign s0_ready = !s0_valid || s1_ready;

    assign request_ready_o = !reset_i && !flush_i &&
        (mode == MODE_RUN) && !s2_miss && s0_ready;
    assign response_valid_o = !reset_i && !flush_i && r_valid;
    assign response_pc_o = r_pc;
    assign response_line_o = r_line;
    assign response_error_o = r_error;

    assign memory_request_valid_o = !reset_i && !flush_i &&
        (mode == MODE_REQUEST) && !memory_pending;
    assign memory_request_address_o = {s2_pc[31:4], 4'b0000};
    assign memory_response_ready_o = !reset_i && memory_pending;
    assign memory_response_fire = memory_response_valid_i &&
        memory_response_ready_o;

    always @(posedge clk_i) begin
        if (reset_i) begin
            mode <= MODE_RUN;
            memory_pending <= 1'b0;
            memory_orphan <= 1'b0;
            refill_line <= 128'd0;
            refill_error <= 1'b0;
            s0_valid <= 1'b0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            r_valid <= 1'b0;
            s0_pc <= 32'd0;
            s1_pc <= 32'd0;
            s1_line <= 128'd0;
            s1_tag <= 22'd0;
            s1_line_valid <= 1'b0;
            s2_pc <= 32'd0;
            s2_line <= 128'd0;
            s2_hit <= 1'b0;
            r_pc <= 32'd0;
            r_line <= 128'd0;
            r_error <= 1'b0;
            hit_event_o <= 1'b0;
            miss_event_o <= 1'b0;
            for (set_index = 0; set_index < 64;
                    set_index = set_index + 1)
                line_valid[set_index] <= 1'b0;
        end else if (flush_i) begin
            mode <= MODE_RUN;
            s0_valid <= 1'b0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            r_valid <= 1'b0;
            hit_event_o <= 1'b0;
            miss_event_o <= 1'b0;
            if (memory_response_fire) begin
                memory_pending <= 1'b0;
                memory_orphan <= 1'b0;
            end else if (memory_pending) begin
                memory_orphan <= 1'b1;
            end else begin
                memory_orphan <= 1'b0;
            end
        end else begin
            hit_event_o <= 1'b0;
            miss_event_o <= 1'b0;

            if (memory_response_fire) begin
                memory_pending <= 1'b0;
                memory_orphan <= 1'b0;
            end

            if (r_ready) begin
                r_valid <= 1'b0;
                if ((mode == MODE_RUN) && !s2_miss && s2_valid) begin
                    r_valid <= 1'b1;
                    r_pc <= s2_pc;
                    r_line <= s2_line;
                    r_error <= 1'b0;
                end else if ((mode == MODE_DELIVER) && s2_valid) begin
                    r_valid <= 1'b1;
                    r_pc <= s2_pc;
                    r_line <= refill_error ? 128'd0 : refill_line;
                    r_error <= refill_error;
                end
            end

            case (mode)
                MODE_RUN: begin
                    if (s2_miss) begin
                        mode <= MODE_REQUEST;
                    end else begin
                        if (s2_ready) begin
                            s2_valid <= s1_valid;
                            if (s1_valid) begin
                                s2_pc <= s1_pc;
                                s2_line <= s1_line;
                                s2_hit <= s1_line_valid &&
                                    (s1_tag == s1_pc[31:10]);
                                hit_event_o <= s1_line_valid &&
                                    (s1_tag == s1_pc[31:10]);
                                miss_event_o <= !s1_line_valid ||
                                    (s1_tag != s1_pc[31:10]);
                            end
                        end
                        if (s1_ready) begin
                            s1_valid <= s0_valid;
                            if (s0_valid) begin
                                s1_pc <= s0_pc;
                                s1_line <= line_data[s0_pc[9:4]];
                                s1_tag <= line_tag[s0_pc[9:4]];
                                s1_line_valid <= line_valid[s0_pc[9:4]];
                            end
                        end
                        if (s0_ready) begin
                            s0_valid <= request_valid_i && request_ready_o;
                            if (request_valid_i && request_ready_o)
                                s0_pc <= request_pc_i;
                        end
                    end
                end
                MODE_REQUEST: begin
                    if (memory_request_valid_o && memory_request_ready_i) begin
                        memory_pending <= 1'b1;
                        memory_orphan <= 1'b0;
                        mode <= MODE_WAIT;
                    end
                end
                MODE_WAIT: begin
                    if (memory_response_fire && !memory_orphan) begin
                        refill_line <= memory_response_read_data_i;
                        refill_error <= memory_response_error_i;
                        if (!memory_response_error_i) begin
                            line_data[s2_pc[9:4]] <=
                                memory_response_read_data_i;
                            line_tag[s2_pc[9:4]] <= s2_pc[31:10];
                            line_valid[s2_pc[9:4]] <= 1'b1;
                        end
                        mode <= MODE_DELIVER;
                    end
                end
                MODE_DELIVER: begin
                    if (r_ready) begin
                        s2_valid <= 1'b0;
                        mode <= MODE_REPLAY;
                    end
                end
                MODE_REPLAY: begin
                    if (s1_valid) begin
                        s1_line <= line_data[s1_pc[9:4]];
                        s1_tag <= line_tag[s1_pc[9:4]];
                        s1_line_valid <= line_valid[s1_pc[9:4]];
                    end
                    mode <= MODE_RUN;
                end
                default: mode <= MODE_RUN;
            endcase
        end
    end
endmodule
