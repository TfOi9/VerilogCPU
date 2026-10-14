`timescale 1ns/1ps

module rv32_response_owner_tb;
    parameter ROB_ENTRIES = 32;
    parameter ROB_TAG_WIDTH = 7;
    reg clock = 0;
    reg reset = 1;
    reg request_valid = 0;
    reg request_ready = 0;
    reg request_mmio = 0;
    reg [ROB_TAG_WIDTH-1:0] request_tag = 0;
    reg [1:0] request_id = 0;
    reg response_ready = 0;
    reg ram_valid = 0;
    reg mmio_valid = 0;
    reg ram_error = 0;
    reg mmio_error = 0;
    reg [ROB_TAG_WIDTH-1:0] ram_tag = 0;
    reg [1:0] ram_id = 0;
    reg [31:0] ram_data = 0;
    wire injected_mmio_request = request_valid && request_mmio;
    integer transaction;
    integer delay_cycle;
    integer checked = 0;

    student_top #(.FE_WIDTH(2), .BE_WIDTH(2),
        .ROB_ENTRIES(ROB_ENTRIES), .ROB_TAG_WIDTH(ROB_TAG_WIDTH)) dut (
        .clock(clock), .reset(reset), .araddr(), .arvalid(), .arready(1'b0),
        .rdata(32'd0), .rresp(2'd0), .rvalid(1'b0), .rready(),
        .awaddr(), .awvalid(), .awready(1'b0), .wdata(), .wstrb(),
        .wvalid(), .wready(1'b0), .bresp(2'd0), .bvalid(1'b0), .bready()
    );
    always #5 clock = ~clock;

    task fail;
        input [511:0] message;
        begin
            $display("FAIL response owner transaction=%0d %0s", transaction, message);
            $stop;
        end
    endtask

    task tick;
        begin
            @(posedge clock);
            #1;
            @(negedge clock);
        end
    endtask

    task check_reply;
        input expected_owner;
        input expected_valid;
        input [ROB_TAG_WIDTH-1:0] expected_tag;
        input [1:0] expected_id;
        input expected_error;
        input [31:0] expected_data;
        begin
            #1;
            if (dut.lsu_mmio_inflight !== expected_owner ||
                    dut.core_d_response_valid !== expected_valid ||
                    dut.mmio_response_ready !== (expected_owner && response_ready) ||
                    dut.dcache_response_ready !== (!expected_owner && response_ready))
                fail("ownership or handshake mismatch");
            if (expected_valid && (dut.core_d_response_rob_tag !== expected_tag ||
                    dut.core_d_response_id !== expected_id ||
                    dut.core_d_response_error !== expected_error ||
                    dut.core_d_response_read_data !== expected_data))
                fail("response identity or payload mismatch");
            checked = checked + 1;
        end
    endtask

    initial begin
        // Isolate the top-level ownership boundary from both protocol engines.
        force dut.core_i_request_valid = 1'b0;
        force dut.core_d_request_valid = request_valid;
        force dut.core_d_request_ready = request_ready;
        force dut.core_d_request_mmio = request_mmio;
        force dut.core_d_request_rob_tag = request_tag;
        force dut.core_d_request_id = request_id;
        force dut.core_d_response_ready = response_ready;
        force dut.dcache_request_valid = 1'b0;
        force dut.mmio_request_valid = injected_mmio_request;
        force dut.mmio_request_ready = request_ready;
        force dut.dcache_response_valid = ram_valid;
        force dut.dcache_response_rob_tag = ram_tag;
        force dut.dcache_response_id = ram_id;
        force dut.dcache_response_read_data = ram_data;
        force dut.dcache_response_error = ram_error;
        force dut.mmio_response_valid = mmio_valid;
        force dut.mmio_response_error = mmio_error;
        tick;
        tick;
        reset = 0;
        for (transaction = 0; transaction < (1 << (ROB_TAG_WIDTH+1));
                transaction = transaction + 1) begin
            request_mmio = transaction[0];
            request_tag = transaction >> 1;
            request_id = (transaction >> 1) & 3;
            request_valid = 1;
            request_ready = 0;
            ram_valid = 0;
            mmio_valid = 0;
            tick;
            if (dut.lsu_mmio_inflight !== 1'b0) fail("unaccepted request changed owner");
            request_ready = 1;
            tick;
            request_valid = 0;
            request_ready = 0;
            ram_tag = request_tag;
            ram_id = request_id;
            ram_data = 32'habc00000 + transaction;
            ram_error = transaction[2];
            mmio_error = transaction[2];
            for (delay_cycle = 0; delay_cycle < 3; delay_cycle = delay_cycle + 1) begin
                check_reply(request_mmio, 0, 0, 0, 0, 0);
                tick;
            end
            ram_valid = !request_mmio;
            mmio_valid = request_mmio;
            response_ready = 0;
            for (delay_cycle = 0; delay_cycle < 3; delay_cycle = delay_cycle + 1) begin
                check_reply(request_mmio, 1, request_tag, request_id,
                    transaction[2], request_mmio ? 0 : ram_data);
                tick;
            end
            response_ready = 1;
            // A RAM request can follow a response on the same edge.
            request_valid = 1;
            request_ready = 1;
            request_mmio = 0;
            tick;
            ram_valid = 0;
            mmio_valid = 0;
            request_valid = 0;
            response_ready = 0;
            check_reply(0, 0, 0, 0, 0, 0);
            ram_tag = ~request_tag;
            ram_id = ~request_id;
            ram_valid = 1;
            check_reply(0, 1, ram_tag, ram_id, ram_error, ram_data);
            response_ready = 1;
            tick;
            ram_valid = 0;
            response_ready = 0;
        end
        request_mmio = 1;
        request_valid = 1;
        request_ready = 1;
        tick;
        reset = 1;
        request_valid = 0;
        tick;
        if (dut.lsu_mmio_inflight !== 0) fail("reset did not release ownership");
        $display("PASS response owner ROB=%0d checked=%0d", ROB_ENTRIES, checked);
        $finish;
    end
    initial begin
        #2000000;
        fail("timeout");
    end
endmodule
