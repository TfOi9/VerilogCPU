`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_lsq_rob_integration_tb;
    localparam ROB_INDEX_WIDTH = 4;
    localparam ROB_TAG_WIDTH = 6;
    localparam LSQ_TAG_WIDTH = 5;
    reg clk_i;
    reg reset_i;
    reg alloc_valid;
    reg alloc_fire;
    reg [`RV32_OP_WIDTH-1:0] alloc_op;
    reg alloc_store;
    reg [`RV32_MEMORY_WIDTH-1:0] alloc_width;
    wire rob_alloc_ready;
    wire [ROB_TAG_WIDTH-1:0] rob_alloc_tag;
    wire lsq_alloc_ready;
    wire [LSQ_TAG_WIDTH-1:0] lsq_alloc_tag;
    reg store_address_valid;
    reg [31:0] store_address;
    reg store_data_valid;
    reg [31:0] store_data;
    reg load_address_valid;
    reg [31:0] load_address;
    reg [ROB_TAG_WIDTH-1:0] transaction_rob_tag;
    reg [LSQ_TAG_WIDTH-1:0] transaction_lsq_tag;
    wire source_valid;
    wire source_ready;
    wire [ROB_TAG_WIDTH-1:0] source_tag;
    wire [31:0] source_value;
    wire source_exception;
    wire [3:0] source_cause;
    wire [31:0] source_tval;
    wire completion_valid;
    wire [ROB_TAG_WIDTH-1:0] completion_tag;
    wire [31:0] completion_value;
    wire completion_exception;
    wire [3:0] completion_cause;
    wire [31:0] completion_tval;
    wire completion_ready;
    wire completion_accept;
    wire completion_writes_rd;
    wire [5:0] completion_phys;
    wire writeback_valid;
    wire [5:0] writeback_phys;
    wire [31:0] writeback_value;
    reg saw_load_writeback;
    wire commit_valid;
    wire commit_fire;
    wire [ROB_TAG_WIDTH-1:0] commit_tag;
    wire [`RV32_OP_WIDTH-1:0] commit_op;
    wire [31:0] commit_value;
    wire commit_lsq_valid;
    wire [LSQ_TAG_WIDTH-1:0] commit_lsq_tag;
    wire commit_exception;
    wire [3:0] commit_cause;
    wire [31:0] commit_tval;
    wire commit_ready;
    wire [ROB_INDEX_WIDTH-1:0] rob_head;
    wire recover_busy;
    wire cache_req_valid;
    reg cache_req_ready;
    wire cache_req_write;
    wire [31:0] cache_req_address;
    wire [31:0] cache_req_data;
    wire [3:0] cache_req_mask;
    reg cache_resp_valid;
    wire cache_resp_ready;
    reg [31:0] cache_resp_data;
    reg cache_resp_error;
    integer cycles;

    rv32_load_store_queue #(
        .ROB_ENTRIES(16), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) lsq (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(1'b0),
        .recover_i(recover_busy), .alloc_valid_i(alloc_valid),
        .alloc_fire_i(alloc_fire), .alloc_store_i(alloc_store),
        .alloc_rob_tag_i(rob_alloc_tag), .alloc_width_i(alloc_width),
        .alloc_unsigned_i(1'b0), .alloc_ready_o(lsq_alloc_ready),
        .alloc_lsq_tag_o(lsq_alloc_tag), .occupancy_o(),
        .load_address_valid_i(load_address_valid),
        .load_address_ready_o(),
        .load_address_rob_tag_i(transaction_rob_tag),
        .load_address_lsq_tag_i(transaction_lsq_tag),
        .load_address_i(load_address),
        .store_address_valid_i(store_address_valid),
        .store_address_ready_o(),
        .store_address_rob_tag_i(transaction_rob_tag),
        .store_address_lsq_tag_i(transaction_lsq_tag),
        .store_address_i(store_address),
        .store_data_valid_i(store_data_valid), .store_data_ready_o(),
        .store_data_rob_tag_i(transaction_rob_tag),
        .store_data_lsq_tag_i(transaction_lsq_tag),
        .store_data_i(store_data), .rob_head_index_i(rob_head),
        .rollback_valid_i(1'b0), .rollback_rob_tag_i({ROB_TAG_WIDTH{1'b0}}),
        .rollback_lsq_tag_i({LSQ_TAG_WIDTH{1'b0}}),
        .completion_valid_o(source_valid),
        .completion_ready_i(source_ready),
        .completion_rob_tag_o(source_tag),
        .completion_value_o(source_value),
        .completion_exception_valid_o(source_exception),
        .completion_exception_cause_o(source_cause),
        .completion_exception_tval_o(source_tval),
        .commit_valid_i(commit_valid),
        .commit_op_i(commit_op),
        .commit_lsq_valid_i(commit_lsq_valid),
        .commit_rob_tag_i(commit_tag),
        .commit_lsq_tag_i(commit_lsq_tag),
        .commit_exception_valid_i(commit_exception),
        .commit_fire_i(commit_fire), .commit_ready_o(commit_ready),
        .cache_request_valid_o(cache_req_valid),
        .cache_request_ready_i(cache_req_ready),
        .cache_request_write_o(cache_req_write),
        .cache_request_address_o(cache_req_address),
        .cache_request_write_data_o(cache_req_data),
        .cache_request_byte_enable_o(cache_req_mask),
        .cache_response_valid_i(cache_resp_valid),
        .cache_response_ready_o(cache_resp_ready),
        .cache_response_read_data_i(cache_resp_data),
        .cache_response_error_i(cache_resp_error)
    );

    rv32_completion_writeback_network #(
        .BE_WIDTH(1), .SOURCE_COUNT(1), .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) network (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(1'b0),
        .recover_i(recover_busy), .source_valid_i(source_valid),
        .source_ready_o(source_ready), .source_rob_tag_i(source_tag),
        .source_value_i(source_value), .source_control_valid_i(1'b0),
        .source_control_taken_i(1'b0), .source_next_pc_i(32'd0),
        .source_exception_valid_i(source_exception),
        .source_exception_cause_i(source_cause),
        .source_exception_tval_i(source_tval),
        .completion_valid_o(completion_valid),
        .completion_tag_o(completion_tag),
        .completion_value_o(completion_value),
        .completion_control_valid_o(), .completion_control_taken_o(),
        .completion_next_pc_o(),
        .completion_exception_valid_o(completion_exception),
        .completion_exception_cause_o(completion_cause),
        .completion_exception_tval_o(completion_tval),
        .completion_ready_i(completion_ready),
        .completion_accept_i(completion_accept),
        .completion_writes_rd_i(completion_writes_rd),
        .completion_phys_i(completion_phys),
        .writeback_valid_o(writeback_valid),
        .writeback_phys_o(writeback_phys),
        .writeback_value_o(writeback_value)
    );

    rv32_reorder_buffer #(
        .ROB_ENTRIES(16), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH), .LSQ_TAG_WIDTH(LSQ_TAG_WIDTH)
    ) rob (
        .clk_i(clk_i), .reset_i(reset_i),
        .alloc_valid_i(alloc_valid), .alloc_fire_i(alloc_fire),
        .alloc_pc_i(32'd0), .alloc_instruction_i(32'd0),
        .alloc_op_i(alloc_op),
        .alloc_writes_rd_i(alloc_op == `RV32_OP_LB),
        .alloc_rd_i(5'd1), .alloc_new_phys_i(6'd1),
        .alloc_old_phys_i(6'd0), .alloc_predicted_next_pc_i(32'd4),
        .alloc_lsq_valid_i(alloc_valid), .alloc_lsq_tag_i(lsq_alloc_tag),
        .alloc_complete_i(1'b0), .alloc_exception_valid_i(1'b0),
        .alloc_exception_cause_i(4'd0), .alloc_exception_tval_i(32'd0),
        .alloc_ready_o(rob_alloc_ready), .alloc_tag_o(rob_alloc_tag),
        .occupancy_o(), .head_index_o(rob_head),
        .completion_valid_i(completion_valid),
        .completion_tag_i(completion_tag),
        .completion_value_i(completion_value),
        .completion_control_valid_i(1'b0),
        .completion_control_taken_i(1'b0),
        .completion_next_pc_i(32'd0),
        .completion_exception_valid_i(completion_exception),
        .completion_exception_cause_i(completion_cause),
        .completion_exception_tval_i(completion_tval),
        .completion_ready_o(completion_ready),
        .completion_accept_o(completion_accept),
        .completion_writes_rd_o(completion_writes_rd),
        .completion_phys_o(completion_phys),
        .commit_ready_i(commit_ready), .commit_valid_o(commit_valid),
        .commit_fire_o(commit_fire), .commit_tag_o(commit_tag),
        .commit_pc_o(), .commit_instruction_o(), .commit_op_o(commit_op),
        .commit_writes_rd_o(), .commit_rd_o(),
        .commit_new_phys_o(), .commit_old_phys_o(),
        .commit_value_o(commit_value), .commit_control_valid_o(),
        .commit_control_taken_o(), .commit_predicted_next_pc_o(),
        .commit_next_pc_o(), .commit_lsq_valid_o(commit_lsq_valid),
        .commit_lsq_tag_o(commit_lsq_tag),
        .commit_exception_valid_o(commit_exception),
        .commit_exception_cause_o(commit_cause),
        .commit_exception_tval_o(commit_tval),
        .recover_busy_o(recover_busy), .recover_redirect_valid_o(),
        .recover_redirect_pc_o(), .rollback_valid_o(),
        .rollback_tag_o(), .rollback_writes_rd_o(),
        .rollback_rd_o(), .rollback_new_phys_o(),
        .rollback_old_phys_o(), .rollback_lsq_valid_o(),
        .rollback_lsq_tag_o()
    );

    task tick;
        begin #5 clk_i = 1; #1; clk_i = 0; #1; end
    endtask

    task check;
        input condition;
        input [255:0] message;
        begin
            if (!condition) begin
                $display("FAIL LSQ integration %0s", message);
                $stop;
            end
        end
    endtask

    always @(posedge clk_i) begin
        if (reset_i)
            saw_load_writeback <= 1'b0;
        else if (writeback_valid && writeback_phys == 6'd1 &&
                writeback_value == 32'hffffff80)
            saw_load_writeback <= 1'b1;
    end

    initial begin
        clk_i = 0; reset_i = 1; alloc_valid = 0; alloc_fire = 0;
        alloc_op = 0; alloc_store = 0; alloc_width = 0;
        store_address_valid = 0; store_address = 0;
        store_data_valid = 0; store_data = 0;
        load_address_valid = 0; load_address = 0;
        transaction_rob_tag = 0; transaction_lsq_tag = 0;
        cache_req_ready = 0; cache_resp_valid = 0;
        cache_resp_data = 0; cache_resp_error = 0;
        tick(); reset_i = 0;

        alloc_valid = 1; alloc_fire = 1; alloc_store = 1;
        alloc_op = `RV32_OP_SW; alloc_width = `RV32_MEMORY_WORD;
        #1; check(rob_alloc_ready && lsq_alloc_ready, "joint allocation");
        transaction_rob_tag = rob_alloc_tag;
        transaction_lsq_tag = lsq_alloc_tag;
        tick(); alloc_valid = 0; alloc_fire = 0;
        store_address_valid = 1; store_address = 32'h100;
        store_data_valid = 1; store_data = 32'hdeadbeef;
        tick(); store_address_valid = 0; store_data_valid = 0;
        cycles = 0;
        while (!commit_valid && cycles < 20) begin
            tick(); cycles = cycles + 1;
        end
        check(commit_valid && !commit_fire, "store waits at ROB head");
        cycles = 0;
        while (!cache_req_valid && cycles < 20) begin
            tick(); cycles = cycles + 1;
        end
        check(cache_req_valid && cache_req_write &&
            cache_req_address == 32'h100 && cache_req_data == 32'hdeadbeef &&
            cache_req_mask == 4'b1111, "cache write request");
        repeat (3) begin
            tick(); check(cache_req_valid && !commit_fire,
                "cache request held");
        end
        cache_req_ready = 1; tick(); cache_req_ready = 0;
        cache_resp_valid = 1; cache_resp_error = 1;
        #1; check(cache_resp_ready, "cache error response ready");
        tick(); cache_resp_valid = 0;
        cycles = 0;
        while (!commit_exception && cycles < 20) begin
            tick(); cycles = cycles + 1;
        end
        check(commit_valid && commit_fire && commit_exception &&
            commit_cause == 7 && commit_tval == 32'h100,
            "late store error reaches ROB");
        tick();
        check(!commit_valid, "store retired after error report");

        reset_i = 1; tick(); reset_i = 0;
        alloc_valid = 1; alloc_fire = 1; alloc_store = 0;
        alloc_op = `RV32_OP_LB; alloc_width = `RV32_MEMORY_BYTE;
        #1; check(rob_alloc_ready && lsq_alloc_ready,
            "load joint allocation");
        transaction_rob_tag = rob_alloc_tag;
        transaction_lsq_tag = lsq_alloc_tag;
        tick(); alloc_valid = 0; alloc_fire = 0;
        load_address_valid = 1; load_address = 32'h101;
        tick(); load_address_valid = 0;
        cycles = 0;
        while (!cache_req_valid && cycles < 20) begin
            tick(); cycles = cycles + 1;
        end
        check(cache_req_valid && !cache_req_write &&
            cache_req_address == 32'h100, "load cache request");
        cache_req_ready = 1; tick(); cache_req_ready = 0;
        cache_resp_valid = 1; cache_resp_error = 0;
        cache_resp_data = 32'h00008000;
        #1; check(cache_resp_ready, "load response ready");
        tick(); cache_resp_valid = 0;
        cycles = 0;
        while (!commit_valid && cycles < 20) begin
            tick(); cycles = cycles + 1;
        end
        check(commit_valid && commit_fire && !commit_exception &&
            commit_value == 32'hffffff80 && saw_load_writeback,
            "load result reached ROB and writeback");
        $display("PASS rv32_lsq_rob_integration_tb");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL LSQ integration watchdog");
        $stop;
    end
endmodule
