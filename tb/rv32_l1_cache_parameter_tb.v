`timescale 1ns/1ps

module rv32_l1_cache_parameter_tb;
    reg clk_i;
    reg reset_i;

    reg i_request_valid;
    wire i_request_ready;
    reg [31:0] i_request_pc;
    wire i_response_valid;
    wire [31:0] i_response_pc;
    wire [127:0] i_response_line;
    wire i_response_error;
    wire i_memory_request_valid;
    wire i_memory_request_ready;
    wire [31:0] i_memory_request_address;
    wire i_memory_response_valid;
    wire i_memory_response_ready;
    wire [127:0] i_memory_response_data;
    wire i_memory_response_error;
    wire i_hit_event;
    wire i_miss_event;

    reg d_request_valid;
    wire d_request_ready;
    reg d_request_write;
    reg [31:0] d_request_address;
    reg [31:0] d_request_write_data;
    reg [3:0] d_request_byte_enable;
    wire d_response_valid;
    wire [31:0] d_response_data;
    wire d_response_error;
    wire d_memory_request_valid;
    wire d_memory_request_ready;
    wire d_memory_request_write;
    wire [31:0] d_memory_request_address;
    wire [127:0] d_memory_request_write_data;
    wire [15:0] d_memory_request_byte_enable;
    wire d_memory_response_valid;
    wire d_memory_response_ready;
    wire [127:0] d_memory_response_data;
    wire d_memory_response_error;
    wire d_hit_event;
    wire d_miss_event;

    integer i_memory_reads;
    integer d_memory_reads;
    integer d_memory_writes;
    integer i_hits;
    integer i_misses;
    integer d_hits;
    integer d_misses;
    integer cycle;
    integer index;
    integer byte_index;
    integer wait_cycles;
    reg [7:0] reference_byte [0:255];

    rv32_l1_instruction_cache #(
        .CACHE_SIZE_BYTES(128),
        .NUM_SETS(4),
        .NUM_WAYS(2)
    ) icache (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(1'b0),
        .request_valid_i(i_request_valid),
        .request_ready_o(i_request_ready),
        .request_pc_i(i_request_pc),
        .response_valid_o(i_response_valid),
        .response_ready_i(1'b1),
        .response_pc_o(i_response_pc),
        .response_line_o(i_response_line),
        .response_error_o(i_response_error),
        .memory_request_valid_o(i_memory_request_valid),
        .memory_request_ready_i(i_memory_request_ready),
        .memory_request_address_o(i_memory_request_address),
        .memory_response_valid_i(i_memory_response_valid),
        .memory_response_ready_o(i_memory_response_ready),
        .memory_response_read_data_i(i_memory_response_data),
        .memory_response_error_i(i_memory_response_error),
        .hit_event_o(i_hit_event), .miss_event_o(i_miss_event)
    );

    rv32_l1_data_cache #(
        .CACHE_SIZE_BYTES(128),
        .NUM_SETS(4),
        .NUM_WAYS(2)
    ) dcache (
        .clk_i(clk_i), .reset_i(reset_i),
        .request_valid_i(d_request_valid),
        .request_ready_o(d_request_ready),
        .request_write_i(d_request_write),
        .request_address_i(d_request_address),
        .request_write_data_i(d_request_write_data),
        .request_byte_enable_i(d_request_byte_enable),
        .response_valid_o(d_response_valid),
        .response_ready_i(1'b1),
        .response_read_data_o(d_response_data),
        .response_error_o(d_response_error),
        .memory_request_valid_o(d_memory_request_valid),
        .memory_request_ready_i(d_memory_request_ready),
        .memory_request_write_o(d_memory_request_write),
        .memory_request_address_o(d_memory_request_address),
        .memory_request_write_data_o(d_memory_request_write_data),
        .memory_request_byte_enable_o(d_memory_request_byte_enable),
        .memory_response_valid_i(d_memory_response_valid),
        .memory_response_ready_o(d_memory_response_ready),
        .memory_response_read_data_i(d_memory_response_data),
        .memory_response_error_i(d_memory_response_error),
        .hit_event_o(d_hit_event), .miss_event_o(d_miss_event)
    );

    rv32_main_memory memory (
        .clk_i(clk_i), .reset_i(reset_i),
        .i_request_valid_i(i_memory_request_valid),
        .i_request_ready_o(i_memory_request_ready),
        .i_request_address_i(i_memory_request_address),
        .i_response_valid_o(i_memory_response_valid),
        .i_response_ready_i(i_memory_response_ready),
        .i_response_read_data_o(i_memory_response_data),
        .i_response_error_o(i_memory_response_error),
        .d_request_valid_i(d_memory_request_valid),
        .d_request_ready_o(d_memory_request_ready),
        .d_request_write_i(d_memory_request_write),
        .d_request_address_i(d_memory_request_address),
        .d_request_write_data_i(d_memory_request_write_data),
        .d_request_byte_enable_i(d_memory_request_byte_enable),
        .d_response_valid_o(d_memory_response_valid),
        .d_response_ready_i(d_memory_response_ready),
        .d_response_read_data_o(d_memory_response_data),
        .d_response_error_o(d_memory_response_error)
    );

    function [7:0] pattern_byte;
        input integer address;
        begin
            pattern_byte = (address >> 3) ^ (address * 13) ^ 8'h5a;
        end
    endfunction

    function [127:0] expected_line;
        input [31:0] pc;
        integer offset;
        reg [31:0] base;
        begin
            base = {pc[31:4], 4'b0000};
            expected_line = 128'd0;
            for (offset = 0; offset < 16; offset = offset + 1)
                expected_line[offset*8 +: 8] = pattern_byte(base + offset);
        end
    endfunction

    function [31:0] expected_word;
        input [31:0] address;
        integer offset;
        begin
            expected_word = 32'd0;
            for (offset = 0; offset < 4; offset = offset + 1)
                expected_word[offset*8 +: 8] =
                    reference_byte[address + offset];
        end
    endfunction

    always #5 clk_i = ~clk_i;

    always @(posedge clk_i) begin
        cycle = cycle + 1;
        if (reset_i) begin
            i_memory_reads = 0;
            d_memory_reads = 0;
            d_memory_writes = 0;
            i_hits = 0;
            i_misses = 0;
            d_hits = 0;
            d_misses = 0;
        end else begin
            if (i_memory_request_valid && i_memory_request_ready)
                i_memory_reads = i_memory_reads + 1;
            if (d_memory_request_valid && d_memory_request_ready) begin
                if (d_memory_request_write)
                    d_memory_writes = d_memory_writes + 1;
                else
                    d_memory_reads = d_memory_reads + 1;
            end
            if (i_hit_event)
                i_hits = i_hits + 1;
            if (i_miss_event)
                i_misses = i_misses + 1;
            if (d_hit_event)
                d_hits = d_hits + 1;
            if (d_miss_event)
                d_misses = d_misses + 1;
        end
    end

    initial begin
        #1000000;
        $fatal(1, "ERROR cache parameter test watchdog expired");
    end

    task fetch_pc;
        input [31:0] pc;
        begin
            @(negedge clk_i);
            while (!i_request_ready)
                @(negedge clk_i);
            i_request_pc = pc;
            i_request_valid = 1'b1;
            @(posedge clk_i);
            #1;
            i_request_valid = 1'b0;
            wait_cycles = 0;
            while (!i_response_valid) begin
                @(posedge clk_i);
                #1;
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 200)
                    $fatal(1, "ERROR I-cache parameter response timeout");
            end
            if (i_response_pc !== pc || i_response_error !== 1'b0 ||
                    i_response_line !== expected_line(pc))
                $fatal(1, "ERROR I-cache parameter response pc=%h", pc);
        end
    endtask

    task load_word;
        input [31:0] address;
        begin
            @(negedge clk_i);
            while (!d_request_ready)
                @(negedge clk_i);
            d_request_valid = 1'b1;
            d_request_write = 1'b0;
            d_request_address = address;
            d_request_write_data = 32'd0;
            d_request_byte_enable = 4'd0;
            @(posedge clk_i);
            #1;
            d_request_valid = 1'b0;
            wait_cycles = 0;
            while (!d_response_valid) begin
                @(posedge clk_i);
                #1;
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 200)
                    $fatal(1, "ERROR D-cache parameter response timeout");
            end
            if (d_response_error !== 1'b0 ||
                    d_response_data !== expected_word(address))
                $fatal(1, "ERROR D-cache parameter load address=%h got=%h expected=%h",
                    address, d_response_data, expected_word(address));
        end
    endtask

    task store_word;
        input [31:0] address;
        input [31:0] value;
        begin
            @(negedge clk_i);
            while (!d_request_ready)
                @(negedge clk_i);
            d_request_valid = 1'b1;
            d_request_write = 1'b1;
            d_request_address = address;
            d_request_write_data = value;
            d_request_byte_enable = 4'hf;
            @(posedge clk_i);
            #1;
            d_request_valid = 1'b0;
            wait_cycles = 0;
            while (!d_response_valid) begin
                @(posedge clk_i);
                #1;
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 200)
                    $fatal(1, "ERROR D-cache parameter store timeout");
            end
            if (d_response_error !== 1'b0 || d_response_data !== 32'd0)
                $fatal(1, "ERROR D-cache parameter store response");
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                reference_byte[address + byte_index] =
                    value[byte_index*8 +: 8];
        end
    endtask

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b1;
        i_request_valid = 1'b0;
        i_request_pc = 32'd0;
        d_request_valid = 1'b0;
        d_request_write = 1'b0;
        d_request_address = 32'd0;
        d_request_write_data = 32'd0;
        d_request_byte_enable = 4'd0;
        cycle = 0;
        wait_cycles = 0;
        for (index = 0; index < 256; index = index + 1) begin
            reference_byte[index] = pattern_byte(index);
            memory.byte_memory[index] = pattern_byte(index);
        end
        repeat (3) @(posedge clk_i);
        #2;
        reset_i = 1'b0;

        fetch_pc(32'h00000000);
        fetch_pc(32'h00000040);
        fetch_pc(32'h00000000);
        fetch_pc(32'h00000080);
        fetch_pc(32'h00000040);
        fetch_pc(32'h00000000);
        if (i_memory_reads != 4 || i_misses != 4 || i_hits != 2)
            $fatal(1, "ERROR I-cache 2-way replacement reads=%0d hits=%0d misses=%0d",
                i_memory_reads, i_hits, i_misses);

        load_word(32'h00000000);
        load_word(32'h00000040);
        load_word(32'h00000000);
        load_word(32'h00000040);
        store_word(32'h00000000, 32'hdeadbeef);
        load_word(32'h00000080);
        load_word(32'h00000040);
        if (d_memory_reads != 3 || d_memory_writes != 1)
            $fatal(1, "ERROR D-cache 2-way replacement reads=%0d writes=%0d",
                d_memory_reads, d_memory_writes);
        if (memory.byte_memory[0] !== 8'hef ||
                memory.byte_memory[1] !== 8'hbe ||
                memory.byte_memory[2] !== 8'had ||
                memory.byte_memory[3] !== 8'hde)
            $fatal(1, "ERROR dirty victim was not written back");
        load_word(32'h00000000);
        if (d_memory_reads != 4 || d_misses != 4 || d_hits < 3)
            $fatal(1, "ERROR D-cache replacement stats reads=%0d hits=%0d misses=%0d",
                d_memory_reads, d_hits, d_misses);

        $display("PASS parameterized 2-way caches with synchronous FakeRAM");
        $finish;
    end
endmodule
