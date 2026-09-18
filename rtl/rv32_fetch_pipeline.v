`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_fetch_pipeline #(
    parameter FE_WIDTH = 1,
    parameter BE_WIDTH = 1,
    parameter FETCH_QUEUE_ENTRIES = 8,
    parameter FETCH_QUEUE_INDEX_WIDTH = 3
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

    reg [31:0] queue_pc [0:FETCH_QUEUE_ENTRIES-1];
    reg [31:0] queue_instruction [0:FETCH_QUEUE_ENTRIES-1];
    reg [31:0] queue_predicted_next_pc [0:FETCH_QUEUE_ENTRIES-1];
    reg queue_error [0:FETCH_QUEUE_ENTRIES-1];
    reg [FETCH_QUEUE_INDEX_WIDTH-1:0] queue_head_reg;
    reg [FETCH_QUEUE_INDEX_WIDTH-1:0] queue_tail_reg;
    reg [FETCH_QUEUE_INDEX_WIDTH:0] queue_occupancy_reg;

    reg [31:0] request_pc [0:REQUEST_TRACK_ENTRIES-1];
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
    integer request_advance_count;
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

    assign icache_flush_o = !reset_i &&
        (redirect_valid_i || icache_flush_reg);
    assign icache_request_valid_o = !reset_i && !redirect_valid_i &&
        !icache_flush_reg && !fault_block_reg &&
        ((request_count_reg < REQUEST_TRACK_ENTRIES) || request_pop_fire);
    assign icache_request_pc_o = next_request_pc_reg;
    assign icache_response_ready_o = !reset_i && !redirect_valid_i &&
        !icache_flush_reg && (!response_matches_head ||
            (available_count >= enqueue_count));

    assign fetch_valid_o = fetch_valid_reg;
    assign fetch_pc_o = fetch_pc_reg;
    assign fetch_instruction_o = fetch_instruction_reg;
    assign fetch_predicted_next_pc_o = fetch_predicted_next_pc_reg;
    assign fetch_error_o = fetch_error_reg;
    assign fetch_occupancy_o = reset_i ?
        {(FETCH_QUEUE_INDEX_WIDTH+1){1'b0}} : queue_occupancy_reg;

    initial begin
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
            (icache_response_pc_i == request_pc[request_head_reg]);

        candidate_valid = {FE_WIDTH{1'b0}};
        candidate_pc = {(FE_WIDTH*32){1'b0}};
        candidate_instruction = {(FE_WIDTH*32){1'b0}};
        candidate_count = words_from_offset(icache_response_pc_i[3:2]);

        for (candidate_lane_index = 0;
                candidate_lane_index < FE_WIDTH;
                candidate_lane_index = candidate_lane_index + 1) begin
            if (icache_response_valid_i && response_matches_head &&
                    !icache_response_error_i &&
                    (candidate_lane_index < candidate_count)) begin
                candidate_valid[candidate_lane_index] = 1'b1;
                candidate_pc[candidate_lane_index*32 +: 32] =
                    icache_response_pc_i + candidate_lane_index*4;
                candidate_instruction[candidate_lane_index*32 +: 32] =
                    icache_response_line_i[
                        (icache_response_pc_i[3:2] +
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
                prediction_valid[enqueue_lane_index] ?
                    prediction_next_pc[enqueue_lane_index*32 +: 32] :
                    candidate_pc[enqueue_lane_index*32 +: 32] + 32'd4;
            enqueue_error[enqueue_lane_index] = 1'b0;

            if (!redirect_found && candidate_valid[enqueue_lane_index] &&
                    prediction_taken[enqueue_lane_index]) begin
                redirect_found = 1'b1;
                predicted_redirect = 1'b1;
                predicted_redirect_pc =
                    prediction_next_pc[enqueue_lane_index*32 +: 32];
                enqueue_count = enqueue_lane_index + 1;
            end
        end

        if (icache_response_error_i) begin
            enqueue_count = 1;
            predicted_redirect = 1'b0;
            predicted_redirect_pc = 32'd0;
            enqueue_pc[0] = icache_response_pc_i;
            enqueue_instruction[0] = 32'd0;
            enqueue_predicted_next_pc[0] =
                icache_response_pc_i + 32'd4;
            enqueue_error[0] = 1'b1;
        end

        available_count = FETCH_QUEUE_ENTRIES -
            (queue_occupancy_reg - dequeue_count);
        response_enqueue_fire = icache_response_valid_i &&
            icache_response_ready_o && response_matches_head;
        request_pop_fire = response_enqueue_fire;
        request_fire = icache_request_valid_o && icache_request_ready_i;
        request_advance_count = words_from_offset(next_request_pc_reg[3:2]);
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
                    sequential_lane_index = sequential_lane_index + 1)
                request_pc[sequential_lane_index] <= 32'd0;
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
                request_tail_reg <= request_tail_reg + 1'b1;
                next_request_pc_reg <= next_request_pc_reg +
                    request_advance_count*4;
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
                    (predicted_redirect || icache_response_error_i)) begin
                request_head_reg <= 2'd0;
                request_tail_reg <= 2'd0;
                request_count_reg <= 3'd0;
                icache_flush_reg <= 1'b1;
                if (predicted_redirect)
                    next_request_pc_reg <= predicted_redirect_pc;
                if (icache_response_error_i)
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
