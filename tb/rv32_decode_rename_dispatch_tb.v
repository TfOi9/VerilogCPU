`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_decode_rename_dispatch_tb;

    parameter FE_WIDTH = 1;
    parameter BE_WIDTH = 1;

    localparam PHYS_REGS = 64;
    localparam PHYS_REG_ADDR_WIDTH = 6;
    localparam ROB_ENTRIES = 32;
    localparam ROB_INDEX_WIDTH = 5;
    localparam ROB_TAG_WIDTH = 7;
    localparam INT_RS_ENTRIES = 8;
    localparam INT_RS_INDEX_WIDTH = 3;
    localparam MUL_RS_ENTRIES = 4;
    localparam MUL_RS_INDEX_WIDTH = 2;
    localparam DIV_RS_ENTRIES = 4;
    localparam DIV_RS_INDEX_WIDTH = 2;
    localparam LOAD_RS_ENTRIES = 8;
    localparam LOAD_RS_INDEX_WIDTH = 3;
    localparam STORE_RS_ENTRIES = 8;
    localparam STORE_RS_INDEX_WIDTH = 3;
    localparam LSQ_ENTRIES = 8;
    localparam LSQ_INDEX_WIDTH = 3;
    localparam LSQ_TAG_WIDTH = 5;

    reg clk_i;
    reg reset_i;
    reg flush_i;
    reg recover_i;
    reg [FE_WIDTH-1:0] fetch_valid_i;
    wire [FE_WIDTH-1:0] fetch_ready_o;
    reg [(FE_WIDTH*32)-1:0] fetch_pc_i;
    reg [(FE_WIDTH*32)-1:0] fetch_instruction_i;
    reg [(FE_WIDTH*32)-1:0] fetch_predicted_next_pc_i;
    reg [FE_WIDTH-1:0] fetch_error_i;
    reg rob_alloc_ready_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rob_alloc_tag_i;
    reg [ROB_INDEX_WIDTH:0] rob_occupancy_i;
    reg int_dispatch_ready_i;
    reg [INT_RS_INDEX_WIDTH:0] int_occupancy_i;
    reg mul_dispatch_ready_i;
    reg [MUL_RS_INDEX_WIDTH:0] mul_occupancy_i;
    reg div_dispatch_ready_i;
    reg [DIV_RS_INDEX_WIDTH:0] div_occupancy_i;
    reg load_dispatch_ready_i;
    reg [LOAD_RS_INDEX_WIDTH:0] load_occupancy_i;
    reg store_dispatch_ready_i;
    reg [STORE_RS_INDEX_WIDTH:0] store_occupancy_i;
    reg lsq_alloc_ready_i;
    reg [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] lsq_alloc_tag_i;
    reg [LSQ_INDEX_WIDTH:0] lsq_occupancy_i;
    wire dispatch_fire_o;
    wire [BE_WIDTH-1:0] dispatch_valid_o;
    wire [BE_WIDTH-1:0] int_dispatch_valid_o;
    wire [BE_WIDTH-1:0] mul_dispatch_valid_o;
    wire [BE_WIDTH-1:0] div_dispatch_valid_o;
    wire [BE_WIDTH-1:0] load_dispatch_valid_o;
    wire [BE_WIDTH-1:0] store_dispatch_valid_o;
    wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] dispatch_op_o;
    wire [(BE_WIDTH*32)-1:0] dispatch_pc_o;
    wire [(BE_WIDTH*32)-1:0] dispatch_instruction_o;
    wire [(BE_WIDTH*32)-1:0] dispatch_immediate_o;
    wire [(BE_WIDTH*32)-1:0] dispatch_predicted_next_pc_o;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] dispatch_rob_tag_o;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] dispatch_lsq_tag_o;
    wire [BE_WIDTH-1:0] dispatch_lhs_ready_o;
    wire [(BE_WIDTH*32)-1:0] dispatch_lhs_value_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] dispatch_lhs_phys_o;
    wire [BE_WIDTH-1:0] dispatch_rhs_ready_o;
    wire [(BE_WIDTH*32)-1:0] dispatch_rhs_value_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] dispatch_rhs_phys_o;
    wire [BE_WIDTH-1:0] rob_alloc_valid_o;
    wire [(BE_WIDTH*32)-1:0] rob_alloc_pc_o;
    wire [(BE_WIDTH*32)-1:0] rob_alloc_instruction_o;
    wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] rob_alloc_op_o;
    wire [BE_WIDTH-1:0] rob_alloc_writes_rd_o;
    wire [(BE_WIDTH*5)-1:0] rob_alloc_rd_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rob_alloc_new_phys_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rob_alloc_old_phys_o;
    wire [(BE_WIDTH*32)-1:0] rob_alloc_predicted_next_pc_o;
    wire [BE_WIDTH-1:0] rob_alloc_lsq_valid_o;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] rob_alloc_lsq_tag_o;
    wire [BE_WIDTH-1:0] rob_alloc_complete_o;
    wire [BE_WIDTH-1:0] rob_alloc_exception_valid_o;
    wire [(BE_WIDTH*4)-1:0] rob_alloc_exception_cause_o;
    wire [(BE_WIDTH*32)-1:0] rob_alloc_exception_tval_o;
    wire [BE_WIDTH-1:0] lsq_alloc_valid_o;
    wire [BE_WIDTH-1:0] lsq_alloc_store_o;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] lsq_alloc_rob_tag_o;
    wire [(BE_WIDTH*`RV32_MEMORY_WIDTH)-1:0] lsq_alloc_width_o;
    wire [BE_WIDTH-1:0] lsq_alloc_unsigned_o;
    reg [BE_WIDTH-1:0] commit_valid_i;
    reg [BE_WIDTH-1:0] commit_writes_rd_i;
    reg [(BE_WIDTH*5)-1:0] commit_rd_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] commit_new_phys_i;
    reg [BE_WIDTH-1:0] rollback_valid_i;
    reg [BE_WIDTH-1:0] rollback_writes_rd_i;
    reg [(BE_WIDTH*5)-1:0] rollback_rd_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rollback_new_phys_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rollback_old_phys_i;
    reg [BE_WIDTH-1:0] writeback_valid_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] writeback_phys_i;
    reg [(BE_WIDTH*32)-1:0] writeback_value_i;
    wire [PHYS_REG_ADDR_WIDTH:0] free_count_o;

    integer checks;
    integer errors;
    integer lane;
    integer guard;
    reg [PHYS_REG_ADDR_WIDTH-1:0] producer_phys;
    reg [PHYS_REG_ADDR_WIDTH:0] free_count_before;

    rv32_decode_rename_dispatch #(
        .FE_WIDTH(FE_WIDTH),
        .BE_WIDTH(BE_WIDTH)
    ) dut (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(flush_i),
        .recover_i(recover_i), .fetch_valid_i(fetch_valid_i),
        .fetch_ready_o(fetch_ready_o), .fetch_pc_i(fetch_pc_i),
        .fetch_instruction_i(fetch_instruction_i),
        .fetch_predicted_next_pc_i(fetch_predicted_next_pc_i),
        .fetch_error_i(fetch_error_i),
        .rob_alloc_ready_i(rob_alloc_ready_i),
        .rob_alloc_tag_i(rob_alloc_tag_i),
        .rob_occupancy_i(rob_occupancy_i),
        .int_dispatch_ready_i(int_dispatch_ready_i),
        .int_occupancy_i(int_occupancy_i),
        .mul_dispatch_ready_i(mul_dispatch_ready_i),
        .mul_occupancy_i(mul_occupancy_i),
        .div_dispatch_ready_i(div_dispatch_ready_i),
        .div_occupancy_i(div_occupancy_i),
        .load_dispatch_ready_i(load_dispatch_ready_i),
        .load_occupancy_i(load_occupancy_i),
        .store_dispatch_ready_i(store_dispatch_ready_i),
        .store_occupancy_i(store_occupancy_i),
        .lsq_alloc_ready_i(lsq_alloc_ready_i),
        .lsq_alloc_tag_i(lsq_alloc_tag_i),
        .lsq_occupancy_i(lsq_occupancy_i),
        .dispatch_fire_o(dispatch_fire_o),
        .dispatch_valid_o(dispatch_valid_o),
        .int_dispatch_valid_o(int_dispatch_valid_o),
        .mul_dispatch_valid_o(mul_dispatch_valid_o),
        .div_dispatch_valid_o(div_dispatch_valid_o),
        .load_dispatch_valid_o(load_dispatch_valid_o),
        .store_dispatch_valid_o(store_dispatch_valid_o),
        .dispatch_op_o(dispatch_op_o), .dispatch_pc_o(dispatch_pc_o),
        .dispatch_instruction_o(dispatch_instruction_o),
        .dispatch_immediate_o(dispatch_immediate_o),
        .dispatch_predicted_next_pc_o(dispatch_predicted_next_pc_o),
        .dispatch_rob_tag_o(dispatch_rob_tag_o),
        .dispatch_lsq_tag_o(dispatch_lsq_tag_o),
        .dispatch_lhs_ready_o(dispatch_lhs_ready_o),
        .dispatch_lhs_value_o(dispatch_lhs_value_o),
        .dispatch_lhs_phys_o(dispatch_lhs_phys_o),
        .dispatch_rhs_ready_o(dispatch_rhs_ready_o),
        .dispatch_rhs_value_o(dispatch_rhs_value_o),
        .dispatch_rhs_phys_o(dispatch_rhs_phys_o),
        .rob_alloc_valid_o(rob_alloc_valid_o),
        .rob_alloc_pc_o(rob_alloc_pc_o),
        .rob_alloc_instruction_o(rob_alloc_instruction_o),
        .rob_alloc_op_o(rob_alloc_op_o),
        .rob_alloc_writes_rd_o(rob_alloc_writes_rd_o),
        .rob_alloc_rd_o(rob_alloc_rd_o),
        .rob_alloc_new_phys_o(rob_alloc_new_phys_o),
        .rob_alloc_old_phys_o(rob_alloc_old_phys_o),
        .rob_alloc_predicted_next_pc_o(rob_alloc_predicted_next_pc_o),
        .rob_alloc_lsq_valid_o(rob_alloc_lsq_valid_o),
        .rob_alloc_lsq_tag_o(rob_alloc_lsq_tag_o),
        .rob_alloc_complete_o(rob_alloc_complete_o),
        .rob_alloc_exception_valid_o(rob_alloc_exception_valid_o),
        .rob_alloc_exception_cause_o(rob_alloc_exception_cause_o),
        .rob_alloc_exception_tval_o(rob_alloc_exception_tval_o),
        .lsq_alloc_valid_o(lsq_alloc_valid_o),
        .lsq_alloc_store_o(lsq_alloc_store_o),
        .lsq_alloc_rob_tag_o(lsq_alloc_rob_tag_o),
        .lsq_alloc_width_o(lsq_alloc_width_o),
        .lsq_alloc_unsigned_o(lsq_alloc_unsigned_o),
        .commit_valid_i(commit_valid_i),
        .commit_writes_rd_i(commit_writes_rd_i),
        .commit_rd_i(commit_rd_i),
        .commit_new_phys_i(commit_new_phys_i),
        .rollback_valid_i(rollback_valid_i),
        .rollback_writes_rd_i(rollback_writes_rd_i),
        .rollback_rd_i(rollback_rd_i),
        .rollback_new_phys_i(rollback_new_phys_i),
        .rollback_old_phys_i(rollback_old_phys_i),
        .writeback_valid_i(writeback_valid_i),
        .writeback_phys_i(writeback_phys_i),
        .writeback_value_i(writeback_value_i),
        .free_count_o(free_count_o)
    );

    always #5 clk_i = ~clk_i;

    task check;
        input condition;
        input integer check_id;
        begin
            checks = checks + 1;
            if (!condition) begin
                errors = errors + 1;
                $display("FAIL dispatch width=%0d/%0d check=%0d time=%0t",
                    FE_WIDTH, BE_WIDTH, check_id, $time);
            end
        end
    endtask

    task tick;
        begin
            @(posedge clk_i);
            #1;
        end
    endtask

    task clear_fetch;
        begin
            fetch_valid_i = {FE_WIDTH{1'b0}};
            fetch_pc_i = {(FE_WIDTH*32){1'b0}};
            fetch_instruction_i = {(FE_WIDTH*32){1'b0}};
            fetch_predicted_next_pc_i = {(FE_WIDTH*32){1'b0}};
            fetch_error_i = {FE_WIDTH{1'b0}};
        end
    endtask

    task put_lane;
        input integer lane_number;
        input [31:0] pc_value;
        input [31:0] instruction_value;
        begin
            fetch_valid_i[lane_number] = 1'b1;
            fetch_pc_i[lane_number*32 +: 32] = pc_value;
            fetch_instruction_i[lane_number*32 +: 32] = instruction_value;
            fetch_predicted_next_pc_i[lane_number*32 +: 32] =
                pc_value + 32'd4;
        end
    endtask

    task check_exception;
        input [31:0] instruction_value;
        input fetch_fault;
        input [3:0] expected_cause;
        input [31:0] expected_tval;
        input integer check_id;
        begin
            clear_fetch;
            put_lane(0, 32'h00000200, instruction_value);
            fetch_error_i[0] = fetch_fault;
            #1;
            check(dispatch_fire_o && rob_alloc_complete_o[0] &&
                rob_alloc_exception_valid_o[0], check_id);
            check(rob_alloc_exception_cause_o[3:0] == expected_cause,
                check_id + 1);
            check(rob_alloc_exception_tval_o[31:0] == expected_tval,
                check_id + 2);
            tick;
            clear_fetch;
        end
    endtask

    initial begin
        clk_i = 1'b0;
        reset_i = 1'b1;
        flush_i = 1'b0;
        recover_i = 1'b0;
        clear_fetch;
        rob_alloc_ready_i = 1'b1;
        rob_alloc_tag_i = {(BE_WIDTH*ROB_TAG_WIDTH){1'b0}};
        rob_occupancy_i = 0;
        int_dispatch_ready_i = 1'b1;
        int_occupancy_i = 0;
        mul_dispatch_ready_i = 1'b1;
        mul_occupancy_i = 0;
        div_dispatch_ready_i = 1'b1;
        div_occupancy_i = 0;
        load_dispatch_ready_i = 1'b1;
        load_occupancy_i = 0;
        store_dispatch_ready_i = 1'b1;
        store_occupancy_i = 0;
        lsq_alloc_ready_i = 1'b1;
        lsq_alloc_tag_i = {(BE_WIDTH*LSQ_TAG_WIDTH){1'b0}};
        lsq_occupancy_i = 0;
        commit_valid_i = {BE_WIDTH{1'b0}};
        commit_writes_rd_i = {BE_WIDTH{1'b0}};
        commit_rd_i = {(BE_WIDTH*5){1'b0}};
        commit_new_phys_i = {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        rollback_valid_i = {BE_WIDTH{1'b0}};
        rollback_writes_rd_i = {BE_WIDTH{1'b0}};
        rollback_rd_i = {(BE_WIDTH*5){1'b0}};
        rollback_new_phys_i = {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        rollback_old_phys_i = {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        writeback_valid_i = {BE_WIDTH{1'b0}};
        writeback_phys_i = {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        writeback_value_i = {(BE_WIDTH*32){1'b0}};
        checks = 0;
        errors = 0;
        for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
            rob_alloc_tag_i[lane*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] = lane + 7;
            lsq_alloc_tag_i[lane*LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] = lane + 3;
        end

        repeat (2) tick;
        reset_i = 1'b0;
        #1;
        check(free_count_o == PHYS_REGS-32, 1);

        put_lane(0, 32'h000000fc, 32'h00100013);
        #1;
        check(dispatch_fire_o && !rob_alloc_writes_rd_o[0] &&
            dispatch_lhs_phys_o[PHYS_REG_ADDR_WIDTH-1:0] == 0 &&
            dispatch_lhs_ready_o[0], 8);
        tick;
        clear_fetch;
        check(free_count_o == PHYS_REGS-32, 9);

        put_lane(0, 32'h00000100, 32'h00100293);
        #1;
        check(dispatch_fire_o && fetch_ready_o[0], 2);
        check(int_dispatch_valid_o[0] && !rob_alloc_complete_o[0], 3);
        check(dispatch_op_o[`RV32_OP_WIDTH-1:0] == `RV32_OP_ADDI &&
            dispatch_immediate_o[31:0] == 32'd1, 4);
        check(dispatch_rob_tag_o[ROB_TAG_WIDTH-1:0] == 7 &&
            rob_alloc_rd_o[4:0] == 5, 5);
        producer_phys = rob_alloc_new_phys_o[PHYS_REG_ADDR_WIDTH-1:0];
        tick;
        clear_fetch;

        put_lane(0, 32'h00000104, 32'h00028333);
        writeback_valid_i[0] = 1'b1;
        writeback_phys_i[PHYS_REG_ADDR_WIDTH-1:0] = producer_phys;
        writeback_value_i[31:0] = 32'h12345678;
        #1;
        check(dispatch_lhs_phys_o[PHYS_REG_ADDR_WIDTH-1:0] ==
            producer_phys, 6);
        check(dispatch_lhs_ready_o[0] &&
            dispatch_lhs_value_o[31:0] == 32'h12345678, 7);
        tick;
        clear_fetch;
        writeback_valid_i = {BE_WIDTH{1'b0}};

        if (FE_WIDTH >= 2 && BE_WIDTH >= 2) begin
            put_lane(0, 32'h00000108, 32'h00200393);
            put_lane(1, 32'h0000010c, 32'h00738433);
            #1;
            check(dispatch_valid_o[1:0] == 2'b11 && dispatch_fire_o, 10);
            check(dispatch_lhs_phys_o[PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH] ==
                rob_alloc_new_phys_o[0 +: PHYS_REG_ADDR_WIDTH], 11);
            check(dispatch_rhs_phys_o[PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH] ==
                rob_alloc_new_phys_o[0 +: PHYS_REG_ADDR_WIDTH], 12);
            check(!dispatch_lhs_ready_o[1] && !dispatch_rhs_ready_o[1], 13);
            tick;
            clear_fetch;

            put_lane(0, 32'h00000110, 32'h00300493);
            put_lane(1, 32'h00000114, 32'h00400493);
            #1;
            check(rob_alloc_old_phys_o[PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH] ==
                rob_alloc_new_phys_o[0 +: PHYS_REG_ADDR_WIDTH], 14);
            tick;
            clear_fetch;
        end

        clear_fetch;
        put_lane(0, 32'h00000120, 32'h02208533);
        if (FE_WIDTH >= 2 && BE_WIDTH >= 2)
            put_lane(1, 32'h00000124, 32'h0220c5b3);
        if (FE_WIDTH >= 4 && BE_WIDTH >= 4) begin
            put_lane(2, 32'h00000128, 32'h0000a603);
            put_lane(3, 32'h0000012c, 32'h0020a023);
        end
        #1;
        check(mul_dispatch_valid_o[0], 20);
        if (FE_WIDTH >= 2 && BE_WIDTH >= 2)
            check(div_dispatch_valid_o[1], 21);
        if (FE_WIDTH >= 4 && BE_WIDTH >= 4) begin
            check(load_dispatch_valid_o[2] && store_dispatch_valid_o[3], 22);
            check(lsq_alloc_valid_o[3:2] == 2'b11 &&
                lsq_alloc_store_o[3:2] == 2'b10, 23);
            check(rob_alloc_lsq_tag_o[2*LSQ_TAG_WIDTH +:
                LSQ_TAG_WIDTH] == lsq_alloc_tag_i[2*LSQ_TAG_WIDTH +:
                LSQ_TAG_WIDTH], 24);
            check(lsq_alloc_rob_tag_o[2*ROB_TAG_WIDTH +:
                ROB_TAG_WIDTH] == rob_alloc_tag_i[2*ROB_TAG_WIDTH +:
                ROB_TAG_WIDTH] &&
                lsq_alloc_rob_tag_o[3*ROB_TAG_WIDTH +:
                ROB_TAG_WIDTH] == rob_alloc_tag_i[3*ROB_TAG_WIDTH +:
                ROB_TAG_WIDTH], 25);
            check(lsq_alloc_width_o[2*`RV32_MEMORY_WIDTH +:
                `RV32_MEMORY_WIDTH] == `RV32_MEMORY_WORD &&
                lsq_alloc_width_o[3*`RV32_MEMORY_WIDTH +:
                `RV32_MEMORY_WIDTH] == `RV32_MEMORY_WORD &&
                !lsq_alloc_unsigned_o[2], 26);
        end
        tick;
        clear_fetch;

        check_exception(32'hffffffff, 1'b1,
            `RV32_EXCEPTION_INSTRUCTION_ACCESS_FAULT, 32'h00000200, 30);
        check_exception(32'hffffffff, 1'b0,
            `RV32_EXCEPTION_ILLEGAL_INSTRUCTION, 32'hffffffff, 33);
        check_exception(32'h00100073, 1'b0,
            `RV32_EXCEPTION_BREAKPOINT, 32'h00000200, 36);
        check_exception(32'h00000073, 1'b0,
            `RV32_EXCEPTION_ENVIRONMENT_CALL, 32'd0, 39);

        clear_fetch;
        put_lane(0, 32'h00000210, 32'h0ff00513);
        #1;
        check(rob_alloc_complete_o[0] &&
            !rob_alloc_exception_valid_o[0] &&
            !(|int_dispatch_valid_o), 42);
        tick;
        clear_fetch;

        put_lane(0, 32'h00000214, 32'hfa588b8f);
        #1;
        check(rob_alloc_complete_o[0] &&
            !rob_alloc_exception_valid_o[0] &&
            !(|int_dispatch_valid_o), 43);
        tick;
        clear_fetch;

        rob_occupancy_i = ROB_ENTRIES;
        put_lane(0, 32'h00000220, 32'h00100a13);
        #1;
        check(!dispatch_fire_o && !(|fetch_ready_o) &&
            !(|dispatch_valid_o), 45);
        rob_occupancy_i = 0;
        clear_fetch;

        mul_occupancy_i = MUL_RS_ENTRIES;
        put_lane(0, 32'h00000224, 32'h02208533);
        #1;
        check(!dispatch_fire_o && !(|dispatch_valid_o), 50);
        mul_occupancy_i = 0;
        clear_fetch;

        div_occupancy_i = DIV_RS_ENTRIES;
        put_lane(0, 32'h00000228, 32'h0220c5b3);
        #1;
        check(!dispatch_fire_o && !(|dispatch_valid_o), 51);
        div_occupancy_i = 0;
        clear_fetch;

        load_occupancy_i = LOAD_RS_ENTRIES;
        put_lane(0, 32'h0000022c, 32'h0000a603);
        #1;
        check(!dispatch_fire_o && !(|dispatch_valid_o), 52);
        load_occupancy_i = 0;
        clear_fetch;

        store_occupancy_i = STORE_RS_ENTRIES;
        put_lane(0, 32'h00000230, 32'h0020a023);
        #1;
        check(!dispatch_fire_o && !(|dispatch_valid_o), 53);
        store_occupancy_i = 0;
        clear_fetch;

        lsq_occupancy_i = LSQ_ENTRIES;
        put_lane(0, 32'h00000234, 32'h0000a603);
        #1;
        check(!dispatch_fire_o && !(|dispatch_valid_o), 54);
        lsq_occupancy_i = 0;
        clear_fetch;

        free_count_before = free_count_o;
        int_dispatch_ready_i = 1'b0;
        put_lane(0, 32'h00000238, 32'h00100a13);
        #1;
        check(!dispatch_fire_o && !(|fetch_ready_o) &&
            dispatch_valid_o[0], 55);
        tick;
        clear_fetch;
        check(free_count_o == free_count_before, 56);
        int_dispatch_ready_i = 1'b1;

        if (FE_WIDTH >= 2 && BE_WIDTH >= 2) begin
            int_occupancy_i = INT_RS_ENTRIES;
            put_lane(0, 32'h00000230, 32'h0ff00513);
            put_lane(1, 32'h00000234, 32'h00100a13);
            #1;
            check(dispatch_valid_o[1:0] == 2'b01 &&
                fetch_ready_o[1:0] == 2'b01 && dispatch_fire_o, 46);
            tick;
            int_occupancy_i = 0;
            clear_fetch;
        end else begin
            int_occupancy_i = INT_RS_ENTRIES;
            put_lane(0, 32'h00000230, 32'h00100a13);
            #1;
            check(!dispatch_fire_o && !(|dispatch_valid_o), 46);
            int_occupancy_i = 0;
            clear_fetch;
        end

        put_lane(0, 32'h00000240, 32'h00100a13);
        recover_i = 1'b1;
        #1;
        check(!dispatch_fire_o && !(|fetch_ready_o), 48);
        recover_i = 1'b0;
        flush_i = 1'b1;
        #1;
        check(!dispatch_fire_o && !(|fetch_ready_o), 49);
        flush_i = 1'b0;
        clear_fetch;

        guard = 0;
        while (free_count_o != 0 && guard < PHYS_REGS) begin
            put_lane(0, 32'h00000300 + guard*4, 32'h00100a13);
            #1;
            check(dispatch_fire_o, 100 + guard);
            tick;
            clear_fetch;
            guard = guard + 1;
        end
        check(free_count_o == 0, 180);
        put_lane(0, 32'h00000400, 32'h00100a13);
        #1;
        check(!dispatch_fire_o && !(|dispatch_valid_o), 181);

        if (errors != 0) begin
            $display("FAIL rv32_decode_rename_dispatch FE=%0d BE=%0d errors=%0d checks=%0d",
                FE_WIDTH, BE_WIDTH, errors, checks);
            $finish(1);
        end
        $display("PASS rv32_decode_rename_dispatch FE=%0d BE=%0d checks=%0d",
            FE_WIDTH, BE_WIDTH, checks);
        $finish;
    end

endmodule

module rv32_decode_rename_dispatch_protocol_tb;

    reg clk;
    reg reset;
    reg [1:0] fetch_valid;

    rv32_decode_rename_dispatch #(
        .FE_WIDTH(2), .BE_WIDTH(2)
    ) dut (
        .clk_i(clk), .reset_i(reset), .flush_i(1'b0), .recover_i(1'b0),
        .fetch_valid_i(fetch_valid), .fetch_ready_o(), .fetch_pc_i(64'd0),
        .fetch_instruction_i(64'd0),
        .fetch_predicted_next_pc_i(64'd0), .fetch_error_i(2'b0),
        .rob_alloc_ready_i(1'b1), .rob_alloc_tag_i(14'd0),
        .rob_occupancy_i(6'd0), .int_dispatch_ready_i(1'b1),
        .int_occupancy_i(4'd0), .mul_dispatch_ready_i(1'b1),
        .mul_occupancy_i(3'd0), .div_dispatch_ready_i(1'b1),
        .div_occupancy_i(3'd0), .load_dispatch_ready_i(1'b1),
        .load_occupancy_i(4'd0), .store_dispatch_ready_i(1'b1),
        .store_occupancy_i(4'd0), .lsq_alloc_ready_i(1'b1),
        .lsq_alloc_tag_i(10'd0), .lsq_occupancy_i(4'd0),
        .commit_valid_i(2'b0), .commit_writes_rd_i(2'b0),
        .commit_rd_i(10'd0), .commit_new_phys_i(12'd0),
        .rollback_valid_i(2'b0), .rollback_writes_rd_i(2'b0),
        .rollback_rd_i(10'd0), .rollback_new_phys_i(12'd0),
        .rollback_old_phys_i(12'd0), .writeback_valid_i(2'b0),
        .writeback_phys_i(12'd0), .writeback_value_i(64'd0)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        reset = 1;
        fetch_valid = 0;
        repeat (2) @(posedge clk);
        reset = 0;
        fetch_valid = 2'b10;
        @(posedge clk);
        #10;
        $display("FAIL protocol violation was not rejected");
        $finish(1);
    end

endmodule
