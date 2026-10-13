`timescale 1ns/1ps

module rv32_l1_cache_axi_pipeline_tb;
    parameter SEED = 1;
    reg clk;
    reg reset;
    reg i_request_valid;
    wire i_request_ready;
    reg [31:0] i_request_address;
    wire i_response_valid;
    reg i_response_ready;
    wire [127:0] i_response_read_data;
    wire i_response_error;
    reg d_request_valid;
    wire d_request_ready;
    reg d_request_write;
    reg [31:0] d_request_address;
    reg [127:0] d_request_write_data;
    reg [15:0] d_request_byte_enable;
    wire d_response_valid;
    reg d_response_ready;
    wire [127:0] d_response_read_data;
    wire d_response_error;
    reg m_request_valid;
    wire m_request_ready;
    reg [31:0] m_request_address;
    reg [31:0] m_request_write_data;
    reg [3:0] m_request_byte_enable;
    wire m_response_valid;
    reg m_response_ready;
    wire m_response_error;
    wire [31:0] araddr;
    wire arvalid;
    reg arready;
    reg [31:0] rdata;
    reg [1:0] rresp;
    reg rvalid;
    wire rready;
    wire [31:0] awaddr;
    wire awvalid;
    reg awready;
    wire [31:0] wdata;
    wire [3:0] wstrb;
    wire wvalid;
    reg wready;
    reg [1:0] bresp;
    reg bvalid;
    wire bready;

    rv32_l1_cache_axi_bridge dut (
        .clk_i(clk), .reset_i(reset),
        .i_request_valid_i(i_request_valid),
        .i_request_ready_o(i_request_ready),
        .i_request_address_i(i_request_address),
        .i_response_valid_o(i_response_valid),
        .i_response_ready_i(i_response_ready),
        .i_response_read_data_o(i_response_read_data),
        .i_response_error_o(i_response_error),
        .d_request_valid_i(d_request_valid),
        .d_request_ready_o(d_request_ready),
        .d_request_write_i(d_request_write),
        .d_request_address_i(d_request_address),
        .d_request_write_data_i(d_request_write_data),
        .d_request_byte_enable_i(d_request_byte_enable),
        .d_response_valid_o(d_response_valid),
        .d_response_ready_i(d_response_ready),
        .d_response_read_data_o(d_response_read_data),
        .d_response_error_o(d_response_error),
        .m_request_valid_i(m_request_valid),
        .m_request_ready_o(m_request_ready),
        .m_request_address_i(m_request_address),
        .m_request_write_data_i(m_request_write_data),
        .m_request_byte_enable_i(m_request_byte_enable),
        .m_response_valid_o(m_response_valid),
        .m_response_ready_i(m_response_ready),
        .m_response_error_o(m_response_error),
        .araddr_o(araddr), .arvalid_o(arvalid), .arready_i(arready),
        .rdata_i(rdata), .rresp_i(rresp), .rvalid_i(rvalid),
        .rready_o(rready), .awaddr_o(awaddr), .awvalid_o(awvalid),
        .awready_i(awready), .wdata_o(wdata), .wstrb_o(wstrb),
        .wvalid_o(wvalid), .wready_i(wready), .bresp_i(bresp),
        .bvalid_i(bvalid), .bready_o(bready)
    );

    reg [31:0] random_state;
    integer transaction_count;
    integer max_read_outstanding;
    integer max_write_outstanding;
    integer max_aw_lead;
    integer max_w_lead;
    integer read_overlap;
    integer write_overlap;
    integer read_error_pending;
    integer write_error_pending;
    integer checks;
    integer test_index;
    integer random_owner;
    reg reset_on_response;

    always #5 clk = ~clk;

    task fail;
        input [8*100-1:0] message;
        begin
            $display("FAIL pipeline seed=%0d transaction=%0d: %0s",
                SEED, transaction_count, message);
            $stop;
        end
    endtask

    task random_step;
        begin
            random_state = random_state ^ (random_state << 13);
            random_state = random_state ^ (random_state >> 17);
            random_state = random_state ^ (random_state << 5);
        end
    endtask

    function [31:0] expected_word;
        input integer index;
        begin
            expected_word = 32'h19283746 ^ (index * 32'h10203040) ^
                transaction_count;
        end
    endfunction

    task reset_bus;
        begin
            @(negedge clk);
            reset = 1'b1;
            #1;
            if (arvalid || awvalid || wvalid || rready || bready ||
                    i_response_valid || d_response_valid || m_response_valid ||
                    i_request_ready || d_request_ready || m_request_ready)
                fail("reset did not suppress channel handshakes");
            i_request_valid = 0;
            d_request_valid = 0;
            m_request_valid = 0;
            i_response_ready = 0;
            d_response_ready = 0;
            m_response_ready = 0;
            arready = 0;
            awready = 0;
            wready = 0;
            rvalid = 0;
            bvalid = 0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            reset = 0;
            #1;
            if (arvalid || awvalid || wvalid || i_response_valid ||
                    d_response_valid || m_response_valid)
                fail("reset retained an old request or response");
            checks = checks + 1;
        end
    endtask

    task run_transaction;
        input integer owner;
        input write_request;
        input [3:0] error_mask;
        input [1:0] error_code;
        input integer schedule;
        input integer hold_cycles;
        integer words;
        integer ar_seen;
        integer r_seen;
        integer aw_seen;
        integer w_seen;
        integer b_seen;
        integer cycles;
        integer held;
        integer lane;
        reg done;
        reg previous_ar_stall;
        reg previous_aw_stall;
        reg previous_w_stall;
        reg [31:0] previous_ar;
        reg [31:0] previous_aw;
        reg [31:0] previous_w;
        reg [3:0] previous_strobe;
        reg [31:0] address;
        reg [127:0] line;
        reg [15:0] mask;
        reg response_seen;
        reg response_error_seen;
        reg [127:0] response_data_seen;
        begin
            transaction_count = transaction_count + 1;
            words = owner == 2 ? 1 : 4;
            address = owner == 2 ? 32'h80000000 + (transaction_count % 4) * 4 :
                32'h00001000 + transaction_count * 16;
            for (lane = 0; lane < 4; lane = lane + 1)
                line[lane*32 +: 32] = expected_word(lane);
            mask = owner == 2 ? {12'd0, transaction_count[3:0]} :
                (transaction_count[0] ? 16'hf05a : 16'ha50f);
            ar_seen = 0;
            r_seen = 0;
            aw_seen = 0;
            w_seen = 0;
            b_seen = 0;
            cycles = 0;
            held = 0;
            done = 0;
            previous_ar_stall = 0;
            previous_aw_stall = 0;
            previous_w_stall = 0;
            @(negedge clk);
            i_request_address = address + 8;
            d_request_address = address + 4;
            d_request_write = write_request;
            d_request_write_data = line;
            d_request_byte_enable = mask;
            m_request_address = address;
            m_request_write_data = line[31:0];
            m_request_byte_enable = mask[3:0];
            i_request_valid = owner == 0;
            d_request_valid = owner == 1;
            m_request_valid = owner == 2;
            @(posedge clk);
            if (!(i_request_ready || d_request_ready || m_request_ready))
                fail("idle bridge did not accept transaction");
            @(negedge clk);
            i_request_valid = 0;
            d_request_valid = 0;
            m_request_valid = 0;
            while (!done) begin
                random_step;
                // Schedules 0/1/2 fill outstanding queues before responding.
                arready = schedule == 0 ? 1'b1 : random_state[0];
                awready = schedule == 1 ? 1'b1 :
                    (schedule == 2 ? w_seen == words : random_state[1]);
                wready = schedule == 2 ? 1'b1 :
                    (schedule == 1 ? aw_seen == words : random_state[2]);
                rvalid = r_seen < ar_seen && (schedule == 0 ?
                    ar_seen == words && cycles > 6 : random_state[3]);
                rdata = expected_word(r_seen);
                rresp = error_mask[r_seen % 4] ? error_code : 2'b00;
                bvalid = b_seen < aw_seen && b_seen < w_seen &&
                    (schedule < 3 ? aw_seen == words && w_seen == words &&
                    cycles > 6 : random_state[4]);
                bresp = error_mask[b_seen % 4] ? error_code : 2'b00;
                i_response_ready = owner != 0 || held >= hold_cycles;
                d_response_ready = owner != 1 || held >= hold_cycles;
                m_response_ready = owner != 2 || held >= hold_cycles;
                // A queued request must not steal the active owner.
                i_request_valid = owner != 0;
                d_request_valid = owner != 1;
                m_request_valid = owner != 2;
                @(posedge clk);
                if (previous_ar_stall && (!arvalid || araddr !== previous_ar))
                    fail("AR changed while stalled");
                if (previous_aw_stall && (!awvalid || awaddr !== previous_aw))
                    fail("AW changed while stalled");
                if (previous_w_stall && (!wvalid || wdata !== previous_w ||
                        wstrb !== previous_strobe))
                    fail("W changed while stalled");
                previous_ar_stall = arvalid && !arready;
                previous_aw_stall = awvalid && !awready;
                previous_w_stall = wvalid && !wready;
                previous_ar = araddr;
                previous_aw = awaddr;
                previous_w = wdata;
                previous_strobe = wstrb;
                if (i_request_ready || d_request_ready || m_request_ready)
                    fail("accepted another transaction before response retirement");
                if (write_request && (arvalid || rready))
                    fail("write transaction used the read channels");
                if (!write_request && (awvalid || wvalid || bready))
                    fail("read transaction used the write channels");
                if (arvalid && arready) begin
                    if (ar_seen >= words || araddr !== address + ar_seen * 4)
                        fail("AR address/order/count mismatch");
                    ar_seen = ar_seen + 1;
                end
                if (awvalid && awready) begin
                    if (aw_seen >= words || awaddr !== address + aw_seen * 4)
                        fail("AW address/order/count mismatch");
                    aw_seen = aw_seen + 1;
                end
                if (wvalid && wready) begin
                    if (w_seen >= words || wdata !== line[w_seen*32 +: 32] ||
                            wstrb !== mask[w_seen*4 +: 4])
                        fail("W data/strobe/order/count mismatch");
                    w_seen = w_seen + 1;
                end
                if (rvalid && rready) begin
                    r_seen = r_seen + 1;
                    if (arvalid && arready) read_overlap = read_overlap + 1;
                    if (rresp != 0 && ar_seen < words)
                        read_error_pending = read_error_pending + 1;
                end
                if (bvalid && bready) begin
                    b_seen = b_seen + 1;
                    if ((awvalid && awready) || (wvalid && wready))
                        write_overlap = write_overlap + 1;
                    if (bresp != 0 && (aw_seen < words || w_seen < words))
                        write_error_pending = write_error_pending + 1;
                end
                if (r_seen > ar_seen || b_seen > aw_seen || b_seen > w_seen)
                    fail("response consumed without matching requests");
                if (ar_seen - r_seen > max_read_outstanding)
                    max_read_outstanding = ar_seen - r_seen;
                if (aw_seen - b_seen > max_write_outstanding)
                    max_write_outstanding = aw_seen - b_seen;
                if (aw_seen - w_seen > max_aw_lead)
                    max_aw_lead = aw_seen - w_seen;
                if (w_seen - aw_seen > max_w_lead)
                    max_w_lead = w_seen - aw_seen;
                response_seen = owner == 0 ? i_response_valid :
                    (owner == 1 ? d_response_valid : m_response_valid);
                response_error_seen = owner == 0 ? i_response_error :
                    (owner == 1 ? d_response_error : m_response_error);
                response_data_seen = owner == 0 ? i_response_read_data :
                    d_response_read_data;
                if ((owner != 0 && i_response_valid) ||
                        (owner != 1 && d_response_valid) ||
                        (owner != 2 && m_response_valid))
                    fail("response delivered to wrong client");
                if (held != 0 && !response_seen)
                    fail("client VALID dropped under backpressure");
                if (response_seen) begin
                    if (write_request ? (aw_seen != words || w_seen != words ||
                            b_seen != words) : (ar_seen != words || r_seen != words))
                        fail("line completed before every AXI response drained");
                    if (response_error_seen !== (error_mask != 0))
                        fail("error aggregation mismatch");
                    if (owner != 2 && response_data_seen !==
                            ((write_request || error_mask != 0) ? 128'd0 : line))
                        fail("line assembly or error-data zeroing mismatch");
                    if (arvalid || awvalid || wvalid || rready || bready)
                        fail("extra channel activity after line completion");
                    if (held >= hold_cycles) done = 1;
                    held = held + 1;
                    if (reset_on_response) begin
                        reset_bus;
                        done = 1;
                    end
                end
                checks = checks + 1;
                cycles = cycles + 1;
                if (cycles > 300) fail("transaction watchdog");
                @(negedge clk);
            end
            i_request_valid = 0;
            d_request_valid = 0;
            m_request_valid = 0;
            i_response_ready = 0;
            d_response_ready = 0;
            m_response_ready = 0;
            arready = 0;
            awready = 0;
            wready = 0;
            rvalid = 0;
            bvalid = 0;
        end
    endtask

    task reset_inflight;
        input integer channel;
        begin
            @(negedge clk);
            i_request_valid = channel == 0;
            d_request_valid = channel == 1 || channel == 2;
            m_request_valid = channel == 3;
            d_request_write = 1;
            @(posedge clk);
            @(negedge clk);
            i_request_valid = 0;
            d_request_valid = 0;
            m_request_valid = 0;
            arready = channel == 0;
            awready = channel == 1 || channel == 3;
            wready = channel == 2 || channel == 3;
            @(posedge clk);
            if (!(arvalid || awvalid || wvalid))
                fail("reset case did not create an in-flight request");
            reset_bus;
        end
    endtask

    initial begin
        clk = 0;
        reset = 1;
        random_state = SEED;
        transaction_count = 0;
        checks = 0;
        max_read_outstanding = 0;
        max_write_outstanding = 0;
        max_aw_lead = 0;
        max_w_lead = 0;
        read_overlap = 0;
        write_overlap = 0;
        read_error_pending = 0;
        write_error_pending = 0;
        reset_on_response = 0;
        i_request_address = 32'h1000;
        d_request_address = 32'h2000;
        d_request_write = 0;
        d_request_write_data = 0;
        d_request_byte_enable = 0;
        m_request_address = 32'h80000000;
        m_request_write_data = 0;
        m_request_byte_enable = 4'hf;
        rdata = 0;
        rresp = 0;
        bresp = 0;
        reset_bus;
        run_transaction(0, 0, 0, 0, 0, 5);
        run_transaction(1, 1, 0, 0, 1, 5);
        run_transaction(1, 1, 0, 0, 2, 5);
        for (test_index = 0; test_index < 4; test_index = test_index + 1) begin
            run_transaction(0, 0, 4'b0001 << test_index, 2'b10, 3, 4);
            run_transaction(1, 0, 4'b0001 << test_index, 2'b11, 0, 4);
            run_transaction(1, 1, 4'b0001 << test_index, 2'b10, 1, 4);
            run_transaction(1, 1, 4'b0001 << test_index, 2'b11, 2, 4);
            run_transaction(1, 1, 4'b0001 << test_index, 2'b01, 3, 4);
        end
        run_transaction(0, 0, 4'b1111, 2'b11, 3, 9);
        run_transaction(1, 0, 4'b0001, 2'b01, 3, 9);
        run_transaction(1, 1, 4'b1111, 2'b10, 3, 9);
        run_transaction(2, 1, 0, 0, 1, 12);
        run_transaction(2, 1, 0, 0, 2, 12);
        run_transaction(2, 1, 1, 2'b10, 1, 12);
        run_transaction(2, 1, 1, 2'b11, 2, 12);
        for (test_index = 0; test_index < 200; test_index = test_index + 1) begin
            random_step;
            random_owner = test_index % 3;
            run_transaction(random_owner,
                random_owner == 2 || (random_owner == 1 && random_state[5]),
                random_owner == 2 ? {3'b000, random_state[6]} : random_state[7:4],
                random_state[8] ? 2'b10 : 2'b11, 3, test_index % 11);
        end
        for (test_index = 0; test_index < 4; test_index = test_index + 1) begin
            reset_inflight(test_index);
            run_transaction(0, 0, 0, 0, 0, 3);
            run_transaction(2, 1, 0, 0, 1, 3);
        end
        reset_on_response = 1;
        run_transaction(0, 0, 0, 0, 0, 20);
        run_transaction(1, 1, 1, 2'b10, 2, 20);
        run_transaction(2, 1, 1, 2'b11, 1, 20);
        reset_on_response = 0;
        run_transaction(1, 0, 0, 0, 3, 3);
        if (max_read_outstanding != 4 || max_write_outstanding != 4 ||
                max_aw_lead != 4 || max_w_lead != 4 ||
                read_overlap == 0 || write_overlap == 0 ||
                read_error_pending == 0 || write_error_pending == 0)
            fail("concurrency coverage was not reached");
        $display("PASS cache AXI pipeline seed=%0d transactions=%0d checks=%0d read_max=%0d write_max=%0d aw_lead=%0d w_lead=%0d read_overlap=%0d write_overlap=%0d read_error_pending=%0d write_error_pending=%0d",
            SEED, transaction_count, checks, max_read_outstanding,
            max_write_outstanding, max_aw_lead, max_w_lead,
            read_overlap, write_overlap, read_error_pending, write_error_pending);
        $finish;
    end

    initial begin
        #5000000;
        fail("global watchdog");
    end
endmodule
