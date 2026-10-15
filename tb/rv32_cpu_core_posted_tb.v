`timescale 1ns/1ps

module rv32_cpu_core_posted_tb;
    parameter RESULT_FALLTHROUGH = 1;
    parameter FE_WIDTH = 4;
    parameter BE_WIDTH = 4;
    parameter RECOVERY_WIDTH = 4;
    parameter PHYS_REGS = 64;
    parameter ROB_ENTRIES = 32;
    localparam ROB_INDEX_WIDTH = address_width_for_count(ROB_ENTRIES);
    localparam ROB_TAG_WIDTH = ROB_INDEX_WIDTH + 2;
    function integer address_width_for_count;
        input integer count;
        integer remaining;
        begin
            remaining = count - 1;
            address_width_for_count = 0;
            while (remaining > 0) begin
                address_width_for_count = address_width_for_count + 1;
                remaining = remaining >> 1;
            end
            if (address_width_for_count < 1)
                address_width_for_count = 1;
        end
    endfunction
    reg clk;
    reg reset;
    wire i_flush;
    wire i_valid;
    wire i_ready;
    wire [31:0] i_pc;
    reg i_response_valid;
    wire i_response_ready;
    reg [31:0] i_response_pc;
    reg [127:0] i_response_line;
    wire d_valid;
    wire d_ready;
    wire d_write;
    wire [31:0] d_address;
    wire [31:0] d_write_data;
    wire [3:0] d_enable;
    wire d_mmio;
    reg d_response_valid;
    wire d_response_ready;
    reg [31:0] d_read_data;
    reg [31:0] instructions [0:8191];
    reg [7:0] memory [0:4095];
    reg i_pending;
    reg [31:0] pending_pc;
    integer i_delay;
    reg d_pending;
    integer d_delay;
    reg exit_pending;
    reg exit_responded;
    reg exit_retired;
    reg [31:0] random_state;
    integer seed;
    integer cycles;
    integer retired;
    integer trace_file;
    integer trace_result;
    reg [31:0] expected_pc;
    reg [31:0] expected_instruction;
    integer expected_writes;
    integer expected_rd;
    reg [31:0] expected_value;
    reg [31:0] expected_exit;
    reg [1023:0] program_path;
    reg [1023:0] trace_path;
    reg [1023:0] wave_path;
    integer lane;
    integer byte_index;
    integer init_index;
    integer integer_issues;
    integer writebacks;
    integer commits;
    integer branch_completions;
    integer sources;
    integer maximum_sources;
    reg full_issue_seen;
    reg full_writeback_seen;
    reg full_commit_seen;
    reg multiple_branches_seen;
    reg recovery_seen;
    reg late_response_seen;
    reg discarded_data_response_seen;
    reg stale_mdu_seen;
    reg partial_dispatch_seen;
    reg misaligned_exception_seen;
    integer exit_count;

    assign i_ready = !i_pending && !i_response_valid && random_state[1];
    assign d_ready = !d_pending && !d_response_valid && random_state[2];

    rv32_cpu_core #(.FE_WIDTH(FE_WIDTH), .BE_WIDTH(BE_WIDTH),
        .RECOVERY_WIDTH(RECOVERY_WIDTH), .POSTED_STORES(1), .RESULT_FALLTHROUGH(RESULT_FALLTHROUGH),
        .PHYS_REGS(PHYS_REGS), .ROB_ENTRIES(ROB_ENTRIES)) dut (
        .dcache_request_rob_tag_o(), .dcache_response_rob_tag_i(0),
        .dcache_request_id_o(), .dcache_response_id_i(2'd0),
        .clk_i(clk), .reset_i(reset), .icache_flush_o(i_flush),
        .icache_request_valid_o(i_valid), .icache_request_ready_i(i_ready),
        .icache_request_pc_o(i_pc), .icache_response_valid_i(i_response_valid),
        .icache_response_ready_o(i_response_ready),
        .icache_response_pc_i(i_response_pc),
        .icache_response_line_i(i_response_line), .icache_response_error_i(1'b0),
        .dcache_request_valid_o(d_valid), .dcache_request_ready_i(d_ready),
        .dcache_store_confirm_valid_i(1'b0), .dcache_store_confirm_id_i(2'd0),
        .dcache_store_confirm_rob_tag_i({ROB_TAG_WIDTH{1'b0}}),
        .dcache_request_irrevocable_i(d_valid && d_ready && d_write && !d_mmio),
        .dcache_request_write_o(d_write), .dcache_request_address_o(d_address),
        .dcache_request_write_data_o(d_write_data),
        .dcache_request_byte_enable_o(d_enable), .dcache_request_mmio_o(d_mmio),
        .dcache_response_valid_i(d_response_valid),
        .dcache_response_ready_o(d_response_ready),
        .dcache_response_read_data_i(d_read_data), .dcache_response_error_i(1'b0)
    );

    task fail;
        input [511:0] message;
        begin
            $display("FAIL core FE=%0d BE=%0d PHYS=%0d ROB=%0d seed=%0d cycle=%0d retired=%0d %0s",
                FE_WIDTH, BE_WIDTH, PHYS_REGS, ROB_ENTRIES, seed, cycles, retired, message);
            $stop;
        end
    endtask

    always #5 clk = ~clk;

    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        if (!reset) begin
            random_state <= {random_state[30:0], random_state[31] ^
                random_state[21] ^ random_state[1] ^ random_state[0]};
            cycles = cycles + 1;
            if (cycles > 100000)
                fail("cycle timeout");
            if (dut.fatal_reg)
                fail("unexpected precise error stop");
            if (i_response_valid && i_response_ready)
                i_response_valid <= 1'b0;
            if (i_valid && i_ready) begin
                i_pending <= 1'b1;
                pending_pc <= i_pc;
                i_delay <= 1 + {30'd0, random_state[4:3]};
            end
            if (i_pending) begin
                if (i_delay == 0 && !i_response_valid) begin
                    i_pending <= 1'b0;
                    i_response_valid <= 1'b1;
                    i_response_pc <= pending_pc;
                    for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                        i_response_line[byte_index*32 +: 32] <=
                            instructions[{19'd0, pending_pc[14:4], 2'b00} + byte_index];
                    if (dut.recover_busy)
                        late_response_seen = 1'b1;
                end else if (i_delay > 0)
                    i_delay <= i_delay - 1;
            end

            if (d_response_valid && d_response_ready) begin
                d_response_valid <= 1'b0;
                if (exit_pending)
                    exit_responded <= 1'b1;
            end
            if (d_valid && d_ready) begin
                d_pending <= 1'b1;
                d_delay <= 32 + {27'd0, random_state[9:5]};
                if (d_write && (!dut.commit_valid[0] ||
                        dut.lsq.request_rob_tag != dut.commit_tag[ROB_TAG_WIDTH-1:0]))
                    fail("store escaped ROB head");
                if (d_mmio) begin
                    if (!d_write || d_address != 32'h80000000 ||
                            d_enable != 4'hf || d_write_data != expected_exit)
                        fail("wrong-path or malformed MMIO store");
                    exit_pending <= 1'b1;
                    exit_count = exit_count + 1;
                    d_read_data <= 0;
                end else begin
                    if (d_address < 32'h10000 || d_address >= 32'h11000)
                        fail("invalid RAM address");
                    for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1) begin
                        if (d_write && d_enable[byte_index])
                            memory[d_address-32'h10000+byte_index] <=
                                d_write_data[byte_index*8 +: 8];
                        d_read_data[byte_index*8 +: 8] <=
                            memory[d_address-32'h10000+byte_index];
                    end
                end
            end
            if (d_pending) begin
                if (d_delay == 0) begin
                    d_pending <= 1'b0;
                    d_response_valid <= 1'b1;
                    if (dut.lsq.inflight_discard)
                        discarded_data_response_seen = 1'b1;
                    if (dut.recover_busy)
                        late_response_seen = 1'b1;
                end else
                    d_delay <= d_delay - 1;
            end

            if (dut.div_response_valid && dut.div_response_ready &&
                    (!dut.rob.entry_busy[dut.div_response_rob_tag[ROB_INDEX_WIDTH-1:0]] ||
                     dut.rob.entry_generation[dut.div_response_rob_tag[ROB_INDEX_WIDTH-1:0]] != dut.div_response_rob_tag[ROB_TAG_WIDTH-1:ROB_INDEX_WIDTH]))
                stale_mdu_seen = 1'b1;
            if (dut.mul_response_valid && dut.mul_response_ready &&
                    (!dut.rob.entry_busy[dut.mul_response_rob_tag[ROB_INDEX_WIDTH-1:0]] ||
                     dut.rob.entry_generation[dut.mul_response_rob_tag[ROB_INDEX_WIDTH-1:0]] != dut.mul_response_rob_tag[ROB_TAG_WIDTH-1:ROB_INDEX_WIDTH]))
                stale_mdu_seen = 1'b1;
            integer_issues = 0;
            writebacks = 0;
            commits = 0;
            branch_completions = 0;
            sources = 0;
            for (lane = 0; lane < BE_WIDTH+3; lane = lane + 1)
                if (dut.source_valid[lane]) sources = sources + 1;
            if (sources > maximum_sources) maximum_sources = sources;
            for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                if (dut.int_issue_valid[lane] && dut.int_issue_ready[lane])
                    integer_issues = integer_issues + 1;
                if (dut.writeback_valid[lane]) writebacks = writebacks + 1;
                if (dut.alu_response_valid[lane] && dut.alu_response_ready[lane] &&
                        dut.alu_response_control_valid[lane])
                    branch_completions = branch_completions + 1;
                if (dut.commit_fire[lane] && !exit_retired) begin
                    commits = commits + 1;
                    trace_result = $fscanf(trace_file, "%h %h %d %d %h\n",
                        expected_pc, expected_instruction, expected_writes,
                        expected_rd, expected_value);
                    if (trace_result != 5)
                        fail("extra retirement or malformed trace");
                    if (dut.rob.commit_pc_o[lane*32 +: 32] !== expected_pc ||
                            dut.rob.commit_instruction_o[lane*32 +: 32] !== expected_instruction ||
                            dut.commit_writes_rd[lane] !== (expected_writes != 0) ||
                            dut.commit_exception_valid[lane]) begin
                        $display("TRACE expected pc=%h instruction=%h actual pc=%h instruction=%h",
                            expected_pc, expected_instruction,
                            dut.rob.commit_pc_o[lane*32 +: 32],
                            dut.rob.commit_instruction_o[lane*32 +: 32]);
                        fail("retirement order or instruction mismatch");
                    end
                    if (expected_writes != 0 && (dut.commit_rd[lane*5 +: 5] != expected_rd[4:0] ||
                            dut.rob.commit_value_o[lane*32 +: 32] !== expected_value)) begin
                        $display("TRACE pc=%h rd=%0d expected=%h actual=%h", expected_pc,
                            expected_rd, expected_value, dut.rob.commit_value_o[lane*32 +: 32]);
                        fail("retirement register mismatch");
                    end
                    retired = retired + 1;
                    if (exit_responded && expected_instruction[6:0] == 7'h23 &&
                            expected_instruction[19:15] == 5'd31)
                        exit_retired = 1'b1;
                end
            end
            if (integer_issues == BE_WIDTH) full_issue_seen = 1'b1;
            if (writebacks == BE_WIDTH) full_writeback_seen = 1'b1;
            if (commits == BE_WIDTH) full_commit_seen = 1'b1;
            if (branch_completions >= 2) multiple_branches_seen = 1'b1;
            if (dut.recover_redirect_valid) recovery_seen = 1'b1;
            if ((dut.alu_response_exception_valid &
                    dut.alu_response_valid & dut.alu_response_ready) != 0)
                misaligned_exception_seen = 1'b1;
            if (dut.dispatch_fire && dut.dispatch_valid != {BE_WIDTH{1'b1}})
                partial_dispatch_seen = 1'b1;
            if (exit_retired) begin
                if (exit_count != 1 || !$feof(trace_file))
                    fail("exit count or missing retirements");
                if (!full_issue_seen || (RESULT_FALLTHROUGH == 0 && !full_writeback_seen) || !full_commit_seen ||
                        !recovery_seen || (RESULT_FALLTHROUGH == 0 && !misaligned_exception_seen) ||
                        (BE_WIDTH > 1 && !partial_dispatch_seen))
                    begin
                        $display("COVER issue=%0d wb=%0d commit=%0d recovery=%0d misalign=%0d partial=%0d",
                            full_issue_seen, full_writeback_seen, full_commit_seen,
                            recovery_seen, misaligned_exception_seen, partial_dispatch_seen);
                        fail("missing width or recovery coverage");
                    end
                if (RESULT_FALLTHROUGH == 0 && BE_WIDTH >= 2 && !multiple_branches_seen)
                    fail("missing concurrent branch completion");
                if (RESULT_FALLTHROUGH == 0 && FE_WIDTH == 4 && BE_WIDTH == 4 &&
                        (!discarded_data_response_seen || !stale_mdu_seen))
                    fail("missing discarded data or stale MDU response");
                $display("PASS core FE=%0d BE=%0d PHYS=%0d ROB=%0d seed=%0d cycles=%0d retired=%0d max_sources=%0d late_response=%0d discarded_data=%0d stale_mdu=%0d",
                    FE_WIDTH, BE_WIDTH, PHYS_REGS, ROB_ENTRIES, seed, cycles, retired, maximum_sources,
                    late_response_seen, discarded_data_response_seen, stale_mdu_seen);
                $fclose(trace_file);
                $finish;
            end
        end
    end

    /* verilator lint_on BLKSEQ */
    initial begin
        clk = 0;
        reset = 1;
        i_pending = 0;
        i_delay = 0;
        pending_pc = 0;
        i_response_valid = 0;
        i_response_pc = 0;
        i_response_line = 0;
        d_pending = 0;
        d_delay = 0;
        d_response_valid = 0;
        d_read_data = 0;
        exit_pending = 0;
        exit_responded = 0;
        exit_retired = 0;
        exit_count = 0;
        cycles = 0;
        retired = 0;
        maximum_sources = 0;
        full_issue_seen = 0;
        full_writeback_seen = 0;
        full_commit_seen = 0;
        multiple_branches_seen = 0;
        recovery_seen = 0;
        late_response_seen = 0;
        discarded_data_response_seen = 0;
        stale_mdu_seen = 0;
        partial_dispatch_seen = 0;
        misaligned_exception_seen = 0;
        seed = 1;
        if (!$value$plusargs("PROGRAM=%s", program_path) ||
                !$value$plusargs("TRACE=%s", trace_path) ||
                !$value$plusargs("EXPECTED=%d", expected_exit))
            fail("missing program, trace or expected result");
        if ($value$plusargs("SEED=%d", seed)) begin end
        random_state = seed;
        if ($value$plusargs("WAVE=%s", wave_path)) begin
            $dumpfile(wave_path);
            $dumpvars(0, rv32_cpu_core_posted_tb);
        end
        for (init_index = 0; init_index < 8192; init_index = init_index + 1)
            instructions[init_index] = 32'h0000006f;
        for (init_index = 0; init_index < 4096; init_index = init_index + 1)
            memory[init_index] = 0;
        $readmemh(program_path, instructions);
        trace_file = $fopen(trace_path, "r");
        if (trace_file == 0) fail("cannot open reference trace");
        repeat (4) @(negedge clk);
        reset = 0;
    end
endmodule
