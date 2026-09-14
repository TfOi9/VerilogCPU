`timescale 1ns/1ps

module rv32_main_memory_tb;
    reg clk_i;
    reg reset_i;
    reg i_request_valid_i;
    wire i_request_ready_o;
    reg [31:0] i_request_address_i;
    wire i_response_valid_o;
    reg i_response_ready_i;
    wire [127:0] i_response_read_data_o;
    wire i_response_error_o;
    reg d_request_valid_i;
    wire d_request_ready_o;
    reg d_request_write_i;
    reg [31:0] d_request_address_i;
    reg [127:0] d_request_write_data_i;
    reg [15:0] d_request_byte_enable_i;
    wire d_response_valid_o;
    reg d_response_ready_i;
    wire [127:0] d_response_read_data_o;
    wire d_response_error_o;
    integer cycle;
    integer accepted;
    integer accepted_other;
    integer step;
    reg [127:0] observed;
    reg [127:0] saved;

    rv32_main_memory dut (
        .clk_i(clk_i), .reset_i(reset_i),
        .i_request_valid_i(i_request_valid_i),
        .i_request_ready_o(i_request_ready_o),
        .i_request_address_i(i_request_address_i),
        .i_response_valid_o(i_response_valid_o),
        .i_response_ready_i(i_response_ready_i),
        .i_response_read_data_o(i_response_read_data_o),
        .i_response_error_o(i_response_error_o),
        .d_request_valid_i(d_request_valid_i),
        .d_request_ready_o(d_request_ready_o),
        .d_request_write_i(d_request_write_i),
        .d_request_address_i(d_request_address_i),
        .d_request_write_data_i(d_request_write_data_i),
        .d_request_byte_enable_i(d_request_byte_enable_i),
        .d_response_valid_o(d_response_valid_o),
        .d_response_ready_i(d_response_ready_i),
        .d_response_read_data_o(d_response_read_data_o),
        .d_response_error_o(d_response_error_o)
    );

    always #5 clk_i = ~clk_i;
    always @(posedge clk_i) cycle <= cycle + 1;

    initial begin
        #20000;
        $fatal(1, "ERROR main memory watchdog expired");
    end

    task send_i;
        input [31:0] address;
        output integer at_cycle;
        begin
            @(negedge clk_i);
            if (!i_request_ready_o)
                $fatal(1, "ERROR I request not ready");
            i_request_address_i = address;
            i_request_valid_i = 1'b1;
            @(posedge clk_i);
            #1;
            at_cycle = cycle;
            i_request_valid_i = 1'b0;
        end
    endtask

    task send_d;
        input write_request;
        input [31:0] address;
        input [127:0] write_data;
        input [15:0] byte_enable;
        output integer at_cycle;
        begin
            @(negedge clk_i);
            if (!d_request_ready_o)
                $fatal(1, "ERROR D request not ready");
            d_request_write_i = write_request;
            d_request_address_i = address;
            d_request_write_data_i = write_data;
            d_request_byte_enable_i = byte_enable;
            d_request_valid_i = 1'b1;
            @(posedge clk_i);
            #1;
            at_cycle = cycle;
            d_request_valid_i = 1'b0;
        end
    endtask

    task await_i;
        input integer at_cycle;
        input expected_error;
        output [127:0] read_data;
        integer tick;
        begin
            for (tick = 1; tick < 50; tick = tick + 1) begin
                @(posedge clk_i);
                #1;
                if (i_response_valid_o || i_request_ready_o)
                    $fatal(1, "ERROR I port released early at cycle %0d",
                        cycle);
            end
            @(posedge clk_i);
            #1;
            if (cycle - at_cycle != 50 || !i_response_valid_o ||
                    i_response_error_o !== expected_error)
                $fatal(1, "ERROR I response timing or status at cycle %0d",
                    cycle);
            read_data = i_response_read_data_o;
        end
    endtask

    task await_d;
        input integer at_cycle;
        input expected_error;
        output [127:0] read_data;
        integer tick;
        begin
            for (tick = 1; tick < 50; tick = tick + 1) begin
                @(posedge clk_i);
                #1;
                if (d_response_valid_o || d_request_ready_o)
                    $fatal(1, "ERROR D port released early at cycle %0d",
                        cycle);
            end
            @(posedge clk_i);
            #1;
            if (cycle - at_cycle != 50 || !d_response_valid_o ||
                    d_response_error_o !== expected_error)
                $fatal(1, "ERROR D response timing or status at cycle %0d",
                    cycle);
            read_data = d_response_read_data_o;
        end
    endtask

    task consume_i;
        begin
            @(negedge clk_i);
            i_response_ready_i = 1'b1;
            @(posedge clk_i);
            #1;
            i_response_ready_i = 1'b0;
            if (i_response_valid_o)
                $fatal(1, "ERROR I response did not retire");
        end
    endtask

    task consume_d;
        begin
            @(negedge clk_i);
            d_response_ready_i = 1'b1;
            @(posedge clk_i);
            #1;
            d_response_ready_i = 1'b0;
            if (d_response_valid_o)
                $fatal(1, "ERROR D response did not retire");
        end
    endtask

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b1;
        cycle = 0;
        i_request_valid_i = 1'b0;
        i_request_address_i = 0;
        i_response_ready_i = 1'b0;
        d_request_valid_i = 1'b0;
        d_request_write_i = 1'b0;
        d_request_address_i = 0;
        d_request_write_data_i = 0;
        d_request_byte_enable_i = 0;
        d_response_ready_i = 1'b0;
        repeat (2) @(posedge clk_i);
        #1;
        reset_i = 1'b0;

        send_i(32'h00000000, accepted);
        await_i(accepted, 1'b0, observed);
        if ($test$plusargs("CHECK_IMAGE")) begin
            if (observed === 128'd0)
                $fatal(1, "ERROR generated image was not loaded");
            consume_i;
            send_i(32'h00080000, accepted);
            await_i(accepted, 1'b0, observed);
            if (observed !== 128'd0)
                $fatal(1, "ERROR sparse image gap was not zero");
            consume_i;
            $display("PASS main memory generated image");
            $finish;
        end
        if (observed !== 128'd0)
            $fatal(1, "ERROR default memory was not zero");
        saved = observed;
        repeat (3) begin
            @(posedge clk_i);
            #1;
            if (!i_response_valid_o || i_response_read_data_o !== saved ||
                    i_request_ready_o)
                $fatal(1, "ERROR I response did not hold under backpressure");
        end
        consume_i;

        send_d(1'b1, 32'h00001000,
            128'hffeeddccbbaa99887766554433221101, 16'h00a5, accepted);
        await_d(accepted, 1'b0, observed);
        if (observed !== 128'd0)
            $fatal(1, "ERROR D write acknowledgement has read data");
        saved = d_response_read_data_o;
        repeat (3) begin
            @(posedge clk_i);
            #1;
            if (!d_response_valid_o || d_response_read_data_o !== saved ||
                    d_request_ready_o)
                $fatal(1, "ERROR D response did not hold under backpressure");
        end
        consume_d;
        send_i(32'h00001000, accepted);
        await_i(accepted, 1'b0, observed);
        if (observed !== 128'h00000000000000007700550000220001)
            $fatal(1, "ERROR byte mask or little-endian line layout");
        consume_i;

        send_d(1'b1, 32'h000ffff0,
            128'h0123456789abcdeffedcba9876543210, 16'hffff, accepted);
        await_d(accepted, 1'b0, observed);
        consume_d;
        send_i(32'h000ffff0, accepted);
        await_i(accepted, 1'b0, observed);
        if (observed !== 128'h0123456789abcdeffedcba9876543210)
            $fatal(1, "ERROR last valid line");
        consume_i;

        send_i(32'h00000001, accepted);
        await_i(accepted, 1'b1, observed);
        if (observed !== 128'd0)
            $fatal(1, "ERROR misaligned I response data");
        consume_i;
        send_i(32'h00100000, accepted);
        await_i(accepted, 1'b1, observed);
        consume_i;
        send_d(1'b1, 32'h00100000, {128{1'b1}}, 16'hffff, accepted);
        await_d(accepted, 1'b1, observed);
        consume_d;
        send_d(1'b1, 32'h00001001, {128{1'b1}}, 16'hffff, accepted);
        await_d(accepted, 1'b1, observed);
        consume_d;
        send_i(32'h00001000, accepted);
        await_i(accepted, 1'b0, observed);
        if (observed !== 128'h00000000000000007700550000220001)
            $fatal(1, "ERROR invalid write modified memory");
        consume_i;

        @(negedge clk_i);
        if (!i_request_ready_o || !d_request_ready_o)
            $fatal(1, "ERROR dual ports not ready");
        i_request_address_i = 32'h00002000;
        i_request_valid_i = 1'b1;
        d_request_write_i = 1'b1;
        d_request_address_i = 32'h00002000;
        d_request_write_data_i = 128'h112233445566778899aabbccddeeff00;
        d_request_byte_enable_i = 16'hffff;
        d_request_valid_i = 1'b1;
        @(posedge clk_i);
        #1;
        accepted = cycle;
        i_request_valid_i = 1'b0;
        d_request_valid_i = 1'b0;
        for (step = 1; step < 50; step = step + 1) begin
            @(posedge clk_i);
            #1;
            if (i_response_valid_o || d_response_valid_o)
                $fatal(1, "ERROR early parallel response");
        end
        @(posedge clk_i);
        #1;
        if (cycle - accepted != 50 || !i_response_valid_o ||
                !d_response_valid_o || i_response_error_o ||
                d_response_error_o ||
                i_response_read_data_o !==
                    128'h112233445566778899aabbccddeeff00)
            $fatal(1, "ERROR simultaneous write/read visibility");
        consume_i;
        consume_d;

        send_i(32'h00004000, accepted);
        send_d(1'b1, 32'h00004000,
            128'h0000000000000000000000000000005a, 16'h0001,
            accepted_other);
        repeat (49) @(posedge clk_i);
        #1;
        if (cycle - accepted != 50 || !i_response_valid_o ||
                i_response_read_data_o !== 128'd0 || d_response_valid_o)
            $fatal(1, "ERROR write became visible before completion");
        @(posedge clk_i);
        #1;
        if (cycle - accepted_other != 50 || !d_response_valid_o)
            $fatal(1, "ERROR later write completion timing");
        consume_i;
        consume_d;
        send_i(32'h00004000, accepted);
        await_i(accepted, 1'b0, observed);
        if (observed !== 128'h5a)
            $fatal(1, "ERROR completed write was not visible");
        consume_i;

        send_i(32'h00001000, accepted);
        send_d(1'b0, 32'h000ffff0, 128'd0, 16'd0, accepted_other);
        for (step = 1; step < 50; step = step + 1) begin
            @(posedge clk_i);
            #1;
            if (d_response_valid_o)
                $fatal(1, "ERROR early independent D response");
        end
        @(posedge clk_i);
        #1;
        if (cycle - accepted_other != 50 || !d_response_valid_o ||
                d_response_error_o || d_response_read_data_o !==
                    128'h0123456789abcdeffedcba9876543210 ||
                !i_response_valid_o || i_response_read_data_o !==
                    128'h00000000000000007700550000220001)
            $fatal(1, "ERROR independent I/D transactions");
        consume_i;
        consume_d;

        send_d(1'b1, 32'h00003000, {128{1'b1}}, 16'hffff, accepted);
        send_i(32'h00002000, accepted_other);
        repeat (25) @(posedge clk_i);
        #1;
        reset_i = 1'b1;
        @(posedge clk_i);
        #1;
        reset_i = 1'b0;
        repeat (30) @(posedge clk_i);
        #1;
        if (d_response_valid_o || i_response_valid_o ||
                !d_request_ready_o || !i_request_ready_o)
            $fatal(1, "ERROR reset did not cancel pending requests");
        send_i(32'h00003000, accepted);
        await_i(accepted, 1'b0, observed);
        if (observed !== 128'd0)
            $fatal(1, "ERROR canceled write modified memory");
        consume_i;
        send_i(32'h00001000, accepted);
        await_i(accepted, 1'b0, observed);
        if (observed !== 128'h00000000000000007700550000220001)
            $fatal(1, "ERROR reset erased committed memory");
        consume_i;

        $display("PASS main memory latency, ports, writes, bounds, reset");
        $finish;
    end
endmodule
