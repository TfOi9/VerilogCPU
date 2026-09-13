`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_load_store_queue_tb;
    parameter BE_WIDTH = 1;
    parameter LSQ_ENTRIES = 8;
    parameter LSQ_INDEX_WIDTH = 3;
    parameter ROB_ENTRIES = 32;
    parameter ROB_INDEX_WIDTH = 5;
    localparam LSQ_TAG_WIDTH = LSQ_INDEX_WIDTH + 2;
    localparam ROB_TAG_WIDTH = ROB_INDEX_WIDTH + 2;

    reg clk_i;
    reg reset_i;
    reg flush_i;
    reg recover_i;
    reg [BE_WIDTH-1:0] alloc_valid_i;
    reg alloc_fire_i;
    reg [BE_WIDTH-1:0] alloc_store_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] alloc_rob_tag_i;
    reg [(BE_WIDTH*`RV32_MEMORY_WIDTH)-1:0] alloc_width_i;
    reg [BE_WIDTH-1:0] alloc_unsigned_i;
    wire alloc_ready_o;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] alloc_lsq_tag_o;
    wire [LSQ_INDEX_WIDTH:0] occupancy_o;
    reg load_address_valid_i;
    wire load_address_ready_o;
    reg [ROB_TAG_WIDTH-1:0] load_address_rob_tag_i;
    reg [LSQ_TAG_WIDTH-1:0] load_address_lsq_tag_i;
    reg [31:0] load_address_i;
    reg store_address_valid_i;
    wire store_address_ready_o;
    reg [ROB_TAG_WIDTH-1:0] store_address_rob_tag_i;
    reg [LSQ_TAG_WIDTH-1:0] store_address_lsq_tag_i;
    reg [31:0] store_address_i;
    reg store_data_valid_i;
    wire store_data_ready_o;
    reg [ROB_TAG_WIDTH-1:0] store_data_rob_tag_i;
    reg [LSQ_TAG_WIDTH-1:0] store_data_lsq_tag_i;
    reg [31:0] store_data_i;
    reg [ROB_INDEX_WIDTH-1:0] rob_head_index_i;
    reg [BE_WIDTH-1:0] rollback_valid_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_rob_tag_i;
    reg [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] rollback_lsq_tag_i;
    wire completion_valid_o;
    reg completion_ready_i;
    wire [ROB_TAG_WIDTH-1:0] completion_rob_tag_o;
    wire [31:0] completion_value_o;
    wire completion_exception_valid_o;
    wire [3:0] completion_exception_cause_o;
    wire [31:0] completion_exception_tval_o;
    reg [BE_WIDTH-1:0] commit_valid_i;
    reg [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] commit_op_i;
    reg [BE_WIDTH-1:0] commit_lsq_valid_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] commit_rob_tag_i;
    reg [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] commit_lsq_tag_i;
    reg [BE_WIDTH-1:0] commit_exception_valid_i;
    reg [BE_WIDTH-1:0] commit_fire_i;
    wire [BE_WIDTH-1:0] commit_ready_o;
    wire cache_request_valid_o;
    reg cache_request_ready_i;
    wire cache_request_write_o;
    wire [31:0] cache_request_address_o;
    wire [31:0] cache_request_write_data_o;
    wire [3:0] cache_request_byte_enable_o;
    reg cache_response_valid_i;
    wire cache_response_ready_o;
    reg [31:0] cache_response_read_data_i;
    reg cache_response_error_i;
    integer checks;
    integer wait_count;
    integer lane;
    reg [LSQ_TAG_WIDTH-1:0] first_tag;
    reg [LSQ_TAG_WIDTH-1:0] second_tag;
    reg [LSQ_TAG_WIDTH-1:0] third_tag;
    reg [LSQ_TAG_WIDTH-1:0] filled_tags [0:LSQ_ENTRIES-1];

    rv32_load_store_queue #(
        .BE_WIDTH(BE_WIDTH), .LSQ_ENTRIES(LSQ_ENTRIES),
        .LSQ_INDEX_WIDTH(LSQ_INDEX_WIDTH),
        .LSQ_TAG_WIDTH(LSQ_TAG_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .recover_i(recover_i),
        .alloc_valid_i(alloc_valid_i),
        .alloc_fire_i(alloc_fire_i),
        .alloc_store_i(alloc_store_i),
        .alloc_rob_tag_i(alloc_rob_tag_i),
        .alloc_width_i(alloc_width_i),
        .alloc_unsigned_i(alloc_unsigned_i),
        .alloc_ready_o(alloc_ready_o),
        .alloc_lsq_tag_o(alloc_lsq_tag_o),
        .occupancy_o(occupancy_o),
        .load_address_valid_i(load_address_valid_i),
        .load_address_ready_o(load_address_ready_o),
        .load_address_rob_tag_i(load_address_rob_tag_i),
        .load_address_lsq_tag_i(load_address_lsq_tag_i),
        .load_address_i(load_address_i),
        .store_address_valid_i(store_address_valid_i),
        .store_address_ready_o(store_address_ready_o),
        .store_address_rob_tag_i(store_address_rob_tag_i),
        .store_address_lsq_tag_i(store_address_lsq_tag_i),
        .store_address_i(store_address_i),
        .store_data_valid_i(store_data_valid_i),
        .store_data_ready_o(store_data_ready_o),
        .store_data_rob_tag_i(store_data_rob_tag_i),
        .store_data_lsq_tag_i(store_data_lsq_tag_i),
        .store_data_i(store_data_i),
        .rob_head_index_i(rob_head_index_i),
        .rollback_valid_i(rollback_valid_i),
        .rollback_rob_tag_i(rollback_rob_tag_i),
        .rollback_lsq_tag_i(rollback_lsq_tag_i),
        .completion_valid_o(completion_valid_o),
        .completion_ready_i(completion_ready_i),
        .completion_rob_tag_o(completion_rob_tag_o),
        .completion_value_o(completion_value_o),
        .completion_exception_valid_o(completion_exception_valid_o),
        .completion_exception_cause_o(completion_exception_cause_o),
        .completion_exception_tval_o(completion_exception_tval_o),
        .commit_valid_i(commit_valid_i),
        .commit_op_i(commit_op_i),
        .commit_lsq_valid_i(commit_lsq_valid_i),
        .commit_rob_tag_i(commit_rob_tag_i),
        .commit_lsq_tag_i(commit_lsq_tag_i),
        .commit_exception_valid_i(commit_exception_valid_i),
        .commit_fire_i(commit_fire_i),
        .commit_ready_o(commit_ready_o),
        .cache_request_valid_o(cache_request_valid_o),
        .cache_request_ready_i(cache_request_ready_i),
        .cache_request_write_o(cache_request_write_o),
        .cache_request_address_o(cache_request_address_o),
        .cache_request_write_data_o(cache_request_write_data_o),
        .cache_request_byte_enable_o(cache_request_byte_enable_o),
        .cache_response_valid_i(cache_response_valid_i),
        .cache_response_ready_o(cache_response_ready_o),
        .cache_response_read_data_i(cache_response_read_data_i),
        .cache_response_error_i(cache_response_error_i)
    );

    function [ROB_TAG_WIDTH-1:0] tag;
        input integer index_value;
        begin tag = index_value; end
    endfunction

    task tick;
        begin
            #5 clk_i = 1'b1;
            #1;
            clk_i = 1'b0;
            #1;
        end
    endtask

    task check;
        input condition;
        input [255:0] message;
        begin
            checks = checks + 1;
            if (!condition) begin
                $display("FAIL LSQ %0s width=%0d", message, BE_WIDTH);
                $stop;
            end
        end
    endtask

    task clear_inputs;
        begin
            alloc_valid_i = 0; alloc_fire_i = 0; alloc_store_i = 0;
            alloc_rob_tag_i = 0; alloc_width_i = 0;
            alloc_unsigned_i = 0;
            load_address_valid_i = 0; load_address_rob_tag_i = 0;
            load_address_lsq_tag_i = 0; load_address_i = 0;
            store_address_valid_i = 0; store_address_rob_tag_i = 0;
            store_address_lsq_tag_i = 0; store_address_i = 0;
            store_data_valid_i = 0; store_data_rob_tag_i = 0;
            store_data_lsq_tag_i = 0; store_data_i = 0;
            rob_head_index_i = 0; rollback_valid_i = 0;
            rollback_rob_tag_i = 0; rollback_lsq_tag_i = 0;
            completion_ready_i = 0; commit_valid_i = 0;
            commit_op_i = 0;
            commit_lsq_valid_i = 0; commit_rob_tag_i = 0;
            commit_lsq_tag_i = 0; commit_exception_valid_i = 0;
            commit_fire_i = 0; cache_request_ready_i = 0;
            cache_response_valid_i = 0; cache_response_read_data_i = 0;
            cache_response_error_i = 0; flush_i = 0; recover_i = 0;
        end
    endtask

    task reset_case;
        begin
            clear_inputs(); reset_i = 1;
            tick(); reset_i = 0; #1;
        end
    endtask

    task allocate_one;
        input is_store_value;
        input [ROB_TAG_WIDTH-1:0] rob_value;
        input [`RV32_MEMORY_WIDTH-1:0] width_value;
        input unsigned_value;
        output [LSQ_TAG_WIDTH-1:0] lsq_value;
        begin
            alloc_valid_i[0] = 1;
            alloc_store_i[0] = is_store_value;
            alloc_rob_tag_i[0 +: ROB_TAG_WIDTH] = rob_value;
            alloc_width_i[0 +: `RV32_MEMORY_WIDTH] = width_value;
            alloc_unsigned_i[0] = unsigned_value;
            #1; check(alloc_ready_o, "allocation ready");
            lsq_value = alloc_lsq_tag_o[0 +: LSQ_TAG_WIDTH];
            alloc_fire_i = 1;
            tick();
            alloc_fire_i = 0; alloc_valid_i = 0;
        end
    endtask

    task load_address;
        input [ROB_TAG_WIDTH-1:0] rob_value;
        input [LSQ_TAG_WIDTH-1:0] lsq_value;
        input [31:0] addr_value;
        begin
            load_address_valid_i = 1;
            load_address_rob_tag_i = rob_value;
            load_address_lsq_tag_i = lsq_value;
            load_address_i = addr_value;
            #1; check(load_address_ready_o, "load address ready");
            tick(); load_address_valid_i = 0;
        end
    endtask

    task store_address;
        input [ROB_TAG_WIDTH-1:0] rob_value;
        input [LSQ_TAG_WIDTH-1:0] lsq_value;
        input [31:0] addr_value;
        begin
            store_address_valid_i = 1;
            store_address_rob_tag_i = rob_value;
            store_address_lsq_tag_i = lsq_value;
            store_address_i = addr_value;
            #1; check(store_address_ready_o, "store address ready");
            tick(); store_address_valid_i = 0;
        end
    endtask

    task store_data;
        input [ROB_TAG_WIDTH-1:0] rob_value;
        input [LSQ_TAG_WIDTH-1:0] lsq_value;
        input [31:0] data_value;
        begin
            store_data_valid_i = 1;
            store_data_rob_tag_i = rob_value;
            store_data_lsq_tag_i = lsq_value;
            store_data_i = data_value;
            #1; check(store_data_ready_o, "store data ready");
            tick(); store_data_valid_i = 0;
        end
    endtask

    task expect_completion;
        input [ROB_TAG_WIDTH-1:0] rob_value;
        input [31:0] value;
        input exception_value;
        input [3:0] cause;
        begin
            wait_count = 0;
            while (!completion_valid_o && wait_count < 30) begin
                tick(); wait_count = wait_count + 1;
            end
            check(completion_valid_o, "completion timeout");
            check(completion_rob_tag_o == rob_value, "completion tag");
            check(completion_value_o == value, "completion value");
            check(completion_exception_valid_o == exception_value,
                "completion exception");
            if (exception_value)
                check(completion_exception_cause_o == cause,
                    "completion cause");
            completion_ready_i = 1;
            tick(); completion_ready_i = 0;
        end
    endtask

    task expect_request;
        input write_value;
        input [31:0] address_value;
        input [3:0] byte_mask;
        begin
            wait_count = 0;
            while (!cache_request_valid_o && wait_count < 30) begin
                tick(); wait_count = wait_count + 1;
            end
            check(cache_request_valid_o, "request timeout");
            check(cache_request_write_o == write_value, "request write");
            check(cache_request_address_o == address_value,
                "request address");
            if (write_value)
                check(cache_request_byte_enable_o == byte_mask,
                    "request byte mask");
            cache_request_ready_i = 1;
            tick(); cache_request_ready_i = 0;
        end
    endtask

    task send_response;
        input [31:0] value;
        input error_value;
        begin
            cache_response_valid_i = 1;
            cache_response_read_data_i = value;
            cache_response_error_i = error_value;
            #1; check(cache_response_ready_o, "response ready");
            tick(); cache_response_valid_i = 0;
        end
    endtask

    initial begin
        clk_i = 0; checks = 0;
        reset_case();

        allocate_one(0, tag(0), `RV32_MEMORY_BYTE, 0, first_tag);
        load_address(tag(0), first_tag, 32'h101);
        expect_request(0, 32'h100, 0);
        repeat (3) tick();
        send_response(32'h00008000, 0);
        expect_completion(tag(0), 32'hffffff80, 0, 0);
        check(occupancy_o == 0, "load released");

        reset_case();
        allocate_one(0, tag(0), `RV32_MEMORY_HALF, 1, first_tag);
        load_address(tag(0), first_tag, 32'h102);
        expect_request(0, 32'h100, 0);
        send_response(32'h80010000, 0);
        expect_completion(tag(0), 32'h00008001, 0, 0);

        reset_case();
        allocate_one(0, tag(0), `RV32_MEMORY_HALF, 0, first_tag);
        load_address(tag(0), first_tag, 32'h102);
        expect_request(0, 32'h100, 0);
        send_response(32'h80010000, 0);
        expect_completion(tag(0), 32'hffff8001, 0, 0);

        reset_case();
        allocate_one(1, tag(0), `RV32_MEMORY_HALF, 0, first_tag);
        allocate_one(0, tag(1), `RV32_MEMORY_BYTE, 1, second_tag);
        load_address(tag(1), second_tag, 32'h103);
        repeat (3) tick();
        check(!cache_request_valid_o && !completion_valid_o,
            "unknown older store blocks load");
        store_address(tag(0), first_tag, 32'h102);
        store_data(tag(0), first_tag, 32'h0000ab80);
        expect_completion(tag(0), 0, 0, 0);
        expect_completion(tag(1), 32'hab, 0, 0);
        check(!cache_request_valid_o, "forward without cache");

        reset_case();
        allocate_one(1, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
        allocate_one(0, tag(1), `RV32_MEMORY_WORD, 0, second_tag);
        store_address_valid_i = 1;
        store_address_rob_tag_i = tag(0);
        store_address_lsq_tag_i = first_tag;
        store_address_i = 32'h100;
        load_address_valid_i = 1;
        load_address_rob_tag_i = tag(1);
        load_address_lsq_tag_i = second_tag;
        load_address_i = 32'h200;
        #1; check(store_address_ready_o && !load_address_ready_o,
            "one AGU accepts oldest address");
        tick(); store_address_valid_i = 0;
        #1; check(load_address_ready_o,
            "second address accepted next cycle");
        tick(); load_address_valid_i = 0;

        reset_case();
        allocate_one(1, tag(0), `RV32_MEMORY_HALF, 0, first_tag);
        allocate_one(0, tag(1), `RV32_MEMORY_WORD, 0, second_tag);
        store_address(tag(0), first_tag, 32'h102);
        store_data(tag(0), first_tag, 32'h00001234);
        load_address(tag(1), second_tag, 32'h100);
        expect_completion(tag(0), 0, 0, 0);
        repeat (3) tick();
        check(!cache_request_valid_o && !completion_valid_o,
            "partial overlap waits");
        commit_valid_i[0] = 1; commit_lsq_valid_i[0] = 1;
        commit_op_i[0 +: `RV32_OP_WIDTH] = `RV32_OP_SH;
        commit_rob_tag_i[0 +: ROB_TAG_WIDTH] = tag(0);
        commit_lsq_tag_i[0 +: LSQ_TAG_WIDTH] = first_tag;
        #1; check(!commit_ready_o[0], "store waits for cache");
        expect_request(1, 32'h100, 4'b1100);
        check(cache_request_write_data_o == 32'h12340000,
            "aligned store data");
        send_response(0, 0);
        #1; check(commit_ready_o[0], "store write acknowledged");
        commit_fire_i[0] = 1; tick();
        commit_fire_i = 0; commit_valid_i = 0;
        rob_head_index_i = 1;
        expect_request(0, 32'h100, 0);
        send_response(32'h12345678, 0);
        expect_completion(tag(1), 32'h12345678, 0, 0);

        reset_case();
        allocate_one(1, tag(0), `RV32_MEMORY_BYTE, 0, first_tag);
        allocate_one(1, tag(1), `RV32_MEMORY_BYTE, 0, second_tag);
        allocate_one(0, tag(2), `RV32_MEMORY_HALF, 0, third_tag);
        store_address(tag(0), first_tag, 32'h100);
        store_data(tag(0), first_tag, 32'h80);
        store_address(tag(1), second_tag, 32'h101);
        store_data(tag(1), second_tag, 32'h7f);
        load_address(tag(2), third_tag, 32'h100);
        expect_completion(tag(0), 0, 0, 0);
        expect_completion(tag(1), 0, 0, 0);
        expect_completion(tag(2), 32'h00007f80, 0, 0);
        check(!cache_request_valid_o, "multi-store byte forwarding");

        reset_case();
        allocate_one(1, tag(0), `RV32_MEMORY_BYTE, 0, first_tag);
        store_address(tag(0), first_tag, 32'h103);
        store_data(tag(0), first_tag, 32'ha5);
        expect_completion(tag(0), 0, 0, 0);
        commit_valid_i[0] = 1; commit_lsq_valid_i[0] = 1;
        commit_op_i[0 +: `RV32_OP_WIDTH] = `RV32_OP_SB;
        commit_rob_tag_i[0 +: ROB_TAG_WIDTH] = tag(0);
        commit_lsq_tag_i[0 +: LSQ_TAG_WIDTH] = first_tag;
        expect_request(1, 32'h100, 4'b1000);
        send_response(0, 1);
        #1; check(!commit_ready_o[0], "error awaits ROB update");
        expect_completion(tag(0), 0, 1, 7);
        commit_exception_valid_i[0] = 1;
        #1; check(commit_ready_o[0], "error ready after ROB update");
        commit_fire_i[0] = 1; tick();
        commit_fire_i = 0; commit_valid_i = 0;

        reset_case();
        allocate_one(0, tag(0), `RV32_MEMORY_HALF, 0, first_tag);
        load_address(tag(0), first_tag, 32'h101);
        expect_completion(tag(0), 0, 1, 4);
        check(!cache_request_valid_o, "misaligned load no request");

        reset_case();
        allocate_one(1, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
        store_address(tag(0), first_tag, 32'h102);
        expect_completion(tag(0), 0, 1, 6);
        commit_valid_i[0] = 1; commit_lsq_valid_i[0] = 1;
        commit_op_i[0 +: `RV32_OP_WIDTH] = `RV32_OP_SW;
        commit_rob_tag_i[0 +: ROB_TAG_WIDTH] = tag(0);
        commit_lsq_tag_i[0 +: LSQ_TAG_WIDTH] = first_tag;
        #1; check(commit_ready_o[0] && !cache_request_valid_o,
            "fault store retires without cache write");

        reset_case();
        allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
        load_address(tag(0), first_tag, 32'h00100000);
        expect_completion(tag(0), 0, 1, 5);

        reset_case();
        allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
        load_address(tag(0), first_tag, 32'h100);
        expect_request(0, 32'h100, 0);
        send_response(0, 1);
        expect_completion(tag(0), 0, 1, 5);

        reset_case();
        allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
        load_address(tag(0), first_tag, 32'h100);
        expect_request(0, 32'h100, 0);
        recover_i = 1; rollback_valid_i[0] = 1;
        rollback_rob_tag_i[0 +: ROB_TAG_WIDTH] = tag(0);
        rollback_lsq_tag_i[0 +: LSQ_TAG_WIDTH] = first_tag;
        cache_response_valid_i = 1;
        cache_response_read_data_i = 32'hdeadbeef;
        #1; check(!cache_response_ready_o,
            "recovery holds cache response");
        tick(); recover_i = 0; rollback_valid_i = 0;
        allocate_one(0, tag(1), `RV32_MEMORY_WORD, 0, second_tag);
        cache_response_valid_i = 0;
        check(first_tag != second_tag, "generation changes on reuse");
        repeat (3) tick();
        check(!completion_valid_o, "stale response discarded");

        if (BE_WIDTH > 1) begin
            reset_case();
            alloc_fire_i = 1;
            for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                alloc_valid_i[lane] = 1;
                alloc_rob_tag_i[lane*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] =
                    tag(lane);
                alloc_width_i[lane*`RV32_MEMORY_WIDTH +:
                    `RV32_MEMORY_WIDTH] = `RV32_MEMORY_WORD;
            end
            #1; check(alloc_ready_o, "wide allocation ready");
            tick(); alloc_fire_i = 0; alloc_valid_i = 0;
            check(occupancy_o == BE_WIDTH, "wide atomic allocation");
        end

        reset_case();
        for (lane = 0; lane < LSQ_ENTRIES; lane = lane + 1)
            allocate_one(0, tag(lane), `RV32_MEMORY_WORD, 0,
                filled_tags[lane]);
        check(occupancy_o == LSQ_ENTRIES, "queue full");
        alloc_valid_i[0] = 1;
        #1; check(!alloc_ready_o, "full queue rejects allocation");
        alloc_valid_i = 0;
        for (lane = LSQ_ENTRIES-1; lane >= 0; lane = lane - 1) begin
            recover_i = 1; rollback_valid_i[0] = 1;
            rollback_rob_tag_i[0 +: ROB_TAG_WIDTH] = tag(lane);
            rollback_lsq_tag_i[0 +: LSQ_TAG_WIDTH] = filled_tags[lane];
            tick();
        end
        recover_i = 0; rollback_valid_i = 0;
        check(occupancy_o == 0, "full queue rollback");
        allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
        check(first_tag != filled_tags[0], "reused slot generation");
        $display("PASS rv32_load_store_queue_tb width=%0d checks=%0d",
            BE_WIDTH, checks);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL LSQ watchdog");
        $stop;
    end
endmodule
