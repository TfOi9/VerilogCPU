`timescale 1ns/1ps
`include "rv32im_defs.vh"
module rv32_store_confirm_tb;
    parameter RECOVER_CONFIRM = 0;
    reg confirm_valid = 0;
    reg [1:0] confirm_id = 0;
    reg [6:0] confirm_rob = 1;
    reg [6:0] response_rob = 1;
    reg flush = 0;
    reg commit_exception = 0;
    reg clk = 0;
    reg reset = 1;
    reg recover = 0;
    reg alloc = 0;
    reg commit_valid = 0;
    wire commit_ready;
    reg cache_ready = 1;
    reg [6:0] alloc_rob = 0;
    wire alloc_ready;
    wire [4:0] alloc_tag;
    reg address_valid = 0;
    reg [6:0] address_rob = 0;
    reg [4:0] address_tag = 0;
    reg [31:0] address_value = 0;
    wire address_ready;
    reg rollback = 0;
    reg [6:0] rollback_rob = 0;
    reg [4:0] rollback_tag = 0;
    wire complete;
    wire [6:0] complete_rob;
    wire [31:0] complete_value;
    wire complete_error;
    wire [3:0] complete_cause;
    wire [31:0] complete_tval;
    wire request_valid;
    wire [1:0] request_id;
    wire [31:0] request_address;
    reg response_valid = 0;
    wire response_ready;
    reg [1:0] response_id = 0;
    reg [31:0] response_value = 0;
    reg response_error = 0;
    reg [4:0] tags [0:4];
    reg [1:0] ids [0:63];
    reg expected_pending = 0;
    reg [6:0] expected_rob;
    reg [31:0] expected_value;
    reg expected_error;
    reg [31:0] expected_tval;
    integer requests = 0;
    integer completions = 0;
    integer i;
    integer wait_count;
    always #5 clk = ~clk;
    rv32_load_store_queue #(.TAGGED_RESPONSES(1),.ECHO_ROB_TAG(1),.LOAD_FALLTHROUGH(1),
        .POSTED_STORES(1),.LATE_STORE_CONFIRM(1)) dut (
        .cache_request_rob_tag_o(), .cache_response_rob_tag_i(response_rob),
        .clk_i(clk),.reset_i(reset),.flush_i(flush),.recover_i(recover),
        .alloc_valid_i(alloc),.alloc_fire_i(alloc && alloc_ready),.alloc_store_i(1'b1),
        .alloc_rob_tag_i(alloc_rob),.alloc_width_i(`RV32_MEMORY_WORD),.alloc_unsigned_i(1'b0),
        .alloc_ready_o(alloc_ready),.alloc_lsq_tag_o(alloc_tag),.occupancy_o(),
        .load_address_valid_i(1'b0),.load_address_ready_o(address_ready),
        .load_address_rob_tag_i(address_rob),.load_address_lsq_tag_i(address_tag),.load_address_i(address_value),
        .store_address_valid_i(address_valid),.store_address_ready_o(),.store_address_rob_tag_i(address_rob),
        .store_address_lsq_tag_i(address_tag),.store_address_i(address_value),
        .store_data_valid_i(address_valid),.store_data_ready_o(),.store_data_rob_tag_i(address_rob),
        .store_data_lsq_tag_i(address_tag),.store_data_i(32'hdeadbeef),.rob_head_index_i(5'd0),
        .rollback_valid_i(rollback),.rollback_rob_tag_i(rollback_rob),.rollback_lsq_tag_i(rollback_tag),
        .completion_valid_o(complete),.completion_ready_i(1'b1),.completion_rob_tag_o(complete_rob),
        .completion_value_o(complete_value),.completion_exception_valid_o(complete_error),
        .completion_exception_cause_o(complete_cause),.completion_exception_tval_o(complete_tval),
        .commit_valid_i(commit_valid),.commit_op_i(`RV32_OP_SW),.commit_lsq_valid_i(1'b1),
        .commit_rob_tag_i(7'd1),.commit_lsq_tag_i(tags[0]),.commit_exception_valid_i(commit_exception),
        .commit_fire_i(commit_valid && commit_ready),.commit_ready_o(commit_ready),.cache_request_valid_o(request_valid),
        .cache_request_ready_i(cache_ready),.cache_request_id_o(request_id),.cache_response_id_i(response_id),
        .cache_store_confirm_valid_i(confirm_valid), .cache_store_confirm_id_i(confirm_id),
        .cache_store_confirm_rob_tag_i(confirm_rob),
        .cache_request_irrevocable_i(1'b0),.cache_request_write_o(),.cache_request_address_o(request_address),
        .cache_request_write_data_o(),.cache_request_byte_enable_o(),.cache_request_mmio_o(),
        .cache_response_valid_i(response_valid),.cache_response_ready_o(response_ready),
        .cache_response_read_data_i(response_value),.cache_response_error_i(response_error)
    );
    reg [1:0] old_id;
    reg [1:0] new_id;
    reg [4:0] old_tag;
    task fail;
        input [8*100-1:0] text;
        begin $display("FAIL Store confirmation: %0s",text); $stop; end
    endtask
    task allocate_store;
        begin
            @(negedge clk); alloc = 1; alloc_rob = 1; #1;
            if (!alloc_ready) fail("allocation blocked"); tags[0] = alloc_tag;
            @(negedge clk); alloc = 0; address_valid = 1;
            address_rob = 1; address_tag = tags[0];
            address_value = RECOVER_CONFIRM == 3 ? 32'h80000000 : 32'h100;
            @(negedge clk); address_valid = 0;
            while (!dut.report_sent[tags[0][2:0]]) @(negedge clk);
        end
    endtask
    task capture_request;
        begin
            while (!request_valid) @(negedge clk);
            old_id = request_id;
            @(negedge clk);
            if (commit_ready) fail("unproven store retired at acceptance");
        end
    endtask
    initial begin
        repeat (3) @(negedge clk); reset = 0;
        allocate_store; old_tag = tags[0]; commit_valid = 1;
        capture_request;
        confirm_valid = 1; confirm_id = old_id; confirm_rob = 7'd33; #1;
        if (commit_ready) fail("wrong ROB generation confirmed store");
        @(negedge clk); confirm_rob = 1; confirm_id = old_id ^ 2'd1; #1;
        if (commit_ready) fail("unknown request ID confirmed store");
        @(negedge clk); confirm_id = old_id;
        if (RECOVER_CONFIRM == 3) begin
            #1; if (commit_ready) fail("RAM proof authorized MMIO store");
            @(negedge clk); confirm_valid = 0;
            if (dut.pending_posted[old_id]) fail("MMIO acquired posted ownership");
            response_id = old_id; response_valid = 1; response_error = 1;
            @(negedge clk); response_valid = 0;
            while (!complete) @(negedge clk);
            if (!complete_error || complete_rob != 1 || complete_cause != 7 ||
                    complete_tval != 32'h80000000) fail("MMIO error lost its owner");
            @(negedge clk); commit_exception = 1;
            #1; if (!commit_ready) fail("MMIO fault did not retire precisely");
            @(negedge clk); commit_valid = 0;
        end else if (RECOVER_CONFIRM == 2) begin
            recover = 1; rollback = 1; rollback_rob = 1; rollback_tag = tags[0];
            @(negedge clk); confirm_valid = 0; recover = 0; rollback = 0;
            commit_valid = 0; cache_ready = 0;
            allocate_store; commit_valid = 1;
            confirm_valid = 1; confirm_id = old_id; #1;
            if (commit_ready) fail("cancelled request confirmed a reused slot");
            @(negedge clk); confirm_valid = 0;
            response_id = old_id; response_valid = 1; response_error = 1;
            @(negedge clk); response_valid = 0;
            if (dut.write_done[tags[0][2:0]] || dut.late_error[tags[0][2:0]])
                fail("cancelled response changed the new store");
        end else if (RECOVER_CONFIRM == 1) begin
            recover = 1; #1;
            if (commit_ready) fail("confirmation retired during recovery");
            @(negedge clk); confirm_valid = 0; recover = 0; #1;
            if (commit_ready || dut.pending_posted[old_id]) fail("ignored confirmation escaped recovery");
            response_id = old_id; response_valid = 1;
            #1; if (!commit_ready) fail("surviving store failed normal response");
            @(negedge clk); response_valid = 0; commit_valid = 0;
        end else begin
            #1; if (!commit_ready || response_valid) fail("hit confirmation did not authorize store");
            @(negedge clk); confirm_valid = 0; commit_valid = 0; cache_ready = 0;
            // Wrap the LSQ generation while the retired write still owns its ID.
            for (i = 0; i < 3; i = i + 1) begin
                allocate_store;
                recover = 1; rollback = 1; rollback_rob = 1; rollback_tag = tags[0];
                @(negedge clk); recover = 0; rollback = 0;
            end
            allocate_store;
            if (tags[0] !== old_tag) fail("generation did not wrap");
            commit_valid = 1;
            while (!request_valid) @(negedge clk);
            new_id = request_id;
            confirm_id = old_id; confirm_valid = 1; #1;
            if (commit_ready) fail("duplicate confirmation authorized reused LSQ entry");
            @(negedge clk); confirm_valid = 0;
            response_id = old_id; response_valid = 1; #1;
            if (commit_ready) fail("retired response authorized reused store");
            @(negedge clk); response_valid = 0;
            if (dut.write_done[tags[0][2:0]]) fail("old packet modified reused LSQ entry");
            cache_ready = 1;
            @(negedge clk); cache_ready = 0;
            confirm_id = old_id; confirm_rob = 7'd65; confirm_valid = 1; #1;
            if (commit_ready) fail("stale confirmation authorized a new request");
            @(negedge clk); confirm_id = new_id; confirm_rob = 1;
            #1; if (!commit_ready) fail("new confirmation lost");
            @(negedge clk); confirm_valid = 0; commit_valid = 0;
            flush = 1;
            @(negedge clk); flush = 0;
            response_id = new_id; response_valid = 1;
            @(negedge clk); response_valid = 0;
        end
        if (dut.inflight_count != 0) fail("inflight drain");
        $display("PASS Store confirmation identity wrap recovery=%0d", RECOVER_CONFIRM); $finish;
    end
    initial begin #100000; fail("simulation timeout"); end
endmodule
