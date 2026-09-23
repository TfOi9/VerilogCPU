`timescale 1ns/1ps

module rv32_l1_instruction_cache #(
    parameter integer CACHE_SIZE_BYTES = 1024,
    parameter integer NUM_SETS = 64,
    parameter integer NUM_WAYS = 1
) (
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

    localparam MODE_RUN = 3'd0;
    localparam MODE_REQUEST = 3'd1;
    localparam MODE_WAIT = 3'd2;
    localparam MODE_DELIVER = 3'd3;
    localparam MODE_REPLAY = 3'd4;

    reg line_valid [0:NUM_WAYS-1][0:NUM_SETS-1];
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
    reg memory_pending;
    reg memory_orphan;
    reg [127:0] refill_line;
    reg refill_error;

    reg s0_valid;
    reg [31:0] s0_pc;
    reg s1_valid;
    reg [31:0] s1_pc;
    reg s1_way_valid [0:NUM_WAYS-1];
    reg s2_valid;
    reg [31:0] s2_pc;
    reg [127:0] s2_line;
    reg [WAY_WIDTH-1:0] s2_way;
    reg s2_hit;

    reg r_valid;
    reg [31:0] r_pc;
    reg [127:0] r_line;
    reg r_error;

    reg [WAY_WIDTH-1:0] miss_way;
    integer set_index;
    integer way_index;
    integer scan_way;

    reg s1_hit;
    reg s1_invalid_found;
    reg [WAY_WIDTH-1:0] s1_hit_way;
    reg [WAY_WIDTH-1:0] s1_invalid_way;
    reg [WAY_WIDTH-1:0] s1_selected_way;
    reg [127:0] s1_selected_line;
    wire s1_ready;
    wire s0_ready;
    wire s2_miss;
    wire s2_ready;
    wire r_ready;
    wire array_read_enable;
    wire pipeline_read_accept;
    wire refill_install;
    wire memory_response_fire;
    wire [INDEX_WIDTH-1:0] s0_set;
    wire [INDEX_WIDTH-1:0] s1_set;
    wire [INDEX_WIDTH-1:0] s2_set;

    assign s0_set = s0_pc[4 +: INDEX_WIDTH];
    assign s1_set = s1_pc[4 +: INDEX_WIDTH];
    assign s2_set = s2_pc[4 +: INDEX_WIDTH];
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
    assign refill_install = !reset_i && !flush_i &&
        (mode == MODE_WAIT) && memory_response_fire &&
        !memory_response_error_i && !memory_orphan;
    assign pipeline_read_accept = (mode == MODE_RUN) && !s2_miss &&
        s1_ready && s0_valid;
    assign array_read_enable = !reset_i && !flush_i &&
        ((mode == MODE_RUN) ||
        ((mode == MODE_REPLAY) && s1_valid));

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
                    s1_pc[31:INDEX_WIDTH+4]) begin
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
    end

    genvar way_gen;
    generate
        for (way_gen = 0; way_gen < NUM_WAYS;
                way_gen = way_gen + 1) begin : cache_way
            wire refill_this_way;
            wire read_this_way;

            assign refill_this_way = refill_install &&
                (miss_way == way_gen);
            assign read_this_way = array_read_enable;
            assign data_ram_address[way_gen] = refill_this_way ?
                s2_set : (pipeline_read_accept ? s0_set : s1_set);
            assign data_ram_enable[way_gen] = read_this_way ||
                refill_this_way;
            assign data_ram_write[way_gen] = refill_this_way;
            assign data_ram_write_data[way_gen] = memory_response_read_data_i;
            assign tag_ram_enable[way_gen] = read_this_way ||
                refill_this_way;
            assign tag_ram_write[way_gen] = refill_this_way;
            assign tag_ram_write_data[way_gen] =
                s2_pc[31:INDEX_WIDTH+4];

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
            s2_pc <= 32'd0;
            s2_line <= 128'd0;
            s2_way <= {WAY_WIDTH{1'b0}};
            s2_hit <= 1'b0;
            r_pc <= 32'd0;
            r_line <= 128'd0;
            r_error <= 1'b0;
            miss_way <= {WAY_WIDTH{1'b0}};
            hit_event_o <= 1'b0;
            miss_event_o <= 1'b0;
            for (set_index = 0; set_index < NUM_SETS;
                    set_index = set_index + 1)
                replacement_way[set_index] <= {WAY_WIDTH{1'b0}};
            for (way_index = 0; way_index < NUM_WAYS;
                    way_index = way_index + 1) begin
                s1_way_valid[way_index] <= 1'b0;
                for (set_index = 0; set_index < NUM_SETS;
                        set_index = set_index + 1)
                    line_valid[way_index][set_index] <= 1'b0;
            end
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

            if (refill_install) begin
                line_valid[miss_way][s2_set] <= 1'b1;
                if (miss_way == LAST_WAY_INDEX[WAY_WIDTH-1:0])
                    replacement_way[s2_set] <= {WAY_WIDTH{1'b0}};
                else
                    replacement_way[s2_set] <= miss_way + 1'b1;
            end

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
                        miss_way <= s2_way;
                        mode <= MODE_REQUEST;
                    end else begin
                        if (s2_ready) begin
                            s2_valid <= s1_valid;
                            if (s1_valid) begin
                                s2_pc <= s1_pc;
                                s2_line <= s1_selected_line;
                                s2_way <= s1_selected_way;
                                s2_hit <= s1_hit;
                                hit_event_o <= s1_hit;
                                miss_event_o <= !s1_hit;
                            end
                        end
                        if (s1_ready) begin
                            s1_valid <= s0_valid;
                            if (s0_valid) begin
                                s1_pc <= s0_pc;
                                for (way_index = 0; way_index < NUM_WAYS;
                                        way_index = way_index + 1)
                                    s1_way_valid[way_index] <=
                                        line_valid[way_index][s0_set];
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
                    if (s1_valid)
                        for (way_index = 0; way_index < NUM_WAYS;
                                way_index = way_index + 1)
                            s1_way_valid[way_index] <=
                                line_valid[way_index][s1_set];
                    mode <= MODE_RUN;
                end
                default: mode <= MODE_RUN;
            endcase
        end
    end

    initial begin
        if (NUM_SETS < 2 || (NUM_SETS & (NUM_SETS - 1)) != 0 ||
                NUM_WAYS < 1 || CACHE_SIZE_BYTES !=
                NUM_SETS * NUM_WAYS * LINE_BYTES)
            $display("ERROR invalid instruction cache parameters");
    end
endmodule
