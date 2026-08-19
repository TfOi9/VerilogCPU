`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32m_divider_tb #(
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

    rv32m_divider #(
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

    task run_case;
        input [`RV32_OP_WIDTH-1:0] op;
        input [31:0] lhs;
        input [31:0] rhs;
        input [31:0] expected_value;
        input [ROB_TAG_WIDTH-1:0] expected_tag;
        integer cycle_index;
        begin
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = op;
            request_lhs_i = lhs;
            request_rhs_i = rhs;
            request_rob_tag_i = expected_tag;
            response_ready_i = 1'b0;
            #1;
            test_count = test_count + 1;
            if (request_ready_o !== 1'b1) begin
                error_count = error_count + 1;
                $display("FAIL request not ready op=%0d lhs=%08x rhs=%08x",
                    op, lhs, rhs);
            end
            @(posedge clk_i);
            #1;
            check_no_response;

            @(negedge clk_i);
            request_valid_i = 1'b0;
            for (cycle_index = 2; cycle_index < 32;
                    cycle_index = cycle_index + 1) begin
                @(posedge clk_i);
                #1;
                check_no_response;
            end

            @(posedge clk_i);
            #1;
            check_response(expected_value, expected_tag);

            @(negedge clk_i);
            response_ready_i = 1'b1;
            @(posedge clk_i);
            #1;
            check_no_response;
            @(negedge clk_i);
            response_ready_i = 1'b0;
        end
    endtask

    task test_exact_latency_and_busy;
        integer cycle_index;
        begin
            reset_dut;
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_DIVU;
            request_lhs_i = 32'd100;
            request_rhs_i = 32'd7;
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
            request_op_i = `RV32_OP_DIV;
            request_lhs_i = 32'h80000000;
            request_rhs_i = 32'hffffffff;
            request_rob_tag_i = {ROB_TAG_WIDTH{1'b0}};
            for (cycle_index = 2; cycle_index < 32;
                    cycle_index = cycle_index + 1) begin
                #1;
                test_count = test_count + 1;
                if (request_ready_o !== 1'b0) begin
                    error_count = error_count + 1;
                    $display("FAIL divider accepted request while busy cycle=%0d",
                        cycle_index);
                end
                @(posedge clk_i);
                #1;
                check_no_response;
                @(negedge clk_i);
            end

            request_valid_i = 1'b0;
            @(posedge clk_i);
            #1;
            check_response(32'd14, {ROB_TAG_WIDTH{1'b1}});
            test_count = test_count + 1;
            if (request_ready_o !== 1'b0) begin
                error_count = error_count + 1;
                $display("FAIL blocked response did not apply backpressure");
            end

            @(negedge clk_i);
            response_ready_i = 1'b1;
            @(posedge clk_i);
            #1;
            check_no_response;
            @(negedge clk_i);
            response_ready_i = 1'b0;
        end
    endtask

    task test_directed_values;
        begin
            reset_dut;
            run_case(`RV32_OP_DIV, 32'd7, 32'd3, 32'd2, 1);
            run_case(`RV32_OP_REM, 32'd7, 32'd3, 32'd1, 2);
            run_case(`RV32_OP_DIV, 32'hfffffff9, 32'd3,
                32'hfffffffe, 3);
            run_case(`RV32_OP_REM, 32'hfffffff9, 32'd3,
                32'hffffffff, 4);
            run_case(`RV32_OP_DIV, 32'd7, 32'hfffffffd,
                32'hfffffffe, 5);
            run_case(`RV32_OP_REM, 32'd7, 32'hfffffffd,
                32'd1, 6);
            run_case(`RV32_OP_DIV, 32'hfffffff9, 32'hfffffffd,
                32'd2, 7);
            run_case(`RV32_OP_REM, 32'hfffffff9, 32'hfffffffd,
                32'hffffffff, 8);
            run_case(`RV32_OP_DIV, 32'h80000000, 32'hffffffff,
                32'h80000000, 9);
            run_case(`RV32_OP_REM, 32'h80000000, 32'hffffffff,
                32'd0, 10);
            run_case(`RV32_OP_DIV, 32'h80000000, 32'd0,
                32'hffffffff, 11);
            run_case(`RV32_OP_REM, 32'h80000000, 32'd0,
                32'h80000000, 12);
            run_case(`RV32_OP_DIVU, 32'hdeadbeef, 32'd0,
                32'hffffffff, 13);
            run_case(`RV32_OP_REMU, 32'hdeadbeef, 32'd0,
                32'hdeadbeef, 14);
            run_case(`RV32_OP_DIVU, 32'd3, 32'd7, 32'd0, 15);
            run_case(`RV32_OP_REMU, 32'd3, 32'd7, 32'd3, 16);
            run_case(`RV32_OP_DIVU, 32'hffffffff, 32'hffffffff,
                32'd1, 17);
            run_case(`RV32_OP_REMU, 32'hffffffff, 32'hffffffff,
                32'd0, 18);
            run_case(`RV32_OP_ADD, 32'hffffffff, 32'hffffffff,
                32'd0, 19);
        end
    endtask

    task test_backpressure_and_replacement;
        integer cycle_index;
        reg [31:0] held_value;
        reg [ROB_TAG_WIDTH-1:0] held_tag;
        begin
            reset_dut;
            run_case(`RV32_OP_DIVU, 32'd100, 32'd9, 32'd11, 20);

            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_REMU;
            request_lhs_i = 32'hffffffff;
            request_rhs_i = 32'd16;
            request_rob_tag_i = 21;
            response_ready_i = 1'b0;
            @(posedge clk_i);
            @(negedge clk_i);
            request_valid_i = 1'b0;
            repeat (30) begin
                @(posedge clk_i);
                @(negedge clk_i);
            end
            @(posedge clk_i);
            #1;
            check_response(32'd15, 21);
            held_value = response_value_o;
            held_tag = response_rob_tag_o;

            repeat (4) begin
                @(posedge clk_i);
                #1;
                test_count = test_count + 1;
                if ((response_valid_o !== 1'b1) ||
                    (response_value_o !== held_value) ||
                    (response_rob_tag_o !== held_tag) ||
                    (request_ready_o !== 1'b0)) begin
                    error_count = error_count + 1;
                    $display("FAIL blocked response changed state");
                end
            end

            @(negedge clk_i);
            response_ready_i = 1'b1;
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_DIV;
            request_lhs_i = 32'hfffffff9;
            request_rhs_i = 32'd3;
            request_rob_tag_i = 22;
            #1;
            check_response(32'd15, 21);
            test_count = test_count + 1;
            if (request_ready_o !== 1'b1) begin
                error_count = error_count + 1;
                $display("FAIL simultaneous replacement not accepted");
            end
            @(posedge clk_i);
            #1;
            check_no_response;
            @(negedge clk_i);
            request_valid_i = 1'b0;
            response_ready_i = 1'b0;

            for (cycle_index = 2; cycle_index < 32;
                    cycle_index = cycle_index + 1) begin
                @(posedge clk_i);
                #1;
                check_no_response;
            end
            @(posedge clk_i);
            #1;
            check_response(32'hfffffffe, 22);
            @(negedge clk_i);
            response_ready_i = 1'b1;
            @(posedge clk_i);
            #1;
            check_no_response;
            @(negedge clk_i);
            response_ready_i = 1'b0;
        end
    endtask

    task test_flush_at_depth;
        input integer advance_cycles;
        integer cycle_index;
        begin
            reset_dut;
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_DIV;
            request_lhs_i = 32'h80000000;
            request_rhs_i = 32'd7;
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
            response_ready_i = 1'b0;
            #1;
            test_count = test_count + 1;
            if (request_ready_o !== 1'b1) begin
                error_count = error_count + 1;
                $display("FAIL flush recovery depth=%0d", advance_cycles);
            end
            repeat (34) begin
                @(posedge clk_i);
                #1;
                check_no_response;
            end
        end
    endtask

    task test_reset_mid_operation;
        begin
            reset_dut;
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_REMU;
            request_lhs_i = 32'hffffffff;
            request_rhs_i = 32'd17;
            request_rob_tag_i = 23;
            @(posedge clk_i);
            @(negedge clk_i);
            request_valid_i = 1'b0;
            repeat (12) begin
                @(posedge clk_i);
                @(negedge clk_i);
            end

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
            response_ready_i = 1'b0;
            repeat (34) begin
                @(posedge clk_i);
                #1;
                check_no_response;
            end
        end
    endtask

    task test_reset_pending_response;
        begin
            reset_dut;
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_DIVU;
            request_lhs_i = 32'hffffffff;
            request_rhs_i = 32'd3;
            request_rob_tag_i = 24;
            response_ready_i = 1'b0;
            @(posedge clk_i);
            @(negedge clk_i);
            request_valid_i = 1'b0;
            repeat (30) begin
                @(posedge clk_i);
                @(negedge clk_i);
            end
            @(posedge clk_i);
            #1;
            check_response(32'h55555555, 24);

            @(negedge clk_i);
            reset_i = 1'b1;
            response_ready_i = 1'b1;
            #1;
            check_masked_empty;
            @(posedge clk_i);
            #1;
            check_masked_empty;
            @(negedge clk_i);
            reset_i = 1'b0;
            response_ready_i = 1'b0;
            #1;
            test_count = test_count + 1;
            if (request_ready_o !== 1'b1) begin
                error_count = error_count + 1;
                $display("FAIL reset recovery from pending response");
            end
            repeat (3) begin
                @(posedge clk_i);
                #1;
                check_no_response;
            end
        end
    endtask

    task run_vector_stream;
        integer scan_result;
        integer issued_count;
        integer cycle_count;
        integer cycle_index;
        integer stall_cycles;
        reg [`RV32_OP_WIDTH-1:0] vector_op;
        reg [31:0] vector_lhs;
        reg [31:0] vector_rhs;
        reg [31:0] vector_expected;
        begin
            reset_dut;
            issued_count = 0;
            cycle_count = 0;
            scan_result = $fscanf(vector_file, "%h %h %h %h\n",
                vector_op, vector_lhs, vector_rhs, vector_expected);

            while ((scan_result == 4) && (cycle_count < 1000000)) begin
                @(negedge clk_i);
                request_valid_i = 1'b1;
                request_op_i = vector_op;
                request_lhs_i = vector_lhs;
                request_rhs_i = vector_rhs;
                request_rob_tag_i = issued_count;
                response_ready_i = 1'b0;
                #1;
                test_count = test_count + 1;
                if (request_ready_o !== 1'b1) begin
                    error_count = error_count + 1;
                    $display("FAIL vector %0d request not ready", issued_count);
                end
                @(posedge clk_i);
                cycle_count = cycle_count + 1;
                @(negedge clk_i);
                request_valid_i = 1'b0;

                for (cycle_index = 2; cycle_index < 32;
                        cycle_index = cycle_index + 1) begin
                    @(posedge clk_i);
                    cycle_count = cycle_count + 1;
                end
                @(posedge clk_i);
                cycle_count = cycle_count + 1;
                #1;
                check_response(vector_expected, issued_count);

                stall_cycles = $random(seed) & 3;
                repeat (stall_cycles) begin
                    @(posedge clk_i);
                    cycle_count = cycle_count + 1;
                    #1;
                    check_response(vector_expected, issued_count);
                end

                @(negedge clk_i);
                response_ready_i = 1'b1;
                @(posedge clk_i);
                cycle_count = cycle_count + 1;
                #1;
                check_no_response;
                response_ready_i = 1'b0;

                issued_count = issued_count + 1;
                scan_result = $fscanf(vector_file, "%h %h %h %h\n",
                    vector_op, vector_lhs, vector_rhs, vector_expected);
            end

            test_count = test_count + 1;
            if (scan_result == 4) begin
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
        seed = 32'h44495632 ^ ROB_TAG_WIDTH;

        if (!$value$plusargs("VECTOR_FILE=%s", vector_path)) begin
            $display("FAIL missing +VECTOR_FILE=<path>");
            $finish(1);
        end
        vector_file = $fopen(vector_path, "r");
        if (vector_file == 0) begin
            $display("FAIL cannot open vector file %s", vector_path);
            $finish(1);
        end

        test_exact_latency_and_busy;
        test_directed_values;
        test_backpressure_and_replacement;
        test_flush_at_depth(0);
        test_flush_at_depth(1);
        test_flush_at_depth(15);
        test_flush_at_depth(30);
        test_flush_at_depth(31);
        test_reset_mid_operation;
        test_reset_pending_response;
        run_vector_stream;

        $fclose(vector_file);
        if (error_count != 0) begin
            $display("FAIL rv32m_divider_tb width=%0d tests=%0d errors=%0d",
                ROB_TAG_WIDTH, test_count, error_count);
            $finish(1);
        end
        $display("PASS rv32m_divider_tb width=%0d tests=%0d",
            ROB_TAG_WIDTH, test_count);
        $finish(0);
    end

endmodule
