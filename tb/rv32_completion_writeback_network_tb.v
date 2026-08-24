`timescale 1ns/1ps

module rv32_completion_writeback_network_tb;

    parameter BE_WIDTH = 1;
    parameter SOURCE_COUNT = BE_WIDTH + 2;
    parameter PHYS_REGS = 64;
    parameter PHYS_REG_ADDR_WIDTH = 6;
    parameter ROB_TAG_WIDTH = 7;

    reg clk_i;
    reg reset_i;
    reg flush_i;
    reg recover_i;
    reg [SOURCE_COUNT-1:0] source_valid_i;
    wire [SOURCE_COUNT-1:0] source_ready_o;
    reg [(SOURCE_COUNT*ROB_TAG_WIDTH)-1:0] source_rob_tag_i;
    reg [(SOURCE_COUNT*32)-1:0] source_value_i;
    reg [SOURCE_COUNT-1:0] source_control_valid_i;
    reg [SOURCE_COUNT-1:0] source_control_taken_i;
    reg [(SOURCE_COUNT*32)-1:0] source_next_pc_i;
    reg [SOURCE_COUNT-1:0] source_exception_valid_i;
    reg [(SOURCE_COUNT*4)-1:0] source_exception_cause_i;
    reg [(SOURCE_COUNT*32)-1:0] source_exception_tval_i;

    wire [BE_WIDTH-1:0] completion_valid_o;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] completion_tag_o;
    wire [(BE_WIDTH*32)-1:0] completion_value_o;
    wire [BE_WIDTH-1:0] completion_control_valid_o;
    wire [BE_WIDTH-1:0] completion_control_taken_o;
    wire [(BE_WIDTH*32)-1:0] completion_next_pc_o;
    wire [BE_WIDTH-1:0] completion_exception_valid_o;
    wire [(BE_WIDTH*4)-1:0] completion_exception_cause_o;
    wire [(BE_WIDTH*32)-1:0] completion_exception_tval_o;
    reg [BE_WIDTH-1:0] completion_ready_i;
    reg [BE_WIDTH-1:0] completion_accept_i;
    reg [BE_WIDTH-1:0] completion_writes_rd_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] completion_phys_i;

    wire [BE_WIDTH-1:0] writeback_valid_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] writeback_phys_o;
    wire [(BE_WIDTH*32)-1:0] writeback_value_o;

    integer test_count;
    integer error_count;
    integer source_index;
    integer lane_index;
    integer cycle_index;
    integer vector_file;
    integer vector_scan_count;
    integer vector_start;
    integer vector_mask;
    integer vector_count;
    integer vector_expected0;
    integer vector_expected1;
    integer vector_expected2;
    integer vector_expected3;
    integer expected_source;
    integer observed_count [0:SOURCE_COUNT-1];
    reg [SOURCE_COUNT-1:0] seen_sources;
    reg [1023:0] vector_file_name;

    rv32_completion_writeback_network #(
        .BE_WIDTH(BE_WIDTH),
        .SOURCE_COUNT(SOURCE_COUNT),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .recover_i(recover_i),
        .source_valid_i(source_valid_i),
        .source_ready_o(source_ready_o),
        .source_rob_tag_i(source_rob_tag_i),
        .source_value_i(source_value_i),
        .source_control_valid_i(source_control_valid_i),
        .source_control_taken_i(source_control_taken_i),
        .source_next_pc_i(source_next_pc_i),
        .source_exception_valid_i(source_exception_valid_i),
        .source_exception_cause_i(source_exception_cause_i),
        .source_exception_tval_i(source_exception_tval_i),
        .completion_valid_o(completion_valid_o),
        .completion_tag_o(completion_tag_o),
        .completion_value_o(completion_value_o),
        .completion_control_valid_o(completion_control_valid_o),
        .completion_control_taken_o(completion_control_taken_o),
        .completion_next_pc_o(completion_next_pc_o),
        .completion_exception_valid_o(completion_exception_valid_o),
        .completion_exception_cause_o(completion_exception_cause_o),
        .completion_exception_tval_o(completion_exception_tval_o),
        .completion_ready_i(completion_ready_i),
        .completion_accept_i(completion_accept_i),
        .completion_writes_rd_i(completion_writes_rd_i),
        .completion_phys_i(completion_phys_i),
        .writeback_valid_o(writeback_valid_o),
        .writeback_phys_o(writeback_phys_o),
        .writeback_value_o(writeback_value_o)
    );

    always #5 clk_i = ~clk_i;

    task check;
        input condition;
        input integer check_id;
        begin
            test_count = test_count + 1;
            if (!condition) begin
                error_count = error_count + 1;
                $display("FAIL check=%0d width=%0d sources=%0d time=%0t",
                    check_id, BE_WIDTH, SOURCE_COUNT, $time);
            end
        end
    endtask

    task clock_edge;
        begin
            @(posedge clk_i);
            #1;
        end
    endtask

    task clear_inputs;
        begin
            flush_i = 1'b0;
            recover_i = 1'b0;
            source_valid_i = {SOURCE_COUNT{1'b0}};
            source_rob_tag_i = {(SOURCE_COUNT*ROB_TAG_WIDTH){1'b0}};
            source_value_i = {(SOURCE_COUNT*32){1'b0}};
            source_control_valid_i = {SOURCE_COUNT{1'b0}};
            source_control_taken_i = {SOURCE_COUNT{1'b0}};
            source_next_pc_i = {(SOURCE_COUNT*32){1'b0}};
            source_exception_valid_i = {SOURCE_COUNT{1'b0}};
            source_exception_cause_i = {(SOURCE_COUNT*4){1'b0}};
            source_exception_tval_i = {(SOURCE_COUNT*32){1'b0}};
            completion_ready_i = {BE_WIDTH{1'b0}};
            completion_accept_i = {BE_WIDTH{1'b0}};
            completion_writes_rd_i = {BE_WIDTH{1'b0}};
            completion_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        end
    endtask

    task set_source_payloads;
        input integer value_base;
        begin
            source_rob_tag_i = {(SOURCE_COUNT*ROB_TAG_WIDTH){1'b0}};
            source_value_i = {(SOURCE_COUNT*32){1'b0}};
            source_control_valid_i = {SOURCE_COUNT{1'b0}};
            source_control_taken_i = {SOURCE_COUNT{1'b0}};
            source_next_pc_i = {(SOURCE_COUNT*32){1'b0}};
            source_exception_valid_i = {SOURCE_COUNT{1'b0}};
            source_exception_cause_i = {(SOURCE_COUNT*4){1'b0}};
            source_exception_tval_i = {(SOURCE_COUNT*32){1'b0}};
            for (source_index = 0; source_index < SOURCE_COUNT;
                    source_index = source_index + 1) begin
                source_rob_tag_i[
                    source_index*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] =
                    source_index + 1;
                source_value_i[source_index*32 +: 32] =
                    value_base + source_index;
                source_control_valid_i[source_index] = source_index[0];
                source_control_taken_i[source_index] =
                    (source_index & 2) != 0;
                source_next_pc_i[source_index*32 +: 32] =
                    32'h20000000 + source_index;
                source_exception_valid_i[source_index] =
                    source_index == SOURCE_COUNT - 1;
                source_exception_cause_i[source_index*4 +: 4] =
                    source_index[3:0];
                source_exception_tval_i[source_index*32 +: 32] =
                    32'h30000000 + source_index;
            end
        end
    endtask

    task reset_dut;
        begin
            clear_inputs;
            reset_i = 1'b1;
            clock_edge;
            reset_i = 1'b0;
            #1;
            check(completion_valid_o == {BE_WIDTH{1'b0}}, 1);
            check(writeback_valid_o == {BE_WIDTH{1'b0}}, 2);
            check(source_ready_o == {SOURCE_COUNT{1'b1}}, 3);
        end
    endtask

    task set_round_robin_start;
        input integer requested_start;
        begin
            reset_dut;
            completion_ready_i = {BE_WIDTH{1'b1}};
            set_source_payloads(32'h10000000);
            if (requested_start != 0) begin
                source_valid_i[requested_start - 1] = 1'b1;
                clock_edge;
                source_valid_i = {SOURCE_COUNT{1'b0}};
                clock_edge;
                check(completion_valid_o == {BE_WIDTH{1'b0}}, 10);
            end
            completion_ready_i = {BE_WIDTH{1'b0}};
        end
    endtask

    task check_expected_lane;
        input integer checked_lane;
        input integer checked_source;
        input integer value_base;
        begin
            check(completion_valid_o[checked_lane], 20 + checked_lane);
            check(completion_tag_o[
                checked_lane*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] ==
                checked_source + 1, 30 + checked_lane);
            check(completion_value_o[checked_lane*32 +: 32] ==
                value_base + checked_source, 40 + checked_lane);
            check(completion_control_valid_o[checked_lane] ==
                checked_source[0], 50 + checked_lane);
            check(completion_control_taken_o[checked_lane] ==
                ((checked_source & 2) != 0), 60 + checked_lane);
            check(completion_next_pc_o[checked_lane*32 +: 32] ==
                32'h20000000 + checked_source, 70 + checked_lane);
            check(completion_exception_valid_o[checked_lane] ==
                (checked_source == SOURCE_COUNT - 1),
                80 + checked_lane);
            check(completion_exception_cause_o[
                checked_lane*4 +: 4] == checked_source[3:0],
                90 + checked_lane);
            check(completion_exception_tval_o[
                checked_lane*32 +: 32] ==
                32'h30000000 + checked_source, 100 + checked_lane);
        end
    endtask

    task test_exhaustive_vectors;
        begin
            if (!$value$plusargs("VECTOR_FILE=%s", vector_file_name)) begin
                $display("FAIL rv32_completion_writeback_network missing VECTOR_FILE");
                $finish(1);
            end
            vector_file = $fopen(vector_file_name, "r");
            if (vector_file == 0) begin
                $display("FAIL rv32_completion_writeback_network cannot open vectors");
                $finish(1);
            end
            while (!$feof(vector_file)) begin
                vector_scan_count = $fscanf(vector_file,
                    "%d %d %d %d %d %d %d\n",
                    vector_start, vector_mask, vector_count,
                    vector_expected0, vector_expected1,
                    vector_expected2, vector_expected3);
                if (vector_scan_count == 7) begin
                    set_round_robin_start(vector_start);
                    set_source_payloads(32'h10000000);
                    source_valid_i = vector_mask[SOURCE_COUNT-1:0];
                    clock_edge;
                    source_valid_i = {SOURCE_COUNT{1'b0}};
                    #1;
                    for (lane_index = 0; lane_index < BE_WIDTH;
                            lane_index = lane_index + 1) begin
                        if (lane_index < vector_count) begin
                            case (lane_index)
                                0: expected_source = vector_expected0;
                                1: expected_source = vector_expected1;
                                2: expected_source = vector_expected2;
                                default: expected_source = vector_expected3;
                            endcase
                            check_expected_lane(lane_index,
                                expected_source, 32'h10000000);
                        end else begin
                            check(!completion_valid_o[lane_index],
                                110 + lane_index);
                        end
                    end
                    if (vector_count != 0) begin
                        check(source_ready_o == {SOURCE_COUNT{1'b0}}, 120);
                        clock_edge;
                        for (lane_index = 0; lane_index < vector_count;
                                lane_index = lane_index + 1) begin
                            case (lane_index)
                                0: expected_source = vector_expected0;
                                1: expected_source = vector_expected1;
                                2: expected_source = vector_expected2;
                                default: expected_source = vector_expected3;
                            endcase
                            check_expected_lane(lane_index,
                                expected_source, 32'h10000000);
                        end
                    end
                end else if (vector_scan_count != -1) begin
                    $display("FAIL malformed writeback vector line");
                    error_count = error_count + 1;
                end
            end
            $fclose(vector_file);
        end
    endtask

    task test_lossless_drain_and_fairness;
        begin
            reset_dut;
            set_source_payloads(32'h40000000);
            source_valid_i = {SOURCE_COUNT{1'b1}};
            clock_edge;
            source_valid_i = {SOURCE_COUNT{1'b0}};
            completion_ready_i = {BE_WIDTH{1'b1}};
            seen_sources = {SOURCE_COUNT{1'b0}};
            for (cycle_index = 0; cycle_index < SOURCE_COUNT + 1;
                    cycle_index = cycle_index + 1) begin
                for (lane_index = 0; lane_index < BE_WIDTH;
                        lane_index = lane_index + 1) begin
                    if (completion_valid_o[lane_index]) begin
                        expected_source = completion_tag_o[
                            lane_index*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] - 1;
                        check(!seen_sources[expected_source], 200);
                        seen_sources[expected_source] = 1'b1;
                    end
                end
                if (completion_valid_o == {BE_WIDTH{1'b0}}) begin
                    cycle_index = SOURCE_COUNT + 1;
                end else begin
                    clock_edge;
                end
            end
            check(seen_sources == {SOURCE_COUNT{1'b1}}, 201);

            reset_dut;
            completion_ready_i = {BE_WIDTH{1'b1}};
            set_source_payloads(32'h50000000);
            source_valid_i = {SOURCE_COUNT{1'b1}};
            for (source_index = 0; source_index < SOURCE_COUNT;
                    source_index = source_index + 1) begin
                observed_count[source_index] = 0;
            end
            for (cycle_index = 0; cycle_index < SOURCE_COUNT * 4 + 2;
                    cycle_index = cycle_index + 1) begin
                for (lane_index = 0; lane_index < BE_WIDTH;
                        lane_index = lane_index + 1) begin
                    if (completion_valid_o[lane_index]) begin
                        expected_source = completion_tag_o[
                            lane_index*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] - 1;
                        observed_count[expected_source] =
                            observed_count[expected_source] + 1;
                    end
                end
                clock_edge;
            end
            for (source_index = 0; source_index < SOURCE_COUNT;
                    source_index = source_index + 1) begin
                check(observed_count[source_index] != 0, 210 + source_index);
            end
            source_valid_i = {SOURCE_COUNT{1'b0}};
        end
    endtask

    task test_recovery_flush_and_writeback;
        begin
            reset_dut;
            set_source_payloads(32'h60000000);
            source_valid_i[0] = 1'b1;
            clock_edge;
            source_valid_i = {SOURCE_COUNT{1'b0}};
            check(completion_valid_o[0], 300);
            recover_i = 1'b1;
            #1;
            check(completion_valid_o == {BE_WIDTH{1'b0}} &&
                source_ready_o == {SOURCE_COUNT{1'b0}}, 301);
            clock_edge;
            recover_i = 1'b0;
            #1;
            check(completion_valid_o[0] &&
                (completion_value_o[31:0] == 32'h60000000), 302);
            flush_i = 1'b1;
            #1;
            check(completion_valid_o == {BE_WIDTH{1'b0}}, 303);
            clock_edge;
            flush_i = 1'b0;
            check(completion_valid_o == {BE_WIDTH{1'b0}}, 304);

            reset_dut;
            set_source_payloads(32'h70000000);
            source_exception_valid_i = {SOURCE_COUNT{1'b0}};
            source_valid_i = {SOURCE_COUNT{1'b0}};
            for (source_index = 0; source_index < BE_WIDTH;
                    source_index = source_index + 1) begin
                source_valid_i[source_index] = 1'b1;
            end
            clock_edge;
            source_valid_i = {SOURCE_COUNT{1'b0}};
            completion_ready_i = {BE_WIDTH{1'b1}};
            completion_accept_i = completion_valid_o;
            completion_writes_rd_i = completion_valid_o;
            for (lane_index = 0; lane_index < BE_WIDTH;
                    lane_index = lane_index + 1) begin
                completion_phys_i[
                    lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = 40 + lane_index;
            end
            #1;
            check(writeback_valid_o == completion_valid_o, 310);
            for (lane_index = 0; lane_index < BE_WIDTH;
                    lane_index = lane_index + 1) begin
                if (writeback_valid_o[lane_index]) begin
                    check(writeback_phys_o[
                        lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] == 40 + lane_index,
                        311 + lane_index);
                    check(writeback_value_o[lane_index*32 +: 32] ==
                        32'h70000000 + lane_index, 320 + lane_index);
                end
            end
            completion_accept_i[0] = 1'b0;
            #1;
            check(!writeback_valid_o[0], 330);
            completion_accept_i[0] = 1'b1;
            completion_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = 0;
            #1;
            check(!writeback_valid_o[0], 331);
            reset_dut;
            set_source_payloads(32'h71000000);
            source_exception_valid_i[0] = 1'b1;
            source_valid_i[0] = 1'b1;
            clock_edge;
            source_valid_i = {SOURCE_COUNT{1'b0}};
            completion_ready_i = {BE_WIDTH{1'b1}};
            completion_accept_i[0] = 1'b1;
            completion_writes_rd_i[0] = 1'b1;
            completion_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = 40;
            #1;
            check(!writeback_valid_o[0], 332);
        end
    endtask

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b0;
        test_count = 0;
        error_count = 0;
        clear_inputs;

        test_exhaustive_vectors;
        test_lossless_drain_and_fairness;
        test_recovery_flush_and_writeback;

        if (error_count != 0) begin
            $display("FAIL rv32_completion_writeback_network width=%0d sources=%0d tests=%0d errors=%0d",
                BE_WIDTH, SOURCE_COUNT, test_count, error_count);
            $finish(1);
        end
        $display("PASS rv32_completion_writeback_network width=%0d sources=%0d tests=%0d",
            BE_WIDTH, SOURCE_COUNT, test_count);
        $finish(0);
    end

    initial begin
        #5000000;
        $display("FAIL rv32_completion_writeback_network timeout");
        $finish(1);
    end

endmodule
