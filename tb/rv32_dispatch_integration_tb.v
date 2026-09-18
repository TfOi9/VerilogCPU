`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_dispatch_integration_tb;

    localparam BE_WIDTH = 4;
    localparam PHYS_REG_ADDR_WIDTH = 6;
    localparam ROB_INDEX_WIDTH = 5;
    localparam ROB_TAG_WIDTH = 7;
    localparam LSQ_TAG_WIDTH = 5;

    reg clk;
    reg reset;
    reg [BE_WIDTH-1:0] fetch_valid;
    wire [BE_WIDTH-1:0] fetch_ready;
    reg [(BE_WIDTH*32)-1:0] fetch_pc;
    reg [(BE_WIDTH*32)-1:0] fetch_instruction;
    reg [(BE_WIDTH*32)-1:0] fetch_predicted_next_pc;

    wire dispatch_fire;
    wire [BE_WIDTH-1:0] int_dispatch_valid;
    wire [BE_WIDTH-1:0] load_dispatch_valid;
    wire [BE_WIDTH-1:0] store_dispatch_valid;
    wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] dispatch_op;
    wire [(BE_WIDTH*32)-1:0] dispatch_pc;
    wire [(BE_WIDTH*32)-1:0] dispatch_immediate;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] dispatch_rob_tag;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] dispatch_lsq_tag;
    wire [BE_WIDTH-1:0] dispatch_lhs_ready;
    wire [(BE_WIDTH*32)-1:0] dispatch_lhs_value;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] dispatch_lhs_phys;
    wire [BE_WIDTH-1:0] dispatch_rhs_ready;
    wire [(BE_WIDTH*32)-1:0] dispatch_rhs_value;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] dispatch_rhs_phys;

    wire rob_alloc_ready;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rob_alloc_tag;
    wire [ROB_INDEX_WIDTH:0] rob_occupancy;
    wire [ROB_INDEX_WIDTH-1:0] rob_head_index;
    wire [BE_WIDTH-1:0] rob_alloc_valid;
    wire [(BE_WIDTH*32)-1:0] rob_alloc_pc;
    wire [(BE_WIDTH*32)-1:0] rob_alloc_instruction;
    wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] rob_alloc_op;
    wire [BE_WIDTH-1:0] rob_alloc_writes_rd;
    wire [(BE_WIDTH*5)-1:0] rob_alloc_rd;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rob_alloc_new_phys;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rob_alloc_old_phys;
    wire [(BE_WIDTH*32)-1:0] rob_alloc_predicted_next_pc;
    wire [BE_WIDTH-1:0] rob_alloc_lsq_valid;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] rob_alloc_lsq_tag;
    wire [BE_WIDTH-1:0] rob_alloc_complete;
    wire [BE_WIDTH-1:0] rob_alloc_exception_valid;
    wire [(BE_WIDTH*4)-1:0] rob_alloc_exception_cause;
    wire [(BE_WIDTH*32)-1:0] rob_alloc_exception_tval;
    wire [BE_WIDTH-1:0] lsq_alloc_valid;
    wire [BE_WIDTH-1:0] lsq_alloc_store;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] lsq_alloc_rob_tag;
    wire [(BE_WIDTH*`RV32_MEMORY_WIDTH)-1:0] lsq_alloc_width;
    wire [BE_WIDTH-1:0] lsq_alloc_unsigned;

    reg [BE_WIDTH-1:0] completion_valid;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] completion_tag;
    reg [(BE_WIDTH*32)-1:0] completion_value;
    reg [BE_WIDTH-1:0] completion_control_valid;
    reg [BE_WIDTH-1:0] completion_control_taken;
    reg [(BE_WIDTH*32)-1:0] completion_next_pc;
    wire [BE_WIDTH-1:0] completion_ready;

    wire [BE_WIDTH-1:0] commit_valid;
    wire [BE_WIDTH-1:0] commit_fire;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] commit_tag;
    wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] commit_op;
    wire [BE_WIDTH-1:0] commit_writes_rd;
    wire [(BE_WIDTH*5)-1:0] commit_rd;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] commit_new_phys;
    wire [BE_WIDTH-1:0] commit_lsq_valid;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] commit_lsq_tag;
    wire [BE_WIDTH-1:0] commit_exception_valid;
    wire [BE_WIDTH-1:0] lsq_commit_ready;

    wire recover_busy;
    wire [BE_WIDTH-1:0] rollback_valid;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_tag;
    wire [BE_WIDTH-1:0] rollback_writes_rd;
    wire [(BE_WIDTH*5)-1:0] rollback_rd;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rollback_new_phys;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rollback_old_phys;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] rollback_lsq_tag;

    wire int_ready;
    wire [3:0] int_occupancy;
    wire load_ready;
    wire [3:0] load_occupancy;
    wire store_ready;
    wire [3:0] store_occupancy;
    wire lsq_ready;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] lsq_alloc_tag;
    wire [3:0] lsq_occupancy;
    wire [6:0] free_count;

    wire load_address_valid;
    wire load_address_ready;
    wire [31:0] load_address;
    wire [ROB_TAG_WIDTH-1:0] load_address_rob_tag;
    wire [LSQ_TAG_WIDTH-1:0] load_address_lsq_tag;
    wire store_address_valid;
    wire store_address_ready;
    wire [31:0] store_address;
    wire [ROB_TAG_WIDTH-1:0] store_address_rob_tag;
    wire [LSQ_TAG_WIDTH-1:0] store_address_lsq_tag;
    wire store_data_valid;
    wire store_data_ready;
    wire [31:0] store_data;
    wire [ROB_TAG_WIDTH-1:0] store_data_rob_tag;
    wire [LSQ_TAG_WIDTH-1:0] store_data_lsq_tag;

    reg [ROB_TAG_WIDTH-1:0] branch_tag;
    integer errors;

    rv32_decode_rename_dispatch #(
        .FE_WIDTH(BE_WIDTH), .BE_WIDTH(BE_WIDTH)
    ) dut (
        .clk_i(clk), .reset_i(reset), .flush_i(1'b0),
        .recover_i(recover_busy), .fetch_valid_i(fetch_valid),
        .fetch_ready_o(fetch_ready), .fetch_pc_i(fetch_pc),
        .fetch_instruction_i(fetch_instruction),
        .fetch_predicted_next_pc_i(fetch_predicted_next_pc),
        .fetch_error_i(4'b0), .rob_alloc_ready_i(rob_alloc_ready),
        .rob_alloc_tag_i(rob_alloc_tag), .rob_occupancy_i(rob_occupancy),
        .int_dispatch_ready_i(int_ready), .int_occupancy_i(int_occupancy),
        .mul_dispatch_ready_i(1'b1), .mul_occupancy_i(3'd0),
        .div_dispatch_ready_i(1'b1), .div_occupancy_i(3'd0),
        .load_dispatch_ready_i(load_ready), .load_occupancy_i(load_occupancy),
        .store_dispatch_ready_i(store_ready),
        .store_occupancy_i(store_occupancy),
        .lsq_alloc_ready_i(lsq_ready), .lsq_alloc_tag_i(lsq_alloc_tag),
        .lsq_occupancy_i(lsq_occupancy), .dispatch_fire_o(dispatch_fire),
        .int_dispatch_valid_o(int_dispatch_valid),
        .load_dispatch_valid_o(load_dispatch_valid),
        .store_dispatch_valid_o(store_dispatch_valid),
        .dispatch_op_o(dispatch_op), .dispatch_pc_o(dispatch_pc),
        .dispatch_immediate_o(dispatch_immediate),
        .dispatch_rob_tag_o(dispatch_rob_tag),
        .dispatch_lsq_tag_o(dispatch_lsq_tag),
        .dispatch_lhs_ready_o(dispatch_lhs_ready),
        .dispatch_lhs_value_o(dispatch_lhs_value),
        .dispatch_lhs_phys_o(dispatch_lhs_phys),
        .dispatch_rhs_ready_o(dispatch_rhs_ready),
        .dispatch_rhs_value_o(dispatch_rhs_value),
        .dispatch_rhs_phys_o(dispatch_rhs_phys),
        .rob_alloc_valid_o(rob_alloc_valid), .rob_alloc_pc_o(rob_alloc_pc),
        .rob_alloc_instruction_o(rob_alloc_instruction),
        .rob_alloc_op_o(rob_alloc_op),
        .rob_alloc_writes_rd_o(rob_alloc_writes_rd),
        .rob_alloc_rd_o(rob_alloc_rd),
        .rob_alloc_new_phys_o(rob_alloc_new_phys),
        .rob_alloc_old_phys_o(rob_alloc_old_phys),
        .rob_alloc_predicted_next_pc_o(rob_alloc_predicted_next_pc),
        .rob_alloc_lsq_valid_o(rob_alloc_lsq_valid),
        .rob_alloc_lsq_tag_o(rob_alloc_lsq_tag),
        .rob_alloc_complete_o(rob_alloc_complete),
        .rob_alloc_exception_valid_o(rob_alloc_exception_valid),
        .rob_alloc_exception_cause_o(rob_alloc_exception_cause),
        .rob_alloc_exception_tval_o(rob_alloc_exception_tval),
        .lsq_alloc_valid_o(lsq_alloc_valid),
        .lsq_alloc_store_o(lsq_alloc_store),
        .lsq_alloc_rob_tag_o(lsq_alloc_rob_tag),
        .lsq_alloc_width_o(lsq_alloc_width),
        .lsq_alloc_unsigned_o(lsq_alloc_unsigned),
        .commit_valid_i(commit_fire),
        .commit_writes_rd_i(commit_writes_rd), .commit_rd_i(commit_rd),
        .commit_new_phys_i(commit_new_phys),
        .rollback_valid_i(rollback_valid),
        .rollback_writes_rd_i(rollback_writes_rd),
        .rollback_rd_i(rollback_rd),
        .rollback_new_phys_i(rollback_new_phys),
        .rollback_old_phys_i(rollback_old_phys),
        .writeback_valid_i(4'b0), .writeback_phys_i(24'd0),
        .writeback_value_i(128'd0), .free_count_o(free_count)
    );

    rv32_reorder_buffer #(
        .BE_WIDTH(BE_WIDTH)
    ) rob (
        .clk_i(clk), .reset_i(reset), .alloc_valid_i(rob_alloc_valid),
        .alloc_fire_i(dispatch_fire), .alloc_pc_i(rob_alloc_pc),
        .alloc_instruction_i(rob_alloc_instruction),
        .alloc_op_i(rob_alloc_op), .alloc_writes_rd_i(rob_alloc_writes_rd),
        .alloc_rd_i(rob_alloc_rd), .alloc_new_phys_i(rob_alloc_new_phys),
        .alloc_old_phys_i(rob_alloc_old_phys),
        .alloc_predicted_next_pc_i(rob_alloc_predicted_next_pc),
        .alloc_lsq_valid_i(rob_alloc_lsq_valid),
        .alloc_lsq_tag_i(rob_alloc_lsq_tag),
        .alloc_complete_i(rob_alloc_complete),
        .alloc_exception_valid_i(rob_alloc_exception_valid),
        .alloc_exception_cause_i(rob_alloc_exception_cause),
        .alloc_exception_tval_i(rob_alloc_exception_tval),
        .alloc_ready_o(rob_alloc_ready), .alloc_tag_o(rob_alloc_tag),
        .occupancy_o(rob_occupancy), .head_index_o(rob_head_index),
        .completion_valid_i(completion_valid), .completion_tag_i(completion_tag),
        .completion_value_i(completion_value),
        .completion_control_valid_i(completion_control_valid),
        .completion_control_taken_i(completion_control_taken),
        .completion_next_pc_i(completion_next_pc),
        .completion_exception_valid_i(4'b0),
        .completion_exception_cause_i(16'd0),
        .completion_exception_tval_i(128'd0),
        .completion_ready_o(completion_ready), .completion_accept_o(),
        .completion_writes_rd_o(), .completion_phys_o(),
        .commit_ready_i(lsq_commit_ready), .commit_valid_o(commit_valid),
        .commit_fire_o(commit_fire), .commit_tag_o(commit_tag),
        .commit_pc_o(), .commit_instruction_o(), .commit_op_o(commit_op),
        .commit_writes_rd_o(commit_writes_rd), .commit_rd_o(commit_rd),
        .commit_new_phys_o(commit_new_phys), .commit_old_phys_o(),
        .commit_value_o(), .commit_control_valid_o(),
        .commit_control_taken_o(), .commit_predicted_next_pc_o(),
        .commit_next_pc_o(), .commit_lsq_valid_o(commit_lsq_valid),
        .commit_lsq_tag_o(commit_lsq_tag),
        .commit_exception_valid_o(commit_exception_valid),
        .commit_exception_cause_o(), .commit_exception_tval_o(),
        .recover_busy_o(recover_busy), .recover_redirect_valid_o(),
        .recover_redirect_pc_o(), .rollback_valid_o(rollback_valid),
        .rollback_tag_o(rollback_tag),
        .rollback_writes_rd_o(rollback_writes_rd),
        .rollback_rd_o(rollback_rd),
        .rollback_new_phys_o(rollback_new_phys),
        .rollback_old_phys_o(rollback_old_phys),
        .rollback_lsq_valid_o(), .rollback_lsq_tag_o(rollback_lsq_tag)
    );

    rv32_integer_reservation_station #(
        .BE_WIDTH(BE_WIDTH)
    ) int_rs (
        .clk_i(clk), .reset_i(reset), .flush_i(1'b0),
        .recover_i(recover_busy), .dispatch_valid_i(int_dispatch_valid),
        .dispatch_fire_i(dispatch_fire), .dispatch_op_i(dispatch_op),
        .dispatch_pc_i(dispatch_pc), .dispatch_immediate_i(dispatch_immediate),
        .dispatch_rob_tag_i(dispatch_rob_tag),
        .dispatch_lhs_ready_i(dispatch_lhs_ready),
        .dispatch_lhs_value_i(dispatch_lhs_value),
        .dispatch_lhs_phys_i(dispatch_lhs_phys),
        .dispatch_rhs_ready_i(dispatch_rhs_ready),
        .dispatch_rhs_value_i(dispatch_rhs_value),
        .dispatch_rhs_phys_i(dispatch_rhs_phys), .dispatch_ready_o(int_ready),
        .occupancy_o(int_occupancy), .broadcast_valid_i(4'b0),
        .broadcast_phys_i(24'd0), .broadcast_value_i(128'd0),
        .rob_head_index_i(rob_head_index), .rollback_valid_i(rollback_valid),
        .rollback_tag_i(rollback_tag), .issue_valid_o(),
        .issue_ready_i(4'b0), .issue_op_o(), .issue_lhs_o(), .issue_rhs_o(),
        .issue_pc_o(), .issue_immediate_o(), .issue_rob_tag_o()
    );

    rv32_memory_reservation_station #(
        .IS_STORE(0), .BE_WIDTH(BE_WIDTH)
    ) load_rs (
        .clk_i(clk), .reset_i(reset), .flush_i(1'b0),
        .recover_i(recover_busy), .dispatch_valid_i(load_dispatch_valid),
        .dispatch_fire_i(dispatch_fire), .dispatch_rob_tag_i(dispatch_rob_tag),
        .dispatch_lsq_tag_i(dispatch_lsq_tag),
        .dispatch_immediate_i(dispatch_immediate),
        .dispatch_base_ready_i(dispatch_lhs_ready),
        .dispatch_base_value_i(dispatch_lhs_value),
        .dispatch_base_phys_i(dispatch_lhs_phys),
        .dispatch_data_ready_i(dispatch_rhs_ready),
        .dispatch_data_value_i(dispatch_rhs_value),
        .dispatch_data_phys_i(dispatch_rhs_phys), .dispatch_ready_o(load_ready),
        .occupancy_o(load_occupancy), .broadcast_valid_i(4'b0),
        .broadcast_phys_i(24'd0), .broadcast_value_i(128'd0),
        .rob_head_index_i(rob_head_index), .rollback_valid_i(rollback_valid),
        .rollback_tag_i(rollback_tag), .address_valid_o(load_address_valid),
        .address_ready_i(load_address_ready), .address_o(load_address),
        .address_rob_tag_o(load_address_rob_tag),
        .address_lsq_tag_o(load_address_lsq_tag), .data_valid_o(),
        .data_ready_i(1'b0), .data_o(), .data_rob_tag_o(), .data_lsq_tag_o()
    );

    rv32_memory_reservation_station #(
        .IS_STORE(1), .BE_WIDTH(BE_WIDTH)
    ) store_rs (
        .clk_i(clk), .reset_i(reset), .flush_i(1'b0),
        .recover_i(recover_busy), .dispatch_valid_i(store_dispatch_valid),
        .dispatch_fire_i(dispatch_fire), .dispatch_rob_tag_i(dispatch_rob_tag),
        .dispatch_lsq_tag_i(dispatch_lsq_tag),
        .dispatch_immediate_i(dispatch_immediate),
        .dispatch_base_ready_i(dispatch_lhs_ready),
        .dispatch_base_value_i(dispatch_lhs_value),
        .dispatch_base_phys_i(dispatch_lhs_phys),
        .dispatch_data_ready_i(dispatch_rhs_ready),
        .dispatch_data_value_i(dispatch_rhs_value),
        .dispatch_data_phys_i(dispatch_rhs_phys),
        .dispatch_ready_o(store_ready), .occupancy_o(store_occupancy),
        .broadcast_valid_i(4'b0), .broadcast_phys_i(24'd0),
        .broadcast_value_i(128'd0), .rob_head_index_i(rob_head_index),
        .rollback_valid_i(rollback_valid), .rollback_tag_i(rollback_tag),
        .address_valid_o(store_address_valid),
        .address_ready_i(store_address_ready), .address_o(store_address),
        .address_rob_tag_o(store_address_rob_tag),
        .address_lsq_tag_o(store_address_lsq_tag),
        .data_valid_o(store_data_valid), .data_ready_i(store_data_ready),
        .data_o(store_data), .data_rob_tag_o(store_data_rob_tag),
        .data_lsq_tag_o(store_data_lsq_tag)
    );

    rv32_load_store_queue #(
        .BE_WIDTH(BE_WIDTH)
    ) lsq (
        .clk_i(clk), .reset_i(reset), .flush_i(1'b0),
        .recover_i(recover_busy),
        .alloc_valid_i(lsq_alloc_valid),
        .alloc_fire_i(dispatch_fire), .alloc_store_i(lsq_alloc_store),
        .alloc_rob_tag_i(lsq_alloc_rob_tag),
        .alloc_width_i(lsq_alloc_width),
        .alloc_unsigned_i(lsq_alloc_unsigned), .alloc_ready_o(lsq_ready),
        .alloc_lsq_tag_o(lsq_alloc_tag), .occupancy_o(lsq_occupancy),
        .load_address_valid_i(load_address_valid),
        .load_address_ready_o(load_address_ready),
        .load_address_rob_tag_i(load_address_rob_tag),
        .load_address_lsq_tag_i(load_address_lsq_tag),
        .load_address_i(load_address),
        .store_address_valid_i(store_address_valid),
        .store_address_ready_o(store_address_ready),
        .store_address_rob_tag_i(store_address_rob_tag),
        .store_address_lsq_tag_i(store_address_lsq_tag),
        .store_address_i(store_address), .store_data_valid_i(store_data_valid),
        .store_data_ready_o(store_data_ready),
        .store_data_rob_tag_i(store_data_rob_tag),
        .store_data_lsq_tag_i(store_data_lsq_tag), .store_data_i(store_data),
        .rob_head_index_i(rob_head_index), .rollback_valid_i(rollback_valid),
        .rollback_rob_tag_i(rollback_tag),
        .rollback_lsq_tag_i(rollback_lsq_tag), .completion_valid_o(),
        .completion_ready_i(1'b0), .completion_rob_tag_o(),
        .completion_value_o(), .completion_exception_valid_o(),
        .completion_exception_cause_o(), .completion_exception_tval_o(),
        .commit_valid_i(commit_valid), .commit_op_i(commit_op),
        .commit_lsq_valid_i(commit_lsq_valid), .commit_rob_tag_i(commit_tag),
        .commit_lsq_tag_i(commit_lsq_tag),
        .commit_exception_valid_i(commit_exception_valid),
        .commit_fire_i(commit_fire), .commit_ready_o(lsq_commit_ready),
        .cache_request_valid_o(), .cache_request_ready_i(1'b0),
        .cache_request_write_o(), .cache_request_address_o(),
        .cache_request_write_data_o(), .cache_request_byte_enable_o(),
        .cache_response_valid_i(1'b0), .cache_response_ready_o(),
        .cache_response_read_data_i(32'd0), .cache_response_error_i(1'b0)
    );

    always #5 clk = ~clk;

    task check;
        input condition;
        input integer id;
        begin
            if (!condition) begin
                errors = errors + 1;
                $display("FAIL dispatch integration check=%0d time=%0t", id, $time);
            end
        end
    endtask

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        clk = 0;
        reset = 1;
        fetch_valid = 0;
        fetch_pc = 0;
        fetch_instruction = 0;
        fetch_predicted_next_pc = 0;
        completion_valid = 0;
        completion_tag = 0;
        completion_value = 0;
        completion_control_valid = 0;
        completion_control_taken = 0;
        completion_next_pc = 0;
        errors = 0;
        repeat (2) tick;
        reset = 0;

        fetch_valid = 4'b1111;
        fetch_pc[31:0] = 32'h100;
        fetch_pc[63:32] = 32'h104;
        fetch_pc[95:64] = 32'h108;
        fetch_pc[127:96] = 32'h10c;
        fetch_instruction[31:0] = 32'h00000463;
        fetch_instruction[63:32] = 32'h00100293;
        fetch_instruction[95:64] = 32'h00002303;
        fetch_instruction[127:96] = 32'h00502023;
        fetch_predicted_next_pc[31:0] = 32'h104;
        fetch_predicted_next_pc[63:32] = 32'h108;
        fetch_predicted_next_pc[95:64] = 32'h10c;
        fetch_predicted_next_pc[127:96] = 32'h110;
        #1;
        check(dispatch_fire && fetch_ready == 4'b1111, 1);
        check(int_dispatch_valid == 4'b0011 &&
            load_dispatch_valid == 4'b0100 &&
            store_dispatch_valid == 4'b1000, 2);
        branch_tag = dispatch_rob_tag[ROB_TAG_WIDTH-1:0];
        tick;
        fetch_valid = 0;
        #1;
        check(rob_occupancy == 4 && int_occupancy == 2, 3);
        check(load_occupancy == 1 && store_occupancy == 1 &&
            lsq_occupancy == 2, 4);
        check(free_count == 30, 5);

        completion_valid[0] = 1'b1;
        completion_tag[ROB_TAG_WIDTH-1:0] = branch_tag;
        completion_control_valid[0] = 1'b1;
        completion_control_taken[0] = 1'b1;
        completion_next_pc[31:0] = 32'h108;
        tick;
        completion_valid = 0;
        completion_control_valid = 0;
        #1;
        check(recover_busy, 6);
        fetch_valid[0] = 1'b1;
        fetch_instruction[31:0] = 32'h00100393;
        #1;
        check(!dispatch_fire && fetch_ready == 0, 7);
        tick;
        fetch_valid = 0;
        #1;
        check(!recover_busy && rob_occupancy == 1, 8);
        check(int_occupancy == 1 && load_occupancy == 0 &&
            store_occupancy == 0 && lsq_occupancy == 0, 9);
        check(free_count == 32, 10);

        if (errors != 0) begin
            $display("FAIL rv32_dispatch_integration_tb errors=%0d", errors);
            $finish(1);
        end
        $display("PASS rv32_dispatch_integration_tb");
        $finish;
    end

endmodule
