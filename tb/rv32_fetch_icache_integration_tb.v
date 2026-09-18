`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_fetch_icache_integration_tb;

    reg clk_i;
    reg reset_i;
    wire icache_flush;
    wire icache_request_valid;
    wire icache_request_ready;
    wire [31:0] icache_request_pc;
    wire icache_response_valid;
    wire icache_response_ready;
    wire [31:0] icache_response_pc;
    wire [127:0] icache_response_line;
    wire icache_response_error;
    wire memory_request_valid;
    wire memory_request_ready;
    wire [31:0] memory_request_address;
    wire memory_response_valid;
    wire memory_response_ready;
    wire [127:0] memory_response_read_data;
    wire memory_response_error;
    wire [3:0] fetch_valid;
    reg [3:0] fetch_ready;
    wire [127:0] fetch_pc;
    wire [127:0] fetch_instruction;
    wire [127:0] fetch_predicted_next_pc;
    wire [3:0] fetch_error;
    wire [3:0] fetch_occupancy;

    integer accepted_count;
    integer cycle_count;
    integer lane;
    reg saw_prediction_flush;
    reg [31:0] expected_pc [0:5];

    rv32_fetch_pipeline #(
        .FE_WIDTH(4),
        .BE_WIDTH(1)
    ) fetch (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .redirect_valid_i(1'b0),
        .redirect_pc_i(32'd0),
        .icache_flush_o(icache_flush),
        .icache_request_valid_o(icache_request_valid),
        .icache_request_ready_i(icache_request_ready),
        .icache_request_pc_o(icache_request_pc),
        .icache_response_valid_i(icache_response_valid),
        .icache_response_ready_o(icache_response_ready),
        .icache_response_pc_i(icache_response_pc),
        .icache_response_line_i(icache_response_line),
        .icache_response_error_i(icache_response_error),
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
        .fetch_valid_o(fetch_valid),
        .fetch_ready_i(fetch_ready),
        .fetch_pc_o(fetch_pc),
        .fetch_instruction_o(fetch_instruction),
        .fetch_predicted_next_pc_o(fetch_predicted_next_pc),
        .fetch_error_o(fetch_error),
        .fetch_occupancy_o(fetch_occupancy)
    );

    rv32_l1_instruction_cache icache (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(icache_flush),
        .request_valid_i(icache_request_valid),
        .request_ready_o(icache_request_ready),
        .request_pc_i(icache_request_pc),
        .response_valid_o(icache_response_valid),
        .response_ready_i(icache_response_ready),
        .response_pc_o(icache_response_pc),
        .response_line_o(icache_response_line),
        .response_error_o(icache_response_error),
        .memory_request_valid_o(memory_request_valid),
        .memory_request_ready_i(memory_request_ready),
        .memory_request_address_o(memory_request_address),
        .memory_response_valid_i(memory_response_valid),
        .memory_response_ready_o(memory_response_ready),
        .memory_response_read_data_i(memory_response_read_data),
        .memory_response_error_i(memory_response_error),
        .hit_event_o(),
        .miss_event_o()
    );

    rv32_main_memory memory (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .i_request_valid_i(memory_request_valid),
        .i_request_ready_o(memory_request_ready),
        .i_request_address_i(memory_request_address),
        .i_response_valid_o(memory_response_valid),
        .i_response_ready_i(memory_response_ready),
        .i_response_read_data_o(memory_response_read_data),
        .i_response_error_o(memory_response_error),
        .d_request_valid_i(1'b0),
        .d_request_ready_o(),
        .d_request_write_i(1'b0),
        .d_request_address_i(32'd0),
        .d_request_write_data_i(128'd0),
        .d_request_byte_enable_i(16'd0),
        .d_response_valid_o(),
        .d_response_ready_i(1'b1),
        .d_response_read_data_o(),
        .d_response_error_o()
    );

    always #5 clk_i = ~clk_i;

    task write_word;
        input integer address;
        input [31:0] instruction;
        begin
            memory.byte_memory[address] = instruction[7:0];
            memory.byte_memory[address + 1] = instruction[15:8];
            memory.byte_memory[address + 2] = instruction[23:16];
            memory.byte_memory[address + 3] = instruction[31:24];
        end
    endtask

    always @(negedge clk_i) begin
        if (!reset_i) begin
            cycle_count = cycle_count + 1;
            if (icache_flush)
                saw_prediction_flush = 1'b1;
            for (lane = 0; lane < 4; lane = lane + 1) begin
                if (fetch_valid[lane] && fetch_ready[lane] &&
                        (accepted_count < 6)) begin
                    if (fetch_pc[lane*32 +: 32] !==
                            expected_pc[accepted_count]) begin
                        $display("ERROR fetch/I-cache integration pc[%0d]=%h expected=%h",
                            accepted_count, fetch_pc[lane*32 +: 32],
                            expected_pc[accepted_count]);
                        $finish(1);
                    end
                    if (fetch_error[lane]) begin
                        $display("ERROR fetch/I-cache integration error flag");
                        $finish(1);
                    end
                    if ((fetch_pc[lane*32 +: 32] == 32'h00000004) &&
                            (fetch_predicted_next_pc[lane*32 +: 32] !=
                                32'h00000020)) begin
                        $display("ERROR fetch/I-cache integration JAL target");
                        $finish(1);
                    end
                    accepted_count = accepted_count + 1;
                end
            end

            if (accepted_count == 6) begin
                if (!saw_prediction_flush) begin
                    $display("ERROR fetch/I-cache integration missing flush");
                    $finish(1);
                end
                $display("PASS rv32_fetch_icache_integration_tb cycles=%0d",
                    cycle_count);
                $finish;
            end

            if (cycle_count > 800) begin
                $display("ERROR fetch/I-cache integration timeout count=%0d occupancy=%0d",
                    accepted_count, fetch_occupancy);
                $finish(1);
            end
        end
    end

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b1;
        fetch_ready = 4'b1111;
        accepted_count = 0;
        cycle_count = 0;
        saw_prediction_flush = 1'b0;
        expected_pc[0] = 32'h00000000;
        expected_pc[1] = 32'h00000004;
        expected_pc[2] = 32'h00000020;
        expected_pc[3] = 32'h00000024;
        expected_pc[4] = 32'h00000028;
        expected_pc[5] = 32'h0000002c;

        #1;
        write_word(32'h00, 32'h00100093);
        write_word(32'h04, 32'h01c0006f);
        write_word(32'h08, 32'h00300193);
        write_word(32'h0c, 32'h00400213);
        write_word(32'h20, 32'h00500293);
        write_word(32'h24, 32'h00600313);
        write_word(32'h28, 32'h00700393);
        write_word(32'h2c, 32'h00800413);

        repeat (3) @(posedge clk_i);
        #1 reset_i = 1'b0;
    end

endmodule
