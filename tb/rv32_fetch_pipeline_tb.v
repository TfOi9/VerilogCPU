`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_fetch_pipeline_tb;

    parameter FE_WIDTH = 1;
    parameter BE_WIDTH = 1;

    reg clk_i;
    reg reset_i;
    reg redirect_valid_i;
    reg [31:0] redirect_pc_i;
    wire icache_flush_o;
    wire icache_request_valid_o;
    reg icache_request_ready_i;
    wire [31:0] icache_request_pc_o;
    reg icache_response_valid_i;
    wire icache_response_ready_o;
    reg [31:0] icache_response_pc_i;
    reg [127:0] icache_response_line_i;
    reg icache_response_error_i;
    reg [BE_WIDTH-1:0] predictor_update_valid_i;
    reg [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] predictor_update_op_i;
    reg [(BE_WIDTH*32)-1:0] predictor_update_pc_i;
    reg [(BE_WIDTH*32)-1:0]
        predictor_update_predicted_next_pc_i;
    reg [(BE_WIDTH*32)-1:0] predictor_update_actual_next_pc_i;
    reg [BE_WIDTH-1:0] predictor_update_actual_taken_i;
    wire [31:0] conditional_correct_o;
    wire [31:0] conditional_total_o;
    wire [31:0] jal_correct_o;
    wire [31:0] jal_total_o;
    wire [31:0] jalr_correct_o;
    wire [31:0] jalr_total_o;
    wire [31:0] control_correct_o;
    wire [31:0] control_total_o;
    wire [FE_WIDTH-1:0] fetch_valid_o;
    reg [FE_WIDTH-1:0] fetch_ready_i;
    wire [(FE_WIDTH*32)-1:0] fetch_pc_o;
    wire [(FE_WIDTH*32)-1:0] fetch_instruction_o;
    wire [(FE_WIDTH*32)-1:0] fetch_predicted_next_pc_o;
    wire [FE_WIDTH-1:0] fetch_error_o;
    wire [3:0] fetch_occupancy_o;

    integer checks;
    integer lane;
    integer request_index;
    integer fill_iterations;
    reg [31:0] request_pc_value;
    reg [31:0] expected_second_pc;
    reg [127:0] line_value;

    rv32_fetch_pipeline #(
        .FE_WIDTH(FE_WIDTH),
        .BE_WIDTH(BE_WIDTH),
        .FETCH_QUEUE_ENTRIES(8),
        .FETCH_QUEUE_INDEX_WIDTH(3)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .redirect_valid_i(redirect_valid_i),
        .redirect_pc_i(redirect_pc_i),
        .icache_flush_o(icache_flush_o),
        .icache_request_valid_o(icache_request_valid_o),
        .icache_request_ready_i(icache_request_ready_i),
        .icache_request_pc_o(icache_request_pc_o),
        .icache_response_valid_i(icache_response_valid_i),
        .icache_response_ready_o(icache_response_ready_o),
        .icache_response_pc_i(icache_response_pc_i),
        .icache_response_line_i(icache_response_line_i),
        .icache_response_error_i(icache_response_error_i),
        .predictor_update_valid_i(predictor_update_valid_i),
        .predictor_update_op_i(predictor_update_op_i),
        .predictor_update_pc_i(predictor_update_pc_i),
        .predictor_update_predicted_next_pc_i(
            predictor_update_predicted_next_pc_i),
        .predictor_update_actual_next_pc_i(
            predictor_update_actual_next_pc_i),
        .predictor_update_actual_taken_i(
            predictor_update_actual_taken_i),
        .conditional_correct_o(conditional_correct_o),
        .conditional_total_o(conditional_total_o),
        .jal_correct_o(jal_correct_o),
        .jal_total_o(jal_total_o),
        .jalr_correct_o(jalr_correct_o),
        .jalr_total_o(jalr_total_o),
        .control_correct_o(control_correct_o),
        .control_total_o(control_total_o),
        .fetch_valid_o(fetch_valid_o),
        .fetch_ready_i(fetch_ready_i),
        .fetch_pc_o(fetch_pc_o),
        .fetch_instruction_o(fetch_instruction_o),
        .fetch_predicted_next_pc_o(fetch_predicted_next_pc_o),
        .fetch_error_o(fetch_error_o),
        .fetch_occupancy_o(fetch_occupancy_o)
    );

    always #5 clk_i = ~clk_i;

    function [31:0] addi_instruction;
        input [11:0] immediate;
        begin
            addi_instruction = {immediate, 5'd0, 3'b000, 5'd1,
                7'b0010011};
        end
    endfunction

    function [31:0] jal_instruction;
        input [20:0] immediate;
        begin
            jal_instruction = {
                immediate[20], immediate[10:1], immediate[11],
                immediate[19:12], 5'd0, 7'b1101111
            };
        end
    endfunction

    function [31:0] branch_instruction;
        input [12:0] immediate;
        begin
            branch_instruction = {
                immediate[12], immediate[10:5], 5'd0, 5'd0, 3'b000,
                immediate[4:1], immediate[11], 7'b1100011
            };
        end
    endfunction

    function [127:0] sequential_line;
        input [11:0] base;
        begin
            sequential_line = {
                addi_instruction(base + 3),
                addi_instruction(base + 2),
                addi_instruction(base + 1),
                addi_instruction(base)
            };
        end
    endfunction

    task tick;
        begin
            @(posedge clk_i);
            #1;
        end
    endtask

    task check;
        input condition;
        input [8*80-1:0] message;
        begin
            checks = checks + 1;
            if (!condition) begin
                $display("ERROR rv32_fetch_pipeline_tb width=%0d: %0s",
                    FE_WIDTH, message);
                $finish(1);
            end
        end
    endtask

    task clear_updates;
        begin
            predictor_update_valid_i = {BE_WIDTH{1'b0}};
            predictor_update_op_i =
                {(BE_WIDTH*`RV32_OP_WIDTH){1'b0}};
            predictor_update_pc_i = {(BE_WIDTH*32){1'b0}};
            predictor_update_predicted_next_pc_i =
                {(BE_WIDTH*32){1'b0}};
            predictor_update_actual_next_pc_i =
                {(BE_WIDTH*32){1'b0}};
            predictor_update_actual_taken_i = {BE_WIDTH{1'b0}};
        end
    endtask

    task update_predictor;
        input [`RV32_OP_WIDTH-1:0] op;
        input [31:0] pc;
        input [31:0] predicted_next_pc;
        input [31:0] actual_next_pc;
        input actual_taken;
        begin
            clear_updates;
            predictor_update_valid_i[0] = 1'b1;
            predictor_update_op_i[0 +: `RV32_OP_WIDTH] = op;
            predictor_update_pc_i[0 +: 32] = pc;
            predictor_update_predicted_next_pc_i[0 +: 32] =
                predicted_next_pc;
            predictor_update_actual_next_pc_i[0 +: 32] =
                actual_next_pc;
            predictor_update_actual_taken_i[0] = actual_taken;
            tick;
            clear_updates;
        end
    endtask

    task pulse_redirect;
        input [31:0] pc;
        begin
            redirect_pc_i = pc;
            redirect_valid_i = 1'b1;
            #1;
            check(icache_flush_o, "redirect did not flush I-cache");
            tick;
            redirect_valid_i = 1'b0;
            redirect_pc_i = 32'd0;
            #1;
            check(fetch_occupancy_o == 0, "redirect did not clear queue");
        end
    endtask

    task accept_request;
        input [31:0] expected_pc;
        begin
            icache_request_ready_i = 1'b1;
            #1;
            check(icache_request_valid_o,
                "expected request was not valid");
            check(icache_request_pc_o == expected_pc,
                "request PC mismatch");
            tick;
            icache_request_ready_i = 1'b0;
            #1;
        end
    endtask

    task send_response;
        input [31:0] pc;
        input [127:0] line_data;
        input response_error;
        begin
            icache_response_pc_i = pc;
            icache_response_line_i = line_data;
            icache_response_error_i = response_error;
            icache_response_valid_i = 1'b1;
            #1;
            check(icache_response_ready_o,
                "expected response was not accepted");
            tick;
            icache_response_valid_i = 1'b0;
            icache_response_error_i = 1'b0;
            icache_response_pc_i = 32'd0;
            icache_response_line_i = 128'd0;
            #1;
        end
    endtask

    task consume_count;
        input integer count;
        integer consume_lane;
        begin
            fetch_ready_i = {FE_WIDTH{1'b0}};
            for (consume_lane = 0; consume_lane < FE_WIDTH;
                    consume_lane = consume_lane + 1)
                if (consume_lane < count)
                    fetch_ready_i[consume_lane] = 1'b1;
            tick;
            fetch_ready_i = {FE_WIDTH{1'b0}};
            #1;
        end
    endtask

    task wait_internal_flush;
        begin
            #1;
            check(icache_flush_o, "predicted redirect did not flush cache");
            tick;
            #1;
            check(!icache_flush_o, "predicted flush lasted too long");
        end
    endtask

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b1;
        redirect_valid_i = 1'b0;
        redirect_pc_i = 32'd0;
        icache_request_ready_i = 1'b0;
        icache_response_valid_i = 1'b0;
        icache_response_pc_i = 32'd0;
        icache_response_line_i = 128'd0;
        icache_response_error_i = 1'b0;
        fetch_ready_i = {FE_WIDTH{1'b0}};
        clear_updates;
        checks = 0;

        tick;
        tick;
        reset_i = 1'b0;
        #1;

        line_value = sequential_line(12'h010);
        accept_request(32'h00000000);
        send_response(32'h00000000, line_value, 1'b0);
        check(fetch_occupancy_o == FE_WIDTH,
            "initial bundle occupancy mismatch");
        for (lane = 0; lane < FE_WIDTH; lane = lane + 1) begin
            check(fetch_valid_o[lane], "missing initial valid lane");
            check(fetch_pc_o[lane*32 +: 32] == lane*4,
                "initial lane PC mismatch");
            check(fetch_instruction_o[lane*32 +: 32] ==
                    line_value[lane*32 +: 32],
                "initial lane instruction mismatch");
            check(fetch_predicted_next_pc_o[lane*32 +: 32] ==
                    lane*4 + 4,
                "sequential predicted PC mismatch");
            check(!fetch_error_o[lane], "unexpected fetch error");
        end
        request_pc_value = fetch_pc_o[0 +: 32];
        line_value = fetch_instruction_o;
        tick;
        check(fetch_occupancy_o == FE_WIDTH,
            "backpressure changed queue occupancy");
        check(fetch_pc_o[0 +: 32] == request_pc_value,
            "backpressure changed oldest PC");
        check(fetch_instruction_o == line_value,
            "backpressure changed output bundle");
        if (FE_WIDTH > 1) begin
            expected_second_pc = fetch_pc_o[32 +: 32];
            consume_count(1);
            check(fetch_pc_o[0 +: 32] == expected_second_pc,
                "partial dequeue did not shift oldest lane");
            consume_count(FE_WIDTH - 1);
        end else begin
            consume_count(1);
        end
        check(fetch_occupancy_o == 0, "initial bundle did not drain");

        pulse_redirect(32'h0000000c);
        accept_request(32'h0000000c);
        line_value = sequential_line(12'h020);
        send_response(32'h0000000c, line_value, 1'b0);
        check(fetch_occupancy_o == 1,
            "line tail did not produce a one-lane prefix");
        check(fetch_pc_o[0 +: 32] == 32'h0000000c,
            "line tail PC mismatch");
        check(fetch_instruction_o[0 +: 32] == line_value[96 +: 32],
            "line tail instruction mismatch");
        consume_count(1);
        accept_request(32'h00000010);
        line_value = sequential_line(12'h030);
        send_response(32'h00000010, line_value, 1'b0);
        check(fetch_pc_o[0 +: 32] == 32'h00000010,
            "next-line PC mismatch");
        consume_count(FE_WIDTH);

        pulse_redirect(32'h00000700);
        request_pc_value = 32'h00000700;
        for (request_index = 0; request_index < 4;
                request_index = request_index + 1) begin
            accept_request(request_pc_value);
            request_pc_value = request_pc_value + FE_WIDTH*4;
        end
        request_pc_value = 32'h00000700;
        for (request_index = 0; request_index < 4;
                request_index = request_index + 1) begin
            send_response(request_pc_value,
                sequential_line(12'h0c0 + request_index*4), 1'b0);
            check(fetch_pc_o[0 +: 32] == request_pc_value,
                "pipelined request response order mismatch");
            consume_count(FE_WIDTH);
            request_pc_value = request_pc_value + FE_WIDTH*4;
        end

        pulse_redirect(32'h00000040);
        accept_request(32'h00000040);
        line_value = sequential_line(12'h040);
        line_value[0 +: 32] = branch_instruction(13'h020);
        send_response(32'h00000040, line_value, 1'b0);
        check(fetch_predicted_next_pc_o[0 +: 32] == 32'h00000044,
            "cold branch was not predicted not taken");
        check(fetch_occupancy_o == FE_WIDTH,
            "not-taken branch incorrectly truncated bundle");
        consume_count(FE_WIDTH);

        update_predictor(`RV32_OP_BEQ, 32'h00000040,
            32'h00000044, 32'h00000060, 1'b1);
        update_predictor(`RV32_OP_BEQ, 32'h00000040,
            32'h00000044, 32'h00000060, 1'b1);
        pulse_redirect(32'h00000040);
        accept_request(32'h00000040);
        send_response(32'h00000040, line_value, 1'b0);
        check(fetch_occupancy_o == 1,
            "taken branch did not truncate at first lane");
        check(fetch_predicted_next_pc_o[0 +: 32] == 32'h00000060,
            "taken branch target mismatch");
        wait_internal_flush;
        consume_count(1);
        accept_request(32'h00000060);

        pulse_redirect(32'h00000080);
        accept_request(32'h00000080);
        line_value = sequential_line(12'h050);
        line_value[0 +: 32] = 32'h00008067;
        send_response(32'h00000080, line_value, 1'b0);
        check(fetch_predicted_next_pc_o[0 +: 32] == 32'h00000084,
            "cold JALR did not fall through");
        consume_count(FE_WIDTH);
        update_predictor(`RV32_OP_JALR, 32'h00000080,
            32'h00000084, 32'h00000100, 1'b1);
        pulse_redirect(32'h00000080);
        accept_request(32'h00000080);
        send_response(32'h00000080, line_value, 1'b0);
        check(fetch_occupancy_o == 1,
            "BTB-hit JALR did not truncate bundle");
        check(fetch_predicted_next_pc_o[0 +: 32] == 32'h00000100,
            "BTB target mismatch");
        wait_internal_flush;
        consume_count(1);

        pulse_redirect(32'h00000120);
        accept_request(32'h00000120);
        line_value = sequential_line(12'h060);
        if (FE_WIDTH == 1)
            line_value[0 +: 32] = jal_instruction(21'h020);
        else
            line_value[32 +: 32] = jal_instruction(21'h01c);
        send_response(32'h00000120, line_value, 1'b0);
        if (FE_WIDTH == 1) begin
            check(fetch_occupancy_o == 1,
                "single-lane JAL occupancy mismatch");
            check(fetch_predicted_next_pc_o[0 +: 32] == 32'h00000140,
                "single-lane JAL target mismatch");
        end else begin
            check(fetch_occupancy_o == 2,
                "JAL did not preserve the leading prefix");
            check(fetch_predicted_next_pc_o[32 +: 32] == 32'h00000140,
                "multi-lane JAL target mismatch");
        end
        wait_internal_flush;
        consume_count((FE_WIDTH == 1) ? 1 : 2);

        pulse_redirect(32'h00000200);
        fill_iterations = 8 / FE_WIDTH;
        request_pc_value = 32'h00000200;
        for (request_index = 0; request_index < fill_iterations;
                request_index = request_index + 1) begin
            accept_request(request_pc_value);
            send_response(request_pc_value,
                sequential_line(12'h070 + request_index*4), 1'b0);
            request_pc_value = request_pc_value + FE_WIDTH*4;
        end
        check(fetch_occupancy_o == 8, "queue did not fill");
        accept_request(request_pc_value);
        icache_response_pc_i = request_pc_value;
        icache_response_line_i = sequential_line(12'h090);
        icache_response_valid_i = 1'b1;
        #1;
        check(!icache_response_ready_o,
            "full queue accepted a response without dequeue credit");
        fetch_ready_i = {FE_WIDTH{1'b1}};
        #1;
        check(icache_response_ready_o,
            "same-cycle dequeue credit did not release response");
        tick;
        fetch_ready_i = {FE_WIDTH{1'b0}};
        icache_response_valid_i = 1'b0;
        #1;
        check(fetch_occupancy_o == 8,
            "simultaneous dequeue/enqueue changed full occupancy");
        for (request_index = 0;
                request_index < ((8 - FE_WIDTH) / FE_WIDTH);
                request_index = request_index + 1)
            consume_count(FE_WIDTH);
        check(fetch_occupancy_o == FE_WIDTH,
            "wrapped queue did not retain replacement bundle");
        check(fetch_pc_o[0 +: 32] == request_pc_value,
            "wrapped queue replacement order mismatch");
        consume_count(FE_WIDTH);
        check(fetch_occupancy_o == 0,
            "wrapped queue did not drain");

        pulse_redirect(32'h00000300);
        accept_request(32'h00000300);
        pulse_redirect(32'h00000400);
        accept_request(32'h00000400);
        icache_response_pc_i = 32'h00000300;
        icache_response_line_i = sequential_line(12'h0a0);
        icache_response_valid_i = 1'b1;
        #1;
        check(icache_response_ready_o,
            "stale response was not drainable");
        tick;
        icache_response_valid_i = 1'b0;
        #1;
        check(fetch_occupancy_o == 0,
            "stale response entered fetch queue");
        send_response(32'h00000400, sequential_line(12'h0b0), 1'b0);
        check(fetch_pc_o[0 +: 32] == 32'h00000400,
            "live response was lost after stale response");
        consume_count(FE_WIDTH);

        pulse_redirect(32'h00000500);
        accept_request(32'h00000500);
        send_response(32'h00000500, 128'd0, 1'b1);
        check(fetch_occupancy_o == 1,
            "cache error did not create one queue entry");
        check(fetch_error_o[0], "cache error flag was not propagated");
        check(fetch_instruction_o[0 +: 32] == 32'd0,
            "cache error instruction was not zero");
        wait_internal_flush;
        consume_count(1);
        check(!icache_request_valid_o,
            "fetch continued after cache error");
        pulse_redirect(32'h00000600);
        check(icache_request_valid_o,
            "redirect did not clear fetch error block");

        check(conditional_total_o == 2,
            "conditional predictor statistics mismatch");
        check(jalr_total_o == 1,
            "JALR predictor statistics mismatch");
        check(control_total_o == 3,
            "control predictor statistics mismatch");

        $display("PASS rv32_fetch_pipeline FE_WIDTH=%0d BE_WIDTH=%0d checks=%0d",
            FE_WIDTH, BE_WIDTH, checks);
        $finish;
    end

endmodule

module rv32_fetch_pipeline_protocol_tb;

    parameter VIOLATION = 1;

    reg clk_i;
    reg reset_i;
    reg redirect_valid_i;
    reg [31:0] redirect_pc_i;
    reg icache_request_ready_i;
    reg icache_response_valid_i;
    reg [31:0] icache_response_pc_i;
    reg [127:0] icache_response_line_i;
    reg icache_response_error_i;
    reg [1:0] fetch_ready_i;
    wire icache_request_valid_o;
    wire [31:0] icache_request_pc_o;
    wire icache_response_ready_o;
    wire [1:0] fetch_valid_o;

    rv32_fetch_pipeline #(
        .FE_WIDTH(2),
        .BE_WIDTH(1)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .redirect_valid_i(redirect_valid_i),
        .redirect_pc_i(redirect_pc_i),
        .icache_flush_o(),
        .icache_request_valid_o(icache_request_valid_o),
        .icache_request_ready_i(icache_request_ready_i),
        .icache_request_pc_o(icache_request_pc_o),
        .icache_response_valid_i(icache_response_valid_i),
        .icache_response_ready_o(icache_response_ready_o),
        .icache_response_pc_i(icache_response_pc_i),
        .icache_response_line_i(icache_response_line_i),
        .icache_response_error_i(icache_response_error_i),
        .predictor_update_valid_i(1'b0),
        .predictor_update_op_i({`RV32_OP_WIDTH{1'b0}}),
        .predictor_update_pc_i(32'd0),
        .predictor_update_predicted_next_pc_i(32'd0),
        .predictor_update_actual_next_pc_i(32'd0),
        .predictor_update_actual_taken_i(1'b0),
        .conditional_correct_o(),
        .conditional_total_o(),
        .jal_correct_o(),
        .jal_total_o(),
        .jalr_correct_o(),
        .jalr_total_o(),
        .control_correct_o(),
        .control_total_o(),
        .fetch_valid_o(fetch_valid_o),
        .fetch_ready_i(fetch_ready_i),
        .fetch_pc_o(),
        .fetch_instruction_o(),
        .fetch_predicted_next_pc_o(),
        .fetch_error_o(),
        .fetch_occupancy_o()
    );

    always #5 clk_i = ~clk_i;

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b1;
        redirect_valid_i = 1'b0;
        redirect_pc_i = 32'd0;
        icache_request_ready_i = 1'b0;
        icache_response_valid_i = 1'b0;
        icache_response_pc_i = 32'd0;
        icache_response_line_i = {4{32'h00000013}};
        icache_response_error_i = 1'b0;
        fetch_ready_i = 2'b00;
        repeat (2) @(posedge clk_i);
        #1 reset_i = 1'b0;

        if (VIOLATION == 2) begin
            redirect_pc_i = 32'h00000002;
            redirect_valid_i = 1'b1;
            @(posedge clk_i);
        end else begin
            icache_request_ready_i = 1'b1;
            @(posedge clk_i);
            #1 icache_request_ready_i = 1'b0;
            icache_response_pc_i = 32'd0;
            icache_response_valid_i = 1'b1;
            @(posedge clk_i);
            #1 icache_response_valid_i = 1'b0;
            if (fetch_valid_o != 2'b11)
                $finish(2);
            fetch_ready_i = 2'b10;
            @(posedge clk_i);
        end

        $finish(2);
    end

endmodule
