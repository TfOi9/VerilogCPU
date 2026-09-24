`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_cpu_core #(
    parameter FE_WIDTH = 1,
    parameter BE_WIDTH = 1,
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter ROB_ENTRIES = 32,
    parameter ROB_INDEX_WIDTH = 5,
    parameter ROB_TAG_WIDTH = 7,
    parameter INT_RS_ENTRIES = 8,
    parameter INT_RS_INDEX_WIDTH = 3,
    parameter MUL_RS_ENTRIES = 4,
    parameter MUL_RS_INDEX_WIDTH = 2,
    parameter DIV_RS_ENTRIES = 4,
    parameter DIV_RS_INDEX_WIDTH = 2,
    parameter LOAD_RS_ENTRIES = 8,
    parameter LOAD_RS_INDEX_WIDTH = 3,
    parameter STORE_RS_ENTRIES = 8,
    parameter STORE_RS_INDEX_WIDTH = 3,
    parameter LSQ_ENTRIES = 8,
    parameter LSQ_INDEX_WIDTH = 3,
    parameter LSQ_TAG_WIDTH = 5,
    parameter FETCH_QUEUE_ENTRIES = 8,
    parameter FETCH_QUEUE_INDEX_WIDTH = 3
) (
    input  wire clk_i,
    input  wire reset_i,

    output wire icache_flush_o,
    output wire icache_request_valid_o,
    input  wire icache_request_ready_i,
    output wire [31:0] icache_request_pc_o,
    input  wire icache_response_valid_i,
    output wire icache_response_ready_o,
    input  wire [31:0] icache_response_pc_i,
    input  wire [127:0] icache_response_line_i,
    input  wire icache_response_error_i,

    output wire dcache_request_valid_o,
    input  wire dcache_request_ready_i,
    output wire dcache_request_write_o,
    output wire [31:0] dcache_request_address_o,
    output wire [31:0] dcache_request_write_data_o,
    output wire [3:0] dcache_request_byte_enable_o,
    output wire dcache_request_mmio_o,
    input  wire dcache_response_valid_i,
    output wire dcache_response_ready_o,
    input  wire [31:0] dcache_response_read_data_i,
    input  wire dcache_response_error_i
);
    /* verilator lint_off PINCONNECTEMPTY */
    /* verilator lint_off UNUSEDSIGNAL */
    localparam COMPLETION_SOURCES = 4;

    wire recover_busy;
    wire recover_redirect_valid;
    wire [31:0] recover_redirect_pc;
    reg fatal_reg;
    wire pipeline_hold;

    wire [FE_WIDTH-1:0] fetch_valid;
    wire [FE_WIDTH-1:0] fetch_ready;
    wire [(FE_WIDTH*32)-1:0] fetch_pc;
    wire [(FE_WIDTH*32)-1:0] fetch_instruction;
    wire [(FE_WIDTH*32)-1:0] fetch_predicted_next_pc;
    wire [FE_WIDTH-1:0] fetch_error;

    wire [BE_WIDTH-1:0] predictor_update_valid;
    wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] predictor_update_op;
    wire [(BE_WIDTH*32)-1:0] predictor_update_pc;
    wire [(BE_WIDTH*32)-1:0] predictor_update_predicted_next_pc;
    wire [(BE_WIDTH*32)-1:0] predictor_update_actual_next_pc;
    wire [BE_WIDTH-1:0] predictor_update_actual_taken;

    wire dispatch_fire;
    wire [BE_WIDTH-1:0] dispatch_valid;
    wire [BE_WIDTH-1:0] int_dispatch_valid;
    wire [BE_WIDTH-1:0] mul_dispatch_valid;
    wire [BE_WIDTH-1:0] div_dispatch_valid;
    wire [BE_WIDTH-1:0] load_dispatch_valid;
    wire [BE_WIDTH-1:0] store_dispatch_valid;
    wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] dispatch_op;
    wire [(BE_WIDTH*32)-1:0] dispatch_pc;
    wire [(BE_WIDTH*32)-1:0] dispatch_instruction;
    wire [(BE_WIDTH*32)-1:0] dispatch_immediate;
    wire [(BE_WIDTH*32)-1:0] dispatch_predicted_next_pc;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] dispatch_rob_tag;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] dispatch_lsq_tag;
    wire [BE_WIDTH-1:0] dispatch_lhs_ready;
    wire [(BE_WIDTH*32)-1:0] dispatch_lhs_value;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] dispatch_lhs_phys;
    wire [BE_WIDTH-1:0] dispatch_rhs_ready;
    wire [(BE_WIDTH*32)-1:0] dispatch_rhs_value;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] dispatch_rhs_phys;

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
    wire rob_alloc_ready;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rob_alloc_tag;
    wire [ROB_INDEX_WIDTH:0] rob_occupancy;
    wire [ROB_INDEX_WIDTH-1:0] rob_head_index;

    wire [BE_WIDTH-1:0] lsq_alloc_valid;
    wire [BE_WIDTH-1:0] lsq_alloc_store;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] lsq_alloc_rob_tag;
    wire [(BE_WIDTH*`RV32_MEMORY_WIDTH)-1:0] lsq_alloc_width;
    wire [BE_WIDTH-1:0] lsq_alloc_unsigned;
    wire lsq_alloc_ready;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] lsq_alloc_tag;
    wire [LSQ_INDEX_WIDTH:0] lsq_occupancy;

    wire int_dispatch_ready;
    wire [INT_RS_INDEX_WIDTH:0] int_occupancy;
    wire mul_dispatch_ready;
    wire [MUL_RS_INDEX_WIDTH:0] mul_occupancy;
    wire div_dispatch_ready;
    wire [DIV_RS_INDEX_WIDTH:0] div_occupancy;
    wire load_dispatch_ready;
    wire [LOAD_RS_INDEX_WIDTH:0] load_occupancy;
    wire store_dispatch_ready;
    wire [STORE_RS_INDEX_WIDTH:0] store_occupancy;

    wire [BE_WIDTH-1:0] rollback_valid;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_tag;
    wire [BE_WIDTH-1:0] rollback_writes_rd;
    wire [(BE_WIDTH*5)-1:0] rollback_rd;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rollback_new_phys;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rollback_old_phys;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] rollback_lsq_tag;

    wire [BE_WIDTH-1:0] int_issue_valid;
    wire [BE_WIDTH-1:0] int_issue_ready;
    wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] int_issue_op;
    wire [(BE_WIDTH*32)-1:0] int_issue_lhs;
    wire [(BE_WIDTH*32)-1:0] int_issue_rhs;
    wire [(BE_WIDTH*32)-1:0] int_issue_pc;
    wire [(BE_WIDTH*32)-1:0] int_issue_immediate;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] int_issue_rob_tag;

    wire alu_response_valid;
    wire alu_response_ready;
    wire [31:0] alu_response_value;
    wire [ROB_TAG_WIDTH-1:0] alu_response_rob_tag;
    wire alu_response_control_valid;
    wire alu_response_control_taken;
    wire [31:0] alu_response_next_pc;

    wire mul_response_valid;
    wire mul_response_ready;
    wire [31:0] mul_response_value;
    wire [ROB_TAG_WIDTH-1:0] mul_response_rob_tag;
    wire div_response_valid;
    wire div_response_ready;
    wire [31:0] div_response_value;
    wire [ROB_TAG_WIDTH-1:0] div_response_rob_tag;

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

    wire lsq_completion_valid;
    wire lsq_completion_ready;
    wire [ROB_TAG_WIDTH-1:0] lsq_completion_rob_tag;
    wire [31:0] lsq_completion_value;
    wire lsq_completion_exception_valid;
    wire [3:0] lsq_completion_exception_cause;
    wire [31:0] lsq_completion_exception_tval;

    wire [COMPLETION_SOURCES-1:0] source_valid;
    wire [COMPLETION_SOURCES-1:0] source_ready;
    wire [(COMPLETION_SOURCES*ROB_TAG_WIDTH)-1:0] source_rob_tag;
    wire [(COMPLETION_SOURCES*32)-1:0] source_value;
    wire [COMPLETION_SOURCES-1:0] source_control_valid;
    wire [COMPLETION_SOURCES-1:0] source_control_taken;
    wire [(COMPLETION_SOURCES*32)-1:0] source_next_pc;
    wire [COMPLETION_SOURCES-1:0] source_exception_valid;
    wire [(COMPLETION_SOURCES*4)-1:0] source_exception_cause;
    wire [(COMPLETION_SOURCES*32)-1:0] source_exception_tval;

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

    wire [BE_WIDTH-1:0] commit_ready;
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

    assign pipeline_hold = recover_busy || fatal_reg;
    assign commit_ready = lsq_commit_ready & ~commit_exception_valid &
        {BE_WIDTH{!fatal_reg}};

    assign source_valid = {lsq_completion_valid, div_response_valid,
        mul_response_valid, alu_response_valid};
    assign source_rob_tag = {lsq_completion_rob_tag, div_response_rob_tag,
        mul_response_rob_tag, alu_response_rob_tag};
    assign source_value = {lsq_completion_value, div_response_value,
        mul_response_value, alu_response_value};
    assign source_control_valid = {3'b000, alu_response_control_valid};
    assign source_control_taken = {3'b000, alu_response_control_taken};
    assign source_next_pc = {96'd0, alu_response_next_pc};
    assign source_exception_valid = {lsq_completion_exception_valid, 3'b000};
    assign source_exception_cause = {lsq_completion_exception_cause, 12'd0};
    assign source_exception_tval = {lsq_completion_exception_tval, 96'd0};
    assign alu_response_ready = source_ready[0];
    assign mul_response_ready = source_ready[1];
    assign div_response_ready = source_ready[2];
    assign lsq_completion_ready = source_ready[3];

    initial begin
        if (FE_WIDTH != 1 || BE_WIDTH != 1) begin
            $display("ERROR rv32_cpu_core only supports single issue");
            $finish(1);
        end
    end

    always @(posedge clk_i) begin
        if (reset_i)
            fatal_reg <= 1'b0;
        else if (commit_valid[0] && commit_exception_valid[0])
            fatal_reg <= 1'b1;
    end

    rv32_fetch_pipeline #(
        .FE_WIDTH(FE_WIDTH), .BE_WIDTH(BE_WIDTH),
        .FETCH_QUEUE_ENTRIES(FETCH_QUEUE_ENTRIES),
        .FETCH_QUEUE_INDEX_WIDTH(FETCH_QUEUE_INDEX_WIDTH)
    ) fetch_pipeline (
        .clk_i(clk_i), .reset_i(reset_i),
        .redirect_valid_i(recover_redirect_valid),
        .redirect_pc_i(recover_redirect_pc),
        .icache_flush_o(icache_flush_o),
        .icache_request_valid_o(icache_request_valid_o),
        .icache_request_ready_i(icache_request_ready_i),
        .icache_request_pc_o(icache_request_pc_o),
        .icache_response_valid_i(icache_response_valid_i),
        .icache_response_ready_o(icache_response_ready_o),
        .icache_response_pc_i(icache_response_pc_i),
        .icache_response_line_i(icache_response_line_i),
        .icache_response_error_i(icache_response_error_i),
        .predictor_update_valid_i(predictor_update_valid),
        .predictor_update_op_i(predictor_update_op),
        .predictor_update_pc_i(predictor_update_pc),
        .predictor_update_predicted_next_pc_i(
            predictor_update_predicted_next_pc),
        .predictor_update_actual_next_pc_i(
            predictor_update_actual_next_pc),
        .predictor_update_actual_taken_i(predictor_update_actual_taken),
        .conditional_correct_o(), .conditional_total_o(),
        .jal_correct_o(), .jal_total_o(), .jalr_correct_o(),
        .jalr_total_o(), .control_correct_o(), .control_total_o(),
        .fetch_valid_o(fetch_valid), .fetch_ready_i(fetch_ready),
        .fetch_pc_o(fetch_pc), .fetch_instruction_o(fetch_instruction),
        .fetch_predicted_next_pc_o(fetch_predicted_next_pc),
        .fetch_error_o(fetch_error), .fetch_occupancy_o()
    );

    rv32_decode_rename_dispatch #(
        .FE_WIDTH(FE_WIDTH), .BE_WIDTH(BE_WIDTH),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH), .INT_RS_ENTRIES(INT_RS_ENTRIES),
        .INT_RS_INDEX_WIDTH(INT_RS_INDEX_WIDTH),
        .MUL_RS_ENTRIES(MUL_RS_ENTRIES),
        .MUL_RS_INDEX_WIDTH(MUL_RS_INDEX_WIDTH),
        .DIV_RS_ENTRIES(DIV_RS_ENTRIES),
        .DIV_RS_INDEX_WIDTH(DIV_RS_INDEX_WIDTH),
        .LOAD_RS_ENTRIES(LOAD_RS_ENTRIES),
        .LOAD_RS_INDEX_WIDTH(LOAD_RS_INDEX_WIDTH),
        .STORE_RS_ENTRIES(STORE_RS_ENTRIES),
        .STORE_RS_INDEX_WIDTH(STORE_RS_INDEX_WIDTH),
        .LSQ_ENTRIES(LSQ_ENTRIES), .LSQ_INDEX_WIDTH(LSQ_INDEX_WIDTH),
        .LSQ_TAG_WIDTH(LSQ_TAG_WIDTH)
    ) dispatch_pipeline (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(1'b0),
        .recover_i(pipeline_hold), .fetch_valid_i(fetch_valid),
        .fetch_ready_o(fetch_ready), .fetch_pc_i(fetch_pc),
        .fetch_instruction_i(fetch_instruction),
        .fetch_predicted_next_pc_i(fetch_predicted_next_pc),
        .fetch_error_i(fetch_error), .rob_alloc_ready_i(rob_alloc_ready),
        .rob_alloc_tag_i(rob_alloc_tag), .rob_occupancy_i(rob_occupancy),
        .int_dispatch_ready_i(int_dispatch_ready),
        .int_occupancy_i(int_occupancy),
        .mul_dispatch_ready_i(mul_dispatch_ready),
        .mul_occupancy_i(mul_occupancy),
        .div_dispatch_ready_i(div_dispatch_ready),
        .div_occupancy_i(div_occupancy),
        .load_dispatch_ready_i(load_dispatch_ready),
        .load_occupancy_i(load_occupancy),
        .store_dispatch_ready_i(store_dispatch_ready),
        .store_occupancy_i(store_occupancy),
        .lsq_alloc_ready_i(lsq_alloc_ready),
        .lsq_alloc_tag_i(lsq_alloc_tag), .lsq_occupancy_i(lsq_occupancy),
        .dispatch_fire_o(dispatch_fire),
        .dispatch_valid_o(dispatch_valid),
        .int_dispatch_valid_o(int_dispatch_valid),
        .mul_dispatch_valid_o(mul_dispatch_valid),
        .div_dispatch_valid_o(div_dispatch_valid),
        .load_dispatch_valid_o(load_dispatch_valid),
        .store_dispatch_valid_o(store_dispatch_valid),
        .dispatch_op_o(dispatch_op), .dispatch_pc_o(dispatch_pc),
        .dispatch_instruction_o(dispatch_instruction),
        .dispatch_immediate_o(dispatch_immediate),
        .dispatch_predicted_next_pc_o(dispatch_predicted_next_pc),
        .dispatch_rob_tag_o(dispatch_rob_tag),
        .dispatch_lsq_tag_o(dispatch_lsq_tag),
        .dispatch_lhs_ready_o(dispatch_lhs_ready),
        .dispatch_lhs_value_o(dispatch_lhs_value),
        .dispatch_lhs_phys_o(dispatch_lhs_phys),
        .dispatch_rhs_ready_o(dispatch_rhs_ready),
        .dispatch_rhs_value_o(dispatch_rhs_value),
        .dispatch_rhs_phys_o(dispatch_rhs_phys),
        .rob_alloc_valid_o(rob_alloc_valid),
        .rob_alloc_pc_o(rob_alloc_pc),
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
        .writeback_valid_i(writeback_valid),
        .writeback_phys_i(writeback_phys),
        .writeback_value_i(writeback_value), .free_count_o()
    );

    rv32_reorder_buffer #(
        .ROB_ENTRIES(ROB_ENTRIES), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH), .BE_WIDTH(BE_WIDTH),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .LSQ_TAG_WIDTH(LSQ_TAG_WIDTH)
    ) rob (
        .clk_i(clk_i), .reset_i(reset_i),
        .alloc_valid_i(rob_alloc_valid), .alloc_fire_i(dispatch_fire),
        .alloc_pc_i(rob_alloc_pc),
        .alloc_instruction_i(rob_alloc_instruction),
        .alloc_op_i(rob_alloc_op),
        .alloc_writes_rd_i(rob_alloc_writes_rd),
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
        .predictor_update_valid_o(predictor_update_valid),
        .predictor_update_op_o(predictor_update_op),
        .predictor_update_pc_o(predictor_update_pc),
        .predictor_update_predicted_next_pc_o(
            predictor_update_predicted_next_pc),
        .predictor_update_actual_next_pc_o(
            predictor_update_actual_next_pc),
        .predictor_update_actual_taken_o(predictor_update_actual_taken),
        .commit_ready_i(commit_ready), .commit_valid_o(commit_valid),
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
        .recover_busy_o(recover_busy),
        .recover_redirect_valid_o(recover_redirect_valid),
        .recover_redirect_pc_o(recover_redirect_pc),
        .rollback_valid_o(rollback_valid), .rollback_tag_o(rollback_tag),
        .rollback_writes_rd_o(rollback_writes_rd),
        .rollback_rd_o(rollback_rd),
        .rollback_new_phys_o(rollback_new_phys),
        .rollback_old_phys_o(rollback_old_phys),
        .rollback_lsq_valid_o(), .rollback_lsq_tag_o(rollback_lsq_tag)
    );

    rv32_integer_reservation_station #(
        .INT_RS_ENTRIES(INT_RS_ENTRIES),
        .INT_RS_INDEX_WIDTH(INT_RS_INDEX_WIDTH), .BE_WIDTH(BE_WIDTH),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) int_rs (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(1'b0),
        .recover_i(pipeline_hold), .dispatch_valid_i(int_dispatch_valid),
        .dispatch_fire_i(dispatch_fire), .dispatch_op_i(dispatch_op),
        .dispatch_pc_i(dispatch_pc),
        .dispatch_immediate_i(dispatch_immediate),
        .dispatch_rob_tag_i(dispatch_rob_tag),
        .dispatch_lhs_ready_i(dispatch_lhs_ready),
        .dispatch_lhs_value_i(dispatch_lhs_value),
        .dispatch_lhs_phys_i(dispatch_lhs_phys),
        .dispatch_rhs_ready_i(dispatch_rhs_ready),
        .dispatch_rhs_value_i(dispatch_rhs_value),
        .dispatch_rhs_phys_i(dispatch_rhs_phys),
        .dispatch_ready_o(int_dispatch_ready),
        .occupancy_o(int_occupancy), .broadcast_valid_i(writeback_valid),
        .broadcast_phys_i(writeback_phys),
        .broadcast_value_i(writeback_value),
        .rob_head_index_i(rob_head_index),
        .rollback_valid_i(rollback_valid),
        .rollback_tag_i(rollback_tag), .issue_valid_o(int_issue_valid),
        .issue_ready_i(int_issue_ready), .issue_op_o(int_issue_op),
        .issue_lhs_o(int_issue_lhs), .issue_rhs_o(int_issue_rhs),
        .issue_pc_o(int_issue_pc),
        .issue_immediate_o(int_issue_immediate),
        .issue_rob_tag_o(int_issue_rob_tag)
    );

    rv32i_alu #(.ROB_TAG_WIDTH(ROB_TAG_WIDTH)) alu (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(1'b0),
        .request_valid_i(int_issue_valid[0]),
        .request_ready_o(int_issue_ready[0]),
        .request_op_i(int_issue_op[0 +: `RV32_OP_WIDTH]),
        .request_lhs_i(int_issue_lhs[0 +: 32]),
        .request_rhs_i(int_issue_rhs[0 +: 32]),
        .request_pc_i(int_issue_pc[0 +: 32]),
        .request_immediate_i(int_issue_immediate[0 +: 32]),
        .request_rob_tag_i(int_issue_rob_tag[0 +: ROB_TAG_WIDTH]),
        .response_valid_o(alu_response_valid),
        .response_ready_i(alu_response_ready),
        .response_value_o(alu_response_value),
        .response_rob_tag_o(alu_response_rob_tag),
        .response_control_valid_o(alu_response_control_valid),
        .response_control_taken_o(alu_response_control_taken),
        .response_next_pc_o(alu_response_next_pc)
    );

    rv32_multiply_reservation_station #(
        .MUL_RS_ENTRIES(MUL_RS_ENTRIES),
        .MUL_RS_INDEX_WIDTH(MUL_RS_INDEX_WIDTH), .BE_WIDTH(BE_WIDTH),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) mul_rs (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(1'b0),
        .recover_i(pipeline_hold), .dispatch_valid_i(mul_dispatch_valid),
        .dispatch_fire_i(dispatch_fire), .dispatch_op_i(dispatch_op),
        .dispatch_rob_tag_i(dispatch_rob_tag),
        .dispatch_lhs_ready_i(dispatch_lhs_ready),
        .dispatch_lhs_value_i(dispatch_lhs_value),
        .dispatch_lhs_phys_i(dispatch_lhs_phys),
        .dispatch_rhs_ready_i(dispatch_rhs_ready),
        .dispatch_rhs_value_i(dispatch_rhs_value),
        .dispatch_rhs_phys_i(dispatch_rhs_phys),
        .dispatch_ready_o(mul_dispatch_ready),
        .occupancy_o(mul_occupancy), .broadcast_valid_i(writeback_valid),
        .broadcast_phys_i(writeback_phys),
        .broadcast_value_i(writeback_value),
        .rob_head_index_i(rob_head_index),
        .rollback_valid_i(rollback_valid), .rollback_tag_i(rollback_tag),
        .response_valid_o(mul_response_valid),
        .response_ready_i(mul_response_ready),
        .response_value_o(mul_response_value),
        .response_rob_tag_o(mul_response_rob_tag)
    );

    rv32_divide_reservation_station #(
        .DIV_RS_ENTRIES(DIV_RS_ENTRIES),
        .DIV_RS_INDEX_WIDTH(DIV_RS_INDEX_WIDTH), .BE_WIDTH(BE_WIDTH),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) div_rs (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(1'b0),
        .recover_i(pipeline_hold), .dispatch_valid_i(div_dispatch_valid),
        .dispatch_fire_i(dispatch_fire), .dispatch_op_i(dispatch_op),
        .dispatch_rob_tag_i(dispatch_rob_tag),
        .dispatch_lhs_ready_i(dispatch_lhs_ready),
        .dispatch_lhs_value_i(dispatch_lhs_value),
        .dispatch_lhs_phys_i(dispatch_lhs_phys),
        .dispatch_rhs_ready_i(dispatch_rhs_ready),
        .dispatch_rhs_value_i(dispatch_rhs_value),
        .dispatch_rhs_phys_i(dispatch_rhs_phys),
        .dispatch_ready_o(div_dispatch_ready),
        .occupancy_o(div_occupancy), .broadcast_valid_i(writeback_valid),
        .broadcast_phys_i(writeback_phys),
        .broadcast_value_i(writeback_value),
        .rob_head_index_i(rob_head_index),
        .rollback_valid_i(rollback_valid), .rollback_tag_i(rollback_tag),
        .response_valid_o(div_response_valid),
        .response_ready_i(div_response_ready),
        .response_value_o(div_response_value),
        .response_rob_tag_o(div_response_rob_tag)
    );

    rv32_memory_reservation_station #(
        .IS_STORE(0), .RS_ENTRIES(LOAD_RS_ENTRIES),
        .RS_INDEX_WIDTH(LOAD_RS_INDEX_WIDTH), .BE_WIDTH(BE_WIDTH),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH), .LSQ_TAG_WIDTH(LSQ_TAG_WIDTH)
    ) load_rs (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(1'b0),
        .recover_i(pipeline_hold), .dispatch_valid_i(load_dispatch_valid),
        .dispatch_fire_i(dispatch_fire),
        .dispatch_rob_tag_i(dispatch_rob_tag),
        .dispatch_lsq_tag_i(dispatch_lsq_tag),
        .dispatch_immediate_i(dispatch_immediate),
        .dispatch_base_ready_i(dispatch_lhs_ready),
        .dispatch_base_value_i(dispatch_lhs_value),
        .dispatch_base_phys_i(dispatch_lhs_phys),
        .dispatch_data_ready_i(dispatch_rhs_ready),
        .dispatch_data_value_i(dispatch_rhs_value),
        .dispatch_data_phys_i(dispatch_rhs_phys),
        .dispatch_ready_o(load_dispatch_ready),
        .occupancy_o(load_occupancy), .broadcast_valid_i(writeback_valid),
        .broadcast_phys_i(writeback_phys),
        .broadcast_value_i(writeback_value),
        .rob_head_index_i(rob_head_index),
        .rollback_valid_i(rollback_valid), .rollback_tag_i(rollback_tag),
        .address_valid_o(load_address_valid),
        .address_ready_i(load_address_ready), .address_o(load_address),
        .address_rob_tag_o(load_address_rob_tag),
        .address_lsq_tag_o(load_address_lsq_tag),
        .data_valid_o(), .data_ready_i(1'b1), .data_o(),
        .data_rob_tag_o(), .data_lsq_tag_o()
    );

    rv32_memory_reservation_station #(
        .IS_STORE(1), .RS_ENTRIES(STORE_RS_ENTRIES),
        .RS_INDEX_WIDTH(STORE_RS_INDEX_WIDTH), .BE_WIDTH(BE_WIDTH),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH), .LSQ_TAG_WIDTH(LSQ_TAG_WIDTH)
    ) store_rs (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(1'b0),
        .recover_i(pipeline_hold), .dispatch_valid_i(store_dispatch_valid),
        .dispatch_fire_i(dispatch_fire),
        .dispatch_rob_tag_i(dispatch_rob_tag),
        .dispatch_lsq_tag_i(dispatch_lsq_tag),
        .dispatch_immediate_i(dispatch_immediate),
        .dispatch_base_ready_i(dispatch_lhs_ready),
        .dispatch_base_value_i(dispatch_lhs_value),
        .dispatch_base_phys_i(dispatch_lhs_phys),
        .dispatch_data_ready_i(dispatch_rhs_ready),
        .dispatch_data_value_i(dispatch_rhs_value),
        .dispatch_data_phys_i(dispatch_rhs_phys),
        .dispatch_ready_o(store_dispatch_ready),
        .occupancy_o(store_occupancy), .broadcast_valid_i(writeback_valid),
        .broadcast_phys_i(writeback_phys),
        .broadcast_value_i(writeback_value),
        .rob_head_index_i(rob_head_index),
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
        .LSQ_ENTRIES(LSQ_ENTRIES), .LSQ_INDEX_WIDTH(LSQ_INDEX_WIDTH),
        .LSQ_TAG_WIDTH(LSQ_TAG_WIDTH), .BE_WIDTH(BE_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) lsq (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(1'b0),
        .recover_i(pipeline_hold), .alloc_valid_i(lsq_alloc_valid),
        .alloc_fire_i(dispatch_fire), .alloc_store_i(lsq_alloc_store),
        .alloc_rob_tag_i(lsq_alloc_rob_tag),
        .alloc_width_i(lsq_alloc_width),
        .alloc_unsigned_i(lsq_alloc_unsigned),
        .alloc_ready_o(lsq_alloc_ready), .alloc_lsq_tag_o(lsq_alloc_tag),
        .occupancy_o(lsq_occupancy),
        .load_address_valid_i(load_address_valid),
        .load_address_ready_o(load_address_ready),
        .load_address_rob_tag_i(load_address_rob_tag),
        .load_address_lsq_tag_i(load_address_lsq_tag),
        .load_address_i(load_address),
        .store_address_valid_i(store_address_valid),
        .store_address_ready_o(store_address_ready),
        .store_address_rob_tag_i(store_address_rob_tag),
        .store_address_lsq_tag_i(store_address_lsq_tag),
        .store_address_i(store_address),
        .store_data_valid_i(store_data_valid),
        .store_data_ready_o(store_data_ready),
        .store_data_rob_tag_i(store_data_rob_tag),
        .store_data_lsq_tag_i(store_data_lsq_tag),
        .store_data_i(store_data), .rob_head_index_i(rob_head_index),
        .rollback_valid_i(rollback_valid),
        .rollback_rob_tag_i(rollback_tag),
        .rollback_lsq_tag_i(rollback_lsq_tag),
        .completion_valid_o(lsq_completion_valid),
        .completion_ready_i(lsq_completion_ready),
        .completion_rob_tag_o(lsq_completion_rob_tag),
        .completion_value_o(lsq_completion_value),
        .completion_exception_valid_o(lsq_completion_exception_valid),
        .completion_exception_cause_o(lsq_completion_exception_cause),
        .completion_exception_tval_o(lsq_completion_exception_tval),
        .commit_valid_i(commit_valid), .commit_op_i(commit_op),
        .commit_lsq_valid_i(commit_lsq_valid),
        .commit_rob_tag_i(commit_tag), .commit_lsq_tag_i(commit_lsq_tag),
        .commit_exception_valid_i(commit_exception_valid),
        .commit_fire_i(commit_fire), .commit_ready_o(lsq_commit_ready),
        .cache_request_valid_o(dcache_request_valid_o),
        .cache_request_ready_i(dcache_request_ready_i),
        .cache_request_write_o(dcache_request_write_o),
        .cache_request_address_o(dcache_request_address_o),
        .cache_request_write_data_o(dcache_request_write_data_o),
        .cache_request_byte_enable_o(dcache_request_byte_enable_o),
        .cache_request_mmio_o(dcache_request_mmio_o),
        .cache_response_valid_i(dcache_response_valid_i),
        .cache_response_ready_o(dcache_response_ready_o),
        .cache_response_read_data_i(dcache_response_read_data_i),
        .cache_response_error_i(dcache_response_error_i)
    );

    rv32_completion_writeback_network #(
        .BE_WIDTH(BE_WIDTH), .SOURCE_COUNT(COMPLETION_SOURCES),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) writeback_network (
        .clk_i(clk_i), .reset_i(reset_i), .flush_i(1'b0),
        .recover_i(pipeline_hold), .source_valid_i(source_valid),
        .source_ready_o(source_ready), .source_rob_tag_i(source_rob_tag),
        .source_value_i(source_value),
        .source_control_valid_i(source_control_valid),
        .source_control_taken_i(source_control_taken),
        .source_next_pc_i(source_next_pc),
        .source_exception_valid_i(source_exception_valid),
        .source_exception_cause_i(source_exception_cause),
        .source_exception_tval_i(source_exception_tval),
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
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_on PINCONNECTEMPTY */
endmodule
