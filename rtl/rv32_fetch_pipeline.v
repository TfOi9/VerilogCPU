`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_fetch_pipeline #(
    parameter FE_WIDTH = 1,
    parameter BE_WIDTH = 1,
    parameter FETCH_QUEUE_ENTRIES = 8,
    parameter FETCH_QUEUE_INDEX_WIDTH = 3,
    parameter FETCH_LINE_BUFFER_ENTRIES = 4,
    parameter FETCH_LINE_BUFFER_SRAM = 0
) (
    input  wire                                         clk_i,
    input  wire                                         reset_i,

    input  wire                                         redirect_valid_i,
    input  wire [31:0]                                  redirect_pc_i,

    output wire                                         icache_flush_o,
    output wire                                         icache_request_valid_o,
    input  wire                                         icache_request_ready_i,
    output wire [31:0]                                  icache_request_pc_o,
    input  wire                                         icache_response_valid_i,
    output wire                                         icache_response_ready_o,
    input  wire [31:0]                                  icache_response_pc_i,
    input  wire [127:0]                                 icache_response_line_i,
    input  wire                                         icache_response_error_i,

    input  wire [BE_WIDTH-1:0]                          predictor_update_valid_i,
    input  wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0]         predictor_update_op_i,
    input  wire [(BE_WIDTH*32)-1:0]                     predictor_update_pc_i,
    input  wire [(BE_WIDTH*32)-1:0]
                                                        predictor_update_predicted_next_pc_i,
    input  wire [(BE_WIDTH*32)-1:0]
                                                        predictor_update_actual_next_pc_i,
    input  wire [BE_WIDTH-1:0]
                                                        predictor_update_actual_taken_i,

    output wire [31:0]                                  conditional_correct_o,
    output wire [31:0]                                  conditional_total_o,
    output wire [31:0]                                  jal_correct_o,
    output wire [31:0]                                  jal_total_o,
    output wire [31:0]                                  jalr_correct_o,
    output wire [31:0]                                  jalr_total_o,
    output wire [31:0]                                  control_correct_o,
    output wire [31:0]                                  control_total_o,

    output wire [FE_WIDTH-1:0]                          fetch_valid_o,
    input  wire [FE_WIDTH-1:0]                          fetch_ready_i,
    output wire [(FE_WIDTH*32)-1:0]                     fetch_pc_o,
    output wire [(FE_WIDTH*32)-1:0]                     fetch_instruction_o,
    output wire [(FE_WIDTH*32)-1:0]                     fetch_predicted_next_pc_o,
    output wire [FE_WIDTH-1:0]                          fetch_error_o,
    output wire [FETCH_QUEUE_INDEX_WIDTH:0]             fetch_occupancy_o
);

    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */

    localparam REQUEST_TRACK_ENTRIES = 4;
    localparam LINE_BUFFER_STORAGE = FETCH_LINE_BUFFER_ENTRIES > 0 ?
        FETCH_LINE_BUFFER_ENTRIES : 1;
    localparam LINE_BUFFER_INDEX_WIDTH = LINE_BUFFER_STORAGE > 1 ?
        address_width_for_count(LINE_BUFFER_STORAGE) : 1;

    localparam LINE_BUFFER_TAG_LOW = LINE_BUFFER_STORAGE > 1 ?
        4 + LINE_BUFFER_INDEX_WIDTH : 4;
    localparam LINE_BUFFER_TAG_WIDTH = 32 - LINE_BUFFER_TAG_LOW;
    // Index bits are implicit; a valid fill initializes every tag bit.
    reg line_buffer_valid [0:LINE_BUFFER_STORAGE-1];
    reg [LINE_BUFFER_TAG_WIDTH-1:0] line_buffer_tag [0:LINE_BUFFER_STORAGE-1];
    reg local_response_valid_reg;
    reg request_blocked_reg;
    reg [31:0] local_response_pc_reg;
    wire [127:0] local_response_line_reg;
    reg [LINE_BUFFER_INDEX_WIDTH-1:0] line_buffer_request_index;
    reg [LINE_BUFFER_INDEX_WIDTH-1:0] line_buffer_response_index;
    integer line_buffer_reset_index;
    wire line_buffer_hit;
    wire local_request_valid;
    wire request_available;
    wire response_valid;
    wire response_ready;
    wire [31:0] response_pc;
    wire [127:0] response_line;
    wire response_error;

    reg [31:0] queue_pc [0:FETCH_QUEUE_ENTRIES-1];
    reg [31:0] queue_instruction [0:FETCH_QUEUE_ENTRIES-1];
    reg [31:0] queue_predicted_next_pc [0:FETCH_QUEUE_ENTRIES-1];
    reg queue_error [0:FETCH_QUEUE_ENTRIES-1];
    reg [FETCH_QUEUE_INDEX_WIDTH-1:0] queue_head_reg;
    reg [FETCH_QUEUE_INDEX_WIDTH-1:0] queue_tail_reg;
    reg [FETCH_QUEUE_INDEX_WIDTH:0] queue_occupancy_reg;

    reg [31:0] request_pc [0:REQUEST_TRACK_ENTRIES-1];
    reg [31:0] request_next_pc [0:REQUEST_TRACK_ENTRIES-1];
    reg [1:0] request_head_reg;
    reg [1:0] request_tail_reg;
    reg [2:0] request_count_reg;
    reg [31:0] next_request_pc_reg;
    reg icache_flush_reg;
    reg fault_block_reg;

    reg [FE_WIDTH-1:0] candidate_valid;
    reg [(FE_WIDTH*32)-1:0] candidate_pc;
    reg [(FE_WIDTH*32)-1:0] candidate_instruction;
    wire [(FE_WIDTH*`RV32_OP_WIDTH)-1:0] predecode_op;
    wire [(FE_WIDTH*32)-1:0] predecode_immediate;
    wire [FE_WIDTH-1:0] prediction_valid;
    wire [FE_WIDTH-1:0] prediction_taken;
    wire [(FE_WIDTH*32)-1:0] prediction_next_pc;
    reg [FE_WIDTH-1:0] early_query_valid;
    reg [(FE_WIDTH*32)-1:0] early_query_pc;
    wire [FE_WIDTH-1:0] early_taken;
    wire [(FE_WIDTH*32)-1:0] early_target;
    reg [31:0] next_request_prediction;
    reg early_redirect_found;
    integer early_lane_index;
    integer early_select_index;
    wire [31:0] response_next_pc;
    wire response_path_mismatch;

    reg [FE_WIDTH-1:0] fetch_valid_reg;
    reg [(FE_WIDTH*32)-1:0] fetch_pc_reg;
    reg [(FE_WIDTH*32)-1:0] fetch_instruction_reg;
    reg [(FE_WIDTH*32)-1:0] fetch_predicted_next_pc_reg;
    reg [FE_WIDTH-1:0] fetch_error_reg;

    reg [31:0] enqueue_pc [0:FE_WIDTH-1];
    reg [31:0] enqueue_instruction [0:FE_WIDTH-1];
    reg [31:0] enqueue_predicted_next_pc [0:FE_WIDTH-1];
    reg enqueue_error [0:FE_WIDTH-1];

    integer candidate_lane_index;
    integer output_lane_index;
    integer enqueue_lane_index;
    integer sequential_lane_index;
    integer assertion_lane_index;
    integer candidate_count;
    integer enqueue_count;
    integer dequeue_count;
    integer available_count;
    reg redirect_found;
    reg predicted_redirect;
    reg [31:0] predicted_redirect_pc;
    reg response_matches_head;
    reg response_enqueue_fire;
    reg request_fire;
    reg request_pop_fire;

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

    function integer words_from_offset;
        input [1:0] word_offset;
        integer words_left;
        begin
            words_left = 4 - word_offset;
            if (words_left > FE_WIDTH)
                words_from_offset = FE_WIDTH;
            else
                words_from_offset = words_left;
        end
    endfunction

    function [FETCH_QUEUE_INDEX_WIDTH-1:0] queue_index_add;
        input [FETCH_QUEUE_INDEX_WIDTH-1:0] base;
        input integer offset;
        integer sum;
        begin
            sum = base + offset;
            if (sum >= FETCH_QUEUE_ENTRIES)
                sum = sum - FETCH_QUEUE_ENTRIES;
            queue_index_add = sum;
        end
    endfunction

    genvar decoder_lane;
    generate
        for (decoder_lane = 0; decoder_lane < FE_WIDTH;
                decoder_lane = decoder_lane + 1) begin : generate_predecode
            /* verilator lint_off PINCONNECTEMPTY */
            rv32im_decoder decoder (
                .instruction_i(candidate_instruction[
                    decoder_lane*32 +: 32]),
                .legal_o(),
                .op_o(predecode_op[
                    decoder_lane*`RV32_OP_WIDTH +: `RV32_OP_WIDTH]),
                .class_o(),
                .rd_o(),
                .rs1_o(),
                .rs2_o(),
                .uses_rs1_o(),
                .uses_rs2_o(),
                .writes_rd_o(),
                .immediate_o(predecode_immediate[
                    decoder_lane*32 +: 32]),
                .memory_width_o(),
                .load_unsigned_o(),
                .serialize_o()
            );
            /* verilator lint_on PINCONNECTEMPTY */
        end
    endgenerate

    /* verilator lint_off PINCONNECTEMPTY */
    rv32_branch_predictor #(
        .FE_WIDTH(FE_WIDTH),
        .BE_WIDTH(BE_WIDTH)
    ) predictor (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .query_valid_i(candidate_valid),
        .query_op_i(predecode_op),
        .query_pc_i(candidate_pc),
        .query_immediate_i(predecode_immediate),
        .prediction_valid_o(prediction_valid),
        .prediction_taken_o(prediction_taken),
        .prediction_btb_hit_o(),
        .prediction_next_pc_o(prediction_next_pc),
        .early_query_valid_i(early_query_valid),
        .early_query_pc_i(early_query_pc),
        .early_taken_o(early_taken),
        .early_target_o(early_target),
        .update_valid_i(predictor_update_valid_i),
        .update_op_i(predictor_update_op_i),
        .update_pc_i(predictor_update_pc_i),
        .update_predicted_next_pc_i(
            predictor_update_predicted_next_pc_i),
        .update_actual_next_pc_i(predictor_update_actual_next_pc_i),
        .update_actual_taken_i(predictor_update_actual_taken_i),
        .conditional_correct_o(conditional_correct_o),
        .conditional_total_o(conditional_total_o),
        .jal_correct_o(jal_correct_o),
        .jal_total_o(jal_total_o),
        .jalr_correct_o(jalr_correct_o),
        .jalr_total_o(jalr_total_o),
        .control_correct_o(control_correct_o),
        .control_total_o(control_total_o)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    always @* begin
        early_query_valid = 0;
        early_query_pc = 0;
        for (early_lane_index = 0; early_lane_index < FE_WIDTH;
                early_lane_index = early_lane_index + 1) begin
            early_query_valid[early_lane_index] =
                early_lane_index < words_from_offset(next_request_pc_reg[3:2]);
            early_query_pc[early_lane_index*32 +: 32] =
                next_request_pc_reg + early_lane_index*4;
        end
    end

    always @* begin
        next_request_prediction = next_request_pc_reg +
            words_from_offset(next_request_pc_reg[3:2])*4;
        early_redirect_found = 1'b0;
        for (early_select_index = 0; early_select_index < FE_WIDTH;
                early_select_index = early_select_index + 1) begin
            if (!early_redirect_found && early_taken[early_select_index]) begin
                early_redirect_found = 1'b1;
                next_request_prediction = early_target[early_select_index*32 +: 32];
            end
        end
    end

    always @* begin
        line_buffer_request_index = (next_request_pc_reg >> 4) &
            (LINE_BUFFER_STORAGE - 1);
        line_buffer_response_index = (icache_response_pc_i >> 4) &
            (LINE_BUFFER_STORAGE - 1);
    end

    wire line_buffer_fill = response_enqueue_fire && !local_response_valid_reg &&
        !response_error && FETCH_LINE_BUFFER_ENTRIES != 0;
    generate
        if (FETCH_LINE_BUFFER_SRAM != 0 && FETCH_LINE_BUFFER_ENTRIES != 0) begin: line_buffer_sram
            wire [LINE_BUFFER_INDEX_WIDTH-1:0] held_index =
                (local_response_pc_reg >> 4) & (LINE_BUFFER_STORAGE - 1);
            wire [LINE_BUFFER_INDEX_WIDTH-1:0] ram_index = line_buffer_fill ?
                line_buffer_response_index : local_request_valid ? line_buffer_request_index : held_index;
            sram_fakeram #(.DEPTH(LINE_BUFFER_STORAGE), .WIDTH(128)) data_array (
                .clk(clk_i), .en(!reset_i && (line_buffer_fill || local_request_valid || local_response_valid_reg)),
                .we(line_buffer_fill), .wmask(1'b1), .addr(ram_index),
                .wdata(response_line), .rdata(local_response_line_reg));
        end else begin: line_buffer_registers
            reg [127:0] data [0:LINE_BUFFER_STORAGE-1];
            reg [127:0] response_data;
            integer reset_index;
            assign local_response_line_reg = response_data;
            always @(posedge clk_i) begin
                if (reset_i) begin
                    response_data <= 0;
                    for (reset_index = 0; reset_index < LINE_BUFFER_STORAGE; reset_index = reset_index + 1)
                        data[reset_index] <= 0;
                end else begin
                    if (line_buffer_fill) data[line_buffer_response_index] <= response_line;
                    if (local_request_valid) response_data <= data[line_buffer_request_index];
                end
            end
        end
    endgenerate
    assign line_buffer_hit = FETCH_LINE_BUFFER_ENTRIES != 0 &&
        line_buffer_valid[line_buffer_request_index] &&
        line_buffer_tag[line_buffer_request_index] == next_request_pc_reg[31:LINE_BUFFER_TAG_LOW];
    assign local_request_valid = request_available && !request_blocked_reg &&
        line_buffer_hit && !(FETCH_LINE_BUFFER_SRAM != 0 && line_buffer_fill) &&
        ((request_count_reg == 0) ||
            ((request_count_reg == 1) && local_response_valid_reg &&
                response_enqueue_fire));
    assign response_valid = local_response_valid_reg || icache_response_valid_i;
    assign response_pc = local_response_valid_reg ?
        local_response_pc_reg : icache_response_pc_i;
    assign response_line = local_response_valid_reg ?
        local_response_line_reg : icache_response_line_i;
    assign response_error = !local_response_valid_reg && icache_response_error_i;
    assign response_next_pc = predicted_redirect ? predicted_redirect_pc :
        response_pc + candidate_count*4;
    assign response_path_mismatch = response_next_pc != request_next_pc[request_head_reg];
    assign icache_flush_o = !reset_i &&
        (redirect_valid_i || icache_flush_reg);
    assign request_available = !reset_i && !redirect_valid_i &&
        !icache_flush_reg && !fault_block_reg &&
        ((request_count_reg < REQUEST_TRACK_ENTRIES) || request_pop_fire);
    assign icache_request_valid_o = request_available && !local_request_valid &&
        (!local_response_valid_reg || response_enqueue_fire);
    assign icache_request_pc_o = next_request_pc_reg;
    assign response_ready = !reset_i && !redirect_valid_i &&
        !icache_flush_reg && (!response_matches_head ||
            (available_count >= enqueue_count));
    assign icache_response_ready_o = response_ready && !local_response_valid_reg;

    assign fetch_valid_o = fetch_valid_reg;
    assign fetch_pc_o = fetch_pc_reg;
    assign fetch_instruction_o = fetch_instruction_reg;
    assign fetch_predicted_next_pc_o = fetch_predicted_next_pc_reg;
    assign fetch_error_o = fetch_error_reg;
    assign fetch_occupancy_o = reset_i ?
        {(FETCH_QUEUE_INDEX_WIDTH+1){1'b0}} : queue_occupancy_reg;

    initial begin
        if ((FETCH_LINE_BUFFER_ENTRIES != 0) &&
                (FETCH_LINE_BUFFER_ENTRIES != 1) &&
                (FETCH_LINE_BUFFER_ENTRIES != 2) &&
                (FETCH_LINE_BUFFER_ENTRIES != 4) &&
                (FETCH_LINE_BUFFER_ENTRIES != 8) &&
                (FETCH_LINE_BUFFER_ENTRIES != 16) &&
                (FETCH_LINE_BUFFER_ENTRIES != 32) &&
                (FETCH_LINE_BUFFER_ENTRIES != 64)) begin
            $display("ERROR rv32_fetch_pipeline invalid line buffer entries=%0d",
                FETCH_LINE_BUFFER_ENTRIES);
            $finish(1);
        end
        if ((FE_WIDTH != 1) && (FE_WIDTH != 2) && (FE_WIDTH != 4)) begin
            $display("ERROR rv32_fetch_pipeline invalid FE_WIDTH=%0d",
                FE_WIDTH);
            $finish(1);
        end
        if ((BE_WIDTH != 1) && (BE_WIDTH != 2) && (BE_WIDTH != 4)) begin
            $display("ERROR rv32_fetch_pipeline invalid BE_WIDTH=%0d",
                BE_WIDTH);
            $finish(1);
        end
        if ((FETCH_QUEUE_ENTRIES < FE_WIDTH) ||
                ((FETCH_QUEUE_ENTRIES & (FETCH_QUEUE_ENTRIES - 1)) != 0)) begin
            $display("ERROR rv32_fetch_pipeline invalid queue entries=%0d",
                FETCH_QUEUE_ENTRIES);
            $finish(1);
        end
        if (FETCH_QUEUE_INDEX_WIDTH !=
                address_width_for_count(FETCH_QUEUE_ENTRIES)) begin
            $display("ERROR rv32_fetch_pipeline queue index width=%0d expected=%0d",
                FETCH_QUEUE_INDEX_WIDTH,
                address_width_for_count(FETCH_QUEUE_ENTRIES));
            $finish(1);
        end
    end

    always @* begin
        fetch_valid_reg = {FE_WIDTH{1'b0}};
        fetch_pc_reg = {(FE_WIDTH*32){1'b0}};
        fetch_instruction_reg = {(FE_WIDTH*32){1'b0}};
        fetch_predicted_next_pc_reg = {(FE_WIDTH*32){1'b0}};
        fetch_error_reg = {FE_WIDTH{1'b0}};
        dequeue_count = 0;

        for (output_lane_index = 0; output_lane_index < FE_WIDTH;
                output_lane_index = output_lane_index + 1) begin
            if (output_lane_index < queue_occupancy_reg) begin
                fetch_valid_reg[output_lane_index] = !reset_i &&
                    !redirect_valid_i;
                fetch_pc_reg[output_lane_index*32 +: 32] =
                    queue_pc[queue_index_add(queue_head_reg,
                        output_lane_index)];
                fetch_instruction_reg[output_lane_index*32 +: 32] =
                    queue_instruction[queue_index_add(queue_head_reg,
                        output_lane_index)];
                fetch_predicted_next_pc_reg[
                    output_lane_index*32 +: 32] =
                    queue_predicted_next_pc[queue_index_add(queue_head_reg,
                        output_lane_index)];
                fetch_error_reg[output_lane_index] =
                    queue_error[queue_index_add(queue_head_reg,
                        output_lane_index)];
                if ((dequeue_count == output_lane_index) &&
                        fetch_ready_i[output_lane_index] &&
                        !reset_i && !redirect_valid_i)
                    dequeue_count = dequeue_count + 1;
            end
        end
    end

    always @* begin
        response_matches_head = (request_count_reg != 0) &&
            (response_pc == request_pc[request_head_reg]);

        candidate_valid = {FE_WIDTH{1'b0}};
        candidate_pc = {(FE_WIDTH*32){1'b0}};
        candidate_instruction = {(FE_WIDTH*32){1'b0}};
        candidate_count = words_from_offset(response_pc[3:2]);

        for (candidate_lane_index = 0;
                candidate_lane_index < FE_WIDTH;
                candidate_lane_index = candidate_lane_index + 1) begin
            if (response_valid && response_matches_head &&
                    !response_error &&
                    (candidate_lane_index < candidate_count)) begin
                candidate_valid[candidate_lane_index] = 1'b1;
                candidate_pc[candidate_lane_index*32 +: 32] =
                    response_pc + candidate_lane_index*4;
                candidate_instruction[candidate_lane_index*32 +: 32] =
                    response_line[
                        (response_pc[3:2] +
                            candidate_lane_index)*32 +: 32];
            end
        end
    end

    always @* begin
        enqueue_count = candidate_count;
        redirect_found = 1'b0;
        predicted_redirect = 1'b0;
        predicted_redirect_pc = 32'd0;

        for (enqueue_lane_index = 0;
                enqueue_lane_index < FE_WIDTH;
                enqueue_lane_index = enqueue_lane_index + 1) begin
            enqueue_pc[enqueue_lane_index] =
                candidate_pc[enqueue_lane_index*32 +: 32];
            enqueue_instruction[enqueue_lane_index] =
                candidate_instruction[enqueue_lane_index*32 +: 32];
            enqueue_predicted_next_pc[enqueue_lane_index] =
                (prediction_valid[enqueue_lane_index] &&
                    (prediction_next_pc[enqueue_lane_index*32 +: 2] ==
                        2'b00)) ?
                    prediction_next_pc[enqueue_lane_index*32 +: 32] :
                    candidate_pc[enqueue_lane_index*32 +: 32] + 32'd4;
            enqueue_error[enqueue_lane_index] = 1'b0;

            if (!redirect_found && candidate_valid[enqueue_lane_index] &&
                    prediction_taken[enqueue_lane_index] &&
                    (prediction_next_pc[enqueue_lane_index*32 +: 2] ==
                        2'b00)) begin
                redirect_found = 1'b1;
                predicted_redirect = 1'b1;
                predicted_redirect_pc =
                    prediction_next_pc[enqueue_lane_index*32 +: 32];
                enqueue_count = enqueue_lane_index + 1;
            end
        end

        if (response_error) begin
            enqueue_count = 1;
            predicted_redirect = 1'b0;
            predicted_redirect_pc = 32'd0;
            enqueue_pc[0] = response_pc;
            enqueue_instruction[0] = 32'd0;
            enqueue_predicted_next_pc[0] =
                response_pc + 32'd4;
            enqueue_error[0] = 1'b1;
        end

        available_count = FETCH_QUEUE_ENTRIES -
            (queue_occupancy_reg - dequeue_count);
        response_enqueue_fire = response_valid &&
            response_ready && response_matches_head;
        request_pop_fire = response_enqueue_fire;
        request_fire = local_request_valid ||
            (icache_request_valid_o && icache_request_ready_i);
    end

    always @(posedge clk_i) begin
        if (reset_i) begin
            local_response_valid_reg <= 1'b0;
            request_blocked_reg <= 1'b0;
            local_response_pc_reg <= 32'd0;
            for (line_buffer_reset_index = 0;
                    line_buffer_reset_index < LINE_BUFFER_STORAGE;
                    line_buffer_reset_index = line_buffer_reset_index + 1) begin
                line_buffer_valid[line_buffer_reset_index] <= 1'b0;
            end
        end else begin
            if (response_enqueue_fire && !local_response_valid_reg &&
                    !response_error && FETCH_LINE_BUFFER_ENTRIES != 0) begin
                line_buffer_valid[line_buffer_response_index] <= 1'b1;
                line_buffer_tag[line_buffer_response_index] <= response_pc[31:LINE_BUFFER_TAG_LOW];
            end
            if (redirect_valid_i || icache_flush_reg ||
                    (response_enqueue_fire &&
                        (response_path_mismatch || response_error))) begin
                local_response_valid_reg <= 1'b0;
                request_blocked_reg <= 1'b0;
            end else if (local_request_valid) begin
                local_response_valid_reg <= 1'b1;
                local_response_pc_reg <= next_request_pc_reg;
            end else if (response_enqueue_fire) begin
                local_response_valid_reg <= 1'b0;
            end
            if (!redirect_valid_i && !icache_flush_reg &&
                    !(response_enqueue_fire &&
                        (response_path_mismatch || response_error)))
                request_blocked_reg <= icache_request_valid_o &&
                    !icache_request_ready_i;
        end
    end

    always @(posedge clk_i) begin
        if (reset_i) begin
            queue_head_reg <= {FETCH_QUEUE_INDEX_WIDTH{1'b0}};
            queue_tail_reg <= {FETCH_QUEUE_INDEX_WIDTH{1'b0}};
            queue_occupancy_reg <=
                {(FETCH_QUEUE_INDEX_WIDTH+1){1'b0}};
            request_head_reg <= 2'd0;
            request_tail_reg <= 2'd0;
            request_count_reg <= 3'd0;
            next_request_pc_reg <= 32'd0;
            icache_flush_reg <= 1'b0;
            fault_block_reg <= 1'b0;
            for (sequential_lane_index = 0;
                    sequential_lane_index < FETCH_QUEUE_ENTRIES;
                    sequential_lane_index = sequential_lane_index + 1) begin
                queue_pc[sequential_lane_index] <= 32'd0;
                queue_instruction[sequential_lane_index] <= 32'd0;
                queue_predicted_next_pc[sequential_lane_index] <= 32'd0;
                queue_error[sequential_lane_index] <= 1'b0;
            end
            for (sequential_lane_index = 0;
                    sequential_lane_index < REQUEST_TRACK_ENTRIES;
                    sequential_lane_index = sequential_lane_index + 1) begin
                request_pc[sequential_lane_index] <= 32'd0;
                request_next_pc[sequential_lane_index] <= 32'd0;
            end
        end else if (redirect_valid_i) begin
            queue_head_reg <= {FETCH_QUEUE_INDEX_WIDTH{1'b0}};
            queue_tail_reg <= {FETCH_QUEUE_INDEX_WIDTH{1'b0}};
            queue_occupancy_reg <=
                {(FETCH_QUEUE_INDEX_WIDTH+1){1'b0}};
            request_head_reg <= 2'd0;
            request_tail_reg <= 2'd0;
            request_count_reg <= 3'd0;
            next_request_pc_reg <= redirect_pc_i;
            icache_flush_reg <= 1'b0;
            fault_block_reg <= 1'b0;
        end else begin
            icache_flush_reg <= 1'b0;

            if (dequeue_count != 0) begin
                queue_head_reg <= queue_index_add(queue_head_reg,
                    dequeue_count);
            end

            if (response_enqueue_fire) begin
                for (sequential_lane_index = 0;
                        sequential_lane_index < FE_WIDTH;
                        sequential_lane_index = sequential_lane_index + 1) begin
                    if (sequential_lane_index < enqueue_count) begin
                        queue_pc[queue_index_add(queue_tail_reg,
                            sequential_lane_index)] <=
                            enqueue_pc[sequential_lane_index];
                        queue_instruction[queue_index_add(queue_tail_reg,
                            sequential_lane_index)] <=
                            enqueue_instruction[sequential_lane_index];
                        queue_predicted_next_pc[queue_index_add(
                            queue_tail_reg, sequential_lane_index)] <=
                            enqueue_predicted_next_pc[
                                sequential_lane_index];
                        queue_error[queue_index_add(queue_tail_reg,
                            sequential_lane_index)] <=
                            enqueue_error[sequential_lane_index];
                    end
                end
                queue_tail_reg <= queue_index_add(queue_tail_reg,
                    enqueue_count);
            end

            case ({response_enqueue_fire, (dequeue_count != 0)})
                2'b10: queue_occupancy_reg <=
                    queue_occupancy_reg + enqueue_count;
                2'b01: queue_occupancy_reg <=
                    queue_occupancy_reg - dequeue_count;
                2'b11: queue_occupancy_reg <= queue_occupancy_reg +
                    enqueue_count - dequeue_count;
                default: queue_occupancy_reg <= queue_occupancy_reg;
            endcase

            if (request_fire) begin
                request_pc[request_tail_reg] <= next_request_pc_reg;
                request_next_pc[request_tail_reg] <= next_request_prediction;
                request_tail_reg <= request_tail_reg + 1'b1;
                next_request_pc_reg <= next_request_prediction;
            end

            if (request_pop_fire) begin
                request_head_reg <= request_head_reg + 1'b1;
            end

            case ({request_fire, request_pop_fire})
                2'b10: request_count_reg <= request_count_reg + 1'b1;
                2'b01: request_count_reg <= request_count_reg - 1'b1;
                default: request_count_reg <= request_count_reg;
            endcase

            if (response_enqueue_fire &&
                    (response_path_mismatch || response_error)) begin
                request_head_reg <= 2'd0;
                request_tail_reg <= 2'd0;
                request_count_reg <= 3'd0;
                icache_flush_reg <= 1'b1;
                next_request_pc_reg <= response_next_pc;
                if (response_error)
                    fault_block_reg <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (!reset_i) begin
            if (redirect_valid_i && (redirect_pc_i[1:0] != 2'b00)) begin
                $display("ERROR rv32_fetch_pipeline unaligned redirect");
                $finish(1);
            end
            if (request_fire &&
                    (icache_request_pc_o[1:0] != 2'b00)) begin
                $display("ERROR rv32_fetch_pipeline unaligned request");
                $finish(1);
            end
            for (assertion_lane_index = 1;
                    assertion_lane_index < FE_WIDTH;
                    assertion_lane_index = assertion_lane_index + 1) begin
                if (fetch_valid_o[assertion_lane_index] &&
                        fetch_ready_i[assertion_lane_index] &&
                        !(fetch_valid_o[assertion_lane_index-1] &&
                            fetch_ready_i[assertion_lane_index-1])) begin
                    $display("ERROR rv32_fetch_pipeline non-prefix ready");
                    $finish(1);
                end
                if (fetch_valid_o[assertion_lane_index] &&
                        !fetch_valid_o[assertion_lane_index-1]) begin
                    $display("ERROR rv32_fetch_pipeline non-prefix valid");
                    $finish(1);
                end
            end
            if (queue_occupancy_reg > FETCH_QUEUE_ENTRIES) begin
                $display("ERROR rv32_fetch_pipeline queue overflow");
                $finish(1);
            end
            if (request_count_reg > REQUEST_TRACK_ENTRIES) begin
                $display("ERROR rv32_fetch_pipeline request overflow");
                $finish(1);
            end
        end
    end
`endif

endmodule
