`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_fetch_sram_buffer_tb;
    parameter FE_WIDTH = 2;
    parameter BE_WIDTH = 2;
    parameter LINE_BUFFER_ENTRIES = 64;
    parameter USE_SRAM = 1;
    parameter DUT_BUFFER_ENTRIES = LINE_BUFFER_ENTRIES;

    reg clk = 0;
    reg reset = 1;
    reg redirect = 0;
    reg [31:0] redirect_pc = 0;
    reg cache_ready = 0;
    reg cache_valid = 0;
    reg [31:0] cache_pc = 0;
    reg [127:0] cache_line = 0;
    reg cache_error = 0;
    reg [FE_WIDTH-1:0] fetch_ready = 0;
    reg [BE_WIDTH-1:0] update_valid = 0;
    reg [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] update_op = 0;
    reg [(BE_WIDTH*32)-1:0] update_pc = 0;
    reg [(BE_WIDTH*32)-1:0] update_predicted = 0;
    reg [(BE_WIDTH*32)-1:0] update_actual = 0;
    reg [BE_WIDTH-1:0] update_taken = 0;
    wire flush;
    wire request_valid;
    wire [31:0] request_pc;
    wire response_ready;
    wire [FE_WIDTH-1:0] fetch_valid;
    wire [(FE_WIDTH*32)-1:0] fetch_pc;
    wire [(FE_WIDTH*32)-1:0] fetch_instruction;
    wire [(FE_WIDTH*32)-1:0] fetch_next;
    wire [FE_WIDTH-1:0] fetch_error;
    integer checks = 0;
    integer requests = 0;
    integer previous_requests;
    integer lane;
    integer words;
    integer offset;
    reg [127:0] line_value;
    reg [(FE_WIDTH*32)-1:0] held_instruction;
    reg [(FE_WIDTH*32)-1:0] held_pc;

    rv32_fetch_pipeline #(.FE_WIDTH(FE_WIDTH), .BE_WIDTH(BE_WIDTH),
        .FETCH_LINE_BUFFER_ENTRIES(DUT_BUFFER_ENTRIES), .FETCH_LINE_BUFFER_SRAM(USE_SRAM)) dut (
        .clk_i(clk), .reset_i(reset), .redirect_valid_i(redirect),
        .redirect_pc_i(redirect_pc), .icache_flush_o(flush),
        .icache_request_valid_o(request_valid), .icache_request_ready_i(cache_ready),
        .icache_request_pc_o(request_pc), .icache_response_valid_i(cache_valid),
        .icache_response_ready_o(response_ready), .icache_response_pc_i(cache_pc),
        .icache_response_line_i(cache_line), .icache_response_error_i(cache_error),
        .predictor_update_valid_i(update_valid), .predictor_update_op_i(update_op),
        .predictor_update_pc_i(update_pc),
        .predictor_update_predicted_next_pc_i(update_predicted),
        .predictor_update_actual_next_pc_i(update_actual),
        .predictor_update_actual_taken_i(update_taken),
        .conditional_correct_o(), .conditional_total_o(), .jal_correct_o(),
        .jal_total_o(), .jalr_correct_o(), .jalr_total_o(),
        .control_correct_o(), .control_total_o(), .fetch_valid_o(fetch_valid),
        .fetch_ready_i(fetch_ready), .fetch_pc_o(fetch_pc),
        .fetch_instruction_o(fetch_instruction), .fetch_predicted_next_pc_o(fetch_next),
        .fetch_error_o(fetch_error), .fetch_occupancy_o()
    );

    always #5 clk = ~clk;
    always @(posedge clk)
        if (!reset && request_valid && cache_ready) requests = requests + 1;

    function [127:0] make_line;
        input [31:0] pc;
        integer word_index;
        reg [31:0] word_pc;
        begin
            for (word_index = 0; word_index < 4; word_index = word_index + 1) begin
                word_pc = {pc[31:4], 4'b0000} + word_index*4;
                make_line[word_index*32 +: 32] =
                    ((word_pc >> 2) << 20) | 32'h00000513;
            end
        end
    endfunction

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task check;
        input condition;
        input [8*96-1:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                $display("ERROR fetch_line_buffer FE=%0d BE=%0d entries=%0d: %0s",
                    FE_WIDTH, BE_WIDTH, LINE_BUFFER_ENTRIES, message);
                $finish(1);
            end
        end
    endtask

    task restart;
        input [31:0] pc;
        begin
            redirect = 1;
            redirect_pc = pc;
            #1;
            check(flush && fetch_valid == 0 && !request_valid,
                "redirect did not cancel frontend traffic");
            tick;
            redirect = 0;
            #1;
        end
    endtask

    task fill;
        input [31:0] pc;
        input [127:0] data;
        input error;
        begin
            restart(pc);
            check(request_valid && request_pc == pc, "cold request missing");
            cache_ready = 1;
            tick;
            cache_ready = 0;
            cache_valid = 1;
            cache_pc = pc;
            cache_line = data;
            cache_error = error;
            #1;
            check(response_ready, "cold response blocked");
            tick;
            cache_valid = 0;
            cache_error = 0;
            #1;
        end
    endtask

    task hot;
        input [31:0] pc;
        input [127:0] data;
        input taken;
        begin
            restart(pc);
            previous_requests = requests;
            check(!request_valid, "hot target issued an I-cache request");
            tick;
            cache_valid = 1;
            cache_pc = pc;
            cache_line = {4{32'hffffffff}};
            cache_error = 1;
            #1;
            check(!response_ready, "old cache response overtook local response");
            tick;
            cache_valid = 0;
            cache_error = 0;
            offset = pc[3:2];
            words = 4 - offset;
            if (words > FE_WIDTH) words = FE_WIDTH;
            if (taken) words = 1;
            check(requests == previous_requests, "hot replay used I-cache");
            for (lane = 0; lane < FE_WIDTH; lane = lane + 1) begin
                check(fetch_valid[lane] == (lane < words), "hot valid prefix mismatch");
                if (lane < words) begin
                    check(fetch_pc[lane*32 +: 32] == pc + lane*4,
                        "hot word PC mismatch");
                    check(fetch_instruction[lane*32 +: 32] == data[(offset+lane)*32 +: 32],
                        "hot instruction mismatch");
                    check(fetch_next[lane*32 +: 32] ==
                        (taken ? pc + 8 : pc + lane*4 + 4), "hot prediction mismatch");
                    check(!fetch_error[lane], "old error contaminated replay");
                end
            end
            held_instruction = fetch_instruction;
            held_pc = fetch_pc;
            repeat (3) tick;
            for (lane = 0; lane < words; lane = lane + 1) begin
                check(fetch_instruction[lane*32 +: 32] == held_instruction[lane*32 +: 32] &&
                    fetch_pc[lane*32 +: 32] == held_pc[lane*32 +: 32],
                    "backpressure changed oldest instruction");
            end
        end
    endtask

    initial begin
        tick;
        tick;
        reset = 0;
        line_value = make_line(0);
        fill(0, line_value, 0);
        if (FE_WIDTH < 4) begin
            check(request_valid && request_pc == FE_WIDTH*4,
                "stalled I-cache request was withdrawn on buffer fill");
            repeat (2) tick;
            check(request_valid && request_pc == FE_WIDTH*4,
                "stalled request payload changed");
        end
        hot(0, line_value, 0);
        hot(4, line_value, 0);
        hot(8, line_value, 0);
        hot(12, line_value, 0);

        line_value = make_line(LINE_BUFFER_ENTRIES*16);
        fill(LINE_BUFFER_ENTRIES*16, line_value, 0);
        restart(0);
        check(request_valid && request_pc == 0, "tag collision produced false hit");
        fill(0, make_line(0), 0);
        hot(0, make_line(0), 0);

        line_value = make_line(32'h80000000);
        fill(32'h80000000, line_value, 0);
        hot(32'h80000000, line_value, 0);
        restart(0);
        check(request_valid && request_pc == 0, "high address tag aliased low memory");
        fill(0, make_line(0), 0);

        fill(LINE_BUFFER_ENTRIES*32, make_line(LINE_BUFFER_ENTRIES*32), 1);
        check(fetch_valid[0] && fetch_error[0], "cache error was not preserved");
        restart(LINE_BUFFER_ENTRIES*32);
        check(request_valid, "failed line was retained in buffer");

        line_value = make_line(32'h100);
        line_value[31:0] = 32'h0080006f;
        fill(32'h100, line_value, 0);
        update_valid[0] = 1;
        update_op[0 +: `RV32_OP_WIDTH] = `RV32_OP_JAL;
        update_pc[31:0] = 32'h100;
        update_predicted[31:0] = 32'h108;
        update_actual[31:0] = 32'h108;
        update_taken[0] = 1;
        tick;
        update_valid = 0;
        hot(32'h100, line_value, 1);

        line_value = make_line(32'h120);
        line_value[31:0] = 32'h0020006f;
        fill(32'h120, line_value, 0);
        hot(32'h120, line_value, 0);

        restart(32'h120);
        tick;
        restart(32'h400);
        tick;
        tick;
        check(fetch_valid == 0, "cancelled local response survived redirect");
        reset = 1;
        tick;
        tick;
        reset = 0;
        #1;
        check(request_valid && request_pc == 0, "reset retained a buffered line");
        $display("PASS fetch_line_buffer FE=%0d BE=%0d entries=%0d checks=%0d",
            FE_WIDTH, BE_WIDTH, LINE_BUFFER_ENTRIES, checks);
        $finish;
    end

    initial begin
        #20000;
        $display("ERROR fetch_line_buffer timeout");
        $finish(1);
    end
endmodule
