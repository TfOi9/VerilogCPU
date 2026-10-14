`timescale 1ns/1ps

module rv32_result_bypass_tb;

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
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH), .FALLTHROUGH(1)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .recover_i(recover_i),
        .source_lookup_tag_o(),
        .source_lookup_write_valid_i({SOURCE_COUNT{1'b0}}),
        .source_lookup_phys_i({(SOURCE_COUNT*PHYS_REG_ADDR_WIDTH){1'b0}}),
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

    reg [31:0] expected [0:SOURCE_COUNT*8-1];
    integer queue_head [0:SOURCE_COUNT-1];
    integer queue_tail [0:SOURCE_COUNT-1];
    integer queued [0:SOURCE_COUNT-1];
    reg [BE_WIDTH-1:0] held_valid;
    reg [(BE_WIDTH*32)-1:0] held_value;
    reg [SOURCE_COUNT-1:0] accepted;
    reg [31:0] random_state;
    integer token;
    integer chosen_source;
    integer completed;

    task tick;
        begin
            #5 clk_i = 1; #1 clk_i = 0; #1;
        end
    endtask
    initial begin
        #1000000; $fatal(1, "ERROR result bypass watchdog");
    end
    initial begin
        clk_i = 0; reset_i = 1; flush_i = 0; recover_i = 0;
        source_valid_i = 0; source_rob_tag_i = 0; source_value_i = 0;
        source_control_valid_i = 0; source_control_taken_i = 0;
        source_next_pc_i = 0; source_exception_valid_i = 0;
        source_exception_cause_i = 0; source_exception_tval_i = 0;
        completion_ready_i = 0; completion_accept_i = 0;
        completion_writes_rd_i = 0; completion_phys_i = 0;
        held_valid = 0; held_value = 0; random_state = 32'h193ac207;
        token = 1; completed = 0;
        for (source_index = 0; source_index < SOURCE_COUNT; source_index = source_index + 1) begin
            queued[source_index] = 0; queue_head[source_index] = 0;
            queue_tail[source_index] = 0;
        end
        repeat (3) tick(); reset_i = 0;
        for (cycle_index = 0; cycle_index < 3020; cycle_index = cycle_index + 1) begin
            random_state = {random_state[30:0], random_state[31] ^
                random_state[21] ^ random_state[1] ^ random_state[0]};
            recover_i = cycle_index < 3000 && (cycle_index % 97 == 11);
            flush_i = cycle_index < 3000 && (cycle_index % 131 == 17);
            completion_ready_i = (cycle_index >= 3000 || random_state[0]) ?
                {BE_WIDTH{1'b1}} : 0;
            completion_accept_i = random_state[BE_WIDTH +: BE_WIDTH];
            completion_writes_rd_i = random_state[2*BE_WIDTH +: BE_WIDTH];
            for (lane_index = 0; lane_index < BE_WIDTH; lane_index = lane_index + 1)
                completion_phys_i[lane_index*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] = lane_index + 1;
            if (flush_i) begin
                source_valid_i = 0; held_valid = 0;
                for (source_index = 0; source_index < SOURCE_COUNT; source_index = source_index + 1) begin
                    queued[source_index] = 0; queue_head[source_index] = 0;
                    queue_tail[source_index] = 0;
                end
            end
            for (source_index = 0; source_index < SOURCE_COUNT; source_index = source_index + 1)
                if (cycle_index < 3000 && !flush_i && !source_valid_i[source_index] &&
                        random_state[(source_index+2)%32]) begin
                    source_valid_i[source_index] = 1;
                    source_value_i[source_index*32 +: 32] = source_index*100000 + token;
                    source_rob_tag_i[source_index*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] = token;
                    source_exception_valid_i[source_index] = token % 13 == 0;
                    source_control_valid_i[source_index] = 1;
                    source_control_taken_i[source_index] = token % 2;
                    source_next_pc_i[source_index*32 +: 32] = token*4;
                    source_exception_cause_i[source_index*4 +: 4] = 5;
                    source_exception_tval_i[source_index*32 +: 32] = token*8;
                    token = token + 1;
                end
            #1;
            if (!flush_i && !recover_i)
                for (lane_index = 0; lane_index < BE_WIDTH; lane_index = lane_index + 1)
                    if (held_valid[lane_index] && (!completion_valid_o[lane_index] ||
                            completion_value_o[lane_index*32 +: 32] != held_value[lane_index*32 +: 32]))
                        $fatal(1, "ERROR bypass changed stalled completion");
            completion_accept_i = completion_accept_i & completion_valid_o & completion_ready_i;
            #1;
            accepted = source_valid_i & source_ready_o;
            for (source_index = 0; source_index < SOURCE_COUNT; source_index = source_index + 1)
                if (accepted[source_index]) begin
                    if (queued[source_index] >= 8) $fatal(1, "ERROR bypass scoreboard overflow");
                    expected[source_index*8 + queue_tail[source_index]] = source_value_i[source_index*32 +: 32];
                    queue_tail[source_index] = (queue_tail[source_index]+1)%8;
                    queued[source_index] = queued[source_index]+1;
                end
            for (lane_index = 0; lane_index < BE_WIDTH; lane_index = lane_index + 1) begin
                if (completion_valid_o[lane_index] && completion_ready_i[lane_index]) begin
                    chosen_source = completion_value_o[lane_index*32 +: 32]/100000;
                    if (chosen_source >= SOURCE_COUNT || queued[chosen_source] == 0 ||
                            expected[chosen_source*8+queue_head[chosen_source]] !== completion_value_o[lane_index*32 +: 32])
                        $fatal(1, "ERROR bypass lost reordered or duplicated result");
                    expected_source = completion_value_o[lane_index*32 +: 32] % 100000;
                    if (completion_tag_o[lane_index*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] !=
                            (expected_source & ((1<<ROB_TAG_WIDTH)-1)) ||
                            !completion_control_valid_o[lane_index] ||
                            completion_control_taken_o[lane_index] != (expected_source%2) ||
                            completion_next_pc_o[lane_index*32 +: 32] != expected_source*4 ||
                            completion_exception_valid_o[lane_index] != (expected_source%13 == 0) ||
                            completion_exception_cause_o[lane_index*4 +: 4] != 5 ||
                            completion_exception_tval_o[lane_index*32 +: 32] != expected_source*8)
                        $fatal(1, "ERROR bypass corrupted completion metadata");
                    queue_head[chosen_source] = (queue_head[chosen_source]+1)%8;
                    queued[chosen_source] = queued[chosen_source]-1;
                    completed = completed + 1;
                end
                if (writeback_valid_o[lane_index] !== (completion_valid_o[lane_index] &&
                        completion_ready_i[lane_index] && completion_accept_i[lane_index] &&
                        completion_writes_rd_i[lane_index] && !completion_exception_valid_o[lane_index]))
                    $fatal(1, "ERROR bypass writeback validation");
            end
            if (!recover_i) begin
                held_valid = completion_valid_o & ~completion_ready_i;
                held_value = completion_value_o;
            end
            tick(); source_valid_i = source_valid_i & ~accepted;
        end
        for (source_index = 0; source_index < SOURCE_COUNT; source_index = source_index + 1)
            if (queued[source_index] != 0) $fatal(1, "ERROR bypass did not drain");
        if (completed < 500) $fatal(1, "ERROR bypass coverage");
        $display("PASS rv32_result_bypass_tb width=%0d sources=%0d completed=%0d", BE_WIDTH, SOURCE_COUNT, completed);
        $finish;
    end
endmodule
