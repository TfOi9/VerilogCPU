`timescale 1ns/1ps

module rv32_l1_data_cache_tb;
    reg clk_i;
    reg reset_i;
    reg request_valid_i;
    wire request_ready_o;
    reg request_write_i;
    reg [31:0] request_address_i;
    reg [31:0] request_write_data_i;
    reg [3:0] request_byte_enable_i;
    wire response_valid_o;
    reg response_ready_i;
    wire [31:0] response_read_data_o;
    wire response_error_o;
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
    wire memory_response_error_raw;
    wire hit_event;
    wire miss_event;

    reg [7:0] reference_byte [0:8191];
    reg [31:0] expected_data [0:2047];
    reg expected_error [0:2047];
    reg expected_strict [0:2047];
    reg expected_seen [0:2047];
    integer expected_cycle [0:2047];
    integer head;
    integer tail;
    integer cycle;
    integer hit_count;
    integer miss_count;
    integer valid_count;
    integer memory_write_count;
    integer memory_read_count;
    integer seed;
    integer i;
    integer j;
    integer step;
    integer baseline;
    integer write_baseline;
    integer random_address;
    reg strict_latency;
    reg stream_mode;
    integer last_stream_cycle;
    reg inject_write_error;
    reg inject_read_error;
    reg force_expected_error;
    reg pending_memory_write;
    reg [31:0] held_data;
    reg held_error;

    rv32_l1_data_cache cache (
        .clk_i(clk_i), .reset_i(reset_i),
        .request_valid_i(request_valid_i),
        .request_ready_o(request_ready_o),
        .request_write_i(request_write_i),
        .request_address_i(request_address_i),
        .request_write_data_i(request_write_data_i),
        .request_byte_enable_i(request_byte_enable_i),
        .response_valid_o(response_valid_o),
        .response_ready_i(response_ready_i),
        .response_read_data_o(response_read_data_o),
        .response_error_o(response_error_o),
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
        .hit_event_o(hit_event), .miss_event_o(miss_event)
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
        .d_response_error_o(memory_response_error_raw)
    );

    assign memory_response_error = memory_response_error_raw ||
        (pending_memory_write && inject_write_error) ||
        (!pending_memory_write && inject_read_error);

    function [7:0] pattern_byte;
        input integer address;
        begin
            pattern_byte = (address >> 3) ^ (address * 13) ^ 8'h5a;
        end
    endfunction

    function [31:0] model_word;
        input [31:0] address;
        integer byte_index;
        begin
            model_word = 0;
            if (address < 8192)
                for (byte_index = 0; byte_index < 4;
                        byte_index = byte_index + 1)
                    model_word[byte_index*8 +: 8] =
                        reference_byte[address + byte_index];
        end
    endfunction

    always #5 clk_i = ~clk_i;

    always @(posedge clk_i) begin
        cycle = cycle + 1;
        if (reset_i) begin
            head = 0;
            tail = 0;
            pending_memory_write <= 1'b0;
        end else begin
            if (memory_request_valid && memory_request_ready) begin
                pending_memory_write <= memory_request_write;
                if (memory_request_write) begin
                    memory_write_count = memory_write_count + 1;
                    if (memory_request_byte_enable !== 16'hffff)
                        $fatal(1, "ERROR writeback mask");
                end else
                    memory_read_count = memory_read_count + 1;
                if (memory_request_address[3:0] != 0)
                    $fatal(1, "ERROR unaligned line transaction");
            end
            if (response_valid_o && response_ready_i) begin
                if (head >= tail)
                    $fatal(1, "ERROR unsolicited response");
                if (response_read_data_o !== expected_data[head] ||
                        response_error_o !== expected_error[head])
                    $fatal(1, "ERROR response %0d got %h/%b expected %h/%b",
                        head, response_read_data_o, response_error_o,
                        expected_data[head], expected_error[head]);
                head = head + 1;
            end
            if (request_valid_i && request_ready_o) begin
                if (stream_mode) begin
                    if (last_stream_cycle >= 0 &&
                            cycle != last_stream_cycle + 1)
                        $fatal(1, "ERROR hit pipeline did not accept each cycle");
                    last_stream_cycle = cycle;
                end
                if (tail >= 2048)
                    $fatal(1, "ERROR scoreboard overflow");
                expected_error[tail] = request_address_i[1:0] != 0 ||
                    request_address_i > 32'h000ffffc ||
                    force_expected_error;
                expected_data[tail] = expected_error[tail] ||
                    request_write_i ? 32'd0 : model_word(request_address_i);
                expected_strict[tail] = strict_latency;
                expected_cycle[tail] = cycle;
                expected_seen[tail] = 1'b0;
                tail = tail + 1;
                if (request_address_i[1:0] == 0 &&
                        request_address_i <= 32'h000ffffc)
                    valid_count = valid_count + 1;
                if (request_write_i && !expected_error[tail-1] &&
                        request_address_i < 8192)
                    for (j = 0; j < 4; j = j + 1)
                        if (request_byte_enable_i[j])
                            reference_byte[request_address_i+j] =
                                request_write_data_i[j*8 +: 8];
            end
            if (hit_event)
                hit_count = hit_count + 1;
            if (miss_event)
                miss_count = miss_count + 1;
        end
        #1;
        if (!reset_i && response_valid_o && head < tail &&
                !expected_seen[head]) begin
            if (expected_strict[head] &&
                    cycle != expected_cycle[head] + 3)
                $fatal(1, "ERROR hit latency at response %0d got %0d expected %0d",
                    head, cycle, expected_cycle[head] + 3);
            expected_seen[head] = 1'b1;
        end
    end

    initial begin
        #5000000;
        $fatal(1, "ERROR data cache watchdog expired");
    end

    task issue;
        input write_value;
        input [31:0] address_value;
        input [31:0] data_value;
        input [3:0] mask_value;
        begin
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_write_i = write_value;
            request_address_i = address_value;
            request_write_data_i = data_value;
            request_byte_enable_i = mask_value;
            while (!request_ready_o)
                @(negedge clk_i);
            @(posedge clk_i);
            #2;
            request_valid_i = 1'b0;
        end
    endtask

    task drain;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (head != tail) begin
                @(posedge clk_i);
                #2;
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 1000)
                    $fatal(1, "ERROR response drain timeout");
            end
        end
    endtask

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b1;
        request_valid_i = 1'b0;
        request_write_i = 1'b0;
        request_address_i = 0;
        request_write_data_i = 0;
        request_byte_enable_i = 0;
        response_ready_i = 1'b1;
        head = 0;
        tail = 0;
        cycle = 0;
        hit_count = 0;
        miss_count = 0;
        valid_count = 0;
        memory_write_count = 0;
        memory_read_count = 0;
        seed = 32'h52a83b1d;
        strict_latency = 1'b0;
        stream_mode = 1'b0;
        last_stream_cycle = -1;
        inject_write_error = 1'b0;
        inject_read_error = 1'b0;
        force_expected_error = 1'b0;
        pending_memory_write = 1'b0;
        #1;
        for (i = 0; i < 8192; i = i + 1) begin
            reference_byte[i] = pattern_byte(i);
            memory.byte_memory[i] = pattern_byte(i);
        end
        repeat (3) @(posedge clk_i);
        #2;
        reset_i = 1'b0;

        issue(0, 0, 0, 0);
        drain();
        if (miss_count != 1 || memory_read_count != 1)
            $fatal(1, "ERROR initial refill");

        strict_latency = 1'b1;
        stream_mode = 1'b1;
        issue(0, 0, 0, 0);
        issue(0, 4, 0, 0);
        issue(1, 0, 32'hdeadbeef, 4'b0101);
        issue(0, 0, 0, 0);
        issue(1, 4, 32'h13579bdf, 4'b1111);
        issue(0, 4, 0, 0);
        issue(1, 0, 32'h11223344, 4'b1010);
        issue(0, 0, 0, 0);
        stream_mode = 1'b0;
        drain();
        strict_latency = 1'b0;
        if (hit_count != 8)
            $fatal(1, "ERROR same-line stream hit count");

        issue(1, 3, 32'hffffffff, 4'hf);
        issue(0, 0, 0, 0);
        drain();

        response_ready_i = 1'b0;
        issue(0, 0, 0, 0);
        issue(1, 0, 32'h76543210, 4'hf);
        issue(0, 0, 0, 0);
        issue(0, 12, 0, 0);
        repeat (8) @(posedge clk_i);
        #2;
        if (!response_valid_o || request_ready_o)
            $fatal(1, "ERROR response backpressure");
        held_data = response_read_data_o;
        held_error = response_error_o;
        repeat (4) @(posedge clk_i);
        #2;
        if (!response_valid_o || response_read_data_o !== held_data ||
                response_error_o !== held_error)
            $fatal(1, "ERROR response changed under backpressure");
        response_ready_i = 1'b1;
        drain();

        write_baseline = memory_write_count;
        issue(1, 0, 32'hcafebabe, 4'b1111);
        issue(0, 32'h1000, 0, 0);
        drain();
        if (memory_write_count != write_baseline + 1)
            $fatal(1, "ERROR dirty victim not written back");
        for (i = 0; i < 16; i = i + 1)
            if (memory.byte_memory[i] !== reference_byte[i])
                $fatal(1, "ERROR dirty writeback byte %0d", i);
        issue(0, 0, 0, 0);
        drain();

        write_baseline = memory_write_count;
        issue(0, 32'h1000, 0, 0);
        drain();
        if (memory_write_count != write_baseline)
            $fatal(1, "ERROR clean victim wrote back");

        inject_read_error = 1'b1;
        force_expected_error = 1'b1;
        issue(0, 32'h2000, 0, 0);
        drain();
        force_expected_error = 1'b0;
        inject_read_error = 1'b0;
        issue(0, 32'h1000, 0, 0);
        drain();

        issue(1, 32'h1000, 32'h55667788, 4'b1111);
        drain();
        inject_write_error = 1'b1;
        force_expected_error = 1'b1;
        write_baseline = memory_write_count;
        issue(0, 32'h2000, 0, 0);
        drain();
        force_expected_error = 1'b0;
        inject_write_error = 1'b0;
        issue(0, 32'h1000, 0, 0);
        drain();
        issue(0, 32'h2000, 0, 0);
        drain();
        if (memory_write_count != write_baseline + 2)
            $fatal(1, "ERROR failed writeback lost dirty victim");

        issue(0, 0, 0, 0);
        drain();
        issue(1, 0, 32'h89abcdef, 4'hf);
        drain();
        write_baseline = memory_write_count;
        inject_read_error = 1'b1;
        force_expected_error = 1'b1;
        issue(0, 32'h1000, 0, 0);
        drain();
        inject_read_error = 1'b0;
        force_expected_error = 1'b0;
        issue(0, 0, 0, 0);
        drain();
        issue(0, 32'h1000, 0, 0);
        drain();
        if (memory_write_count != write_baseline + 1)
            $fatal(1, "ERROR refill failure did not keep clean victim");

        for (step = 0; step < 256; step = step + 1) begin
            random_address = ($random(seed) & 32'h7fffffff) % 1024;
            random_address = random_address * 4;
            if (($random(seed) & 3) == 0)
                issue(1, random_address, $random(seed),
                    ($random(seed) & 4'hf) | 4'b0001);
            else
                issue(0, random_address, 0, 0);
        end
        drain();
        for (step = 0; step < 256; step = step + 1)
            issue(0, 32'h1000 + step*16, 0, 0);
        drain();
        for (i = 0; i < 4096; i = i + 1)
            if (memory.byte_memory[i] !== reference_byte[i])
                $fatal(1, "ERROR random memory consistency byte %0d", i);

        baseline = memory_read_count + memory_write_count;
        issue(0, 32'h00100000, 0, 0);
        issue(1, 32'h00000003, 32'h12345678, 4'hf);
        drain();
        if (memory_read_count + memory_write_count != baseline)
            $fatal(1, "ERROR invalid request reached memory");
        if (hit_count + miss_count != valid_count)
            $fatal(1, "ERROR event count %0d != %0d",
                hit_count + miss_count, valid_count);

        $display("PASS rv32_l1_data_cache_tb hits=%0d misses=%0d",
            hit_count, miss_count);
        $finish;
    end
endmodule
