`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_load_store_queue #(
    parameter LSQ_ENTRIES = 8,
    parameter LSQ_INDEX_WIDTH = 3,
    parameter LSQ_GENERATION_WIDTH = 2,
    parameter LSQ_TAG_WIDTH = 5,
    parameter BE_WIDTH = 1,
    parameter ROB_ENTRIES = 32,
    parameter ROB_INDEX_WIDTH = 5,
    parameter ROB_TAG_WIDTH = 7,
    parameter MEMORY_BYTES = 1048576
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
    input  wire [BE_WIDTH-1:0] rollback_valid_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_rob_tag_i,
    input  wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] rollback_lsq_tag_i,
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
    output wire cache_request_write_o,
    output wire [31:0] cache_request_address_o,
    output wire [31:0] cache_request_write_data_o,
    output wire [3:0] cache_request_byte_enable_o,
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
    reg inflight;
    reg inflight_write;
    reg inflight_discard;
    reg [ROB_TAG_WIDTH-1:0] inflight_rob_tag;
    reg [LSQ_TAG_WIDTH-1:0] inflight_lsq_tag;
    reg [31:0] inflight_address;

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
    reg [LSQ_INDEX_WIDTH-1:0] load_slot;
    reg [LSQ_INDEX_WIDTH-1:0] store_slot;
    reg [LSQ_INDEX_WIDTH-1:0] data_slot;
    reg [LSQ_INDEX_WIDTH-1:0] inflight_slot;
    reg [LSQ_INDEX_WIDTH-1:0] commit_slot;
    reg [LSQ_INDEX_WIDTH-1:0] sequential_commit_slot;
    integer source_candidate;
    integer request_candidate;
    integer candidate_distance;
    integer best_distance;
    integer best_store_distance;
    integer i;
    integer j;
    integer occupancy_index;
    integer byte_index;
    integer alloc_choice;
    integer access_bytes;
    integer precompute_index;
    integer sequential_index;
    integer sequential_lane;
    integer assertion_lane;
    reg [LSQ_INDEX_WIDTH-1:0] assertion_slot;
    reg [31:0] byte_address;
    reg [1:0] byte_offset;
    reg best_store_data_ready;
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
        integer bytes;
        begin
            bytes = size_bytes(code);
            address_fault = bytes == 0 || (addr & (bytes-1)) != 0 ||
                addr > MEMORY_BYTES - bytes;
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
                MEMORY_BYTES < 4 || (MEMORY_BYTES & 3) != 0) begin
            $display("ERROR rv32_load_store_queue invalid parameters");
            $finish(1);
        end
    end

    assign completion_valid_o = !reset_i && !flush_i && !recover_i &&
        source_valid;
    assign completion_rob_tag_o = source_rob_tag;
    assign completion_value_o = source_value;
    assign completion_exception_valid_o = source_exception_valid;
    assign completion_exception_cause_o = source_exception_cause;
    assign completion_exception_tval_o = source_exception_tval;
    assign cache_request_valid_o = !reset_i && !flush_i && !recover_i &&
        request_valid;
    assign cache_request_write_o = request_write;
    assign cache_request_address_o = request_address;
    assign cache_request_write_data_o = request_write_data;
    assign cache_request_byte_enable_o = request_byte_enable;
    assign store_data_ready_o = !reset_i && !flush_i && !recover_i &&
        store_data_valid_i && data_match && !data_valid[data_slot];
    assign cache_response_ready_o = !reset_i && !flush_i &&
        !recover_i && inflight &&
        (inflight_write || inflight_discard || !inflight_match || !source_valid);

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
        access_bytes = 0;
        best_store_distance = -1;
        byte_address = 0;
        byte_offset = 0;
        best_store_data_ready = 1'b0;
        j = 0;
        byte_index = 0;
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
        inflight_match = busy[inflight_slot] &&
            {generation[inflight_slot], inflight_slot} == inflight_lsq_tag &&
            rob_tag[inflight_slot] == inflight_rob_tag;
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
            forwarding_mask[i] = 0;
            forwarding_value[i] = 0;
            load_blocked[i] = !address_valid[i] || fault_valid[i];
            if (busy[i] && !is_store[i] && address_valid[i] &&
                    !fault_valid[i]) begin
                access_bytes = entry_size[i];
                for (j = 0; j < LSQ_ENTRIES; j = j + 1) begin
                    if (busy[j] && is_store[j] &&
                            entry_distance[j] < entry_distance[i] &&
                            !address_valid[j])
                        load_blocked[i] = 1'b1;
                end
                for (byte_index = 0; byte_index < 4;
                        byte_index = byte_index + 1) begin
                    if (byte_index < access_bytes) begin
                        byte_address = address[i] + byte_index;
                        best_store_distance = -1;
                        best_store_data_ready = 1'b0;
                        for (j = 0; j < LSQ_ENTRIES; j = j + 1) begin
                            if (busy[j] && is_store[j] && address_valid[j] &&
                                    !fault_valid[j] &&
                                    entry_distance[j] < entry_distance[i] &&
                                    byte_address[31:2] == address[j][31:2] &&
                                    byte_address[1:0] >= address[j][1:0] &&
                                    (byte_address[1:0] - address[j][1:0]) <
                                        entry_size[j] &&
                                    (best_store_distance < 0 ||
                                        entry_distance[j] >
                                            best_store_distance)) begin
                                best_store_distance = entry_distance[j];
                                best_store_data_ready = data_valid[j];
                                forwarding_mask[i][byte_index] = 1'b1;
                                byte_offset = byte_address[1:0] -
                                    address[j][1:0];
                                forwarding_value[i][byte_index*8 +: 8] =
                                    store_data[j] >> (byte_offset*8);
                            end
                        end
                        if (forwarding_mask[i][byte_index] &&
                                !best_store_data_ready)
                            load_blocked[i] = 1'b1;
                    end
                end
                if (forwarding_mask[i] != 0 &&
                        forwarding_mask[i] != (4'b1111 >> (4-access_bytes)))
                    load_blocked[i] = 1'b1;
            end
        end

        source_candidate = -1;
        best_distance = ROB_ENTRIES;
        for (i = 0; i < LSQ_ENTRIES; i = i + 1) begin
            if (busy[i] && !report_sent[i] && address_valid[i] &&
                    (is_store[i] ? (data_valid[i] || fault_valid[i]) :
                        (fault_valid[i] || (!started[i] &&
                            !load_blocked[i] && forwarding_mask[i] != 0)))) begin
                candidate_distance = entry_distance[i];
                if (candidate_distance < best_distance) begin
                    source_candidate = i;
                    best_distance = candidate_distance;
                end
            end
            if (busy[i] && is_store[i] && late_error[i] &&
                    !late_error_sent[i]) begin
                candidate_distance = entry_distance[i];
                if (candidate_distance < best_distance) begin
                    source_candidate = i;
                    best_distance = candidate_distance;
                end
            end
        end

        request_candidate = -1;
        best_distance = ROB_ENTRIES;
        for (i = 0; i < LSQ_ENTRIES; i = i + 1) begin
            if (busy[i] && !is_store[i] && address_valid[i] &&
                    !fault_valid[i] && !report_sent[i] && !started[i] &&
                    !load_blocked[i] && forwarding_mask[i] == 0) begin
                candidate_distance = entry_distance[i];
                if (candidate_distance < best_distance) begin
                    request_candidate = i;
                    best_distance = candidate_distance;
                end
            end
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
                                (late_error[commit_slot] &&
                                    commit_exception_valid_i[i]));
                    end
                end
            end
        end
    end

    always @* begin
        occupancy_o = 0;
        for (occupancy_index = 0; occupancy_index < LSQ_ENTRIES;
                occupancy_index = occupancy_index + 1)
            if (busy[occupancy_index]) occupancy_o = occupancy_o + 1'b1;
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
            request_write <= 1'b0;
            request_rob_tag <= 0;
            request_lsq_tag <= 0;
            request_address <= 0;
            request_write_data <= 0;
            request_byte_enable <= 0;
            inflight <= 1'b0;
            inflight_write <= 1'b0;
            inflight_discard <= 1'b0;
            inflight_rob_tag <= 0;
            inflight_lsq_tag <= 0;
            inflight_address <= 0;
        end else begin
            if (recover_i) begin
                for (sequential_index = 0; sequential_index < LSQ_ENTRIES;
                        sequential_index = sequential_index + 1) begin
                    for (sequential_lane = 0; sequential_lane < BE_WIDTH;
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
                            if (inflight && inflight_lsq_tag ==
                                    {generation[sequential_index],
                                        sequential_index[LSQ_INDEX_WIDTH-1:0]})
                                inflight_discard <= 1'b1;
                        end
                    end
                end
            end else begin
                if (source_valid && completion_ready_i) begin
                    source_valid <= 1'b0;
                    if (busy[source_lsq_tag[LSQ_INDEX_WIDTH-1:0]] &&
                            !is_store[source_lsq_tag[LSQ_INDEX_WIDTH-1:0]] &&
                            {generation[source_lsq_tag[LSQ_INDEX_WIDTH-1:0]],
                                source_lsq_tag[LSQ_INDEX_WIDTH-1:0]} ==
                                source_lsq_tag)
                        busy[source_lsq_tag[LSQ_INDEX_WIDTH-1:0]] <= 1'b0;
                end
                if (cache_request_valid_o && cache_request_ready_i) begin
                    request_valid <= 1'b0;
                    inflight <= 1'b1;
                    inflight_write <= request_write;
                    inflight_discard <= 1'b0;
                    inflight_rob_tag <= request_rob_tag;
                    inflight_lsq_tag <= request_lsq_tag;
                    inflight_address <= address[
                        request_lsq_tag[LSQ_INDEX_WIDTH-1:0]];
                end
                if (cache_response_valid_i && cache_response_ready_o) begin
                    inflight <= 1'b0;
                    if (!inflight_discard && inflight_match) begin
                        if (inflight_write) begin
                            if (cache_response_error_i)
                                late_error[inflight_slot] <= 1'b1;
                            else
                                write_done[inflight_slot] <= 1'b1;
                        end else begin
                            source_valid <= 1'b1;
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
                end else if (!source_valid && source_candidate >= 0) begin
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
                            extend_value(forwarding_value[source_candidate],
                                width[source_candidate],
                                load_unsigned[source_candidate]);
                        report_sent[source_candidate] <= 1'b1;
                    end
                end

                if (!request_valid && !inflight &&
                        !(cache_request_valid_o && cache_request_ready_i)) begin
                    if (commit_valid_i[0] && commit_lsq_valid_i[0] &&
                            is_store_op(commit_op_i[0 +: `RV32_OP_WIDTH])) begin
                        sequential_commit_slot = commit_lsq_tag_i[
                            0 +: LSQ_INDEX_WIDTH];
                        if (busy[sequential_commit_slot] &&
                                is_store[sequential_commit_slot] &&
                                {generation[sequential_commit_slot],
                                    sequential_commit_slot} ==
                                    commit_lsq_tag_i[0 +: LSQ_TAG_WIDTH] &&
                                rob_tag[sequential_commit_slot] ==
                                    commit_rob_tag_i[0 +: ROB_TAG_WIDTH] &&
                                address_valid[sequential_commit_slot] &&
                                data_valid[sequential_commit_slot] &&
                                !fault_valid[sequential_commit_slot] &&
                                !write_requested[sequential_commit_slot]) begin
                            request_valid <= 1'b1;
                            request_write <= 1'b1;
                            request_rob_tag <= rob_tag[sequential_commit_slot];
                            request_lsq_tag <= {
                                generation[sequential_commit_slot],
                                sequential_commit_slot};
                            request_address <= {
                                address[sequential_commit_slot][31:2],
                                2'b00};
                            request_write_data <=
                                store_data[sequential_commit_slot] <<
                                (address[sequential_commit_slot][1:0]*8);
                            request_byte_enable <=
                                (4'b1111 >> (4-size_bytes(
                                    width[sequential_commit_slot])))
                                    << address[sequential_commit_slot][1:0];
                            write_requested[sequential_commit_slot] <= 1'b1;
                        end else if (request_candidate >= 0) begin
                            request_valid <= 1'b1;
                            request_write <= 1'b0;
                            request_rob_tag <= rob_tag[request_candidate];
                            request_lsq_tag <= {generation[request_candidate],
                                request_candidate[LSQ_INDEX_WIDTH-1:0]};
                            request_address <= {address[request_candidate][31:2],
                                2'b00};
                            request_write_data <= 0;
                            request_byte_enable <= 0;
                            started[request_candidate] <= 1'b1;
                        end
                    end else if (request_candidate >= 0) begin
                        request_valid <= 1'b1;
                        request_write <= 1'b0;
                        request_rob_tag <= rob_tag[request_candidate];
                        request_lsq_tag <= {generation[request_candidate],
                            request_candidate[LSQ_INDEX_WIDTH-1:0]};
                        request_address <= {address[request_candidate][31:2],
                            2'b00};
                        request_write_data <= 0;
                        request_byte_enable <= 0;
                        started[request_candidate] <= 1'b1;
                    end
                end

                if (load_address_valid_i && load_address_ready_o) begin
                    address_valid[load_slot] <= 1'b1;
                    address[load_slot] <= load_address_i;
                    fault_valid[load_slot] <= address_fault(load_address_i,
                        width[load_slot]);
                    fault_cause[load_slot] <= address_fault_cause(
                        load_address_i, width[load_slot], 1'b0);
                end
                if (store_address_valid_i && store_address_ready_o) begin
                    address_valid[store_slot] <= 1'b1;
                    address[store_slot] <= store_address_i;
                    fault_valid[store_slot] <= address_fault(store_address_i,
                        width[store_slot]);
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
