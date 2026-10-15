`timescale 1ns/1ps

module rv32_store_directory_tb;
    parameter WAYS = 2;
    parameter DIRECTORY = 2;
    parameter NONBLOCKING = 1;
    parameter SETS = 8;
    localparam DIR_SETS = DIRECTORY < SETS ? DIRECTORY : SETS;
    localparam ALIAS_SET = DIR_SETS;
    reg clk = 0;
    reg reset = 1;
    reg req_valid = 0;
    reg req_write = 0;
    reg [31:0] req_address = 0;
    reg [31:0] req_data = 0;
    reg [3:0] req_mask = 0;
    reg [1:0] req_id = 0;
    wire req_ready;
    wire irrevocable;
    wire resp_valid;
    reg resp_ready = 1;
    wire [31:0] resp_data;
    wire resp_error;
    wire [1:0] resp_id;
    wire [6:0] resp_tag;
    wire mem_valid;
    wire mem_ready;
    wire mem_write;
    wire [31:0] mem_address;
    wire [127:0] mem_data;
    wire [15:0] mem_mask;
    wire mem_resp_valid;
    wire mem_resp_ready;
    wire mem_resp_write;
    wire mem_resp_error;
    wire [127:0] mem_resp_data;
    reg read_pending = 0;
    reg write_pending = 0;
    reg read_error = 0;
    reg write_error = 0;
    reg inject_read_error = 0;
    reg inject_write_error = 0;
    reg [127:0] read_data;
    integer read_due;
    integer write_due;
    reg backing_valid [0:127];
    reg [27:0] backing_address [0:127];
    reg [127:0] backing_data [0:127];
    reg reference_valid [0:511];
    reg [29:0] reference_address [0:511];
    reg [31:0] reference_data [0:511];
    reg pending [0:3];
    reg [31:0] expected_data [0:3];
    reg expected_error [0:3];
    reg expected_posted [0:3];
    integer cycle = 0;
    integer checks = 0;
    integer grants = 0;
    integer next_id = 0;
    integer last_grant = 0;
    integer memory_slot;
    integer reference_slot;
    integer scan;
    integer lane;
    integer step;
    integer wait_count;
    integer last_response_cycle;
    reg held = 0;
    reg [31:0] held_data;
    reg held_error;
    reg [1:0] held_id;
    reg [31:0] value;

    always #5 clk = ~clk;
    rv32_l1_data_cache #(
        .CACHE_SIZE_BYTES(SETS*WAYS*16), .NUM_SETS(SETS), .NUM_WAYS(WAYS),
        .STORE_DIRECTORY_ENTRIES(DIRECTORY), .NONBLOCKING(NONBLOCKING)
    ) cache (
        .clk_i(clk), .reset_i(reset), .request_valid_i(req_valid),
        .request_ready_o(req_ready), .request_irrevocable_o(irrevocable),
        .request_write_i(req_write), .request_rob_tag_i({5'd0, req_id}),
        .request_id_i(req_id), .request_address_i(req_address),
        .request_write_data_i(req_data), .request_byte_enable_i(req_mask),
        .response_valid_o(resp_valid), .response_ready_i(resp_ready),
        .response_read_data_o(resp_data), .response_error_o(resp_error),
        .response_id_o(resp_id), .response_rob_tag_o(resp_tag),
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
    assign mem_resp_error = mem_resp_write ? write_error : read_error;
    assign mem_resp_data = mem_resp_write ? 128'd0 : read_data;

    task fail;
        input [8*100-1:0] reason;
        begin
            $display("FAIL Store directory ways=%0d entries=%0d nb=%0d cycle=%0d: %0s",
                WAYS, DIRECTORY, NONBLOCKING, cycle, reason);
            $stop;
        end
    endtask
    function [31:0] initial_word;
        input [31:0] address;
        begin initial_word = 32'h91a30000 ^ address; end
    endfunction
    function [31:0] reference_word;
        input [31:0] address;
        integer index;
        begin
            reference_word = initial_word(address);
            for (index = 0; index < 512; index = index + 1)
                if (reference_valid[index] && reference_address[index] == address[31:2])
                    reference_word = reference_data[index];
        end
    endfunction

    always @(posedge clk) begin
        cycle = cycle + 1;
        if (!reset) begin
            if (held && (!resp_valid || resp_data !== held_data ||
                    resp_error !== held_error || resp_id !== held_id))
                fail("response changed under backpressure");
            held = resp_valid && !resp_ready;
            held_data = resp_data; held_error = resp_error; held_id = resp_id;
            if (resp_valid && resp_ready) begin
                if (!pending[resp_id] || resp_tag !== {5'd0, resp_id})
                    fail("response identity mismatch");
                if (resp_error !== expected_error[resp_id] || resp_data !== expected_data[resp_id])
                    fail("response value or error mismatch");
                if (expected_posted[resp_id] && resp_error)
                    fail("irrevocable request failed");
                pending[resp_id] = 0;
                checks = checks + 1;
                last_response_cycle = cycle;
            end
            if (req_valid && req_ready) begin
                if (pending[req_id]) fail("live ID reused");
                pending[req_id] = 1;
                expected_posted[req_id] = irrevocable;
                grants = grants + irrevocable;
                if (!req_write && irrevocable) fail("load received a Store grant");
                expected_data[req_id] = req_write || expected_error[req_id] ?
                    32'd0 : reference_word(req_address);
                if (req_write && !expected_error[req_id]) begin
                    reference_slot = -1;
                    for (scan = 0; scan < 512; scan = scan + 1)
                        if (reference_valid[scan] && reference_address[scan] == req_address[31:2])
                            reference_slot = scan;
                    if (reference_slot < 0)
                        for (scan = 511; scan >= 0; scan = scan - 1)
                            if (!reference_valid[scan]) reference_slot = scan;
                    if (reference_slot < 0) fail("reference capacity exhausted");
                    value = reference_word(req_address);
                    for (lane = 0; lane < 4; lane = lane + 1)
                        if (req_mask[lane]) value[lane*8 +: 8] = req_data[lane*8 +: 8];
                    reference_valid[reference_slot] = 1;
                    reference_address[reference_slot] = req_address[31:2];
                    reference_data[reference_slot] = value;
                end
            end
            if (mem_resp_valid && mem_resp_ready) begin
                if (mem_resp_write) write_pending = 0;
                else read_pending = 0;
            end
            if (mem_valid && mem_ready) begin
                memory_slot = -1;
                for (scan = 0; scan < 128; scan = scan + 1)
                    if (backing_valid[scan] && backing_address[scan] == mem_address[31:4])
                        memory_slot = scan;
                if (memory_slot < 0) begin
                    for (scan = 127; scan >= 0; scan = scan - 1)
                        if (!backing_valid[scan]) memory_slot = scan;
                    if (memory_slot < 0) fail("backing capacity exhausted");
                    backing_valid[memory_slot] = 1;
                    backing_address[memory_slot] = mem_address[31:4];
                    for (lane = 0; lane < 4; lane = lane + 1)
                        backing_data[memory_slot][lane*32 +: 32] = initial_word(mem_address+lane*4);
                end
                if (mem_write) begin
                    write_pending = 1; write_due = cycle + 4;
                    write_error = inject_write_error; inject_write_error = 0;
                    if (!write_error)
                        for (lane = 0; lane < 16; lane = lane + 1)
                            if (mem_mask[lane])
                                backing_data[memory_slot][lane*8 +: 8] = mem_data[lane*8 +: 8];
                end else begin
                    read_pending = 1; read_due = cycle + 7;
                    read_error = inject_read_error; inject_read_error = 0;
                    read_data = backing_data[memory_slot];
                end
            end
        end
        if (cycle > 10000) fail("watchdog");
    end
    task drain;
        begin
            wait_count = 0;
            while (pending[0] || pending[1] || pending[2] || pending[3]) begin
                @(negedge clk); wait_count = wait_count + 1;
                if (wait_count > 500) fail("drain timeout");
            end
            repeat (2) @(negedge clk);
        end
    endtask
    task send;
        input write_request;
        input [31:0] address;
        input [31:0] data;
        input [3:0] mask;
        input error;
        input integer grant;
        begin
            @(negedge clk);
            req_id = next_id[1:0]; next_id = (next_id+1)%4;
            if (pending[req_id]) fail("send reused a live ID");
            req_valid = 1; req_write = write_request;
            req_address = address; req_data = data; req_mask = mask;
            expected_error[req_id] = error;
            wait_count = 0;
            #1;
            while (!req_ready) begin
                @(negedge clk); #1; wait_count = wait_count + 1;
                if (wait_count > 500) fail("request timeout");
            end
            last_grant = irrevocable;
            if (grant >= 0 && irrevocable !== (grant != 0)) fail("unexpected residency proof");
            @(posedge clk); @(negedge clk); req_valid = 0;
        end
    endtask
    initial begin
        for (scan = 0; scan < 128; scan = scan + 1) backing_valid[scan] = 0;
        for (scan = 0; scan < 512; scan = scan + 1) reference_valid[scan] = 0;
        for (scan = 0; scan < 4; scan = scan + 1) pending[scan] = 0;
        repeat (3) @(negedge clk); reset = 0;
        // All ways in one set remain provable after each successful fill.
        for (step = 0; step < WAYS; step = step + 1) begin
            send(0, step*SETS*16, 0, 0, 0, 0); drain;
        end
        for (step = 0; step < WAYS; step = step + 1) begin
            send(1, step*SETS*16, 32'hcdef1234 ^ step, 5, 0, 1); drain;
            send(0, step*SETS*16, 0, 0, 0, 0); drain;
        end
        // Replacing way zero must preserve the proof for every other way.
        send(0, WAYS*SETS*16, 0, 0, 0, 0); drain;
        for (step = 1; step < WAYS; step = step + 1) begin
            send(1, step*SETS*16, 32'h3210abcd, 10, 0, 1); drain;
        end
        if (DIR_SETS < SETS) begin
            send(0, ALIAS_SET*16, 0, 0, 0, 0); drain;
            send(1, WAYS*SETS*16, 32'hdeadbeef, 15, 0, 0); drain;
            send(0, ALIAS_SET*16, 0, 0, 0, 0); drain;
            send(1, ALIAS_SET*16, 32'h2468ace0, 3, 0, 1); drain;
        end
        // Full upper address identity is required despite identical set indices.
        send(1, 32'h0e000000, 32'h11112222, 15, 0, 0); drain;
        send(0, 32'h0e000000, 0, 0, 0, 0); drain;
        send(1, 32'h0f000000, 32'h33334444, 15, 0, 0); drain;
        send(0, 32'h0f000000, 0, 0, 0, 0); drain;
        // Failed refills cannot establish an irrevocable Store grant.
        inject_read_error = 1;
        send(0, 32'h01200020, 0, 0, 1, 0); drain;
        send(1, 32'h01200020, 32'h55556666, 15, 0, 0); drain;
        send(1, 32'h01200020, 32'h77778888, 12, 0, 1); drain;
        send(0, 32'h01200020, 0, 0, 0, 0); drain;
        // Preserve payload under response backpressure and byte-write forwarding.
        resp_ready = 0;
        send(1, 32'h01200020, 32'habcdefff, 6, 0, 1);
        repeat (8) @(negedge clk); resp_ready = 1; drain;
        send(0, 32'h01200020, 0, 0, 0, 0); drain;
        // MMIO and misaligned requests never acquire a RAM proof.
        send(1, 32'h80000000, 1, 15, 1, 0); drain;
        send(1, 32'h01200021, 1, 15, 1, 0); drain;
        reset = 1; repeat (3) @(negedge clk); reset = 0;
        send(1, 32'h01200020, 32'h77779999, 15, 0, 0); drain;
        if (grants < 2*WAYS+1) fail("missing Store grant coverage");
        $display("PASS Store directory ways=%0d entries=%0d nb=%0d checks=%0d grants=%0d",
            WAYS, DIRECTORY, NONBLOCKING, checks, grants);
        $finish;
    end
endmodule
