`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_posted_store_tb;
    wire cache_irrevocable;
    reg recover_i;
    reg flush_i;
    reg rollback_valid;
    reg [6:0] rollback_rob;
    reg [4:0] rollback_lsq;
    reg [4:0] younger_tag;
    integer early_count;
    reg [4:0] head_index;
    reg clk_i;
    reg reset_i;
    reg alloc_valid_i;
    reg alloc_fire_i;
    reg alloc_store_i;
    reg [6:0] alloc_rob_tag_i;
    reg [`RV32_MEMORY_WIDTH-1:0] alloc_width_i;
    wire alloc_ready_o;
    wire [4:0] alloc_lsq_tag_o;
    wire [3:0] occupancy_o;
    reg load_address_valid_i;
    wire load_address_ready_o;
    reg [6:0] load_address_rob_tag_i;
    reg [4:0] load_address_lsq_tag_i;
    reg [31:0] load_address_i;
    reg store_address_valid_i;
    wire store_address_ready_o;
    reg [6:0] store_address_rob_tag_i;
    reg [4:0] store_address_lsq_tag_i;
    reg [31:0] store_address_i;
    reg store_data_valid_i;
    wire store_data_ready_o;
    reg [6:0] store_data_rob_tag_i;
    reg [4:0] store_data_lsq_tag_i;
    reg [31:0] store_data_i;
    wire completion_valid_o;
    reg completion_ready_i;
    wire [6:0] completion_rob_tag_o;
    wire [31:0] completion_value_o;
    wire completion_exception_valid_o;
    reg commit_valid_i;
    reg [`RV32_OP_WIDTH-1:0] commit_op_i;
    reg commit_lsq_valid_i;
    reg [6:0] commit_rob_tag_i;
    reg [4:0] commit_lsq_tag_i;
    reg commit_fire_i;
    wire commit_ready_o;
    wire cache_request_valid;
    wire cache_request_ready;
    wire cache_request_write;
    wire [31:0] cache_request_address;
    wire [31:0] cache_request_write_data;
    wire [3:0] cache_request_byte_enable;
    wire cache_response_valid;
    wire cache_response_ready;
    wire [31:0] cache_response_read_data;
    wire cache_response_error;
    wire memory_request_valid;
    wire memory_request_ready;
    wire memory_request_write;
    wire [31:0] memory_request_address;
    wire [127:0] memory_request_write_data;
    wire [15:0] memory_request_byte_enable;
    wire memory_response_valid;
    wire memory_response_ready;
    wire [127:0] memory_response_read_data;
    wire memory_response_error;
    integer cache_write_count;
    integer wait_count;
    reg [4:0] store_tag;
    reg [4:0] load_tag;

    rv32_load_store_queue #(.POSTED_STORES(1), .LOAD_FALLTHROUGH(1)) lsq (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(flush_i),
        .recover_i(recover_i),
        .alloc_valid_i(alloc_valid_i), .alloc_fire_i(alloc_fire_i),
        .alloc_store_i(alloc_store_i),
        .alloc_rob_tag_i(alloc_rob_tag_i),
        .alloc_width_i(alloc_width_i), .alloc_unsigned_i(1'b0),
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
        .rob_head_index_i(head_index),
        .rollback_valid_i(rollback_valid),
        .rollback_rob_tag_i(rollback_rob),
        .rollback_lsq_tag_i(rollback_lsq),
        .completion_valid_o(completion_valid_o),
        .completion_ready_i(completion_ready_i),
        .completion_rob_tag_o(completion_rob_tag_o),
        .completion_value_o(completion_value_o),
        .completion_exception_valid_o(completion_exception_valid_o),
        .completion_exception_cause_o(),
        .completion_exception_tval_o(),
        .commit_valid_i(commit_valid_i),
        .commit_op_i(commit_op_i),
        .commit_lsq_valid_i(commit_lsq_valid_i),
        .commit_rob_tag_i(commit_rob_tag_i),
        .commit_lsq_tag_i(commit_lsq_tag_i),
        .commit_exception_valid_i(1'b0),
        .commit_fire_i(commit_fire_i),
        .commit_ready_o(commit_ready_o),
        .cache_request_valid_o(cache_request_valid),
        .cache_request_ready_i(cache_request_ready),
        .cache_request_irrevocable_i(cache_irrevocable),
        .cache_request_write_o(cache_request_write),
        .cache_request_address_o(cache_request_address),
        .cache_request_write_data_o(cache_request_write_data),
        .cache_request_byte_enable_o(cache_request_byte_enable),
        .cache_request_mmio_o(),
        .cache_response_valid_i(cache_response_valid),
        .cache_response_ready_o(cache_response_ready),
        .cache_response_read_data_i(cache_response_read_data),
        .cache_response_error_i(cache_response_error)
    );

    rv32_l1_data_cache cache (
        .clk_i(clk_i), .reset_i(reset_i),
        .request_valid_i(cache_request_valid),
        .request_ready_o(cache_request_ready),
        .request_irrevocable_o(cache_irrevocable),
        .request_write_i(cache_request_write),
        .request_address_i(cache_request_address),
        .request_write_data_i(cache_request_write_data),
        .request_byte_enable_i(cache_request_byte_enable),
        .response_valid_o(cache_response_valid),
        .response_ready_i(cache_response_ready),
        .response_read_data_o(cache_response_read_data),
        .response_error_o(cache_response_error),
        .memory_request_valid_o(memory_request_valid),
        .memory_request_ready_i(memory_request_ready),
        .memory_request_write_o(memory_request_write),
        .memory_request_address_o(memory_request_address),
        .memory_request_write_data_o(memory_request_write_data),
        .memory_request_byte_enable_o(memory_request_byte_enable),
        .memory_response_valid_i(memory_response_valid),
        .memory_response_ready_o(memory_response_ready),
        .memory_response_read_data_i(memory_response_read_data),
        .memory_response_error_i(memory_response_error),
        .hit_event_o(), .miss_event_o()
    );

    rv32_main_memory memory (
        .clk_i(clk_i), .reset_i(reset_i),
        .i_request_valid_i(1'b0), .i_request_ready_o(),
        .i_request_address_i(32'd0),
        .i_response_valid_o(), .i_response_ready_i(1'b1),
        .i_response_read_data_o(), .i_response_error_o(),
        .d_request_valid_i(memory_request_valid),
        .d_request_ready_o(memory_request_ready),
        .d_request_write_i(memory_request_write),
        .d_request_address_i(memory_request_address),
        .d_request_write_data_i(memory_request_write_data),
        .d_request_byte_enable_i(memory_request_byte_enable),
        .d_response_valid_o(memory_response_valid),
        .d_response_ready_i(memory_response_ready),
        .d_response_read_data_o(memory_response_read_data),
        .d_response_error_o(memory_response_error)
    );

    always @(posedge clk_i)
        if (!reset_i && cache_request_valid && cache_request_ready &&
                cache_request_write)
            cache_write_count = cache_write_count + 1;

    task tick;
        begin
            #5 clk_i = 1'b1;
            #1 clk_i = 1'b0;
            #1;
        end
    endtask

    task await_completion;
        input [6:0] rob_tag;
        input [31:0] value;
        begin
            wait_count = 0;
            while (!completion_valid_o && wait_count < 300) begin
                tick();
                wait_count = wait_count + 1;
            end
            if (!completion_valid_o || completion_rob_tag_o != rob_tag ||
                    completion_value_o !== value ||
                    completion_exception_valid_o)
                $fatal(1, "ERROR LSQ completion tag=%h value=%h",
                    completion_rob_tag_o, completion_value_o);
            completion_ready_i = 1'b1;
            tick();
            completion_ready_i = 1'b0;
        end
    endtask

    initial begin
        #100000;
        $fatal(1, "ERROR LSQ data cache integration watchdog expired");
    end

    initial begin
        recover_i = 0; flush_i = 0; rollback_valid = 0;
        rollback_rob = 0; rollback_lsq = 0; head_index = 0; early_count = 0;
        clk_i = 0;
        reset_i = 1;
        alloc_valid_i = 0;
        alloc_fire_i = 0;
        alloc_store_i = 0;
        alloc_rob_tag_i = 0;
        alloc_width_i = 0;
        load_address_valid_i = 0;
        load_address_rob_tag_i = 0;
        load_address_lsq_tag_i = 0;
        load_address_i = 0;
        store_address_valid_i = 0;
        store_address_rob_tag_i = 0;
        store_address_lsq_tag_i = 0;
        store_address_i = 0;
        store_data_valid_i = 0;
        store_data_rob_tag_i = 0;
        store_data_lsq_tag_i = 0;
        store_data_i = 0;
        completion_ready_i = 0;
        commit_valid_i = 0;
        commit_op_i = 0;
        commit_lsq_valid_i = 0;
        commit_rob_tag_i = 0;
        commit_lsq_tag_i = 0;
        commit_fire_i = 0;
        cache_write_count = 0;
        repeat (3) tick();
        reset_i = 0;

        alloc_valid_i = 1;
        alloc_store_i = 1;
        alloc_rob_tag_i = 0;
        alloc_width_i = `RV32_MEMORY_BYTE;
        #1;
        if (!alloc_ready_o)
            $fatal(1, "ERROR store allocation not ready");
        store_tag = alloc_lsq_tag_o;
        alloc_fire_i = 1;
        tick();
        alloc_valid_i = 0;
        alloc_fire_i = 0;

        store_address_valid_i = 1;
        store_address_rob_tag_i = 0;
        store_address_lsq_tag_i = store_tag;
        store_address_i = 32'h201;
        #1;
        if (!store_address_ready_o)
            $fatal(1, "ERROR store address not ready");
        tick();
        store_address_valid_i = 0;
        store_data_valid_i = 1;
        store_data_rob_tag_i = 0;
        store_data_lsq_tag_i = store_tag;
        store_data_i = 32'haa;
        #1;
        if (!store_data_ready_o)
            $fatal(1, "ERROR store data not ready");
        tick();
        store_data_valid_i = 0;
        await_completion(0, 0);
        repeat (8) tick();
        if (cache_write_count != 0 || cache_request_valid ||
                occupancy_o != 1)
            $fatal(1, "ERROR store reached cache before commit candidate");

        commit_valid_i = 1;
        commit_lsq_valid_i = 1;
        commit_op_i = `RV32_OP_SB;
        commit_rob_tag_i = 0;
        commit_lsq_tag_i = store_tag;
        #1;
        wait_count = 0;
        while (!commit_ready_o && wait_count < 300) begin
            tick();
            wait_count = wait_count + 1;
        end
        if (!commit_ready_o || cache_write_count != 1 ||
                occupancy_o != 1)
            $fatal(1, "ERROR committed store was not acknowledged");
        commit_fire_i = 1;
        tick();
        commit_fire_i = 0;
        commit_valid_i = 0;
        commit_lsq_valid_i = 0;
        if (occupancy_o != 0)
            $fatal(1, "ERROR committed store not released");

        alloc_valid_i = 1;
        alloc_store_i = 0;
        alloc_rob_tag_i = 1;
        alloc_width_i = `RV32_MEMORY_WORD;
        #1;
        if (!alloc_ready_o)
            $fatal(1, "ERROR load allocation not ready");
        load_tag = alloc_lsq_tag_o;
        alloc_fire_i = 1;
        tick();
        alloc_valid_i = 0;
        alloc_fire_i = 0;
        load_address_valid_i = 1;
        load_address_rob_tag_i = 1;
        load_address_lsq_tag_i = load_tag;
        load_address_i = 32'h200;
        #1;
        if (!load_address_ready_o)
            $fatal(1, "ERROR load address not ready");
        tick();
        load_address_valid_i = 0;
        await_completion(1, 32'h0000aa00);
        if (occupancy_o != 0 || memory.byte_memory[32'h201] != 0)
            $fatal(1, "ERROR load or write-back visibility");

        // A resident RAM store retires at cache acceptance, before its response.
        allocate_store(2, 32'h202, 32'hbb, `RV32_MEMORY_BYTE, store_tag);
        allocate_store(3, 32'h208, 32'hdeadbeef, `RV32_MEMORY_WORD, younger_tag);
        commit_valid_i = 1; commit_lsq_valid_i = 1;
        commit_op_i = `RV32_OP_SB; commit_rob_tag_i = 2;
        commit_lsq_tag_i = store_tag; head_index = 2;
        #1;
        wait_count = 0;
        while (!commit_ready_o && wait_count < 100) begin
            tick(); wait_count = wait_count + 1;
        end
        if (!commit_ready_o || !cache_request_valid || !cache_request_ready ||
                !cache_irrevocable || cache_response_valid)
            $fatal(1, "ERROR resident store did not retire before response");
        commit_fire_i = 1; tick();
        commit_fire_i = 0; commit_valid_i = 0; commit_lsq_valid_i = 0;
        // Recovery cancels only the younger store while the committed write drains.
        recover_i = 1; rollback_valid = 1; rollback_rob = 3;
        rollback_lsq = younger_tag; tick(); rollback_valid = 0;
        repeat (10) tick(); recover_i = 0;
        if (occupancy_o != 0 || cache_write_count != 2)
            $fatal(1, "ERROR rollback altered committed store ownership");
        read_word(4, 32'h200, 32'h00bbaa00);
        read_word(5, 32'h208, 32'd0);

        // A full LSQ flush also preserves an accepted cache write.
        allocate_store(6, 32'h200, 32'h11223344, `RV32_MEMORY_WORD, store_tag);
        commit_valid_i = 1; commit_lsq_valid_i = 1;
        commit_op_i = `RV32_OP_SW; commit_rob_tag_i = 6;
        commit_lsq_tag_i = store_tag; head_index = 6;
        #1;
        wait_count = 0;
        while (!commit_ready_o && wait_count < 100) begin
            tick(); wait_count = wait_count + 1;
        end
        if (!cache_irrevocable || !commit_ready_o)
            $fatal(1, "ERROR second posted store not accepted");
        commit_fire_i = 1; tick(); commit_fire_i = 0;
        commit_valid_i = 0; commit_lsq_valid_i = 0; flush_i = 1;
        tick(); flush_i = 0; repeat (10) tick();
        read_word(7, 32'h200, 32'h11223344);
        if (cache_write_count != 3)
            $fatal(1, "ERROR posted write duplication");
        $display("PASS rv32_posted_store_tb rollback flush partial-byte reuse");
        $finish;
    end

    task allocate_store;
        input [6:0] tag;
        input [31:0] addr;
        input [31:0] value;
        input [`RV32_MEMORY_WIDTH-1:0] size;
        output [4:0] lsq_tag;
        begin
            alloc_valid_i = 1; alloc_store_i = 1; alloc_rob_tag_i = tag;
            alloc_width_i = size; #1;
            if (!alloc_ready_o) $fatal(1, "ERROR posted allocation");
            lsq_tag = alloc_lsq_tag_o; alloc_fire_i = 1; tick();
            alloc_valid_i = 0; alloc_fire_i = 0;
            store_address_valid_i = 1; store_address_rob_tag_i = tag;
            store_address_lsq_tag_i = lsq_tag; store_address_i = addr;
            store_data_valid_i = 1; store_data_rob_tag_i = tag;
            store_data_lsq_tag_i = lsq_tag; store_data_i = value; #1;
            if (!store_address_ready_o || !store_data_ready_o)
                $fatal(1, "ERROR posted operands");
            tick(); store_address_valid_i = 0; store_data_valid_i = 0;
            await_completion(tag, 0);
        end
    endtask

    task read_word;
        input [6:0] tag;
        input [31:0] addr;
        input [31:0] value;
        begin
            head_index = tag[4:0];
            alloc_valid_i = 1; alloc_store_i = 0; alloc_rob_tag_i = tag;
            alloc_width_i = `RV32_MEMORY_WORD; #1;
            if (!alloc_ready_o) $fatal(1, "ERROR posted load allocation");
            load_tag = alloc_lsq_tag_o; alloc_fire_i = 1; tick();
            alloc_valid_i = 0; alloc_fire_i = 0;
            load_address_valid_i = 1; load_address_rob_tag_i = tag;
            load_address_lsq_tag_i = load_tag; load_address_i = addr; #1;
            if (!load_address_ready_o) $fatal(1, "ERROR posted load address");
            tick(); load_address_valid_i = 0; await_completion(tag, value);
        end
    endtask
endmodule
