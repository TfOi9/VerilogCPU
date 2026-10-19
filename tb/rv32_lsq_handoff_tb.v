`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_lsq_handoff_tb;
    parameter FAST_MODE = 1;
    parameter TAGGED_MODE = 1;
    parameter BE_WIDTH = 1;
    parameter POSTED_STORES = 1;
    parameter LOAD_FALLTHROUGH = 1;
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
    wire cache_request_mmio_o;
    reg cache_response_valid_i;
    wire cache_response_ready_o;
    reg [31:0] cache_response_read_data_i;
    reg cache_response_error_i;
    reg cache_request_irrevocable_i;
    integer requests, completions, writes, responses;
    wire [1:0] cache_request_id_o;
    wire [ROB_TAG_WIDTH-1:0] cache_request_rob_tag_o;
    reg [1:0] cache_response_id_i;
    reg [ROB_TAG_WIDTH-1:0] cache_response_rob_tag_i;
    reg [1:0] saved_id [0:15];
    reg [ROB_TAG_WIDTH-1:0] saved_rob [0:15];
    integer checks;
    integer wait_count;
    integer lane;
    reg [LSQ_TAG_WIDTH-1:0] first_tag;
    reg [LSQ_TAG_WIDTH-1:0] second_tag;
    reg [LSQ_TAG_WIDTH-1:0] third_tag;
    reg [LSQ_TAG_WIDTH-1:0] filled_tags [0:LSQ_ENTRIES-1];
    integer store_size;
    integer load_size;
    integer store_offset;
    integer load_offset;
    integer word_case;
    integer wrap_case;
    integer ready_case;
    integer store_start;
    integer load_start;
    integer head;
    reg overlap;
    reg [31:0] expected_load;

    rv32_load_store_queue #(
        .POSTED_STORES(POSTED_STORES), .LOAD_FALLTHROUGH(LOAD_FALLTHROUGH), .FAST_RETURN(FAST_MODE), .TAGGED_RESPONSES(TAGGED_MODE), .ECHO_ROB_TAG(TAGGED_MODE),
        .BE_WIDTH(BE_WIDTH), .LSQ_ENTRIES(LSQ_ENTRIES),
        .LSQ_INDEX_WIDTH(LSQ_INDEX_WIDTH),
        .LSQ_TAG_WIDTH(LSQ_TAG_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) dut (
        .cache_request_rob_tag_o(cache_request_rob_tag_o), .cache_response_rob_tag_i(cache_response_rob_tag_i),
        .cache_request_id_o(cache_request_id_o), .cache_response_id_i(cache_response_id_i),
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
        .cache_store_confirm_valid_i(1'b0), .cache_store_confirm_id_i(2'd0),
        .cache_store_confirm_rob_tag_i({ROB_TAG_WIDTH{1'b0}}),
        .cache_request_irrevocable_i(cache_request_irrevocable_i),
        .cache_request_write_o(cache_request_write_o),
        .cache_request_address_o(cache_request_address_o),
        .cache_request_write_data_o(cache_request_write_data_o),
        .cache_request_byte_enable_o(cache_request_byte_enable_o),
        .cache_request_mmio_o(cache_request_mmio_o),
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
        input [1023:0] message;
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
            cache_request_irrevocable_i = 0;
            cache_response_id_i = 0; cache_response_rob_tag_i = 0;
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
            check(!cache_request_mmio_o, "RAM request route");
            if (write_value)
                check(cache_request_byte_enable_o == byte_mask,
                    "request byte mask");
            cache_request_ready_i = 1;
            tick(); cache_request_ready_i = 0;
        end
    endtask

    task expect_mmio_request;
        input [31:0] data_value;
        begin
            wait_count = 0;
            while (!cache_request_valid_o && wait_count < 30) begin
                tick(); wait_count = wait_count + 1;
            end
            check(cache_request_valid_o, "MMIO request timeout");
            check(cache_request_write_o, "MMIO request write");
            check(cache_request_mmio_o, "MMIO request route");
            check(cache_request_address_o == 32'h80000000,
                "MMIO request address");
            check(cache_request_write_data_o == data_value,
                "MMIO request data");
            check(cache_request_byte_enable_o == 4'hf,
                "MMIO request byte mask");
            cache_request_ready_i = 1;
            tick(); cache_request_ready_i = 0;
        end
    endtask

    task send_response;
        input [31:0] value;
        input error_value;
        begin
            cache_response_id_i = saved_id[responses];
            cache_response_rob_tag_i = saved_rob[responses];
            cache_response_valid_i = 1;
            cache_response_read_data_i = value;
            cache_response_error_i = error_value;
            #1; check(cache_response_ready_o, "response ready");
            tick(); cache_response_valid_i = 0; #1;
        end
    endtask


    always @(posedge clk_i) begin
        if (reset_i) begin requests <= 0; completions <= 0; writes <= 0; responses <= 0; end
        else begin
            if (cache_request_valid_o && cache_request_ready_i) begin
                saved_id[requests] <= cache_request_id_o;
                saved_rob[requests] <= cache_request_rob_tag_o;
                requests <= requests + 1;
                if (cache_request_write_o) writes <= writes + 1;
            end
            if (cache_response_valid_i && cache_response_ready_o) responses <= responses + 1;
            if (completion_valid_o && completion_ready_i) completions <= completions + 1;
        end
    end

    task drive_load;
        input [ROB_TAG_WIDTH-1:0] r;
        input [LSQ_TAG_WIDTH-1:0] q;
        input [31:0] a;
        begin
            load_address_valid_i = 1;
            load_address_rob_tag_i = r;
            load_address_lsq_tag_i = q;
            load_address_i = a;
            #1;
        end
    endtask

    task commit_head;
        input [ROB_TAG_WIDTH-1:0] r;
        input [LSQ_TAG_WIDTH-1:0] q;
        begin
            commit_valid_i = 1; commit_lsq_valid_i = 1;
            commit_rob_tag_i = 0; commit_lsq_tag_i = 0; commit_op_i = 0;
            commit_rob_tag_i[0 +: ROB_TAG_WIDTH] = r;
            commit_lsq_tag_i[0 +: LSQ_TAG_WIDTH] = q;
            commit_op_i[0 +: `RV32_OP_WIDTH] = `RV32_OP_SW;
            commit_fire_i = 0; #1;
        end
    endtask

    initial begin
        clk_i = 0; checks = 0;
        if (FAST_MODE != 0) begin
            reset_case();
            allocate_one(0, tag(0), `RV32_MEMORY_BYTE, 0, first_tag);
            drive_load(tag(ROB_ENTRIES), first_tag, 32'h103);
            check(!load_address_ready_o && !cache_request_valid_o,
                "stale full ROB tag rejected");
            drive_load(tag(0), first_tag, 32'h103);
            check(load_address_ready_o && cache_request_valid_o,
                "incoming load issues before edge");
            check(cache_request_address_o == 32'h100 && !cache_request_write_o,
                "direct load aligned payload");
            tick(); load_address_valid_i = 0; load_address_i = 32'hffffffff;
            repeat (4) begin
                #1; check(cache_request_valid_o && cache_request_address_o == 32'h100,
                    "direct capture stable under stall");
                tick();
            end
            expect_request(0, 32'h100, 0);
            send_response(32'h80aabbcc, 0);
            repeat (3) begin
                check(completion_valid_o && completion_value_o == 32'hffffff80,
                    "captured return stable under stall"); tick();
            end
            expect_completion(tag(0), 32'hffffff80, 0, 0);
            check(requests == 1 && completions == 1, "one direct request and completion");

            reset_case();
            allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
            cache_request_ready_i = 1;
            drive_load(tag(0), first_tag, 32'h204);
            check(cache_request_valid_o, "ready direct load has no setup bubble");
            tick(); load_address_valid_i = 0;
            repeat (4) tick();
            check(requests == 1 && !cache_request_valid_o, "direct load not duplicated");
            completion_ready_i = 1;
            send_response(32'h12345678, 0);
            check(completions == 1 && occupancy_o == 0, "direct return releases one slot");

            for (word_case = 0; word_case < 2; word_case = word_case + 1) begin
                reset_case();
                allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
                drive_load(tag(0), first_tag, word_case == 0 ? 32'h103 : 32'h80000000);
                check(!cache_request_valid_o, "faulting load never requests cache");
                tick(); load_address_valid_i = 0;
                expect_completion(tag(0), 0, 1, word_case == 0 ? 4'd4 : 4'd5);
                check(requests == 0, "fault produces no memory side effect");
            end

            reset_case();
            cache_request_ready_i = 1;
            for (word_case = 0; word_case < 5; word_case = word_case + 1) begin
                allocate_one(0, tag(word_case), `RV32_MEMORY_WORD, 0, filled_tags[word_case]);
                drive_load(tag(word_case), filled_tags[word_case], 32'h800+word_case*4);
                if (word_case < 4) check(cache_request_valid_o, "available direct request credit");
                else check(!cache_request_valid_o, "fifth request waits for credit");
                tick(); load_address_valid_i = 0;
            end
            check(requests == 4, "exactly four requests in flight");
            completion_ready_i = 1;
            cache_response_id_i = saved_id[0]; cache_response_rob_tag_i = saved_rob[0];
            cache_response_valid_i = 1; cache_response_read_data_i = 32'h12340000;
            #1; check(cache_response_ready_o && cache_request_valid_o,
                "response credit accepts fifth request on same edge");
            tick(); cache_response_valid_i = 0;
            check(requests == 5 && completions == 1, "turnover preserves both handshakes");
            for (word_case = 1; word_case < 5; word_case = word_case + 1)
                send_response(32'h12340000+word_case, 0);
            check(completions == 5 && occupancy_o == 0, "turnover returns each live identity once");

            reset_case();
            allocate_one(1, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
            allocate_one(0, tag(1), `RV32_MEMORY_WORD, 0, second_tag);
            load_address(tag(1), second_tag, 32'h200);
            check(!cache_request_valid_o, "unknown older store blocks direct load");
            store_address(tag(0), first_tag, 32'h100);
            store_data(tag(0), first_tag, 32'h11223344);
            expect_completion(tag(0), 0, 0, 0);
            expect_request(0, 32'h200, 0);
            send_response(32'h87654321, 0);
            expect_completion(tag(1), 32'h87654321, 0, 0);
            check(writes == 0 && requests == 1, "uncommitted store never escapes");

            reset_case();
            allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
            drive_load(tag(0), first_tag, 32'h300);
            recover_i = 1; rollback_valid_i = 1;
            rollback_rob_tag_i[0 +: ROB_TAG_WIDTH] = tag(0);
            rollback_lsq_tag_i[0 +: LSQ_TAG_WIDTH] = first_tag;
            #1; check(!cache_request_valid_o && !load_address_ready_o,
                "recovery cancels unaccepted direct load");
            tick(); recover_i = 0; rollback_valid_i = 0; load_address_valid_i = 0;
            allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, second_tag);
            check(second_tag != first_tag, "recovery advances LSQ generation");
            drive_load(tag(0), first_tag, 32'h300);
            check(!load_address_ready_o && !cache_request_valid_o,
                "stale LSQ generation rejected");
            load_address_valid_i = 0;
            cache_request_ready_i = 1;
            drive_load(tag(0), second_tag, 32'h300); tick(); load_address_valid_i = 0;
            send_response(32'h55aa55aa, 0);
            expect_completion(tag(0), 32'h55aa55aa, 0, 0);
            check(requests == 1, "only live generation requested");

            reset_case();
            allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
            cache_request_ready_i = 1;
            drive_load(tag(0), first_tag, 32'h400); tick(); load_address_valid_i = 0;
            flush_i = 1; tick(); flush_i = 0;
            allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, second_tag);
            send_response(32'hdeadbeef, 0);
            check(!completion_valid_o && occupancy_o == 1,
                "flushed response cannot complete reused slot");
            drive_load(tag(0), second_tag, 32'h404); tick(); load_address_valid_i = 0;
            send_response(32'hbadc0ffe, 0);
            expect_completion(tag(0), 32'hbadc0ffe, 0, 0);
            check(completions == 1 && requests == 2, "flush drains only old ownership");

            if (BE_WIDTH > 1) begin
                reset_case();
                allocate_one(1, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
                allocate_one(1, tag(1), `RV32_MEMORY_WORD, 0, second_tag);
                store_address(tag(0), first_tag, 32'h500);
                store_data(tag(0), first_tag, 32'h11111111);
                expect_completion(tag(0), 0, 0, 0);
                store_address(tag(1), second_tag, 32'h504);
                store_data(tag(1), second_tag, 32'h22222222);
                expect_completion(tag(1), 0, 0, 0);
                commit_head(tag(0), first_tag);
                commit_valid_i[1] = 1; commit_lsq_valid_i[1] = 1;
                commit_op_i[`RV32_OP_WIDTH +: `RV32_OP_WIDTH] = `RV32_OP_SW;
                commit_rob_tag_i[ROB_TAG_WIDTH +: ROB_TAG_WIDTH] = tag(1);
                commit_lsq_tag_i[LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] = second_tag;
                cache_request_ready_i = 1; cache_request_irrevocable_i = 1;
                #1; check(cache_request_valid_o && !commit_ready_o[0],
                    "store proof registers before retirement");
                tick();
                check(writes == 1 && commit_ready_o[0], "registered store proof permits head");
                check(!cache_request_valid_o, "nonretiring prefix blocks next store");
                commit_fire_i[0] = 1; commit_exception_valid_i[0] = 1;
                #1; check(!cache_request_valid_o, "exception prefix blocks next store");
                commit_exception_valid_i[0] = 0;
                commit_rob_tag_i[ROB_TAG_WIDTH +: ROB_TAG_WIDTH] = tag(1) ^ (1 << ROB_INDEX_WIDTH);
                #1; check(!cache_request_valid_o, "prefix checks complete ROB generation");
                commit_rob_tag_i[ROB_TAG_WIDTH +: ROB_TAG_WIDTH] = tag(1);
                commit_lsq_tag_i[LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] = second_tag ^ (1 << LSQ_INDEX_WIDTH);
                #1; check(!cache_request_valid_o, "prefix checks LSQ generation");
                commit_lsq_tag_i[LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] = second_tag;
                #1; check(cache_request_valid_o && cache_request_address_o == 32'h504 &&
                    !cache_request_mmio_o, "retiring prefix authorizes next RAM store");
                tick();
                commit_head(tag(1), second_tag); rob_head_index_i = 1;
                check(writes == 2 && commit_ready_o[0], "continuous store transfer preserves proof");
                commit_fire_i[0] = 1; tick(); commit_valid_i = 0; commit_lsq_valid_i = 0;
                commit_fire_i = 0; cache_request_ready_i = 0; cache_request_irrevocable_i = 0;
                send_response(0, 0); send_response(0, 0);
                check(occupancy_o == 0 && writes == 2, "posted responses retain independent ownership");

                reset_case();
                allocate_one(1, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
                allocate_one(1, tag(1), `RV32_MEMORY_WORD, 0, second_tag);
                store_address(tag(0), first_tag, 32'h580);
                store_data(tag(0), first_tag, 32'h11111111);
                expect_completion(tag(0), 0, 0, 0);
                store_address(tag(1), second_tag, 32'h80000000);
                store_data(tag(1), second_tag, 32'h2a);
                expect_completion(tag(1), 0, 0, 0);
                commit_head(tag(0), first_tag);
                commit_valid_i[1] = 1; commit_lsq_valid_i[1] = 1;
                commit_op_i[`RV32_OP_WIDTH +: `RV32_OP_WIDTH] = `RV32_OP_SW;
                commit_rob_tag_i[ROB_TAG_WIDTH +: ROB_TAG_WIDTH] = tag(1);
                commit_lsq_tag_i[LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] = second_tag;
                cache_request_ready_i = 1; cache_request_irrevocable_i = 1;
                tick(); commit_fire_i[0] = 1;
                #1; check(!cache_request_valid_o, "MMIO cannot use retiring prefix");
                tick(); cache_request_ready_i = 0; commit_valid_i = 0; commit_fire_i = 0;
                send_response(0, 0);
                commit_head(tag(1), second_tag); rob_head_index_i = 1;
                expect_mmio_request(32'h2a);
                check(!commit_ready_o[0], "MMIO waits for write response despite proof");
                send_response(0, 0);
                check(commit_ready_o[0], "MMIO becomes ready after write response");
                commit_fire_i[0] = 1; tick(); commit_valid_i = 0; commit_fire_i = 0;
                check(occupancy_o == 0 && writes == 2, "MMIO head commits exactly once");
            end
        end

        reset_case();
        allocate_one(1, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
        allocate_one(1, tag(1), `RV32_MEMORY_WORD, 0, second_tag);
        store_address(tag(0), first_tag, 32'h600);
        store_data(tag(0), first_tag, 32'h11111111);
        expect_completion(tag(0), 0, 0, 0);
        commit_head(tag(0), first_tag);
        expect_request(1, 32'h600, 4'hf); commit_valid_i = 0;
        store_address(tag(1), second_tag, 32'h604);
        store_data(tag(1), second_tag, 32'h22222222);
        cache_response_id_i = saved_id[0]; cache_response_rob_tag_i = saved_rob[0];
        cache_response_valid_i = 1; #1; check(cache_response_ready_o, "store acknowledgment ready");
        tick(); cache_response_valid_i = 0;
        check(completion_valid_o && completion_rob_tag_o == tag(1),
            "store acknowledgment overlaps completion");
        expect_completion(tag(1), 0, 0, 0);
        $display("PASS LSQ handoff width=%0d fast=%0d checks=%0d", BE_WIDTH, FAST_MODE, checks);
        $finish;
    end
    initial begin #100000; $display("FAIL handoff watchdog"); $finish; end
endmodule
