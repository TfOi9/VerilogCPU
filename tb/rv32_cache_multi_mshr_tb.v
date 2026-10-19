`timescale 1ns/1ps
module rv32_cache_multi_mshr_tb;
    parameter MSHRS = 4;
    parameter WAITERS = 4;
    parameter PREFETCH = 0;
    parameter DISTANCE = 4;
    localparam ID_WIDTH = $clog2(MSHRS);
    reg pf_enable = 0;
    wire idle;
    reg hold_pf_returns = 0;
    reg [MSHRS-1:0] read_is_prefetch = 0;
    integer pf_reads = 0, empty_deliveries = 0, pf_joins = 0, all_active = 0;
    integer pf_slot, pf_cycles, pf_before, pf_writes;
    reg [31:0] pf_target;
    parameter LATENCY = 31;
    parameter BAD_ID = 0;
    parameter AUX = 0;
    parameter WAYS = 2;
    parameter SETS = 4;
    parameter HINTS = 16;
    parameter LATE_CONFIRM = 0;
    wire confirm_valid;
    wire [1:0] confirm_id;
    wire [6:0] confirm_tag;
    reg expected_write [0:3];
    integer confirmations = 0;
    parameter SEED = 1;
    parameter DIRECTORY = 0;
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
    integer cycle = 0;
    reg [MSHRS-1:0] read_pending = 0;
    reg [127:0] read_lines [0:MSHRS-1];
    reg [MSHRS-1:0] read_errors = 0;
    integer read_dues [0:MSHRS-1];
    wire [ID_WIDTH-1:0] mem_id;
    reg [ID_WIDTH-1:0] write_id = 0;
    reg [ID_WIDTH-1:0] resp_read_id;
    reg resp_read_found;
    integer choose, selected;
    always @* begin
        resp_read_id = 0;
        resp_read_found = 0;
        for (choose = 0; choose < MSHRS; choose = choose + 1) begin
            selected = SEED % 2 ? MSHRS - 1 - choose : choose;
            if (!resp_read_found && read_pending[selected] && cycle >= read_dues[selected] &&
                    !(hold_pf_returns && read_is_prefetch[selected])) begin
                resp_read_found = 1;
                resp_read_id = selected[ID_WIDTH-1:0];
            end
        end
    end
    wire [ID_WIDTH-1:0] mem_resp_id = mem_resp_write ? write_id : resp_read_id;
    wire [ID_WIDTH-1:0] cache_resp_id = BAD_ID != 0 ? (mem_resp_id ^ 1'b1) : mem_resp_id;
    reg hold_returns = 0;
    reg hold_write_accept = 0;
    integer read_requests = 0;
    integer write_requests = 0;
    integer merges = 0;
    integer dual_active = 0;
    integer dual_complete = 0;
    integer join_pop = 0;
    integer full_waiter_stalls = 0, full_join_pop = 0;
    always @(posedge clk) begin
        if (!reset && cache.s2_miss && cache.m_match &&
                cache.m_count[cache.m_match_slot] == WAITERS) begin
            if (!cache.m_join) full_waiter_stalls = full_waiter_stalls + 1;
            if (cache.m_join && cache.m_delivery && cache.m_delivery_slot == cache.m_match_slot)
                full_join_pop = full_join_pop + 1;
        end
    end
    integer start_reads;
    integer errors = 0;
    integer w;
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
    rv32_l1_data_cache #(.CACHE_SIZE_BYTES(SETS*16*WAYS), .NUM_SETS(SETS),
        .NUM_WAYS(WAYS), .STORE_HINTS(HINTS), .LATE_STORE_CONFIRM(LATE_CONFIRM),
        .STORE_DIRECTORY_ENTRIES(DIRECTORY), .AUX_RETURNS(AUX), .NONBLOCKING(1), .MSHR_ENTRIES(MSHRS), .MSHR_WAITERS(WAITERS),
        .STREAM_PREFETCH(PREFETCH), .STREAM_PREFETCH_DISTANCE(DISTANCE)) cache (
        .memory_request_id_o(mem_id), .memory_response_id_i(cache_resp_id),
        .request_rob_tag_i(req_rob_tag), .response_rob_tag_o(resp_rob_tag),
        .prefetch_enable_i(pf_enable), .idle_o(idle),
        .clk_i(clk), .reset_i(reset), .request_valid_i(req_valid),
        .request_ready_o(req_ready), .store_confirm_valid_o(confirm_valid), .store_confirm_id_o(confirm_id),
        .store_confirm_rob_tag_o(confirm_tag),
        .aux_response_valid_i(1'b0), .aux_response_ready_o(),
        .aux_response_id_i(2'd0), .aux_response_rob_tag_i(7'd0),
        .aux_response_error_i(1'b0),
        .request_irrevocable_o(irrevocable),
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
    assign mem_ready = mem_write ? !write_pending && !hold_write_accept : !read_pending[mem_id];
    assign mem_resp_write = !hold_returns && write_pending && cycle >= write_due;
    assign mem_resp_valid = !hold_returns && (mem_resp_write ||
        resp_read_found);
    assign mem_resp_data = mem_resp_write ? 128'd0 : read_lines[resp_read_id];
    assign mem_resp_error = mem_resp_write ? write_error : read_errors[resp_read_id];

    task fail;
        input [8*100-1:0] reason;
        begin
            $display("coverage merges=%0d dual=%0d both=%0d overlaps=%0d errors=%0d",
                merges,dual_active,dual_complete,overlaps,errors);
            $display("FAIL MSHR ways=%0d seed=%0d cycle=%0d: %0s",WAYS,SEED,cycle,reason);
            $stop;
        end
    endtask
    always @(posedge clk) begin
        if (!reset) begin
            cycle = cycle + 1;
            if (cache.m_valid == ((1 << MSHRS) - 1)) all_active = all_active + 1;
            if (cache.m_delivery && cache.m_count[cache.m_delivery_slot] == 0)
                empty_deliveries = empty_deliveries + 1;
            if (cache.m_join && cache.m_prefetch[cache.m_match_slot]) pf_joins = pf_joins + 1;
            if (held && (!resp_valid || resp_data !== held_data ||
                    resp_error !== held_error || resp_id !== held_id))
                fail("response changed under backpressure");
            held = resp_valid && !resp_ready;
            held_data = resp_data; held_error = resp_error; held_id = resp_id;
            if ((|read_pending) && write_pending) overlaps = overlaps + 1;
            if (cache.m_valid == 3) dual_active = dual_active + 1;
            if (cache.m_complete == 3) dual_complete = dual_complete + 1;
            if (cache.m_join) merges = merges + 1;
            if (cache.m_join && cache.m_delivery && cache.m_match_slot == cache.m_delivery_slot)
                join_pop = join_pop + 1;
            if (req_valid && !req_ready && cache.miss_active &&
                    ((req_address >> 4) & (SETS-1)) == cache.miss_index) locked = locked + 1;
            if (confirm_valid) begin
                if (!pending[confirm_id] || !expected_write[confirm_id] ||
                        expected_error[confirm_id] || expected_posted[confirm_id])
                    fail("invalid or duplicate Store confirmation");
                if (confirm_tag !== expected_rob_tag[confirm_id])
                    fail("Store confirmation identity mismatch");
                expected_posted[confirm_id] = 1;
                confirmations = confirmations + 1;
            end
            if (resp_valid && resp_ready) begin
                if (!pending[resp_id]) fail("duplicate or unknown ID");
                if (resp_rob_tag !== expected_rob_tag[resp_id]) fail("ROB metadata changed ownership");
                if (resp_error !== expected_error[resp_id]) fail("wrong error ownership");
                if (resp_error) errors = errors + 1;
                if (!resp_error && resp_data !== expected[resp_id]) begin
                    $display("id=%0d got=%h expected=%h",resp_id,resp_data,expected[resp_id]);
                    fail("wrong data");
                end
                if (expected_posted[resp_id] && resp_error) fail("posted store failed");
                pending[resp_id] = 0;
                checks = checks + 1;
                if (cache.miss_active) hum_hits = hum_hits + 1;
            end
            if (req_valid && req_ready) begin
                if (pending[req_id]) fail("ID reused while pending");
                pending[req_id] = 1;
                expected_write[req_id] = req_write;
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
                        if (write_mask[lane] && !write_error) memory[write_address/4+lane/4][(lane%4)*8 +: 8] = write_data[lane*8 +: 8];
                    write_pending = 0;
                end else read_pending[resp_read_id] = 0;
            end
            if (mem_valid && mem_ready) begin
                if (mem_write) begin
                    write_pending = 1; write_id = mem_id; write_address = mem_address;
                    write_requests = write_requests + 1;
                    write_data = mem_data; write_mask = mem_mask;
                    write_due = cycle + LATENCY + (SEED % 2 ? 17 : 0);
                    write_error = inject_write_error; inject_write_error = 0;
                end else begin
                    read_pending[mem_id] = 1;
                    read_is_prefetch[mem_id] = cache.m_prefetch[mem_id];
                    if (cache.m_prefetch[mem_id]) pf_reads = pf_reads + 1;
                    read_dues[mem_id] = cycle + LATENCY + (hold_returns ?
                        (mem_id ? 13 : 0) : (mem_id ? 0 : 13));
                    read_errors[mem_id] = inject_read_error; inject_read_error = 0;
                    read_requests = read_requests + 1;
                    for (lane = 0; lane < 4; lane = lane + 1)
                        read_lines[mem_id][lane*32 +: 32] = memory[mem_address/4+lane];
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
    task fresh;
        begin
            drain;
            @(negedge clk); reset = 1; held = 0;
            for (i = 0; i < 256; i = i + 1) memory[i] = reference[i];
            repeat (3) @(negedge clk);
            reset = 0; inject_read_error = 0; inject_write_error = 0;
        end
    endtask
    task wait_dual;
        begin
            timeout_count = 0;
            while (cache.m_valid != 3) begin
                @(negedge clk); timeout_count = timeout_count + 1;
                if (timeout_count > 200) fail("second miss was serialized");
            end
        end
    endtask
    task cache_idle;
        begin
            @(negedge clk); pf_enable = 0;
            pf_cycles = 0;
            while (!idle) begin
                @(negedge clk); pf_cycles = pf_cycles + 1;
                if (pf_cycles > 4000) fail("cache did not drain speculative work");
            end
            repeat (3) @(negedge clk);
        end
    endtask
    task await_prefetch;
        begin
            pf_slot = -1; pf_cycles = 0;
            while (pf_slot < 0) begin
                @(negedge clk); pf_cycles = pf_cycles + 1;
                for (index = 0; index < MSHRS; index = index + 1)
                    if (cache.m_valid[index] && cache.m_prefetch[index] && read_pending[index]) pf_slot = index;
                if (pf_cycles > 1000) fail("stream never allocated a prefetch");
            end
            pf_target = {cache.m_line[pf_slot],4'b0000};
        end
    endtask
    task train_stream;
        begin
            pf_enable = 1; hold_pf_returns = 1;
            send(0,0,0,0,0,0); drain;
            send(1,0,16,0,0,0); drain;
            await_prefetch;
        end
    endtask
    task qualify_prefetch;
        begin
            fresh; train_stream;
            send(2,0,pf_target+4,0,0,0);
            repeat (8) @(negedge clk);
            if (cache.m_prefetch[pf_slot] || cache.m_count[pf_slot] == 0)
                fail("demand failed to adopt a speculative refill");
            hold_pf_returns = 0; drain; cache_idle;
            if (pf_joins == 0) fail("missing demand join coverage");

            fresh; train_stream;
            pf_before = checks;
            hold_pf_returns = 0; cache_idle;
            if (checks != pf_before || empty_deliveries == 0)
                fail("speculative completion escaped to the core");

            fresh; train_stream;
            read_errors[pf_slot] = 1; pf_before = checks;
            hold_pf_returns = 0; cache_idle;
            if (checks != pf_before) fail("prefetch error escaped to the core");
            send(0,0,pf_target,0,0,0); drain;

            fresh; train_stream;
            pf_enable = 0;
            read_errors[pf_slot] = 1;
            send(2,0,0,0,0,0);
            pf_cycles = 0;
            while (!(cache.s2_valid && !cache.s2_prefetch && cache.s2_hit && cache.s2_id == 2)) begin
                @(negedge clk); pf_cycles = pf_cycles + 1;
                if (pf_cycles > 100) fail("demand hit did not reach S2");
            end
            read_dues[pf_slot] = cycle;
            hold_pf_returns = 0;
            #1;
            if (!(cache.m_delivery && cache.m_count[cache.m_delivery_slot] == 0))
                fail("missing empty prefetch error and demand hit collision");
            drain; cache_idle;

            cache_idle; fresh;
            for (w = 0; w < WAYS; w = w + 1) begin
                send(0,1,(1+DISTANCE)*16+(w+1)*SETS*16,32'h31415926 ^ w,15,0); drain;
            end
            inject_write_error = 1; train_stream;
            pf_writes = write_requests;
            hold_pf_returns = 0; cache_idle;
            if (write_requests == 0) fail("missing dirty speculative victim");
            pf_before = read_requests;
            send(0,0,(1+DISTANCE)*16+SETS*16,0,0,0); drain;
            if (read_requests != pf_before) fail("failed speculative writeback destroyed its victim");
            send(1,0,(1+DISTANCE)*16,0,0,0); drain;
            if (memory[((1+DISTANCE)*16+SETS*16)/4] !== reference[((1+DISTANCE)*16+SETS*16)/4])
                fail("dirty victim retry lost committed bytes");
            cache_idle;
            if (pf_reads < 4 || pf_joins == 0 || empty_deliveries < 2)
                fail("missing speculative ownership coverage");
            $display("PASS Prefetch mshrs=%0d ways=%0d seed=%0d checks=%0d pf_reads=%0d joins=%0d empty=%0d",
                MSHRS,WAYS,SEED,checks,pf_reads,pf_joins,empty_deliveries);
            $finish;
        end
    endtask
    initial begin
        held = 0;
        for (i = 0; i < 256; i = i + 1) begin
            reference[i] = 32'h90000000 ^ (i*4); memory[i] = reference[i];
        end
        for (i = 0; i < 4; i = i + 1) pending[i] = 0;
        repeat (3) @(negedge clk); reset = 0;
        if (PREFETCH != 0) qualify_prefetch;
        if (MSHRS == 4 && BAD_ID == 0) begin
            hold_returns = 1; resp_ready = 0;
            send(0,0,64,0,0,0); send(1,0,80,0,0,0);
            send(2,0,96,0,0,0); send(3,0,112,0,0,0);
            pf_cycles = 0;
            while (cache.m_valid != 15) begin
                @(negedge clk); pf_cycles = pf_cycles + 1;
                if (pf_cycles > 1000) fail("four misses were serialized");
            end
            hold_returns = 0; repeat (LATENCY+40) @(negedge clk);
            resp_ready = 1; drain; fresh;
            if (all_active == 0) fail("four active slots were not observed");
        end
        fresh;
        for (w = 0; w < WAYS; w = w + 1) begin
            send(0,1,w*SETS*16,32'habcde000 ^ w,15,0); drain;
        end
        hold_write_accept = 1;
        start_reads = read_requests;
        send(0,0,WAYS*SETS*16,0,0,0);
        repeat (LATENCY + 40) @(negedge clk);
        if (read_requests != start_reads)
            fail("read issued before writeback payload acceptance");
        if (mem_valid !== 1'b1 || mem_write !== 1'b1 || mem_address !== 0)
            fail("blocked writeback lost its victim identity");
        for (lane = 0; lane < 4; lane = lane + 1)
            if (mem_data[lane*32 +: 32] !== reference[lane])
                fail("blocked writeback payload was overwritten");
        hold_write_accept = 0;
        drain;
        if (memory[0] !== reference[0]) fail("shared MSHR payload lost dirty data");
        fresh;
        send(0,0,16,0,0,0); drain;
        strict_mode = 1;
        for (step = 0; step < 16; step = step + 1)
            send(step[1:0],step[0],16,32'h2468ace0,15,0);
        drain; strict_mode = 0;

        fresh;
        send(0,1,80,32'h76543210,15,0); drain;
        hold_returns = 1;
        send(0,0,128,0,0,0);
        send(1,0,132,0,0,0);
        if (WAITERS >= 3) send(2,0,136,0,0,0);
        while (!read_pending[0]) @(negedge clk);
        while (cache.m_count[0] != (WAITERS < 3 ? WAITERS : 3)) @(negedge clk);
        resp_ready = 0;
        send(3,1,80,32'habcd0123,15,0);
        while (!(cache.s1_valid && cache.s1_address == 80)) @(negedge clk);
        read_dues[0] = cycle; hold_returns = 0;
        repeat (20) @(negedge clk);
        resp_ready = 1; drain;
        send(0,0,80,0,0,0); drain;

        fresh; hold_returns = 1; start_reads = read_requests;
        send(0,0,128,0,0,0);
        send(1,1,132,32'h1234abcd,10,0);
        if (WAITERS == 2) begin
            send(3,0,144,0,0,0);
            send(2,0,132,0,0,0);
        end else begin
            send(2,0,132,0,0,0);
            send(3,0,144,0,0,0);
        end
        wait_dual;
        repeat (8) @(negedge clk);
        if (read_requests != start_reads + 2) fail("same line was not merged into one refill");
        resp_ready = 0; hold_returns = 0;
        repeat (LATENCY + 40) @(negedge clk);
        resp_ready = 1; drain;
        send(0,0,132,0,0,0); drain;

        fresh;
        for (w = 0; w < WAYS; w = w + 1) begin
            send(0,1,w*SETS*16,32'h31415926 ^ w,15,0); drain;
            send(0,1,w*SETS*16+16,32'h27182818 ^ w,15,0); drain;
        end
        inject_write_error = 1; inject_read_error = SEED % 3 == 0; hold_returns = 1;
        send(0,0,WAYS*SETS*16,0,0,1);
        send(1,0,WAYS*SETS*16+4,0,0,1);
        send(2,0,WAYS*SETS*16+16,0,0,0);
        wait_dual;
        repeat (5) @(negedge clk); hold_returns = 0;
        drain;
        start_reads = read_requests;
        send(0,0,0,0,0,0); drain;
        if (read_requests != start_reads) fail("writeback error destroyed dirty victim");
        send(0,0,WAYS*SETS*16,0,0,0); drain;
        if (memory[0] !== reference[0]) fail("dirty victim retry lost data");

        fresh;
        for (w = 0; w < WAYS; w = w + 1) begin
            send(0,1,w*SETS*16,32'h42424242 ^ w,15,0); drain;
        end
        inject_read_error = 1;
        send(0,0,WAYS*SETS*16,0,0,1);
        send(1,1,WAYS*SETS*16+4,32'hdead0123,15,1); drain;
        if (cache.line_dirty[0][0] || memory[0] !== reference[0])
            fail("successful writeback did not preserve a clean victim after refill error");
        start_reads = write_requests;
        send(0,0,WAYS*SETS*16,0,0,0); drain;
        if (write_requests != start_reads) fail("clean victim was written back again");

        fresh; inject_read_error = 1; hold_returns = 1;
        send(0,0,512,0,0,1);
        send(1,1,516,32'hdeadbeef,15,1);
        send(2,0,528,0,0,0);
        wait_dual;
        repeat (5) @(negedge clk); hold_returns = 0;
        drain;
        send(0,0,512,0,0,0); drain;

        fresh;
        for (step = 0; step < 600; step = step + 1) begin
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            send(step[1:0],random_state[0],{22'd0,random_state[9:2],2'b00},
                random_state ^ 32'h31415926,random_state[7:4],0);
            if (step % 7 == 0) begin
                resp_ready = 0; repeat (8) @(negedge clk); resp_ready = 1;
            end
        end
        drain;
        fresh; hold_returns = 1;
        send(0,0,640,0,0,0);
        send(1,0,656,0,0,0);
        wait_dual;
        @(negedge clk); reset = 1; req_valid = 0;
        read_pending = 0; write_pending = 0;
        for (i = 0; i < 4; i = i + 1) pending[i] = 0;
        repeat (3) @(negedge clk);
        if (cache.m_valid != 0 || resp_valid || mem_valid) fail("reset retained MSHR ownership");
        reset = 0; hold_returns = 0;
        send(0,0,640,0,0,0); drain;
        if (WAITERS == 2 && (full_waiter_stalls == 0 || full_join_pop == 0))
            fail("missing full waiter backpressure or simultaneous push/pop");
        if (merges < 3 || dual_active == 0 || dual_complete == 0 || overlaps == 0 || errors != 6)
            fail("missing concurrency or error coverage");
        $display("PASS Cache multi MSHR ways=%0d seed=%0d latency=%0d checks=%0d merges=%0d dual=%0d both_ready=%0d join_pop=%0d errors=%0d",
            WAYS,SEED,LATENCY,checks,merges,dual_active,dual_complete,join_pop,errors);
        $finish;
    end
    initial begin #10000000; fail("wall simulation timeout"); end
endmodule
