`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_reorder_buffer_tb;

    parameter ROB_ENTRIES = 32;
    parameter ROB_INDEX_WIDTH = 5;
    parameter ROB_GENERATION_WIDTH = 2;
    parameter ROB_TAG_WIDTH = ROB_INDEX_WIDTH + ROB_GENERATION_WIDTH;
    parameter BE_WIDTH = 1;
    parameter PHYS_REG_ADDR_WIDTH = 7;
    parameter LSQ_TAG_WIDTH = 6;

    reg clk_i;
    reg reset_i;
    reg [BE_WIDTH-1:0] alloc_valid_i;
    reg alloc_fire_i;
    reg [(BE_WIDTH*32)-1:0] alloc_pc_i;
    reg [(BE_WIDTH*32)-1:0] alloc_instruction_i;
    reg [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] alloc_op_i;
    reg [BE_WIDTH-1:0] alloc_writes_rd_i;
    reg [(BE_WIDTH*5)-1:0] alloc_rd_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] alloc_new_phys_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] alloc_old_phys_i;
    reg [(BE_WIDTH*32)-1:0] alloc_predicted_next_pc_i;
    reg [BE_WIDTH-1:0] alloc_lsq_valid_i;
    reg [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] alloc_lsq_tag_i;
    reg [BE_WIDTH-1:0] alloc_complete_i;
    reg [BE_WIDTH-1:0] alloc_exception_valid_i;
    reg [(BE_WIDTH*4)-1:0] alloc_exception_cause_i;
    reg [(BE_WIDTH*32)-1:0] alloc_exception_tval_i;
    wire alloc_ready_o;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] alloc_tag_o;
    wire [ROB_INDEX_WIDTH:0] occupancy_o;
    wire [ROB_INDEX_WIDTH-1:0] head_index_o;

    reg [BE_WIDTH-1:0] completion_valid_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] completion_tag_i;
    reg [(BE_WIDTH*32)-1:0] completion_value_i;
    reg [BE_WIDTH-1:0] completion_control_valid_i;
    reg [BE_WIDTH-1:0] completion_control_taken_i;
    reg [(BE_WIDTH*32)-1:0] completion_next_pc_i;
    reg [BE_WIDTH-1:0] completion_exception_valid_i;
    reg [(BE_WIDTH*4)-1:0] completion_exception_cause_i;
    reg [(BE_WIDTH*32)-1:0] completion_exception_tval_i;
    wire [BE_WIDTH-1:0] completion_ready_o;
    wire [BE_WIDTH-1:0] completion_accept_o;

    reg [BE_WIDTH-1:0] commit_ready_i;
    wire [BE_WIDTH-1:0] commit_valid_o;
    wire [BE_WIDTH-1:0] commit_fire_o;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] commit_tag_o;
    wire [(BE_WIDTH*32)-1:0] commit_pc_o;
    wire [(BE_WIDTH*32)-1:0] commit_instruction_o;
    wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] commit_op_o;
    wire [BE_WIDTH-1:0] commit_writes_rd_o;
    wire [(BE_WIDTH*5)-1:0] commit_rd_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] commit_new_phys_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] commit_old_phys_o;
    wire [(BE_WIDTH*32)-1:0] commit_value_o;
    wire [BE_WIDTH-1:0] commit_control_valid_o;
    wire [BE_WIDTH-1:0] commit_control_taken_o;
    wire [(BE_WIDTH*32)-1:0] commit_predicted_next_pc_o;
    wire [(BE_WIDTH*32)-1:0] commit_next_pc_o;
    wire [BE_WIDTH-1:0] commit_lsq_valid_o;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] commit_lsq_tag_o;
    wire [BE_WIDTH-1:0] commit_exception_valid_o;
    wire [(BE_WIDTH*4)-1:0] commit_exception_cause_o;
    wire [(BE_WIDTH*32)-1:0] commit_exception_tval_o;

    wire recover_busy_o;
    wire recover_redirect_valid_o;
    wire [31:0] recover_redirect_pc_o;
    wire [BE_WIDTH-1:0] rollback_valid_o;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_tag_o;
    wire [BE_WIDTH-1:0] rollback_writes_rd_o;
    wire [(BE_WIDTH*5)-1:0] rollback_rd_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rollback_new_phys_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rollback_old_phys_o;
    wire [BE_WIDTH-1:0] rollback_lsq_valid_o;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] rollback_lsq_tag_o;

    reg [ROB_TAG_WIDTH-1:0] saved_tags [0:ROB_ENTRIES-1];
    reg [31:0] reference_pc [0:4095];
    reg [ROB_GENERATION_WIDTH-1:0] reference_generation [0:ROB_ENTRIES-1];
    integer test_count;
    integer error_count;
    integer lane_index;
    integer item_index;
    integer cycle_index;
    integer bundle_count;
    integer ready_count;
    integer expected_fire_count;
    integer reference_head;
    integer reference_tail;
    integer reference_count;
    integer reference_slot;
    integer random_value;
    integer seed;
    integer rollback_seen;
    integer expected_rollback_index;
    integer vector_file;
    integer vector_scan_count;
    integer vector_ready_mask;
    integer vector_alloc_count;
    integer vector_base_pc;
    integer vector_occupancy;
    integer vector_commit_valid;
    integer vector_commit_fire;
    integer vector_commit_pc0;
    integer vector_commit_pc1;
    integer vector_commit_pc2;
    integer vector_commit_pc3;
    integer vector_alloc_tag0;
    integer vector_alloc_tag1;
    integer vector_alloc_tag2;
    integer vector_alloc_tag3;
    integer vector_expected_pc;
    integer vector_expected_tag;
    reg [1023:0] vector_file_name;
    reg [ROB_TAG_WIDTH-1:0] first_tag;
    reg [ROB_TAG_WIDTH-1:0] reused_tag;

    rv32_reorder_buffer #(
        .ROB_ENTRIES(ROB_ENTRIES),
        .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_GENERATION_WIDTH(ROB_GENERATION_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH),
        .BE_WIDTH(BE_WIDTH),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .LSQ_TAG_WIDTH(LSQ_TAG_WIDTH)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .alloc_valid_i(alloc_valid_i),
        .alloc_fire_i(alloc_fire_i),
        .alloc_pc_i(alloc_pc_i),
        .alloc_instruction_i(alloc_instruction_i),
        .alloc_op_i(alloc_op_i),
        .alloc_writes_rd_i(alloc_writes_rd_i),
        .alloc_rd_i(alloc_rd_i),
        .alloc_new_phys_i(alloc_new_phys_i),
        .alloc_old_phys_i(alloc_old_phys_i),
        .alloc_predicted_next_pc_i(alloc_predicted_next_pc_i),
        .alloc_lsq_valid_i(alloc_lsq_valid_i),
        .alloc_lsq_tag_i(alloc_lsq_tag_i),
        .alloc_complete_i(alloc_complete_i),
        .alloc_exception_valid_i(alloc_exception_valid_i),
        .alloc_exception_cause_i(alloc_exception_cause_i),
        .alloc_exception_tval_i(alloc_exception_tval_i),
        .alloc_ready_o(alloc_ready_o),
        .alloc_tag_o(alloc_tag_o),
        .occupancy_o(occupancy_o),
        .head_index_o(head_index_o),
        .completion_valid_i(completion_valid_i),
        .completion_tag_i(completion_tag_i),
        .completion_value_i(completion_value_i),
        .completion_control_valid_i(completion_control_valid_i),
        .completion_control_taken_i(completion_control_taken_i),
        .completion_next_pc_i(completion_next_pc_i),
        .completion_exception_valid_i(completion_exception_valid_i),
        .completion_exception_cause_i(completion_exception_cause_i),
        .completion_exception_tval_i(completion_exception_tval_i),
        .completion_ready_o(completion_ready_o),
        .completion_accept_o(completion_accept_o),
        .commit_ready_i(commit_ready_i),
        .commit_valid_o(commit_valid_o),
        .commit_fire_o(commit_fire_o),
        .commit_tag_o(commit_tag_o),
        .commit_pc_o(commit_pc_o),
        .commit_instruction_o(commit_instruction_o),
        .commit_op_o(commit_op_o),
        .commit_writes_rd_o(commit_writes_rd_o),
        .commit_rd_o(commit_rd_o),
        .commit_new_phys_o(commit_new_phys_o),
        .commit_old_phys_o(commit_old_phys_o),
        .commit_value_o(commit_value_o),
        .commit_control_valid_o(commit_control_valid_o),
        .commit_control_taken_o(commit_control_taken_o),
        .commit_predicted_next_pc_o(commit_predicted_next_pc_o),
        .commit_next_pc_o(commit_next_pc_o),
        .commit_lsq_valid_o(commit_lsq_valid_o),
        .commit_lsq_tag_o(commit_lsq_tag_o),
        .commit_exception_valid_o(commit_exception_valid_o),
        .commit_exception_cause_o(commit_exception_cause_o),
        .commit_exception_tval_o(commit_exception_tval_o),
        .recover_busy_o(recover_busy_o),
        .recover_redirect_valid_o(recover_redirect_valid_o),
        .recover_redirect_pc_o(recover_redirect_pc_o),
        .rollback_valid_o(rollback_valid_o),
        .rollback_tag_o(rollback_tag_o),
        .rollback_writes_rd_o(rollback_writes_rd_o),
        .rollback_rd_o(rollback_rd_o),
        .rollback_new_phys_o(rollback_new_phys_o),
        .rollback_old_phys_o(rollback_old_phys_o),
        .rollback_lsq_valid_o(rollback_lsq_valid_o),
        .rollback_lsq_tag_o(rollback_lsq_tag_o)
    );

    always #5 clk_i = ~clk_i;

    task check;
        input condition;
        input integer check_id;
        begin
            test_count = test_count + 1;
            if (!condition) begin
                error_count = error_count + 1;
                $display("FAIL check=%0d entries=%0d width=%0d time=%0t",
                    check_id, ROB_ENTRIES, BE_WIDTH, $time);
            end
        end
    endtask

    task clear_inputs;
        begin
            alloc_valid_i = {BE_WIDTH{1'b0}};
            alloc_fire_i = 1'b0;
            alloc_pc_i = {(BE_WIDTH*32){1'b0}};
            alloc_instruction_i = {(BE_WIDTH*32){1'b0}};
            alloc_op_i = {(BE_WIDTH*`RV32_OP_WIDTH){1'b0}};
            alloc_writes_rd_i = {BE_WIDTH{1'b0}};
            alloc_rd_i = {(BE_WIDTH*5){1'b0}};
            alloc_new_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            alloc_old_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            alloc_predicted_next_pc_i = {(BE_WIDTH*32){1'b0}};
            alloc_lsq_valid_i = {BE_WIDTH{1'b0}};
            alloc_lsq_tag_i = {(BE_WIDTH*LSQ_TAG_WIDTH){1'b0}};
            alloc_complete_i = {BE_WIDTH{1'b0}};
            alloc_exception_valid_i = {BE_WIDTH{1'b0}};
            alloc_exception_cause_i = {(BE_WIDTH*4){1'b0}};
            alloc_exception_tval_i = {(BE_WIDTH*32){1'b0}};
            completion_valid_i = {BE_WIDTH{1'b0}};
            completion_tag_i = {(BE_WIDTH*ROB_TAG_WIDTH){1'b0}};
            completion_value_i = {(BE_WIDTH*32){1'b0}};
            completion_control_valid_i = {BE_WIDTH{1'b0}};
            completion_control_taken_i = {BE_WIDTH{1'b0}};
            completion_next_pc_i = {(BE_WIDTH*32){1'b0}};
            completion_exception_valid_i = {BE_WIDTH{1'b0}};
            completion_exception_cause_i = {(BE_WIDTH*4){1'b0}};
            completion_exception_tval_i = {(BE_WIDTH*32){1'b0}};
            commit_ready_i = {BE_WIDTH{1'b0}};
        end
    endtask

    task clock_edge;
        begin
            @(posedge clk_i);
            #1;
        end
    endtask

    task reset_dut;
        begin
            clear_inputs;
            reset_i = 1'b1;
            clock_edge;
            clock_edge;
            reset_i = 1'b0;
            #1;
            check(occupancy_o == 0, 1);
            check(alloc_ready_o == 1'b1, 2);
            check(commit_valid_o == {BE_WIDTH{1'b0}}, 3);
            check(completion_ready_o == {BE_WIDTH{1'b1}}, 4);
            check(!recover_busy_o && !recover_redirect_valid_o, 5);
            check(head_index_o == 0, 6);
        end
    endtask

    task prepare_allocation;
        input integer count;
        input integer base_pc;
        input complete_value;
        begin
            alloc_valid_i = {BE_WIDTH{1'b0}};
            alloc_pc_i = {(BE_WIDTH*32){1'b0}};
            alloc_instruction_i = {(BE_WIDTH*32){1'b0}};
            alloc_op_i = {(BE_WIDTH*`RV32_OP_WIDTH){1'b0}};
            alloc_writes_rd_i = {BE_WIDTH{1'b0}};
            alloc_rd_i = {(BE_WIDTH*5){1'b0}};
            alloc_new_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            alloc_old_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            alloc_predicted_next_pc_i = {(BE_WIDTH*32){1'b0}};
            alloc_lsq_valid_i = {BE_WIDTH{1'b0}};
            alloc_lsq_tag_i = {(BE_WIDTH*LSQ_TAG_WIDTH){1'b0}};
            alloc_complete_i = {BE_WIDTH{1'b0}};
            for (lane_index = 0; lane_index < count;
                    lane_index = lane_index + 1) begin
                alloc_valid_i[lane_index] = 1'b1;
                alloc_pc_i[lane_index*32 +: 32] = base_pc + lane_index*4;
                alloc_instruction_i[lane_index*32 +: 32] =
                    32'h10000000 + base_pc + lane_index;
                alloc_op_i[lane_index*`RV32_OP_WIDTH +:
                    `RV32_OP_WIDTH] = `RV32_OP_ADD;
                alloc_writes_rd_i[lane_index] = 1'b1;
                alloc_rd_i[lane_index*5 +: 5] = lane_index + 1;
                alloc_new_phys_i[
                    lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = lane_index + 32;
                alloc_old_phys_i[
                    lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = lane_index + 1;
                alloc_lsq_valid_i[lane_index] = lane_index[0];
                alloc_lsq_tag_i[lane_index*LSQ_TAG_WIDTH +:
                    LSQ_TAG_WIDTH] = lane_index + 3;
                alloc_complete_i[lane_index] = complete_value;
            end
            alloc_fire_i = 1'b1;
        end
    endtask

    task allocate_one;
        input integer pc_value;
        input complete_value;
        begin
            prepare_allocation(1, pc_value, complete_value);
            #1;
            check(alloc_ready_o, 10);
            saved_tags[item_index] = alloc_tag_o[ROB_TAG_WIDTH-1:0];
            clock_edge;
            alloc_fire_i = 1'b0;
            alloc_valid_i = {BE_WIDTH{1'b0}};
        end
    endtask

    task test_basic_and_completion;
        begin
            reset_dut;
            commit_ready_i = {BE_WIDTH{1'b0}};
            prepare_allocation(BE_WIDTH, 32'h1000, 1'b1);
            #1;
            for (lane_index = 0; lane_index < BE_WIDTH;
                    lane_index = lane_index + 1) begin
                check(alloc_tag_o[lane_index*ROB_TAG_WIDTH +:
                    ROB_INDEX_WIDTH] == lane_index, 20 + lane_index);
            end
            clock_edge;
            alloc_fire_i = 1'b0;
            alloc_valid_i = {BE_WIDTH{1'b0}};
            #1;
            check(commit_valid_o == {BE_WIDTH{1'b1}}, 30);
            for (lane_index = 0; lane_index < BE_WIDTH;
                    lane_index = lane_index + 1) begin
                check(commit_pc_o[lane_index*32 +: 32] ==
                    32'h1000 + lane_index*4, 31 + lane_index);
                check(commit_rd_o[lane_index*5 +: 5] == lane_index + 1,
                    40 + lane_index);
            end

            commit_ready_i = {BE_WIDTH{1'b0}};
            commit_ready_i[0] = 1'b1;
            if (BE_WIDTH > 2) begin
                commit_ready_i[2] = 1'b1;
            end
            #1;
            check(commit_fire_o[0] == 1'b1, 50);
            if (BE_WIDTH > 1) begin
                check(commit_fire_o[BE_WIDTH-1:1] ==
                    {(BE_WIDTH-1){1'b0}}, 51);
            end
            clock_edge;
            commit_ready_i = {BE_WIDTH{1'b1}};
            clock_edge;
            clear_inputs;
            #1;
            check(occupancy_o == 0, 52);
            check(head_index_o == BE_WIDTH, 521);

            item_index = 0;
            allocate_one(32'h2000, 1'b0);
            first_tag = saved_tags[0];
            #1;
            check(commit_valid_o == {BE_WIDTH{1'b0}}, 53);
            completion_valid_i[0] = 1'b1;
            completion_tag_i[ROB_TAG_WIDTH-1:0] = first_tag;
            completion_value_i[31:0] = 32'hdeadbeef;
            completion_exception_valid_i[0] = 1'b1;
            completion_exception_cause_i[3:0] = 4'd5;
            completion_exception_tval_i[31:0] = 32'hbad00000;
            #1;
            check(completion_accept_o[0], 54);
            check(!commit_valid_o[0], 55);
            clock_edge;
            completion_valid_i = {BE_WIDTH{1'b0}};
            #1;
            check(commit_valid_o[0], 56);
            check(commit_value_o[31:0] == 32'hdeadbeef, 57);
            check(commit_exception_valid_o[0] &&
                (commit_exception_cause_o[3:0] == 4'd5) &&
                (commit_exception_tval_o[31:0] == 32'hbad00000), 58);
            commit_ready_i = {BE_WIDTH{1'b1}};
            clock_edge;
            clear_inputs;
        end
    endtask

    task test_full_wrap_and_generation;
        begin
            reset_dut;
            commit_ready_i = {BE_WIDTH{1'b0}};
            item_index = 0;
            allocate_one(32'h3000, 1'b0);
            first_tag = saved_tags[0];
            completion_valid_i[0] = 1'b1;
            completion_tag_i[ROB_TAG_WIDTH-1:0] = first_tag;
            #1;
            check(completion_accept_o[0], 70);
            clock_edge;
            completion_valid_i = {BE_WIDTH{1'b0}};
            commit_ready_i = {BE_WIDTH{1'b1}};
            clock_edge;
            commit_ready_i = {BE_WIDTH{1'b0}};

            for (item_index = 1; item_index < ROB_ENTRIES;
                    item_index = item_index + 1) begin
                allocate_one(32'h3000 + item_index*4, 1'b1);
                commit_ready_i = {BE_WIDTH{1'b1}};
                clock_edge;
                commit_ready_i = {BE_WIDTH{1'b0}};
            end
            check(occupancy_o == 0, 71);
            item_index = 0;
            allocate_one(32'h4000, 1'b0);
            reused_tag = saved_tags[0];
            check(first_tag[ROB_INDEX_WIDTH-1:0] ==
                reused_tag[ROB_INDEX_WIDTH-1:0], 72);
            check(first_tag[ROB_TAG_WIDTH-1:ROB_INDEX_WIDTH] !=
                reused_tag[ROB_TAG_WIDTH-1:ROB_INDEX_WIDTH], 73);
            completion_valid_i[0] = 1'b1;
            completion_tag_i[ROB_TAG_WIDTH-1:0] = first_tag;
            #1;
            check(completion_ready_o[0] && !completion_accept_o[0], 74);
            clock_edge;
            completion_tag_i[ROB_TAG_WIDTH-1:0] = reused_tag;
            #1;
            check(completion_accept_o[0], 75);
            clock_edge;
            clear_inputs;

            reset_dut;
            commit_ready_i = {BE_WIDTH{1'b0}};
            for (item_index = 0; item_index < ROB_ENTRIES;
                    item_index = item_index + 1) begin
                allocate_one(32'h5000 + item_index*4, 1'b0);
            end
            prepare_allocation(1, 32'h6000, 1'b0);
            #1;
            check(!alloc_ready_o, 76);
            alloc_fire_i = 1'b0;
            alloc_valid_i = {BE_WIDTH{1'b0}};
            reset_i = 1'b1;
            clock_edge;
            reset_i = 1'b0;
            clear_inputs;
        end
    endtask

    task test_recovery;
        integer initial_younger;
        integer total_entries;
        begin
            reset_dut;
            commit_ready_i = {BE_WIDTH{1'b0}};
            item_index = 0;
            allocate_one(32'h7000, 1'b0);
            item_index = 1;
            allocate_one(32'h7004, 1'b0);
            alloc_predicted_next_pc_i[31:0] = 32'h7100;
            initial_younger = BE_WIDTH;
            for (item_index = 2; item_index < 2 + initial_younger;
                    item_index = item_index + 1) begin
                allocate_one(32'h7000 + item_index*4, 1'b0);
            end
            total_entries = 2 + initial_younger;

            prepare_allocation(1, 32'h7800, 1'b0);
            saved_tags[total_entries] = alloc_tag_o[ROB_TAG_WIDTH-1:0];
            alloc_fire_i = 1'b1;
            completion_valid_i[0] = 1'b1;
            completion_tag_i[ROB_TAG_WIDTH-1:0] = saved_tags[1];
            completion_control_valid_i[0] = 1'b1;
            completion_control_taken_i[0] = 1'b1;
            completion_next_pc_i[31:0] = 32'h7200;
            if (BE_WIDTH > 1) begin
                completion_valid_i[1] = 1'b1;
                completion_tag_i[ROB_TAG_WIDTH +: ROB_TAG_WIDTH] =
                    saved_tags[2];
                completion_control_valid_i[1] = 1'b1;
                completion_control_taken_i[1] = 1'b1;
                completion_next_pc_i[63:32] = 32'h7300;
            end
            #1;
            check(alloc_ready_o && completion_accept_o[0], 90);
            clock_edge;
            alloc_fire_i = 1'b0;
            alloc_valid_i = {BE_WIDTH{1'b0}};
            completion_valid_i = {BE_WIDTH{1'b0}};
            #1;
            check(recover_busy_o && recover_redirect_valid_o, 91);
            check(recover_redirect_pc_o == 32'h7200, 92);
            check(completion_ready_o == {BE_WIDTH{1'b0}}, 93);
            check(commit_valid_o == {BE_WIDTH{1'b0}}, 94);

            total_entries = total_entries + 1;
            rollback_seen = 0;
            expected_rollback_index = total_entries - 1;
            while (recover_busy_o) begin
                for (lane_index = 0; lane_index < BE_WIDTH;
                        lane_index = lane_index + 1) begin
                    if (rollback_valid_o[lane_index]) begin
                        check(rollback_tag_o[
                            lane_index*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] ==
                            saved_tags[expected_rollback_index],
                            100 + rollback_seen);
                        expected_rollback_index =
                            expected_rollback_index - 1;
                        rollback_seen = rollback_seen + 1;
                    end
                end
                clock_edge;
            end
            check(rollback_seen == total_entries - 2, 120);
            check(occupancy_o == 2, 121);
            check(!recover_redirect_valid_o, 122);
            completion_valid_i[0] = 1'b1;
            completion_tag_i[ROB_TAG_WIDTH-1:0] = saved_tags[2];
            #1;
            check(completion_ready_o[0] && !completion_accept_o[0], 123);
            clock_edge;
            clear_inputs;

            reset_dut;
            item_index = 0;
            allocate_one(32'h7c00, 1'b0);
            for (item_index = 1; item_index <= BE_WIDTH;
                    item_index = item_index + 1) begin
                allocate_one(32'h7c00 + item_index*4, 1'b0);
            end
            completion_valid_i[0] = 1'b1;
            completion_tag_i[ROB_TAG_WIDTH-1:0] = saved_tags[0];
            completion_control_valid_i[0] = 1'b1;
            completion_next_pc_i[31:0] = 32'h7d00;
            clock_edge;
            completion_valid_i = {BE_WIDTH{1'b0}};
            #1;
            check(recover_busy_o &&
                (rollback_valid_o == {BE_WIDTH{1'b1}}), 124);
            clock_edge;
            check(!recover_busy_o && (occupancy_o == 1), 125);
            clear_inputs;

            reset_dut;
            item_index = 0;
            allocate_one(32'h8000, 1'b0);
            completion_valid_i[0] = 1'b1;
            completion_tag_i[ROB_TAG_WIDTH-1:0] = saved_tags[0];
            completion_control_valid_i[0] = 1'b1;
            completion_next_pc_i[31:0] = 32'h8100;
            clock_edge;
            completion_valid_i = {BE_WIDTH{1'b0}};
            #1;
            check(recover_busy_o && (rollback_valid_o == 0), 126);
            clock_edge;
            check(!recover_busy_o && (occupancy_o == 1), 127);
            clear_inputs;
        end
    endtask

    task test_random_reference;
        begin
            reset_dut;
            reference_head = 0;
            reference_tail = 0;
            reference_count = 0;
            for (item_index = 0; item_index < ROB_ENTRIES;
                    item_index = item_index + 1) begin
                reference_generation[item_index] =
                    {ROB_GENERATION_WIDTH{1'b0}};
            end
            seed = 32'h524f4239 ^ ROB_ENTRIES ^ BE_WIDTH;

            for (cycle_index = 0; cycle_index < 400;
                    cycle_index = cycle_index + 1) begin
                clear_inputs;
                random_value = $random(seed);
                ready_count = (random_value & 32'h7fffffff) %
                    (BE_WIDTH + 1);
                for (lane_index = 0; lane_index < ready_count;
                        lane_index = lane_index + 1) begin
                    commit_ready_i[lane_index] = 1'b1;
                end

                random_value = $random(seed);
                bundle_count = (random_value & 32'h7fffffff) %
                    (BE_WIDTH + 1);
                if (bundle_count > ROB_ENTRIES - reference_count) begin
                    bundle_count = ROB_ENTRIES - reference_count;
                end
                prepare_allocation(bundle_count,
                    32'h9000 + cycle_index*16, 1'b1);
                alloc_fire_i = bundle_count != 0;
                #1;

                expected_fire_count = ready_count;
                if (expected_fire_count > BE_WIDTH) begin
                    expected_fire_count = BE_WIDTH;
                end
                if (expected_fire_count > reference_count) begin
                    expected_fire_count = reference_count;
                end
                for (lane_index = 0; lane_index < BE_WIDTH;
                        lane_index = lane_index + 1) begin
                    check(commit_valid_o[lane_index] ==
                        (lane_index < reference_count), 200);
                    check(commit_fire_o[lane_index] ==
                        (lane_index < expected_fire_count), 201);
                    if (lane_index < reference_count) begin
                        check(commit_pc_o[lane_index*32 +: 32] ==
                            reference_pc[reference_head + lane_index], 202);
                    end
                end
                check(occupancy_o == reference_count, 203);
                check(alloc_ready_o, 204);
                for (lane_index = 0; lane_index < bundle_count;
                        lane_index = lane_index + 1) begin
                    reference_slot = (reference_tail + lane_index) &
                        (ROB_ENTRIES - 1);
                    check(alloc_tag_o[lane_index*ROB_TAG_WIDTH +:
                        ROB_TAG_WIDTH] == {
                        reference_generation[reference_slot],
                        reference_slot[ROB_INDEX_WIDTH-1:0]}, 205);
                end

                clock_edge;
                reference_head = reference_head + expected_fire_count;
                reference_count = reference_count - expected_fire_count;
                for (lane_index = 0; lane_index < bundle_count;
                        lane_index = lane_index + 1) begin
                    reference_pc[reference_head + reference_count +
                        lane_index] = 32'h9000 + cycle_index*16 +
                        lane_index*4;
                    reference_slot = (reference_tail + lane_index) &
                        (ROB_ENTRIES - 1);
                    reference_generation[reference_slot] =
                        reference_generation[reference_slot] + 1'b1;
                end
                reference_tail = (reference_tail + bundle_count) &
                    (ROB_ENTRIES - 1);
                reference_count = reference_count + bundle_count;

                if ((reference_head > 2048) && (reference_count < 1024)) begin
                    for (item_index = 0; item_index < reference_count;
                            item_index = item_index + 1) begin
                        reference_pc[item_index] =
                            reference_pc[reference_head + item_index];
                    end
                    reference_head = 0;
                end
            end
            clear_inputs;
        end
    endtask

    task test_software_reference_vectors;
        begin : vector_test_body
            if (!$value$plusargs("VECTOR_FILE=%s", vector_file_name)) begin
                $display("FAIL missing ROB VECTOR_FILE plusarg");
                error_count = error_count + 1;
                disable vector_test_body;
            end
            vector_file = $fopen(vector_file_name, "r");
            if (vector_file == 0) begin
                $display("FAIL cannot open ROB vector file %0s",
                    vector_file_name);
                error_count = error_count + 1;
                disable vector_test_body;
            end

            reset_dut;
            while (!$feof(vector_file)) begin
                vector_scan_count = $fscanf(vector_file,
                    "%h %d %h %d %h %h %h %h %h %h %h %h %h %h\n",
                    vector_ready_mask, vector_alloc_count, vector_base_pc,
                    vector_occupancy, vector_commit_valid,
                    vector_commit_fire, vector_commit_pc0,
                    vector_commit_pc1, vector_commit_pc2,
                    vector_commit_pc3, vector_alloc_tag0,
                    vector_alloc_tag1, vector_alloc_tag2,
                    vector_alloc_tag3);
                if (vector_scan_count == 14) begin
                    clear_inputs;
                    commit_ready_i = vector_ready_mask[BE_WIDTH-1:0];
                    prepare_allocation(vector_alloc_count,
                        vector_base_pc, 1'b1);
                    alloc_fire_i = vector_alloc_count != 0;
                    #1;
                    check(occupancy_o == vector_occupancy, 300);
                    check(commit_valid_o ==
                        vector_commit_valid[BE_WIDTH-1:0], 301);
                    check(commit_fire_o ==
                        vector_commit_fire[BE_WIDTH-1:0], 302);
                    check(alloc_ready_o, 303);
                    for (lane_index = 0; lane_index < BE_WIDTH;
                            lane_index = lane_index + 1) begin
                        case (lane_index)
                            0: begin
                                vector_expected_pc = vector_commit_pc0;
                                vector_expected_tag = vector_alloc_tag0;
                            end
                            1: begin
                                vector_expected_pc = vector_commit_pc1;
                                vector_expected_tag = vector_alloc_tag1;
                            end
                            2: begin
                                vector_expected_pc = vector_commit_pc2;
                                vector_expected_tag = vector_alloc_tag2;
                            end
                            default: begin
                                vector_expected_pc = vector_commit_pc3;
                                vector_expected_tag = vector_alloc_tag3;
                            end
                        endcase
                        if (commit_valid_o[lane_index]) begin
                            check(commit_pc_o[lane_index*32 +: 32] ==
                                vector_expected_pc, 304);
                        end
                        if (lane_index < vector_alloc_count) begin
                            check(alloc_tag_o[
                                lane_index*ROB_TAG_WIDTH +:
                                ROB_TAG_WIDTH] == vector_expected_tag,
                                305);
                        end
                    end
                    clock_edge;
                end else if (vector_scan_count != -1) begin
                    $display("FAIL malformed ROB vector line");
                    error_count = error_count + 1;
                end
            end
            $fclose(vector_file);
            clear_inputs;
        end
    endtask

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b0;
        test_count = 0;
        error_count = 0;
        clear_inputs;

        test_basic_and_completion;
        test_full_wrap_and_generation;
        test_recovery;
        test_random_reference;
        test_software_reference_vectors;

        if (error_count != 0) begin
            $display("FAIL rv32_reorder_buffer entries=%0d width=%0d tests=%0d errors=%0d",
                ROB_ENTRIES, BE_WIDTH, test_count, error_count);
            $finish(1);
        end
        $display("PASS rv32_reorder_buffer entries=%0d width=%0d tests=%0d",
            ROB_ENTRIES, BE_WIDTH, test_count);
        $finish(0);
    end

    initial begin
        #3000000;
        $display("FAIL rv32_reorder_buffer timeout");
        $finish(1);
    end

endmodule
