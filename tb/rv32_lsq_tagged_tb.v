`timescale 1ns/1ps
`include "rv32im_defs.vh"
module rv32_lsq_tagged_tb #(parameter BAD_TAG = 0);
    reg clk = 0;
    reg reset = 1;
    reg recover = 0;
    reg alloc = 0;
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
    reg [6:0] response_tag = 0;
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
    rv32_load_store_queue #(.TAGGED_RESPONSES(1),.ECHO_ROB_TAG(1),.LOAD_FALLTHROUGH(1)) dut (
        .cache_request_rob_tag_o(), .cache_response_rob_tag_i(response_tag),
        .clk_i(clk),.reset_i(reset),.flush_i(1'b0),.recover_i(recover),
        .alloc_valid_i(alloc),.alloc_fire_i(alloc && alloc_ready),.alloc_store_i(1'b0),
        .alloc_rob_tag_i(alloc_rob),.alloc_width_i(`RV32_MEMORY_WORD),.alloc_unsigned_i(1'b0),
        .alloc_ready_o(alloc_ready),.alloc_lsq_tag_o(alloc_tag),.occupancy_o(),
        .load_address_valid_i(address_valid),.load_address_ready_o(address_ready),
        .load_address_rob_tag_i(address_rob),.load_address_lsq_tag_i(address_tag),.load_address_i(address_value),
        .store_address_valid_i(1'b0),.store_address_ready_o(),.store_address_rob_tag_i(7'd0),
        .store_address_lsq_tag_i(5'd0),.store_address_i(32'd0),
        .store_data_valid_i(1'b0),.store_data_ready_o(),.store_data_rob_tag_i(7'd0),
        .store_data_lsq_tag_i(5'd0),.store_data_i(32'd0),.rob_head_index_i(5'd0),
        .rollback_valid_i(rollback),.rollback_rob_tag_i(rollback_rob),.rollback_lsq_tag_i(rollback_tag),
        .completion_valid_o(complete),.completion_ready_i(1'b1),.completion_rob_tag_o(complete_rob),
        .completion_value_o(complete_value),.completion_exception_valid_o(complete_error),
        .completion_exception_cause_o(complete_cause),.completion_exception_tval_o(complete_tval),
        .commit_valid_i(1'b0),.commit_op_i(6'd0),.commit_lsq_valid_i(1'b0),
        .commit_rob_tag_i(7'd0),.commit_lsq_tag_i(5'd0),.commit_exception_valid_i(1'b0),
        .commit_fire_i(1'b0),.commit_ready_o(),.cache_request_valid_o(request_valid),
        .cache_request_ready_i(1'b1),.cache_request_id_o(request_id),.cache_response_id_i(response_id),
        .cache_store_confirm_valid_i(1'b0), .cache_store_confirm_id_i(2'd0),
        .cache_store_confirm_rob_tag_i(7'd0),
        .cache_request_irrevocable_i(1'b0),.cache_request_write_o(),.cache_request_address_o(request_address),
        .cache_request_write_data_o(),.cache_request_byte_enable_o(),.cache_request_mmio_o(),
        .cache_response_valid_i(response_valid),.cache_response_ready_o(response_ready),
        .cache_response_read_data_i(response_value),.cache_response_error_i(response_error)
    );
    task fail;
        input [8*100-1:0] text;
        begin $display("FAIL tagged LSQ: %0s",text); $stop; end
    endtask
    always @(posedge clk) if (!reset) begin
        if (request_valid) begin ids[request_address[7:2]] = request_id; requests = requests + 1; end
        if (complete && BAD_TAG == 0) begin
            if (!expected_pending || complete_rob !== expected_rob ||
                    complete_error !== expected_error || complete_value !== expected_value)
                fail("completion attached to wrong generation or ROB entry");
            if (complete_error && (complete_cause !== 4'd5 || complete_tval !== expected_tval))
                fail("wrong precise exception");
            expected_pending = 0; completions = completions + 1;
        end
    end
    task load;
        input integer tag_index;
        input [6:0] rob;
        input [31:0] value;
        begin
            @(negedge clk); alloc = 1; alloc_rob = rob; #1;
            if (!alloc_ready) fail("allocation blocked"); tags[tag_index] = alloc_tag;
            @(negedge clk); alloc = 0; address_valid = 1;
            address_rob = rob; address_tag = tags[tag_index]; address_value = value;
            @(posedge clk); while (!address_ready) @(posedge clk);
            @(negedge clk); address_valid = 0;
        end
    endtask
    task respond;
        input [1:0] id;
        input [6:0] rob;
        input [31:0] value;
        input error;
        input discard;
        input [31:0] tval;
        begin
            @(negedge clk); response_id = id;
            response_tag = rob ^ (BAD_TAG != 0 ? 7'h40 : 7'd0);
            response_value = value;
            response_error = error; response_valid = 1;
            expected_pending = !discard; expected_rob = rob;
            expected_value = error ? 0 : value; expected_error = error; expected_tval = tval;
            @(posedge clk); while (!response_ready) @(posedge clk);
            @(negedge clk); response_valid = 0;
            wait_count = 0;
            while (expected_pending) begin @(negedge clk); wait_count = wait_count + 1;
                if (wait_count > 30) fail("missing completion"); end
        end
    endtask
    initial begin
        repeat (3) @(negedge clk); reset = 0;
        for (i = 0; i < 4; i = i + 1) load(i,i[6:0],32'h100+i*4);
        while (requests < 4) @(negedge clk);
        respond(ids[3],3,32'h33445566,0,0,0);
        recover = 1; rollback = 1; rollback_rob = 0; rollback_tag = tags[0];
        @(negedge clk); recover = 0; rollback = 0;
        load(4,16,32'h180);
        while (requests < 5) @(negedge clk);
        respond(ids[0],0,32'hffffffff,1,1,32'h100);
        respond(ids[32],16,32'h778899aa,0,0,0);
        respond(ids[2],2,0,1,0,32'h108);
        respond(ids[1],1,32'h11223344,0,0,0);
        if (completions != 4 || dut.inflight_count != 0) fail("missing drain");
        $display("PASS tagged LSQ reverse replies rollback slot reuse precise error"); $finish;
    end
    initial begin #100000; fail("simulation timeout"); end
endmodule
