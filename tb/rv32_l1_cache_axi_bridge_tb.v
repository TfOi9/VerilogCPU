`timescale 1ns/1ps

module rv32_l1_cache_axi_bridge_tb;
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

    reg [31:0] expected_words [0:3];
    reg [31:0] backing_words [0:3];
    reg [15:0] expected_mask;
    integer beat;
    integer byte_index;
    integer timeout_count;
    integer write_beat_count;

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

    always #5 clk = ~clk;

    task fail;
        input [8*96-1:0] message;
        begin
            $display("FAIL %0s at %0t", message, $time);
            $finish(1);
        end
    endtask

    task send_write_beat;
        input [31:0] expected_address;
        input [31:0] expected_data;
        input [3:0] expected_strobe;
        input [1:0] expected_bresp;
        integer aw_seen;
        integer w_seen;
        integer cycles;
        begin
            aw_seen = 0;
            w_seen = 0;
            cycles = 0;
            while (!aw_seen || !w_seen) begin
                @(negedge clk);
                awready = !aw_seen && ((cycles % 2) ==
                    (write_beat_count % 2));
                wready = !w_seen && ((cycles % 2) !=
                    (write_beat_count % 2));
                if (awvalid && awaddr !== expected_address)
                    fail("AXI AW address changed under backpressure");
                if (wvalid && (wdata !== expected_data ||
                        wstrb !== expected_strobe))
                    fail("AXI W payload changed under backpressure");
                @(posedge clk);
                if (awvalid && awready) begin
                    if (awaddr !== expected_address)
                        fail("AXI AW address mismatch");
                    aw_seen = 1;
                end
                if (wvalid && wready) begin
                    if (wdata !== expected_data || wstrb !== expected_strobe)
                        fail("AXI W data or strobe mismatch");
                    w_seen = 1;
                end
                cycles = cycles + 1;
                if (cycles > 20)
                    fail("timeout waiting for split AXI write beat");
            end
            write_beat_count = write_beat_count + 1;

            @(negedge clk);
            awready = 1'b0;
            wready = 1'b0;
            bresp = expected_bresp;
            bvalid = 1'b1;
            timeout_count = 0;
            while (!bready) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
                if (timeout_count > 20)
                    fail("timeout waiting for AXI B ready");
            end
            @(posedge clk);
            @(negedge clk);
            bvalid = 1'b0;
        end
    endtask

    task send_read_beat;
        input [31:0] expected_address;
        input [31:0] read_data;
        input [1:0] read_response;
        begin
            timeout_count = 0;
            while (!arvalid) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
                if (timeout_count > 20)
                    fail("timeout waiting for AXI AR valid");
            end
            if (araddr !== expected_address)
                fail("AXI AR address mismatch");
            @(negedge clk);
            arready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            arready = 1'b0;
            rdata = read_data;
            rresp = read_response;
            rvalid = 1'b1;
            timeout_count = 0;
            while (!rready) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
                if (timeout_count > 20)
                    fail("timeout waiting for AXI R ready");
            end
            @(posedge clk);
            @(negedge clk);
            rvalid = 1'b0;
        end
    endtask

    task wait_i_response;
        begin
            timeout_count = 0;
            while (!i_response_valid) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
                if (timeout_count > 30)
                    fail("timeout waiting for I-cache response");
            end
        end
    endtask

    task wait_d_response;
        begin
            timeout_count = 0;
            while (!d_response_valid) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
                if (timeout_count > 30)
                    fail("timeout waiting for D-cache response");
            end
        end
    endtask

    task wait_m_response;
        begin
            timeout_count = 0;
            while (!m_response_valid) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
                if (timeout_count > 30)
                    fail("timeout waiting for MMIO response");
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        i_request_valid = 1'b0;
        i_request_address = 32'd0;
        i_response_ready = 1'b0;
        d_request_valid = 1'b0;
        d_request_write = 1'b0;
        d_request_address = 32'd0;
        d_request_write_data = 128'd0;
        d_request_byte_enable = 16'd0;
        d_response_ready = 1'b0;
        m_request_valid = 1'b0;
        m_request_address = 32'd0;
        m_request_write_data = 32'd0;
        m_request_byte_enable = 4'd0;
        m_response_ready = 1'b0;
        arready = 1'b0;
        rdata = 32'd0;
        rresp = 2'b00;
        rvalid = 1'b0;
        awready = 1'b0;
        wready = 1'b0;
        bresp = 2'b00;
        bvalid = 1'b0;
        write_beat_count = 0;
        expected_words[0] = 32'h11223344;
        expected_words[1] = 32'h55667788;
        expected_words[2] = 32'h99aabbcc;
        expected_words[3] = 32'hddeeff00;
        expected_mask = 16'ha53c;
        for (beat = 0; beat < 4; beat = beat + 1)
            backing_words[beat] = 32'h01020304 * (beat + 1);

        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        d_request_valid = 1'b1;
        d_request_write = 1'b1;
        d_request_address = 32'h00000123;
        d_request_write_data = {expected_words[3], expected_words[2],
            expected_words[1], expected_words[0]};
        d_request_byte_enable = expected_mask;
        i_request_valid = 1'b1;
        i_request_address = 32'h00000124;
        #1;
        if (!d_request_ready || i_request_ready)
            fail("D-cache must win simultaneous line request arbitration");
        @(posedge clk);
        @(negedge clk);
        d_request_valid = 1'b0;

        for (beat = 0; beat < 4; beat = beat + 1) begin
            send_write_beat(32'h00000120 + beat * 4,
                expected_words[beat], expected_mask[beat*4 +: 4], 2'b00);
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (expected_mask[beat*4 + byte_index])
                    backing_words[beat][byte_index*8 +: 8] =
                        expected_words[beat][byte_index*8 +: 8];
        end

        wait_d_response;
        if (d_response_error || d_response_read_data !== 128'd0)
            fail("successful D-cache write response is incorrect");
        repeat (3) begin
            @(negedge clk);
            if (!d_response_valid || i_request_ready)
                fail("response backpressure must hold D response and arbiter");
        end
        d_response_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        d_response_ready = 1'b0;
        timeout_count = 0;
        while (!i_request_ready) begin
            @(negedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > 20)
                fail("I-cache request did not proceed after D response");
        end
        @(posedge clk);
        @(negedge clk);
        i_request_valid = 1'b0;

        for (beat = 0; beat < 4; beat = beat + 1)
            begin
            send_read_beat(32'h00000120 + beat * 4,
                backing_words[beat], 2'b00);
            end
        wait_i_response;
        if (i_response_error || i_response_read_data !==
            {backing_words[3], backing_words[2], backing_words[1],
                backing_words[0]})
            fail("four-beat I-cache refill data is incorrect");
        i_response_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        i_response_ready = 1'b0;

        i_request_valid = 1'b1;
        i_request_address = 32'h00000408;
        @(posedge clk);
        if (!i_request_ready)
            fail("second I-cache line request was not accepted");
        @(negedge clk);
        i_request_valid = 1'b0;
        send_read_beat(32'h00000400, 32'hbad0bad0, 2'b11);
        wait_i_response;
        if (!i_response_error || i_response_read_data !== 128'd0)
            fail("AXI read error did not propagate to I-cache");
        i_response_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        i_response_ready = 1'b0;

        d_request_valid = 1'b1;
        d_request_write = 1'b1;
        d_request_address = 32'h00000500;
        d_request_write_data = 128'h0123456789abcdef_fedcba9876543210;
        d_request_byte_enable = 16'hffff;
        @(posedge clk);
        if (!d_request_ready)
            fail("D-cache error test request was not accepted");
        @(negedge clk);
        d_request_valid = 1'b0;
        send_write_beat(32'h00000500, 32'h76543210, 4'hf, 2'b10);
        wait_d_response;
        if (!d_response_error || i_response_valid)
            fail("AXI write error did not route to D-cache");
        d_response_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        d_response_ready = 1'b0;

        m_request_valid = 1'b1;
        m_request_address = 32'h80000000;
        m_request_write_data = 32'h12345678;
        m_request_byte_enable = 4'hf;
        d_request_valid = 1'b1;
        d_request_write = 1'b0;
        d_request_address = 32'h00000600;
        i_request_valid = 1'b1;
        i_request_address = 32'h00000700;
        #1;
        if (!m_request_ready || d_request_ready || i_request_ready)
            fail("MMIO must win simultaneous bridge arbitration");
        @(posedge clk);
        @(negedge clk);
        m_request_valid = 1'b0;
        send_write_beat(32'h80000000, 32'h12345678, 4'hf, 2'b10);
        wait_m_response;
        if (!m_response_error || d_response_valid || i_response_valid)
            fail("MMIO B error did not route to MMIO client");
        repeat (3) begin
            @(negedge clk);
            if (awvalid || wvalid || d_request_ready || i_request_ready)
                fail("MMIO response must hold bridge without extra beats");
        end
        m_response_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        m_response_ready = 1'b0;
        if (!d_request_ready || i_request_ready)
            fail("D-cache must follow completed MMIO transaction");
        d_request_valid = 1'b0;
        i_request_valid = 1'b0;

        $display("PASS cache AXI bridge line and MMIO arbitration, backpressure and errors");
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL bridge testbench watchdog");
        $finish(1);
    end
endmodule
