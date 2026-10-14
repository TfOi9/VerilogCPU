`timescale 1ns/1ps
module rv32_cache_hum_tb;
    parameter WAYS = 2;
    parameter SEED = 1;
    reg clk = 0;
    reg reset = 1;
    reg req_valid = 0;
    wire req_ready;
    wire irrevocable;
    reg req_write = 0;
    reg [6:0] req_rob_tag = 0;
    wire [6:0] resp_rob_tag;
    reg [6:0] expected_rob_tag [0:3];
    reg [1:0] req_id = 0;
    reg [31:0] req_address = 0;
    reg [31:0] req_data = 0;
    reg [3:0] req_mask = 0;
    wire resp_valid;
    reg resp_ready = 1;
    wire [1:0] resp_id;
    wire [31:0] resp_data;
    wire resp_error;
    wire mem_valid;
    wire mem_ready;
    wire mem_write;
    wire [31:0] mem_address;
    wire [127:0] mem_data;
    wire [15:0] mem_mask;
    wire mem_resp_valid;
    wire mem_resp_ready;
    wire mem_resp_write;
    wire [127:0] mem_resp_data;
    wire mem_resp_error;
    reg read_pending = 0;
    reg write_pending = 0;
    reg read_error = 0;
    reg write_error = 0;
    integer read_due;
    integer write_due;
    integer read_address;
    integer write_address;
    reg [127:0] write_data;
    reg [15:0] write_mask;
    reg [127:0] read_data;
    reg inject_read_error = 0;
    reg inject_write_error = 0;
    reg issue_error = 0;
    reg strict_mode = 0;
    reg expected_strict [0:3];
    reg expected_seen [0:3];
    integer expected_cycle [0:3];
    reg pending [0:3];
    reg expected_error [0:3];
    reg expected_posted [0:3];
    reg [31:0] expected [0:3];
    reg [31:0] reference [0:255];
    reg [31:0] memory [0:255];
    integer cycle = 0;
    integer checks = 0;
    integer hum_hits = 0;
    integer overlaps = 0;
    integer locked = 0;
    integer i;
    integer lane;
    integer step;
    integer index;
    integer timeout_count;
    reg [31:0] random_state = SEED;
    reg held;
    reg [31:0] held_data;
    reg held_error;
    reg [1:0] held_id;
    reg [31:0] old_value;

    always #5 clk = ~clk;
    rv32_l1_data_cache #(.CACHE_SIZE_BYTES(64*WAYS), .NUM_SETS(4),
        .NUM_WAYS(WAYS), .STORE_HINTS(16), .NONBLOCKING(1)) cache (
        .request_rob_tag_i(req_rob_tag), .response_rob_tag_o(resp_rob_tag),
        .clk_i(clk), .reset_i(reset), .request_valid_i(req_valid),
        .request_ready_o(req_ready), .request_irrevocable_o(irrevocable),
        .request_write_i(req_write), .request_id_i(req_id),
        .request_address_i(req_address), .request_write_data_i(req_data),
        .request_byte_enable_i(req_mask), .response_valid_o(resp_valid),
        .response_ready_i(resp_ready), .response_id_o(resp_id),
        .response_read_data_o(resp_data), .response_error_o(resp_error),
        .memory_request_valid_o(mem_valid), .memory_request_ready_i(mem_ready),
        .memory_request_write_o(mem_write), .memory_request_address_o(mem_address),
        .memory_request_write_data_o(mem_data), .memory_request_byte_enable_o(mem_mask),
        .memory_response_valid_i(mem_resp_valid), .memory_response_ready_o(mem_resp_ready),
        .memory_response_write_i(mem_resp_write), .memory_response_read_data_i(mem_resp_data),
        .memory_response_error_i(mem_resp_error), .hit_event_o(), .miss_event_o()
    );
    assign mem_ready = mem_write ? !write_pending : !read_pending;
    assign mem_resp_write = write_pending && cycle >= write_due;
    assign mem_resp_valid = mem_resp_write || (read_pending && cycle >= read_due);
    assign mem_resp_data = mem_resp_write ? 128'd0 : read_data;
    assign mem_resp_error = mem_resp_write ? write_error : read_error;

    task fail;
        input [8*100-1:0] reason;
        begin
            $display("FAIL HUM ways=%0d seed=%0d cycle=%0d: %0s",WAYS,SEED,cycle,reason);
            $stop;
        end
    endtask
    always @(posedge clk) begin
        if (!reset) begin
            cycle = cycle + 1;
            if (held && (!resp_valid || resp_data !== held_data ||
                    resp_error !== held_error || resp_id !== held_id))
                fail("response changed under backpressure");
            held = resp_valid && !resp_ready;
            held_data = resp_data; held_error = resp_error; held_id = resp_id;
            if (read_pending && write_pending) overlaps = overlaps + 1;
            if (req_valid && !req_ready && cache.miss_active &&
                    req_address[5:4] == cache.miss_index) locked = locked + 1;
            if (resp_valid && resp_ready) begin
                if (!pending[resp_id]) fail("duplicate or unknown ID");
                if (resp_rob_tag !== expected_rob_tag[resp_id]) fail("ROB metadata changed ownership");
                if (resp_error !== expected_error[resp_id]) fail("wrong error ownership");
                if (!resp_error && resp_data !== expected[resp_id]) begin
                    $display("id=%0d got=%h expected=%h",resp_id,resp_data,expected[resp_id]);
                    fail("wrong data");
                end
                if (expected_posted[resp_id] && resp_error) fail("posted store failed");
                pending[resp_id] = 0;
                checks = checks + 1;
                if (cache.miss_active && resp_id != cache.miss_id) hum_hits = hum_hits + 1;
            end
            if (req_valid && req_ready) begin
                if (pending[req_id]) fail("ID reused while pending");
                pending[req_id] = 1;
                expected_rob_tag[req_id] = req_rob_tag;
                expected_error[req_id] = issue_error;
                expected_strict[req_id] = strict_mode;
                expected_seen[req_id] = 0;
                expected_cycle[req_id] = cycle;
                expected_posted[req_id] = irrevocable;
                expected[req_id] = req_write || issue_error ? 0 : reference[req_address[9:2]];
                if (req_write && !issue_error)
                    for (lane = 0; lane < 4; lane = lane + 1)
                        if (req_mask[lane]) reference[req_address[9:2]][lane*8 +: 8] = req_data[lane*8 +: 8];
            end
            if (mem_resp_valid && mem_resp_ready) begin
                if (mem_resp_write) begin
                    for (lane = 0; lane < 16; lane = lane + 1)
                        if (write_mask[lane]) memory[write_address/4+lane/4][(lane%4)*8 +: 8] = write_data[lane*8 +: 8];
                    write_pending = 0;
                end else read_pending = 0;
            end
            if (mem_valid && mem_ready) begin
                if (mem_write) begin
                    write_pending = 1; write_address = mem_address;
                    write_data = mem_data; write_mask = mem_mask;
                    write_due = cycle + (SEED % 2 ? 53 : 23);
                    write_error = inject_write_error; inject_write_error = 0;
                end else begin
                    read_pending = 1; read_address = mem_address;
                    read_due = cycle + (SEED % 2 ? 31 : 47);
                    read_error = inject_read_error; inject_read_error = 0;
                    for (lane = 0; lane < 4; lane = lane + 1)
                        read_data[lane*32 +: 32] = memory[read_address/4+lane];
                end
            end
        end
        #1;
        if (!reset && resp_valid && pending[resp_id] && !expected_seen[resp_id]) begin
            if (expected_strict[resp_id] && cycle != expected_cycle[resp_id] + 3)
                fail("uncontended hit latency changed");
            expected_seen[resp_id] = 1;
        end
    end
    task send;
        input [1:0] id;
        input write_request;
        input [31:0] address;
        input [31:0] data;
        input [3:0] mask;
        input error_expected;
        begin
            timeout_count = 0;
            while (pending[id]) begin @(negedge clk); timeout_count = timeout_count + 1;
                if (timeout_count > 2000) fail("pending ID timeout"); end
            @(negedge clk);
            req_valid = 1; req_id = id; req_rob_tag = cycle[6:0] ^ {5'd0,id}; req_write = write_request;
            req_address = address; req_data = data; req_mask = mask;
            issue_error = error_expected;
            @(posedge clk);
            while (!req_ready) begin
                @(posedge clk); timeout_count = timeout_count + 1;
                if (timeout_count > 2000) fail("request timeout");
            end
            @(negedge clk); req_valid = 0;
        end
    endtask
    task drain;
        begin
            timeout_count = 0;
            while (pending[0] || pending[1] || pending[2] || pending[3]) begin
                @(negedge clk); timeout_count = timeout_count + 1;
                if (timeout_count > 2000) fail("drain timeout");
            end
        end
    endtask
    initial begin
        held = 0;
        for (i = 0; i < 256; i = i + 1) begin
            reference[i] = 32'h90000000 ^ (i*4); memory[i] = reference[i];
        end
        for (i = 0; i < 4; i = i + 1) pending[i] = 0;
        repeat (3) @(negedge clk); reset = 0;
        send(0,1,0,32'h12345678,15,0); drain;
        if (WAYS == 2) begin send(0,1,64,32'habcdef01,15,0); drain; end
        send(0,0,16,0,0,0); drain;
        strict_mode = 1;
        for (step = 0; step < 16; step = step + 1)
            send(step[1:0],step[0],16,32'h2468ace0,15,0);
        drain; strict_mode = 0;
        send(0,0,128,0,0,0);
        send(1,0,16,0,0,0);
        send(2,1,16,32'h66778899,10,0);
        send(3,0,0,0,0,0); drain;
        send(0,1,128,32'hdeadbeef,15,0); drain;
        inject_write_error = 1;
        send(0,0,192,0,0,1);
        send(1,0,16,0,0,0); drain;
        send(0,0,192,0,0,0); drain;
        inject_read_error = 1;
        send(0,0,544,0,0,1); drain;
        send(0,0,544,0,0,0); drain;
        for (step = 0; step < 400; step = step + 1) begin
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            send(step[1:0],random_state[0],{22'd0,random_state[9:2],2'b00},
                random_state ^ 32'h31415926,random_state[7:4],0);
            if (step % 7 == 0) begin
                resp_ready = 0; repeat (8) @(negedge clk); resp_ready = 1;
            end
        end
        drain;
        if (hum_hits < 2 || overlaps < 4 || locked == 0) fail("missing concurrency coverage");
        $display("PASS Cache HUM ways=%0d seed=%0d checks=%0d hit_under_miss=%0d overlap=%0d locked=%0d",WAYS,SEED,checks,hum_hits,overlaps,locked);
        $finish;
    end
    initial begin #10000000; fail("wall simulation timeout"); end
endmodule
