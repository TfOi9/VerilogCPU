`timescale 1ns/1ps

module rv32_response_owner_tb;
    parameter ROB_ENTRIES = 32;
    parameter ROB_TAG_WIDTH = 7;
    parameter NONBLOCKING = 1;
    reg clock = 0;
    reg reset = 1;
    reg response_ready = 0;
    reg ram_valid = 0;
    reg mmio_valid = 0;
    reg ram_error = 0;
    reg mmio_error = 0;
    reg [ROB_TAG_WIDTH-1:0] ram_tag = 0;
    reg [1:0] ram_id = 0;
    reg [31:0] ram_data = 0;
    reg [ROB_TAG_WIDTH-1:0] aux_tag = 0;
    reg [1:0] aux_id = 0;
    wire [127:0] ram_line = {4{ram_data}};
    integer transaction;
    integer checked = 0;

    student_top #(.FE_WIDTH(2), .BE_WIDTH(2),
        .NONBLOCKING_DCACHE(NONBLOCKING),
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
        input expected_valid;
        input [ROB_TAG_WIDTH-1:0] expected_tag;
        input [1:0] expected_id;
        input expected_error;
        input [31:0] expected_data;
        begin
            #1;
            if (dut.core_d_response_valid !== expected_valid ||
                    dut.dcache_response_ready !== response_ready)
                fail("handshake mismatch");
            if (expected_valid && (dut.core_d_response_rob_tag !== expected_tag ||
                    dut.core_d_response_id !== expected_id ||
                    dut.core_d_response_error !== expected_error ||
                    dut.core_d_response_read_data !== expected_data))
                fail("response identity or payload mismatch");
            checked = checked + 1;
        end
    endtask

    initial begin
        // Inject packets before the shared return registers.
        force dut.core_i_request_valid = 1'b0;
        force dut.core_d_request_valid = 1'b0;
        force dut.core_d_response_ready = response_ready;
        force dut.dcache.mode = 3'd0;
        force dut.dcache.s0_valid = 1'b0;
        force dut.dcache.s1_valid = 1'b0;
        force dut.dcache.s2_valid = ram_valid;
        force dut.dcache.s2_hit = 1'b1;
        force dut.dcache.s2_bad_address = ram_error;
        force dut.dcache.s2_write = 1'b0;
        force dut.dcache.s2_address = 32'd0;
        force dut.dcache.s2_line = ram_line;
        force dut.dcache.s2_id = ram_id;
        force dut.dcache.s2_rob_tag = ram_tag;
        force dut.mmio_response_valid = mmio_valid;
        force dut.mmio_response_error = mmio_error;
        force dut.mmio_response_id = aux_id;
        force dut.mmio_response_rob_tag = aux_tag;
        tick;
        tick;
        reset = 0;
        for (transaction = 0; transaction < (1 << (ROB_TAG_WIDTH+1));
                transaction = transaction + 1) begin
            ram_tag = transaction >> 1;
            ram_id = transaction & 3;
            ram_data = 32'habc00000 + transaction;
            ram_error = transaction[2];
            aux_tag = ~ram_tag;
            aux_id = ~ram_id;
            mmio_error = transaction[3];
            ram_valid = 1;
            mmio_valid = 1;
            #1;
            if (dut.mmio_response_ready) fail("auxiliary packet bypassed RAM priority");
            check_reply(0, 0, 0, 0, 0);
            tick;
            ram_valid = 0;
            check_reply(1, ram_tag, ram_id, ram_error, ram_error ? 0 : ram_data);
            if (NONBLOCKING == 0) begin
                if (dut.mmio_response_ready) fail("full return register accepted auxiliary packet");
                response_ready = 1;
            end
            tick;
            mmio_valid = 0;
            if (NONBLOCKING != 0) begin
                if (dut.mmio_response_ready) fail("full skid queue reported capacity");
                check_reply(1, ram_tag, ram_id, ram_error, ram_error ? 0 : ram_data);
                tick;
                check_reply(1, ram_tag, ram_id, ram_error, ram_error ? 0 : ram_data);
                response_ready = 1;
                tick;
            end
            response_ready = 0;
            check_reply(1, aux_tag, aux_id, mmio_error, 0);
            tick;
            check_reply(1, aux_tag, aux_id, mmio_error, 0);
            response_ready = 1;
            // Pop and replace on the same edge without adding RAM latency.
            ram_valid = 1;
            tick;
            ram_valid = 0;
            check_reply(1, ram_tag, ram_id, ram_error, ram_error ? 0 : ram_data);
            tick;
            response_ready = 0;
            check_reply(0, 0, 0, 0, 0);
        end
        ram_valid = 1;
        tick;
        reset = 1;
        ram_valid = 0;
        tick;
        check_reply(0, 0, 0, 0, 0);
        $display("PASS response owner ROB=%0d NB=%0d checked=%0d", ROB_ENTRIES, NONBLOCKING, checked);
        $finish;
    end
    initial begin
        #2000000;
        fail("timeout");
    end
endmodule
