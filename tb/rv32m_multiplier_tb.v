`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32m_multiplier_tb #(
    parameter ROB_TAG_WIDTH = 5
);

    reg clk_i;
    reg reset_i;
    reg flush_i;
    reg request_valid_i;
    wire request_ready_o;
    reg [`RV32_OP_WIDTH-1:0] request_op_i;
    reg [31:0] request_lhs_i;
    reg [31:0] request_rhs_i;
    reg [ROB_TAG_WIDTH-1:0] request_rob_tag_i;
    wire response_valid_o;
    reg response_ready_i;
    wire [31:0] response_value_o;
    wire [ROB_TAG_WIDTH-1:0] response_rob_tag_o;

    integer test_count;
    integer error_count;
    integer seed;
    integer vector_file;
    reg [1023:0] vector_path;

    reg [31:0] expected_value_queue [0:63];
    reg [ROB_TAG_WIDTH-1:0] expected_tag_queue [0:63];

    rv32m_multiplier #(
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .request_valid_i(request_valid_i),
        .request_ready_o(request_ready_o),
        .request_op_i(request_op_i),
        .request_lhs_i(request_lhs_i),
        .request_rhs_i(request_rhs_i),
        .request_rob_tag_i(request_rob_tag_i),
        .response_valid_o(response_valid_o),
        .response_ready_i(response_ready_i),
        .response_value_o(response_value_o),
        .response_rob_tag_o(response_rob_tag_o)
    );

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    function [31:0] reference_value;
        input [`RV32_OP_WIDTH-1:0] op;
        input [31:0] lhs;
        input [31:0] rhs;
        reg signed [32:0] extended_lhs;
        reg signed [32:0] extended_rhs;
        reg signed [65:0] product;
        begin
            case (op)
                `RV32_OP_MUL: begin
                    extended_lhs = {1'b0, lhs};
                    extended_rhs = {1'b0, rhs};
                    product = extended_lhs * extended_rhs;
                    reference_value = product[31:0];
                end
                `RV32_OP_MULH: begin
                    extended_lhs = {lhs[31], lhs};
                    extended_rhs = {rhs[31], rhs};
                    product = extended_lhs * extended_rhs;
                    reference_value = product[63:32];
                end
                `RV32_OP_MULHSU: begin
                    extended_lhs = {lhs[31], lhs};
                    extended_rhs = {1'b0, rhs};
                    product = extended_lhs * extended_rhs;
                    reference_value = product[63:32];
                end
                `RV32_OP_MULHU: begin
                    extended_lhs = {1'b0, lhs};
                    extended_rhs = {1'b0, rhs};
                    product = extended_lhs * extended_rhs;
                    reference_value = product[63:32];
                end
                default: begin
                    reference_value = 32'd0;
                end
            endcase
        end
    endfunction

    task check_masked_empty;
        begin
            test_count = test_count + 1;
            if ((request_ready_o !== 1'b0) ||
                (response_valid_o !== 1'b0) ||
                (response_value_o !== 32'd0) ||
                (response_rob_tag_o !== {ROB_TAG_WIDTH{1'b0}})) begin
                error_count = error_count + 1;
                $display("FAIL masked outputs tag_width=%0d", ROB_TAG_WIDTH);
            end
        end
    endtask

    task check_no_response;
        begin
            test_count = test_count + 1;
            if (response_valid_o !== 1'b0) begin
                error_count = error_count + 1;
                $display("FAIL unexpected response value=%08x tag=%0d",
                    response_value_o, response_rob_tag_o);
            end
        end
    endtask

    task check_response;
        input [31:0] expected_value;
        input [ROB_TAG_WIDTH-1:0] expected_tag;
        begin
            test_count = test_count + 1;
            if ((response_valid_o !== 1'b1) ||
                (response_value_o !== expected_value) ||
                (response_rob_tag_o !== expected_tag)) begin
                error_count = error_count + 1;
                $display("FAIL response got valid=%b value=%08x tag=%0d",
                    response_valid_o, response_value_o, response_rob_tag_o);
                $display("  expected valid=1 value=%08x tag=%0d",
                    expected_value, expected_tag);
            end
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk_i);
            reset_i = 1'b1;
            flush_i = 1'b0;
            request_valid_i = 1'b0;
            response_ready_i = 1'b0;
            #1;
            check_masked_empty;
            @(posedge clk_i);
            #1;
            check_masked_empty;
            @(negedge clk_i);
            reset_i = 1'b0;
            #1;
            test_count = test_count + 1;
            if ((request_ready_o !== 1'b1) ||
                (response_valid_o !== 1'b0)) begin
                error_count = error_count + 1;
                $display("FAIL reset recovery tag_width=%0d", ROB_TAG_WIDTH);
            end
        end
    endtask

    task test_exact_latency;
        reg [31:0] expected;
        begin
            reset_dut;
            expected = reference_value(
                `RV32_OP_MULHSU, 32'h80000000, 32'hffffffff);

            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_MULHSU;
            request_lhs_i = 32'h80000000;
            request_rhs_i = 32'hffffffff;
            request_rob_tag_i = {ROB_TAG_WIDTH{1'b1}};
            response_ready_i = 1'b0;
            #1;
            test_count = test_count + 1;
            if (request_ready_o !== 1'b1) begin
                error_count = error_count + 1;
                $display("FAIL latency request was not accepted");
            end
            @(posedge clk_i);
            #1;
            check_no_response;

            @(negedge clk_i);
            request_valid_i = 1'b0;
            @(posedge clk_i);
            #1;
            check_no_response;

            @(posedge clk_i);
            #1;
            check_response(expected, {ROB_TAG_WIDTH{1'b1}});

            @(negedge clk_i);
            response_ready_i = 1'b1;
            @(posedge clk_i);
            #1;
            check_no_response;
        end
    endtask

    task test_invalid_operation;
        begin
            reset_dut;
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_ADD;
            request_lhs_i = 32'hffffffff;
            request_rhs_i = 32'hffffffff;
            request_rob_tag_i = {{(ROB_TAG_WIDTH-1){1'b0}}, 1'b1};
            response_ready_i = 1'b0;
            @(posedge clk_i);
            @(negedge clk_i);
            request_valid_i = 1'b0;
            @(posedge clk_i);
            @(posedge clk_i);
            #1;
            check_response(32'd0,
                {{(ROB_TAG_WIDTH-1){1'b0}}, 1'b1});
            @(negedge clk_i);
            response_ready_i = 1'b1;
            @(posedge clk_i);
            #1;
            check_no_response;
        end
    endtask

    task test_throughput;
        integer issue_index;
        integer response_index;
        reg [31:0] expected;
        begin
            reset_dut;
            response_ready_i = 1'b1;
            for (issue_index = 0; issue_index < 16;
                    issue_index = issue_index + 1) begin
                @(negedge clk_i);
                request_valid_i = 1'b1;
                case (issue_index & 3)
                    0: request_op_i = `RV32_OP_MUL;
                    1: request_op_i = `RV32_OP_MULH;
                    2: request_op_i = `RV32_OP_MULHSU;
                    default: request_op_i = `RV32_OP_MULHU;
                endcase
                request_lhs_i = 32'h80000000 ^ issue_index;
                request_rhs_i = 32'hfffffff1 - issue_index;
                request_rob_tag_i = issue_index;
                #1;
                test_count = test_count + 1;
                if (request_ready_o !== 1'b1) begin
                    error_count = error_count + 1;
                    $display("FAIL throughput request %0d not ready",
                        issue_index);
                end
                @(posedge clk_i);
                #1;
                if (issue_index < 2) begin
                    check_no_response;
                end else begin
                    response_index = issue_index - 2;
                    case (response_index & 3)
                        0: request_op_i = `RV32_OP_MUL;
                        1: request_op_i = `RV32_OP_MULH;
                        2: request_op_i = `RV32_OP_MULHSU;
                        default: request_op_i = `RV32_OP_MULHU;
                    endcase
                    expected = reference_value(request_op_i,
                        32'h80000000 ^ response_index,
                        32'hfffffff1 - response_index);
                    check_response(expected, response_index);
                end
            end

            @(negedge clk_i);
            request_valid_i = 1'b0;
            for (response_index = 14; response_index < 16;
                    response_index = response_index + 1) begin
                @(posedge clk_i);
                #1;
                case (response_index & 3)
                    0: request_op_i = `RV32_OP_MUL;
                    1: request_op_i = `RV32_OP_MULH;
                    2: request_op_i = `RV32_OP_MULHSU;
                    default: request_op_i = `RV32_OP_MULHU;
                endcase
                expected = reference_value(request_op_i,
                    32'h80000000 ^ response_index,
                    32'hfffffff1 - response_index);
                check_response(expected, response_index);
            end
            @(posedge clk_i);
            #1;
            check_no_response;
        end
    endtask

    task test_backpressure_and_replacement;
        integer issue_index;
        integer response_index;
        reg [31:0] held_value;
        reg [ROB_TAG_WIDTH-1:0] held_tag;
        reg [`RV32_OP_WIDTH-1:0] expected_op;
        reg [31:0] expected;
        begin
            reset_dut;
            response_ready_i = 1'b0;
            for (issue_index = 0; issue_index < 3;
                    issue_index = issue_index + 1) begin
                @(negedge clk_i);
                request_valid_i = 1'b1;
                request_op_i = `RV32_OP_MULHU;
                request_lhs_i = 32'hffffffff - issue_index;
                request_rhs_i = 32'h80000001 + issue_index;
                request_rob_tag_i = issue_index;
                #1;
                test_count = test_count + 1;
                if (request_ready_o !== 1'b1) begin
                    error_count = error_count + 1;
                    $display("FAIL fill request %0d not ready", issue_index);
                end
                @(posedge clk_i);
            end
            #1;
            expected = reference_value(
                `RV32_OP_MULHU, 32'hffffffff, 32'h80000001);
            check_response(expected, {ROB_TAG_WIDTH{1'b0}});
            test_count = test_count + 1;
            if (request_ready_o !== 1'b0) begin
                error_count = error_count + 1;
                $display("FAIL full pipeline did not apply backpressure");
            end
            held_value = response_value_o;
            held_tag = response_rob_tag_o;

            @(negedge clk_i);
            request_valid_i = 1'b0;
            repeat (3) begin
                @(posedge clk_i);
                #1;
                test_count = test_count + 1;
                if ((response_valid_o !== 1'b1) ||
                    (response_value_o !== held_value) ||
                    (response_rob_tag_o !== held_tag) ||
                    (request_ready_o !== 1'b0)) begin
                    error_count = error_count + 1;
                    $display("FAIL blocked pipeline changed state");
                end
            end

            for (response_index = 0; response_index < 4;
                    response_index = response_index + 1) begin
                @(negedge clk_i);
                response_ready_i = 1'b1;
                if (response_index == 0) begin
                    request_valid_i = 1'b1;
                    request_op_i = `RV32_OP_MULH;
                    request_lhs_i = 32'h80000000;
                    request_rhs_i = 32'h00000002;
                    request_rob_tag_i = 3;
                end else begin
                    request_valid_i = 1'b0;
                end
                #1;
                if (response_index < 3) begin
                    expected_op = `RV32_OP_MULHU;
                    expected = reference_value(expected_op,
                        32'hffffffff - response_index,
                        32'h80000001 + response_index);
                end else begin
                    expected_op = `RV32_OP_MULH;
                    expected = reference_value(expected_op,
                        32'h80000000, 32'h00000002);
                end
                check_response(expected, response_index);
                if ((response_index == 0) &&
                    (request_ready_o !== 1'b1)) begin
                    error_count = error_count + 1;
                    $display("FAIL simultaneous replacement not accepted");
                end
                @(posedge clk_i);
            end
            #1;
            check_no_response;
        end
    endtask

    task test_flush_at_depth;
        input integer advance_cycles;
        integer cycle_index;
        begin
            reset_dut;
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_MULH;
            request_lhs_i = 32'h80000000;
            request_rhs_i = 32'hffffffff;
            request_rob_tag_i = advance_cycles;
            response_ready_i = 1'b0;
            @(posedge clk_i);
            @(negedge clk_i);
            request_valid_i = 1'b0;

            for (cycle_index = 0; cycle_index < advance_cycles;
                    cycle_index = cycle_index + 1) begin
                @(posedge clk_i);
                @(negedge clk_i);
            end

            flush_i = 1'b1;
            request_valid_i = 1'b1;
            response_ready_i = 1'b1;
            #1;
            check_masked_empty;
            @(posedge clk_i);
            #1;
            check_masked_empty;

            @(negedge clk_i);
            flush_i = 1'b0;
            request_valid_i = 1'b0;
            repeat (4) begin
                @(posedge clk_i);
                #1;
                check_no_response;
            end
        end
    endtask

    task test_full_flush_and_reset_priority;
        integer issue_index;
        begin
            reset_dut;
            response_ready_i = 1'b0;
            for (issue_index = 0; issue_index < 3;
                    issue_index = issue_index + 1) begin
                @(negedge clk_i);
                request_valid_i = 1'b1;
                request_op_i = `RV32_OP_MUL;
                request_lhs_i = issue_index + 1;
                request_rhs_i = 32'hffffffff;
                request_rob_tag_i = issue_index;
                @(posedge clk_i);
            end

            @(negedge clk_i);
            reset_i = 1'b1;
            flush_i = 1'b1;
            request_valid_i = 1'b1;
            response_ready_i = 1'b1;
            #1;
            check_masked_empty;
            @(posedge clk_i);
            #1;
            check_masked_empty;

            @(negedge clk_i);
            reset_i = 1'b0;
            flush_i = 1'b0;
            request_valid_i = 1'b0;
            repeat (4) begin
                @(posedge clk_i);
                #1;
                check_no_response;
            end
        end
    endtask

    task run_vector_stream;
        integer queue_head;
        integer queue_tail;
        integer queue_count;
        integer pending_valid;
        integer eof_reached;
        integer scan_result;
        integer do_enqueue;
        integer do_dequeue;
        integer issued_count;
        integer cycle_count;
        integer finished;
        reg [`RV32_OP_WIDTH-1:0] vector_op;
        reg [31:0] vector_lhs;
        reg [31:0] vector_rhs;
        reg [31:0] vector_expected;
        begin
            reset_dut;
            queue_head = 0;
            queue_tail = 0;
            queue_count = 0;
            pending_valid = 0;
            eof_reached = 0;
            issued_count = 0;
            cycle_count = 0;
            finished = 0;

            while ((finished == 0) && (cycle_count < 500000)) begin
                @(negedge clk_i);
                cycle_count = cycle_count + 1;
                response_ready_i = (($random(seed) & 32'h00000007) != 0);

                if ((pending_valid == 0) && (eof_reached == 0) &&
                    (($random(seed) & 32'h00000003) != 0)) begin
                    scan_result = $fscanf(vector_file, "%h %h %h %h\n",
                        vector_op, vector_lhs, vector_rhs, vector_expected);
                    if (scan_result == 4) begin
                        pending_valid = 1;
                    end else begin
                        eof_reached = 1;
                    end
                end

                request_valid_i = pending_valid;
                request_op_i = vector_op;
                request_lhs_i = vector_lhs;
                request_rhs_i = vector_rhs;
                request_rob_tag_i = issued_count;
                #1;

                do_enqueue = request_valid_i && request_ready_o;
                do_dequeue = response_valid_o && response_ready_i;

                if (response_valid_o) begin
                    test_count = test_count + 1;
                    if (queue_count == 0) begin
                        error_count = error_count + 1;
                        $display("FAIL vector stream produced ghost response");
                    end else if ((response_value_o !==
                            expected_value_queue[queue_head]) ||
                        (response_rob_tag_o !==
                            expected_tag_queue[queue_head])) begin
                        error_count = error_count + 1;
                        $display("FAIL vector %0d got value=%08x tag=%0d",
                            issued_count, response_value_o,
                            response_rob_tag_o);
                        $display("  expected value=%08x tag=%0d",
                            expected_value_queue[queue_head],
                            expected_tag_queue[queue_head]);
                    end
                end

                if (do_enqueue) begin
                    if (queue_count >= 63) begin
                        error_count = error_count + 1;
                        $display("FAIL scoreboard overflow");
                    end
                    expected_value_queue[queue_tail] = vector_expected;
                    expected_tag_queue[queue_tail] = issued_count;
                end

                @(posedge clk_i);
                #1;
                if (do_dequeue) begin
                    queue_head = (queue_head + 1) & 63;
                end
                if (do_enqueue) begin
                    queue_tail = (queue_tail + 1) & 63;
                    issued_count = issued_count + 1;
                    pending_valid = 0;
                end
                case ({do_enqueue[0], do_dequeue[0]})
                    2'b10: queue_count = queue_count + 1;
                    2'b01: queue_count = queue_count - 1;
                    default: queue_count = queue_count;
                endcase

                if (eof_reached && (pending_valid == 0) &&
                    (queue_count == 0) && !response_valid_o) begin
                    finished = 1;
                end
            end

            test_count = test_count + 1;
            if (finished == 0) begin
                error_count = error_count + 1;
                $display("FAIL vector stream timeout after %0d cycles",
                    cycle_count);
            end
            $display("Checked %0d vectors with ROB_TAG_WIDTH=%0d in %0d cycles",
                issued_count, ROB_TAG_WIDTH, cycle_count);
            request_valid_i = 1'b0;
            response_ready_i = 1'b0;
        end
    endtask

    initial begin
        reset_i = 1'b0;
        flush_i = 1'b0;
        request_valid_i = 1'b0;
        request_op_i = `RV32_OP_INVALID;
        request_lhs_i = 32'd0;
        request_rhs_i = 32'd0;
        request_rob_tag_i = {ROB_TAG_WIDTH{1'b0}};
        response_ready_i = 1'b0;
        test_count = 0;
        error_count = 0;
        seed = 32'h4d554c33 ^ ROB_TAG_WIDTH;

        if (!$value$plusargs("VECTOR_FILE=%s", vector_path)) begin
            $display("FAIL missing +VECTOR_FILE=<path>");
            $finish(1);
        end
        vector_file = $fopen(vector_path, "r");
        if (vector_file == 0) begin
            $display("FAIL cannot open vector file %s", vector_path);
            $finish(1);
        end

        test_exact_latency;
        test_invalid_operation;
        test_throughput;
        test_backpressure_and_replacement;
        test_flush_at_depth(0);
        test_flush_at_depth(1);
        test_flush_at_depth(2);
        test_full_flush_and_reset_priority;
        run_vector_stream;

        $fclose(vector_file);
        if (error_count != 0) begin
            $display("FAIL rv32m_multiplier_tb width=%0d tests=%0d errors=%0d",
                ROB_TAG_WIDTH, test_count, error_count);
            $finish(1);
        end
        $display("PASS rv32m_multiplier_tb width=%0d tests=%0d",
            ROB_TAG_WIDTH, test_count);
        $finish(0);
    end

endmodule
