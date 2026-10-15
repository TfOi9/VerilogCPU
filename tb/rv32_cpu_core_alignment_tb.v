`timescale 1ns/1ps

module rv32_cpu_core_alignment_tb;
    parameter FE_WIDTH = 1;
    parameter BE_WIDTH = 1;

    reg clk;
    reg reset;
    wire i_flush;
    wire i_valid;
    wire [31:0] i_pc;
    reg i_response_valid;
    reg [31:0] i_response_pc;
    reg [127:0] i_response_line;
    wire i_response_ready;
    wire d_valid;
    reg [31:0] words [0:63];
    integer test_case;
    integer cycles;
    integer retired;
    integer lane;
    integer word_index;
    integer expected_retired;
    reg [31:0] expected_pc;
    reg [31:0] expected_target;

    rv32_cpu_core #(.FE_WIDTH(FE_WIDTH), .BE_WIDTH(BE_WIDTH)) dut (
        .dcache_request_rob_tag_o(), .dcache_response_rob_tag_i(0),
        .dcache_request_id_o(), .dcache_response_id_i(2'd0),
        .clk_i(clk), .reset_i(reset), .icache_flush_o(i_flush),
        .icache_request_valid_o(i_valid),
        .icache_request_ready_i(!i_response_valid),
        .icache_request_pc_o(i_pc), .icache_response_valid_i(i_response_valid),
        .icache_response_ready_o(i_response_ready),
        .icache_response_pc_i(i_response_pc),
        .icache_response_line_i(i_response_line), .icache_response_error_i(1'b0),
        .dcache_request_valid_o(d_valid), .dcache_request_ready_i(1'b1),
        .dcache_store_confirm_valid_i(1'b0), .dcache_store_confirm_id_i(2'd0),
        .dcache_store_confirm_rob_tag_i(7'd0),
        .dcache_request_irrevocable_i(1'b0),
        .dcache_request_write_o(), .dcache_request_address_o(),
        .dcache_request_write_data_o(), .dcache_request_byte_enable_o(),
        .dcache_request_mmio_o(), .dcache_response_valid_i(1'b0),
        .dcache_response_ready_o(), .dcache_response_read_data_i(32'd0),
        .dcache_response_error_i(1'b0)
    );

    task fail;
        input [8*80-1:0] message;
        begin
            $display("FAIL alignment FE=%0d BE=%0d case=%0d: %0s",
                FE_WIDTH, BE_WIDTH, test_case, message);
            $stop;
        end
    endtask

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (reset || i_flush) begin
            i_response_valid <= 1'b0;
        end else begin
            if (i_response_valid && i_response_ready)
                i_response_valid <= 1'b0;
            if (i_valid && !i_response_valid) begin
                i_response_valid <= 1'b1;
                i_response_pc <= i_pc;
                for (word_index = 0; word_index < 4; word_index = word_index + 1)
                    i_response_line[word_index*32 +: 32] <=
                        words[{i_pc[7:4], 2'b00} + word_index];
            end
        end
        if (!reset) begin
            cycles = cycles + 1;
            if (cycles > 2000) fail("cycle timeout");
            if (d_valid) fail("younger store escaped exception");
            for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                if (dut.commit_fire[lane]) begin
                    if (dut.rob.commit_pc_o[lane*32 +: 32] >= expected_pc)
                        fail("faulting or younger instruction retired");
                    retired = retired + 1;
                    if (test_case == 4 && dut.commit_rd[lane*5 +: 5] == 2 &&
                            dut.rob.commit_value_o[lane*32 +: 32] != 8)
                        fail("aligned JALR link value mismatch");
                end
            end
            if (dut.fatal_reg) begin
                if (!dut.commit_exception_valid[0] ||
                        dut.rob.commit_pc_o[0 +: 32] != expected_pc ||
                        dut.rob.commit_exception_cause_o[0 +: 4] != 0 ||
                        dut.rob.commit_exception_tval_o[0 +: 32] != expected_target ||
                        retired != expected_retired)
                    fail("incorrect precise instruction address exception");
                $display("PASS alignment FE=%0d BE=%0d case=%0d pc=%h tval=%h retired=%0d",
                    FE_WIDTH, BE_WIDTH, test_case, expected_pc, expected_target, retired);
                $finish;
            end
        end
    end

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        i_response_valid = 1'b0;
        i_response_pc = 32'd0;
        i_response_line = 128'd0;
        cycles = 0;
        retired = 0;
        if (!$value$plusargs("CASE=%d", test_case)) test_case = 0;
        for (word_index = 0; word_index < 64; word_index = word_index + 1)
            words[word_index] = 32'h00000013;
        expected_pc = 0;
        expected_target = 2;
        expected_retired = 0;
        case (test_case)
            0: words[0] = 32'h002000ef;
            1: begin
                words[0] = 32'h00300093;
                words[1] = 32'h00008167;
                expected_pc = 4;
                expected_retired = 1;
            end
            2: words[0] = 32'h00000163;
            3: begin
                words[0] = 32'h00001163;
                words[1] = 32'h002000ef;
                expected_pc = 4;
                expected_target = 6;
                expected_retired = 1;
            end
            4: begin
                words[0] = 32'h00900093;
                words[1] = 32'h00008167;
                words[2] = 32'h002000ef;
                expected_pc = 8;
                expected_target = 10;
                expected_retired = 2;
            end
            default: fail("unknown test case");
        endcase
        words[(expected_pc >> 2) + 1] = 32'h00002023;
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
    end
endmodule
