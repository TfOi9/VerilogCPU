`timescale 1ns/1ps

module rv32_l1_cache_wide_bridge_tb;
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
    reg [1:0] d_request_id = 0;
    wire [1:0] d_response_id;
    reg [1:0] expected_write_id;
    reg [3:0] expected_read_error;
    reg [31:0] d_request_address;
    reg [127:0] d_request_write_data;
    reg [15:0] d_request_byte_enable;
    wire d_response_valid;
    reg d_response_ready;
    wire [127:0] d_response_read_data;
    wire d_response_error;
    wire d_response_write;
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

    rv32_l1_cache_axi_bridge #(.PARALLEL(1), .D_TAGGED(1), .D_ID_WIDTH(2), .READ_ENTRIES(4)) dut (
        .d_request_id_i(d_request_id), .d_response_id_o(d_response_id),
        .d_response_write_o(d_response_write),
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

    integer cycle = 0;
    integer batch;
    integer lane;
    integer words;
    integer count;
    integer start_cycle;
    integer ar_total = 0;
    integer ar_seen = 0;
    integer r_seen = 0;
    integer w_total = 0;
    integer aw_seen = 0;
    integer w_seen = 0;
    integer b_seen = 0;
    integer checks = 0;
    integer overlap = 0;
    integer read_max = 0;
    integer mmio_words = 0;
    reg [31:0] ar_expected [0:511];
    reg [31:0] aw_expected [0:511];
    reg [31:0] w_expected [0:511];
    reg [3:0] mask_expected [0:511];
    reg r_error_expected [0:511];
    reg b_error_expected [0:511];
    integer r_due [0:511];
    integer b_due [0:511];
    reg i_pending = 0;
    reg [3:0] dr_pending = 0;
    reg dw_pending = 0;
    reg m_pending = 0;
    reg d_read_error;
    reg d_write_error;
    reg i_read_error;
    reg m_write_error;
    reg [127:0] d_expected [0:3];
    reg [127:0] i_expected;
    reg ar_held = 0;
    reg aw_held = 0;
    reg w_held = 0;
    reg r_held = 0;
    reg b_held = 0;
    reg response_held = 0;
    reg held_write;
    reg [1:0] held_id;
    reg held_error;
    reg [127:0] held_response;
    reg [31:0] held_ar;
    reg [31:0] held_aw;
    reg [31:0] held_w;
    reg [3:0] held_mask;
    reg [31:0] random_state = SEED;
    reg [31:0] base;
    always #5 clk = ~clk;
    function [31:0] value;
        input [31:0] address;
        begin value = 32'h5a000000 ^ address; end
    endfunction
    task fail;
        input [8*100-1:0] reason;
        begin
            $display("FAIL MSHR bridge seed=%0d cycle=%0d: %0s",SEED,cycle,reason);
            $stop;
        end
    endtask
    always @(negedge clk) begin
        if (!reset) begin
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            arready = random_state[0] || random_state[5];
            awready = random_state[1] || random_state[6];
            wready = random_state[2] || random_state[7];
            if (!r_held) begin
                rvalid = r_seen < ar_seen && cycle >= r_due[r_seen] && random_state[8];
                rdata = value(ar_expected[r_seen]);
                rresp = r_error_expected[r_seen] ? 2'b10 : 0;
            end
            if (!b_held) begin
                bvalid = b_seen < aw_seen && b_seen < w_seen && cycle >= b_due[b_seen] && random_state[9];
                bresp = b_error_expected[b_seen] ? 2'b10 : 0;
            end
        end
    end
    always @(posedge clk) begin
        if (!reset) begin
            cycle = cycle + 1;
            if (ar_held && (!arvalid || araddr !== held_ar)) fail("AR changed under backpressure");
            if (aw_held && (!awvalid || awaddr !== held_aw)) fail("AW changed under backpressure");
            if (w_held && (!wvalid || wdata !== held_w || wstrb !== held_mask)) fail("W changed under backpressure");
            ar_held = arvalid && !arready; held_ar = araddr;
            aw_held = awvalid && !awready; held_aw = awaddr;
            w_held = wvalid && !wready; held_w = wdata; held_mask = wstrb;
            r_held = rvalid && !rready; b_held = bvalid && !bready;
            if (response_held && (!d_response_valid || d_response_write !== held_write ||
                    d_response_error !== held_error || d_response_read_data !== held_response || d_response_id !== held_id))
                fail("response changed under backpressure");
            response_held = d_response_valid && !d_response_ready;
            held_id = d_response_id; held_write = d_response_write; held_error = d_response_error; held_response = d_response_read_data;
            if (m_request_ready && (i_pending || dr_pending || dw_pending)) fail("MMIO bypassed earlier transactions");
            if (dut.arbiter.read_count == 4 && dut.arbiter.write_busy) overlap = overlap + 1;
            if (ar_seen-r_seen > read_max) read_max = ar_seen-r_seen;
            if (i_request_valid && i_request_ready) begin
                if (i_pending) fail("duplicate I request"); i_pending = 1;
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    ar_expected[ar_total] = (i_request_address & 32'hfffffff0) + lane*4;
                    r_due[ar_total] = cycle + 45;
                    r_error_expected[ar_total] = i_read_error && lane == 2;
                    i_expected[lane*32 +: 32] = value(ar_expected[ar_total]); ar_total = ar_total + 1;
                end
            end
            if (d_request_valid && d_request_ready && !d_request_write) begin
                if (dr_pending[d_request_id]) fail("duplicate D read ID");
                dr_pending[d_request_id] = 1; expected_read_error[d_request_id] = d_read_error;
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    ar_expected[ar_total] = (d_request_address & 32'hfffffff0) + lane*4;
                    r_due[ar_total] = cycle + 40;
                    r_error_expected[ar_total] = d_read_error && lane == 1;
                    d_expected[d_request_id][lane*32 +: 32] = value(ar_expected[ar_total]); ar_total = ar_total + 1;
                end
            end
            if ((d_request_valid && d_request_ready && d_request_write) ||
                    (m_request_valid && m_request_ready)) begin
                words = m_request_valid && m_request_ready ? 1 : 4;
                if (words == 1) m_pending = 1;
                else begin if (dw_pending) fail("duplicate D write"); dw_pending = 1; expected_write_id = d_request_id; end
                for (lane = 0; lane < words; lane = lane + 1) begin
                    aw_expected[w_total] = words == 1 ? m_request_address :
                        (d_request_address & 32'hfffffff0) + lane*4;
                    w_expected[w_total] = words == 1 ? m_request_write_data : d_request_write_data[lane*32 +: 32];
                    mask_expected[w_total] = words == 1 ? m_request_byte_enable : d_request_byte_enable[lane*4 +: 4];
                    b_due[w_total] = cycle + 60;
                    b_error_expected[w_total] = words == 1 ? m_write_error : d_write_error && lane == 3;
                    w_total = w_total + 1;
                end
            end
            if (arvalid && arready) begin
                if (ar_seen >= ar_total || araddr !== ar_expected[ar_seen]) fail("AR ordering"); ar_seen = ar_seen + 1;
            end
            if (awvalid && awready) begin
                if (aw_seen >= w_total || awaddr !== aw_expected[aw_seen]) fail("AW ordering");
                if (awaddr[31]) mmio_words = mmio_words + 1;
                aw_seen = aw_seen + 1;
            end
            if (wvalid && wready) begin
                if (w_seen >= w_total || wdata !== w_expected[w_seen] || wstrb !== mask_expected[w_seen]) fail("W ordering/mask"); w_seen = w_seen + 1;
            end
            if (rvalid && rready) r_seen = r_seen + 1;
            if (bvalid && bready) b_seen = b_seen + 1;
            if (i_response_valid && i_response_ready) begin
                if (!i_pending || i_response_error !== i_read_error ||
                    i_response_read_data !== (i_read_error ? 128'd0 : i_expected)) fail("I response ownership");
                i_pending = 0; checks = checks + 1;
            end
            if (d_response_valid && d_response_ready) begin
                if (d_response_write) begin
                    if (!dw_pending || d_response_id !== expected_write_id || d_response_error !== d_write_error || d_response_read_data !== 0) fail("D write response"); dw_pending = 0;
                end else begin
                    if (!dr_pending[d_response_id] || d_response_error !== expected_read_error[d_response_id] ||
                            d_response_read_data !== (expected_read_error[d_response_id] ? 128'd0 : d_expected[d_response_id]))
                        fail("D read response identity or data");
                    dr_pending[d_response_id] = 0;
                end
                checks = checks + 1;
            end
            if (m_response_valid && m_response_ready) begin
                if (!m_pending || m_response_error !== m_write_error) fail("MMIO response"); m_pending = 0; checks = checks + 1;
            end
        end
    end
    task request_d;
        input write_request;
        begin
            @(negedge clk); d_request_valid = 1; d_request_write = write_request;
            @(posedge clk); while (!d_request_ready) @(posedge clk);
            @(negedge clk); d_request_valid = 0;
        end
    endtask
    initial begin
        clk = 0; reset = 1; arready = 0; awready = 0; wready = 0; rvalid = 0; bvalid = 0;
        i_request_valid = 0; d_request_valid = 0; m_request_valid = 0;
        i_response_ready = 1; d_response_ready = 0; m_response_ready = 1;
        i_request_address = 0; d_request_address = 0; d_request_write = 0;
        d_request_write_data = 0; d_request_byte_enable = 0;
        m_request_address = 0; m_request_write_data = 0; m_request_byte_enable = 0;
        rdata = 0; rresp = 0; bresp = 0;
        repeat (3) @(negedge clk); reset = 0;
        for (batch = 0; batch < 24; batch = batch + 1) begin
            base = 32'h1000 + batch*256;
            d_read_error = batch % 3 == 0; d_write_error = batch % 5 == 0;
            i_read_error = batch % 7 == 0; m_write_error = batch % 11 == 0;
            d_response_ready = 0;
            d_request_address = base;
            for (lane = 0; lane < 4; lane = lane + 1) d_request_write_data[lane*32 +: 32] = value(base+lane*4);
            d_request_id = batch[1:0]; d_request_byte_enable = 16'ha5f0; request_d(1);
            d_request_id = 0; d_request_address = base + 64; request_d(0);
            d_request_id = 1; d_read_error = !d_read_error;
            d_request_address = base + 128; request_d(0);
            d_request_id = 2; d_read_error = !d_read_error;
            d_request_address = base + 192; request_d(0);
            @(negedge clk); i_request_address = base + 224; i_request_valid = 1;
            @(posedge clk); while (!i_request_ready) @(posedge clk);
            @(negedge clk); i_request_valid = 0;
            m_request_address = 32'h80000000 + (batch%4)*4;
            m_request_write_data = value(m_request_address); m_request_byte_enable = batch[3:0]; m_request_valid = 1;
            start_cycle = cycle;
            while (cycle-start_cycle < 90) @(negedge clk);
            d_response_ready = 1;
            @(posedge clk); while (!m_request_ready) @(posedge clk);
            @(negedge clk); m_request_valid = 0;
            count = 0;
            while (i_pending || dr_pending || dw_pending || m_pending) begin
                @(negedge clk); count = count + 1; if (count > 1000) fail("response timeout");
            end
        end
        if (checks != 144 || read_max < 16 || overlap == 0 || mmio_words != 24 ||
                ar_seen != 384 || r_seen != 384 || aw_seen != 120 || w_seen != 120 || b_seen != 120)
            fail("missing protocol coverage");
        d_read_error = 0; d_write_error = 0; i_read_error = 0;
        d_response_ready = 0;
        d_request_address = 32'h7000; request_d(1);
        d_request_address = 32'h7040; request_d(0);
        @(negedge clk); i_request_address = 32'h7080; i_request_valid = 1;
        @(posedge clk); while (!i_request_ready) @(posedge clk);
        @(negedge clk); i_request_valid = 0;
        repeat (6) @(negedge clk);
        reset = 1; #1;
        if (arvalid || awvalid || wvalid || rready || bready ||
                d_response_valid || i_response_valid || m_response_valid)
            fail("reset did not suppress pending handshakes");
        repeat (3) @(negedge clk);
        i_pending = 0; dr_pending = 0; dw_pending = 0; m_pending = 0;
        ar_total = 0; ar_seen = 0; r_seen = 0; w_total = 0;
        aw_seen = 0; w_seen = 0; b_seen = 0;
        ar_held = 0; aw_held = 0; w_held = 0; r_held = 0; b_held = 0;
        response_held = 0; rvalid = 0; bvalid = 0;
        d_response_ready = 1; reset = 0;
        d_request_address = 32'h7100; request_d(0);
        count = 0;
        while (dr_pending) begin
            @(negedge clk); count = count + 1;
            if (count > 1000) fail("post-reset response timeout");
        end
        $display("PASS wide MSHR bridge seed=%0d responses=%0d read_max=%0d overlap=%0d MMIO_words=%0d",SEED,checks,read_max,overlap,mmio_words);
        $finish;
    end
    initial begin #1000000; fail("simulation timeout"); end
endmodule
