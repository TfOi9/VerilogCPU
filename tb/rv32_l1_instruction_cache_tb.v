`timescale 1ns/1ps

module rv32_l1_instruction_cache_tb;
    reg clk_i;
    reg reset_i;
    reg flush_i;
    reg request_valid_i;
    wire request_ready_o;
    reg [31:0] request_pc_i;
    wire response_valid_o;
    reg response_ready_i;
    wire [31:0] response_pc_o;
    wire [127:0] response_line_o;
    wire response_error_o;
    wire memory_request_valid;
    wire memory_request_ready;
    wire memory_request_ready_raw;
    wire [31:0] memory_request_address;
    wire memory_response_valid;
    wire memory_response_ready;
    wire [127:0] memory_response_data;
    wire memory_response_error;
    wire hit_event;
    wire miss_event;

    integer cycle;
    integer head;
    integer tail;
    integer hit_count;
    integer miss_count;
    integer seed;
    integer index;
    integer step;
    integer baseline;
    integer accepted_cycle;
    integer random_value;
    reg strict_latency;
    reg random_backpressure;
    reg block_memory_request;
    reg [31:0] expected_pc [0:511];
    reg expected_error [0:511];
    reg expected_strict [0:511];
    reg expected_seen [0:511];
    integer expected_cycle [0:511];

    rv32_l1_instruction_cache cache (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(flush_i),
        .request_valid_i(request_valid_i),
        .request_ready_o(request_ready_o),
        .request_pc_i(request_pc_i),
        .response_valid_o(response_valid_o),
        .response_ready_i(response_ready_i),
        .response_pc_o(response_pc_o),
        .response_line_o(response_line_o),
        .response_error_o(response_error_o),
        .memory_request_valid_o(memory_request_valid),
        .memory_request_ready_i(memory_request_ready),
        .memory_request_address_o(memory_request_address),
        .memory_response_valid_i(memory_response_valid),
        .memory_response_ready_o(memory_response_ready),
        .memory_response_read_data_i(memory_response_data),
        .memory_response_error_i(memory_response_error),
        .hit_event_o(hit_event), .miss_event_o(miss_event)
    );

    rv32_main_memory memory (
        .clk_i(clk_i), .reset_i(reset_i),
        .i_request_valid_i(memory_request_valid && !block_memory_request),
        .i_request_ready_o(memory_request_ready_raw),
        .i_request_address_i(memory_request_address),
        .i_response_valid_o(memory_response_valid),
        .i_response_ready_i(memory_response_ready),
        .i_response_read_data_o(memory_response_data),
        .i_response_error_o(memory_response_error),
        .d_request_valid_i(1'b0), .d_request_ready_o(),
        .d_request_write_i(1'b0), .d_request_address_i(32'd0),
        .d_request_write_data_i(128'd0),
        .d_request_byte_enable_i(16'd0),
        .d_response_valid_o(), .d_response_ready_i(1'b1),
        .d_response_read_data_o(), .d_response_error_o()
    );

    assign memory_request_ready =
        memory_request_ready_raw && !block_memory_request;

    function [7:0] pattern_byte;
        input [31:0] address;
        begin
            pattern_byte = (address >> 4) + (address >> 8) +
                ((address & 15) * 7);
        end
    endfunction

    function [127:0] expected_line;
        input [31:0] pc;
        reg [31:0] base;
        integer offset;
        begin
            base = {pc[31:4], 4'b0000};
            expected_line = 128'd0;
            if (base < 32'h00000c00 || base == 32'h000ffff0)
                for (offset = 0; offset < 16; offset = offset + 1)
                    expected_line[offset*8 +: 8] =
                        pattern_byte(base + offset);
        end
    endfunction

    always #5 clk_i = ~clk_i;

    always @(negedge clk_i) begin
        if (random_backpressure)
            response_ready_i = (($random(seed) & 3) != 0);
    end

    always @(posedge clk_i) begin
        cycle = cycle + 1;
        if (reset_i) begin
            head = 0;
            tail = 0;
        end else if (flush_i) begin
            head = 0;
            tail = 0;
        end else begin
            if (response_valid_o && response_ready_i) begin
                if (head >= tail)
                    $fatal(1, "ERROR unsolicited cache response");
                if (response_pc_o !== expected_pc[head] ||
                        response_error_o !== expected_error[head] ||
                        response_line_o !==
                            (expected_error[head] ? 128'd0 :
                                expected_line(expected_pc[head])))
                    $fatal(1, "ERROR response mismatch pc=%h expected=%h",
                        response_pc_o, expected_pc[head]);
                head = head + 1;
            end
            if (request_valid_i && request_ready_o) begin
                if (tail >= 512)
                    $fatal(1, "ERROR scoreboard overflow");
                expected_pc[tail] = request_pc_i;
                expected_error[tail] = (request_pc_i >= 32'h00100000);
                expected_strict[tail] = strict_latency;
                expected_seen[tail] = 1'b0;
                expected_cycle[tail] = cycle;
                tail = tail + 1;
            end
            if (hit_event)
                hit_count = hit_count + 1;
            if (miss_event)
                miss_count = miss_count + 1;
        end
        #1;
        if (!reset_i && !flush_i && response_valid_o &&
                head < tail && !expected_seen[head]) begin
            if (response_pc_o !== expected_pc[head])
                $fatal(1, "ERROR response order at cycle %0d", cycle);
            if (expected_strict[head] &&
                    cycle != expected_cycle[head] + 3)
                $fatal(1, "ERROR hit latency pc=%h got=%0d expected=%0d",
                    response_pc_o, cycle, expected_cycle[head] + 3);
            expected_seen[head] = 1'b1;
        end
    end

    initial begin
        #200000;
        $fatal(1, "ERROR instruction cache watchdog expired");
    end

    task send_request;
        input [31:0] pc;
        output integer at_cycle;
        begin
            @(negedge clk_i);
            while (!request_ready_o)
                @(negedge clk_i);
            request_pc_i = pc;
            request_valid_i = 1'b1;
            @(posedge clk_i);
            #2;
            at_cycle = cycle;
            request_valid_i = 1'b0;
        end
    endtask

    task wait_empty;
        integer watch;
        begin
            watch = 0;
            while (head != tail) begin
                @(posedge clk_i);
                #2;
                watch = watch + 1;
                if (watch > 1000)
                    $fatal(1, "ERROR response drain timeout");
            end
        end
    endtask

    task flush_pipeline;
        begin
            @(negedge clk_i);
            flush_i = 1'b1;
            @(posedge clk_i);
            #2;
            flush_i = 1'b0;
        end
    endtask

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b1;
        flush_i = 1'b0;
        request_valid_i = 1'b0;
        request_pc_i = 32'd0;
        response_ready_i = 1'b1;
        strict_latency = 1'b0;
        random_backpressure = 1'b0;
        block_memory_request = 1'b0;
        cycle = 0;
        head = 0;
        tail = 0;
        hit_count = 0;
        miss_count = 0;
        seed = 32'h12345678;

        #1;
        for (index = 0; index < 3072; index = index + 1)
            memory.byte_memory[index] = pattern_byte(index);
        for (index = 0; index < 16; index = index + 1)
            memory.byte_memory[32'h000ffff0 + index] =
                pattern_byte(32'h000ffff0 + index);
        repeat (3) @(posedge clk_i);
        #2;
        reset_i = 1'b0;

        send_request(32'h00000000, accepted_cycle);
        wait_empty();
        if (miss_count != 1)
            $fatal(1, "ERROR initial refill was not counted");

        strict_latency = 1'b1;
        send_request(32'h00000000, accepted_cycle);
        send_request(32'h00000004, accepted_cycle);
        send_request(32'h0000000c, accepted_cycle);
        send_request(32'h00000000, accepted_cycle);
        wait_empty();
        if (hit_count != 4)
            $fatal(1, "ERROR streaming hits were not counted");

        strict_latency = 1'b0;
        send_request(32'h00000010, accepted_cycle);
        send_request(32'h00000020, accepted_cycle);
        wait_empty();
        strict_latency = 1'b1;
        send_request(32'h0000000c, accepted_cycle);
        send_request(32'h00000010, accepted_cycle);
        wait_empty();

        strict_latency = 1'b0;
        baseline = miss_count;
        send_request(32'h00000400, accepted_cycle);
        send_request(32'h00000000, accepted_cycle);
        send_request(32'h00000010, accepted_cycle);
        wait_empty();
        if (miss_count != baseline + 2)
            $fatal(1, "ERROR stale younger lookup was not replayed");

        response_ready_i = 1'b0;
        strict_latency = 1'b0;
        send_request(32'h00000010, accepted_cycle);
        send_request(32'h00000020, accepted_cycle);
        send_request(32'h00000010, accepted_cycle);
        send_request(32'h00000020, accepted_cycle);
        repeat (9) @(posedge clk_i);
        #2;
        if (!response_valid_o || response_pc_o != 32'h00000010 ||
                request_ready_o)
            $fatal(1, "ERROR response backpressure did not propagate");
        response_ready_i = 1'b1;
        wait_empty();

        response_ready_i = 1'b0;
        for (step = 0; step < 4; step = step + 1) begin
            send_request(32'h00000010, accepted_cycle);
            repeat (step) @(posedge clk_i);
            flush_pipeline();
            repeat (4) @(posedge clk_i);
            #2;
            if (response_valid_o || head != tail)
                $fatal(1, "ERROR flush leaked a response stage=%0d", step);
        end
        response_ready_i = 1'b1;
        strict_latency = 1'b1;
        send_request(32'h00000010, accepted_cycle);
        wait_empty();

        strict_latency = 1'b0;
        send_request(32'h00000800, accepted_cycle);
        while (!memory.i_busy) begin
            @(posedge clk_i);
            #2;
        end
        flush_pipeline();
        strict_latency = 1'b1;
        send_request(32'h00000010, accepted_cycle);
        wait_empty();
        strict_latency = 1'b0;
        baseline = miss_count;
        send_request(32'h00000900, accepted_cycle);
        wait_empty();
        if (miss_count != baseline + 1)
            $fatal(1, "ERROR new miss behind orphan was not counted");
        baseline = miss_count;
        send_request(32'h00000800, accepted_cycle);
        wait_empty();
        if (miss_count != baseline + 1)
            $fatal(1, "ERROR orphan refill was installed");

        block_memory_request = 1'b1;
        send_request(32'h00000b00, accepted_cycle);
        while (!memory_request_valid) begin
            @(posedge clk_i);
            #2;
        end
        flush_pipeline();
        if (memory.i_busy)
            $fatal(1, "ERROR unaccepted refill was not canceled");
        block_memory_request = 1'b0;
        strict_latency = 1'b1;
        send_request(32'h00000010, accepted_cycle);
        wait_empty();

        strict_latency = 1'b0;
        send_request(32'h00000a00, accepted_cycle);
        while (!memory_response_valid) begin
            @(posedge clk_i);
            #2;
        end
        flush_pipeline();
        baseline = miss_count;
        send_request(32'h00000a00, accepted_cycle);
        wait_empty();
        if (miss_count != baseline + 1)
            $fatal(1, "ERROR coincident flush installed a refill");

        send_request(32'h000ffffc, accepted_cycle);
        send_request(32'h00100000, accepted_cycle);
        wait_empty();

        send_request(32'h00000700, accepted_cycle);
        while (!memory.i_busy) begin
            @(posedge clk_i);
            #2;
        end
        @(negedge clk_i);
        reset_i = 1'b1;
        @(posedge clk_i);
        #2;
        reset_i = 1'b0;
        repeat (4) @(posedge clk_i);
        #2;
        if (response_valid_o || memory.i_busy || head != tail)
            $fatal(1, "ERROR reset did not cancel the refill");
        baseline = miss_count;
        send_request(32'h00000700, accepted_cycle);
        wait_empty();
        if (miss_count != baseline + 1)
            $fatal(1, "ERROR reset retained a valid cache line");

        random_backpressure = 1'b1;
        for (step = 0; step < 80; step = step + 1) begin
            random_value = $random(seed) & 15;
            send_request((random_value % 12) * 32'h100 +
                ((random_value & 3) * 4), accepted_cycle);
        end
        wait_empty();
        random_backpressure = 1'b0;
        response_ready_i = 1'b1;

        if (head != tail)
            $fatal(1, "ERROR responses remain pending");
        $display("PASS pipelined L1 instruction cache (%0d hits, %0d misses)",
            hit_count, miss_count);
        $finish;
    end
endmodule
