`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_completion_writeback_integration_tb;

    localparam BE_WIDTH = 2;
    localparam SOURCE_COUNT = 4;
    localparam PHYS_REGS = 64;
    localparam PHYS_REG_ADDR_WIDTH = 6;
    localparam ROB_ENTRIES = 16;
    localparam ROB_INDEX_WIDTH = 4;
    localparam ROB_GENERATION_WIDTH = 2;
    localparam ROB_TAG_WIDTH = 6;
    localparam LSQ_TAG_WIDTH = 4;

    reg clk_i;
    reg reset_i;
    reg flush_i;

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

    wire [BE_WIDTH-1:0] completion_valid;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] completion_tag;
    wire [(BE_WIDTH*32)-1:0] completion_value;
    wire [BE_WIDTH-1:0] completion_control_valid;
    wire [BE_WIDTH-1:0] completion_control_taken;
    wire [(BE_WIDTH*32)-1:0] completion_next_pc;
    wire [BE_WIDTH-1:0] completion_exception_valid;
    wire [(BE_WIDTH*4)-1:0] completion_exception_cause;
    wire [(BE_WIDTH*32)-1:0] completion_exception_tval;
    wire [BE_WIDTH-1:0] completion_ready;
    wire [BE_WIDTH-1:0] completion_accept;
    wire [BE_WIDTH-1:0] completion_writes_rd;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] completion_phys;
    wire [BE_WIDTH-1:0] writeback_valid;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] writeback_phys;
    wire [(BE_WIDTH*32)-1:0] writeback_value;

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
    wire alloc_ready_o;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] alloc_tag_o;
    wire [ROB_INDEX_WIDTH:0] occupancy_o;
    wire [ROB_INDEX_WIDTH-1:0] head_index_o;

    reg [BE_WIDTH-1:0] commit_ready_i;
    wire [BE_WIDTH-1:0] commit_valid_o;
    wire [BE_WIDTH-1:0] commit_fire_o;
    wire recover_busy_o;
    wire recover_redirect_valid_o;
    wire [31:0] recover_redirect_pc_o;

    reg [(2*BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] prf_read_addr;
    wire [(2*BE_WIDTH*32)-1:0] prf_read_data;

    reg [ROB_TAG_WIDTH-1:0] saved_tag0;
    reg [ROB_TAG_WIDTH-1:0] saved_tag1;
    reg [ROB_TAG_WIDTH-1:0] saved_tag2;
    reg [ROB_TAG_WIDTH-1:0] saved_tag3;
    integer test_count;
    integer error_count;

    rv32_completion_writeback_network #(
        .BE_WIDTH(BE_WIDTH),
        .SOURCE_COUNT(SOURCE_COUNT),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) network (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .recover_i(recover_busy_o),
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
        .completion_valid_o(completion_valid),
        .completion_tag_o(completion_tag),
        .completion_value_o(completion_value),
        .completion_control_valid_o(completion_control_valid),
        .completion_control_taken_o(completion_control_taken),
        .completion_next_pc_o(completion_next_pc),
        .completion_exception_valid_o(completion_exception_valid),
        .completion_exception_cause_o(completion_exception_cause),
        .completion_exception_tval_o(completion_exception_tval),
        .completion_ready_i(completion_ready),
        .completion_accept_i(completion_accept),
        .completion_writes_rd_i(completion_writes_rd),
        .completion_phys_i(completion_phys),
        .writeback_valid_o(writeback_valid),
        .writeback_phys_o(writeback_phys),
        .writeback_value_o(writeback_value)
    );

    rv32_reorder_buffer #(
        .ROB_ENTRIES(ROB_ENTRIES),
        .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_GENERATION_WIDTH(ROB_GENERATION_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH),
        .BE_WIDTH(BE_WIDTH),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .LSQ_TAG_WIDTH(LSQ_TAG_WIDTH)
    ) rob (
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
        .alloc_lsq_valid_i({BE_WIDTH{1'b0}}),
        .alloc_lsq_tag_i({(BE_WIDTH*LSQ_TAG_WIDTH){1'b0}}),
        .alloc_complete_i({BE_WIDTH{1'b0}}),
        .alloc_exception_valid_i({BE_WIDTH{1'b0}}),
        .alloc_exception_cause_i({(BE_WIDTH*4){1'b0}}),
        .alloc_exception_tval_i({(BE_WIDTH*32){1'b0}}),
        .alloc_ready_o(alloc_ready_o),
        .alloc_tag_o(alloc_tag_o),
        .occupancy_o(occupancy_o),
        .head_index_o(head_index_o),
        .completion_valid_i(completion_valid),
        .completion_tag_i(completion_tag),
        .completion_value_i(completion_value),
        .completion_control_valid_i(completion_control_valid),
        .completion_control_taken_i(completion_control_taken),
        .completion_next_pc_i(completion_next_pc),
        .completion_exception_valid_i(completion_exception_valid),
        .completion_exception_cause_i(completion_exception_cause),
        .completion_exception_tval_i(completion_exception_tval),
        .completion_ready_o(completion_ready),
        .completion_accept_o(completion_accept),
        .completion_writes_rd_o(completion_writes_rd),
        .completion_phys_o(completion_phys),
        .commit_ready_i(commit_ready_i),
        .commit_valid_o(commit_valid_o),
        .commit_fire_o(commit_fire_o),
        .commit_tag_o(),
        .commit_pc_o(),
        .commit_instruction_o(),
        .commit_op_o(),
        .commit_writes_rd_o(),
        .commit_rd_o(),
        .commit_new_phys_o(),
        .commit_old_phys_o(),
        .commit_value_o(),
        .commit_control_valid_o(),
        .commit_control_taken_o(),
        .commit_predicted_next_pc_o(),
        .commit_next_pc_o(),
        .commit_lsq_valid_o(),
        .commit_lsq_tag_o(),
        .commit_exception_valid_o(),
        .commit_exception_cause_o(),
        .commit_exception_tval_o(),
        .recover_busy_o(recover_busy_o),
        .recover_redirect_valid_o(recover_redirect_valid_o),
        .recover_redirect_pc_o(recover_redirect_pc_o),
        .rollback_valid_o(),
        .rollback_tag_o(),
        .rollback_writes_rd_o(),
        .rollback_rd_o(),
        .rollback_new_phys_o(),
        .rollback_old_phys_o(),
        .rollback_lsq_valid_o(),
        .rollback_lsq_tag_o()
    );

    rv32_physical_register_file #(
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .BE_WIDTH(BE_WIDTH)
    ) prf (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .read_addr_i(prf_read_addr),
        .read_data_o(prf_read_data),
        .write_valid_i(writeback_valid),
        .write_addr_i(writeback_phys),
        .write_data_i(writeback_value)
    );

    always #5 clk_i = ~clk_i;

    task check;
        input condition;
        input integer check_id;
        begin
            test_count = test_count + 1;
            if (!condition) begin
                error_count = error_count + 1;
                $display("FAIL integration check=%0d time=%0t", check_id,
                    $time);
            end
        end
    endtask

    task clock_edge;
        begin
            @(posedge clk_i);
            #1;
        end
    endtask

    task clear_sources;
        begin
            source_valid_i = {SOURCE_COUNT{1'b0}};
            source_rob_tag_i = {(SOURCE_COUNT*ROB_TAG_WIDTH){1'b0}};
            source_value_i = {(SOURCE_COUNT*32){1'b0}};
            source_control_valid_i = {SOURCE_COUNT{1'b0}};
            source_control_taken_i = {SOURCE_COUNT{1'b0}};
            source_next_pc_i = {(SOURCE_COUNT*32){1'b0}};
            source_exception_valid_i = {SOURCE_COUNT{1'b0}};
            source_exception_cause_i = {(SOURCE_COUNT*4){1'b0}};
            source_exception_tval_i = {(SOURCE_COUNT*32){1'b0}};
        end
    endtask

    task clear_allocation;
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
        end
    endtask

    task prepare_allocation;
        input integer count;
        input integer first_phys;
        begin
            clear_allocation;
            alloc_fire_i = 1'b1;
            alloc_valid_i[0] = 1'b1;
            alloc_pc_i[31:0] = 32'h1000 + first_phys*4;
            alloc_instruction_i[31:0] = 32'h00000033;
            alloc_op_i[`RV32_OP_WIDTH-1:0] = `RV32_OP_ADD;
            alloc_writes_rd_i[0] = 1'b1;
            alloc_rd_i[4:0] = first_phys - 39;
            alloc_new_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = first_phys;
            alloc_old_phys_i[PHYS_REG_ADDR_WIDTH-1:0] =
                first_phys - 39;
            if (count == 2) begin
                alloc_valid_i[1] = 1'b1;
                alloc_pc_i[63:32] = 32'h1004 + first_phys*4;
                alloc_instruction_i[63:32] = 32'h00000033;
                alloc_op_i[`RV32_OP_WIDTH +: `RV32_OP_WIDTH] =
                    `RV32_OP_ADD;
                alloc_writes_rd_i[1] = 1'b1;
                alloc_rd_i[9:5] = first_phys - 38;
                alloc_new_phys_i[
                    PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] =
                    first_phys + 1;
                alloc_old_phys_i[
                    PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] =
                    first_phys - 38;
            end
        end
    endtask

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b0;
        flush_i = 1'b0;
        commit_ready_i = {BE_WIDTH{1'b0}};
        prf_read_addr = {(2*BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        test_count = 0;
        error_count = 0;
        clear_sources;
        clear_allocation;

        reset_i = 1'b1;
        clock_edge;
        clock_edge;
        reset_i = 1'b0;
        #1;
        check(alloc_ready_o && (occupancy_o == 0), 1);

        prepare_allocation(2, 40);
        #1;
        saved_tag0 = alloc_tag_o[ROB_TAG_WIDTH-1:0];
        saved_tag1 = alloc_tag_o[ROB_TAG_WIDTH +: ROB_TAG_WIDTH];
        clock_edge;
        clear_allocation;
        check(occupancy_o == 2, 2);

        source_valid_i[1:0] = 2'b11;
        source_rob_tag_i[ROB_TAG_WIDTH-1:0] = saved_tag0;
        source_rob_tag_i[ROB_TAG_WIDTH +: ROB_TAG_WIDTH] = saved_tag1;
        source_value_i[31:0] = 32'h11112222;
        source_value_i[63:32] = 32'h33334444;
        prf_read_addr[PHYS_REG_ADDR_WIDTH-1:0] = 40;
        prf_read_addr[2*PHYS_REG_ADDR_WIDTH-1:PHYS_REG_ADDR_WIDTH] = 41;
        clock_edge;
        clear_sources;
        #1;
        check(completion_accept == 2'b11, 3);
        check(completion_writes_rd == 2'b11, 4);
        check(completion_phys[PHYS_REG_ADDR_WIDTH-1:0] == 40 &&
            completion_phys[2*PHYS_REG_ADDR_WIDTH-1:
                PHYS_REG_ADDR_WIDTH] == 41, 5);
        check(writeback_valid == 2'b11, 6);
        check(prf_read_data[31:0] == 32'h11112222 &&
            prf_read_data[63:32] == 32'h33334444, 7);
        clock_edge;
        check(prf_read_data[31:0] == 32'h11112222 &&
            prf_read_data[63:32] == 32'h33334444, 8);
        check(commit_valid_o == 2'b11, 9);

        source_valid_i[2] = 1'b1;
        source_rob_tag_i[2*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] = saved_tag0;
        source_value_i[2*32 +: 32] = 32'hdeadbeef;
        clock_edge;
        clear_sources;
        #1;
        check(completion_valid[0] && !completion_accept[0], 10);
        check(writeback_valid == 2'b00, 11);
        clock_edge;
        check(prf_read_data[31:0] == 32'h11112222, 12);

        prepare_allocation(1, 42);
        #1;
        saved_tag2 = alloc_tag_o[ROB_TAG_WIDTH-1:0];
        clock_edge;
        clear_allocation;
        source_valid_i[3] = 1'b1;
        source_rob_tag_i[3*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] = saved_tag2;
        source_value_i[3*32 +: 32] = 32'h55556666;
        source_exception_valid_i[3] = 1'b1;
        source_exception_cause_i[3*4 +: 4] = 4'd5;
        source_exception_tval_i[3*32 +: 32] = 32'hbad00000;
        prf_read_addr[PHYS_REG_ADDR_WIDTH-1:0] = 42;
        clock_edge;
        clear_sources;
        #1;
        check(completion_accept[0] && completion_writes_rd[0], 13);
        check(completion_exception_valid[0] &&
            (writeback_valid == 2'b00), 14);
        clock_edge;
        check(prf_read_data[31:0] == 0, 15);

        prepare_allocation(1, 43);
        #1;
        saved_tag3 = alloc_tag_o[ROB_TAG_WIDTH-1:0];
        clock_edge;
        clear_allocation;
        source_valid_i[1:0] = 2'b11;
        source_rob_tag_i[ROB_TAG_WIDTH-1:0] = saved_tag3;
        source_rob_tag_i[ROB_TAG_WIDTH +: ROB_TAG_WIDTH] = saved_tag3;
        source_value_i[31:0] = 32'h77778888;
        source_value_i[63:32] = 32'h9999aaaa;
        prf_read_addr[PHYS_REG_ADDR_WIDTH-1:0] = 43;
        clock_edge;
        clear_sources;
        #1;
        check(completion_valid == 2'b11 &&
            completion_accept == 2'b01, 16);
        check(writeback_valid == 2'b01 &&
            (writeback_value[31:0] == 32'h77778888), 17);
        clock_edge;
        check(prf_read_data[31:0] == 32'h77778888, 18);

        if (error_count != 0) begin
            $display("FAIL rv32_completion_writeback_integration tests=%0d errors=%0d",
                test_count, error_count);
            $finish(1);
        end
        $display("PASS rv32_completion_writeback_integration tests=%0d",
            test_count);
        $finish(0);
    end

    initial begin
        #100000;
        $display("FAIL rv32_completion_writeback_integration timeout");
        $finish(1);
    end

endmodule
