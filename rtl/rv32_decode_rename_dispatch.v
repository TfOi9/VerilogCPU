`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32_decode_rename_dispatch #(
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
    parameter LSQ_TAG_WIDTH = 5
) (
    input  wire                                             clk_i,
    input  wire                                             reset_i,
    input  wire                                             flush_i,
    input  wire                                             recover_i,

    input  wire [FE_WIDTH-1:0]                              fetch_valid_i,
    output wire [FE_WIDTH-1:0]                              fetch_ready_o,
    input  wire [(FE_WIDTH*32)-1:0]                         fetch_pc_i,
    input  wire [(FE_WIDTH*32)-1:0]                         fetch_instruction_i,
    input  wire [(FE_WIDTH*32)-1:0]
                                                            fetch_predicted_next_pc_i,
    input  wire [FE_WIDTH-1:0]                              fetch_error_i,

    input  wire                                             rob_alloc_ready_i,
    input  wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              rob_alloc_tag_i,
    input  wire [ROB_INDEX_WIDTH:0]                         rob_occupancy_i,
    input  wire                                             int_dispatch_ready_i,
    input  wire [INT_RS_INDEX_WIDTH:0]                      int_occupancy_i,
    input  wire                                             mul_dispatch_ready_i,
    input  wire [MUL_RS_INDEX_WIDTH:0]                      mul_occupancy_i,
    input  wire                                             div_dispatch_ready_i,
    input  wire [DIV_RS_INDEX_WIDTH:0]                      div_occupancy_i,
    input  wire                                             load_dispatch_ready_i,
    input  wire [LOAD_RS_INDEX_WIDTH:0]                     load_occupancy_i,
    input  wire                                             store_dispatch_ready_i,
    input  wire [STORE_RS_INDEX_WIDTH:0]                    store_occupancy_i,
    input  wire                                             lsq_alloc_ready_i,
    input  wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0]              lsq_alloc_tag_i,
    input  wire [LSQ_INDEX_WIDTH:0]                         lsq_occupancy_i,

    output wire                                             dispatch_fire_o,
    output wire [BE_WIDTH-1:0]                              dispatch_valid_o,
    output wire [BE_WIDTH-1:0]                              int_dispatch_valid_o,
    output wire [BE_WIDTH-1:0]                              mul_dispatch_valid_o,
    output wire [BE_WIDTH-1:0]                              div_dispatch_valid_o,
    output wire [BE_WIDTH-1:0]                              load_dispatch_valid_o,
    output wire [BE_WIDTH-1:0]                              store_dispatch_valid_o,
    output wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0]             dispatch_op_o,
    output wire [(BE_WIDTH*32)-1:0]                         dispatch_pc_o,
    output wire [(BE_WIDTH*32)-1:0]                         dispatch_instruction_o,
    output wire [(BE_WIDTH*32)-1:0]                         dispatch_immediate_o,
    output wire [(BE_WIDTH*32)-1:0]
                                                            dispatch_predicted_next_pc_o,
    output wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              dispatch_rob_tag_o,
    output wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0]              dispatch_lsq_tag_o,
    output wire [BE_WIDTH-1:0]                              dispatch_lhs_ready_o,
    output wire [(BE_WIDTH*32)-1:0]                         dispatch_lhs_value_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        dispatch_lhs_phys_o,
    output wire [BE_WIDTH-1:0]                              dispatch_rhs_ready_o,
    output wire [(BE_WIDTH*32)-1:0]                         dispatch_rhs_value_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        dispatch_rhs_phys_o,

    output wire [BE_WIDTH-1:0]                              rob_alloc_valid_o,
    output wire [(BE_WIDTH*32)-1:0]                         rob_alloc_pc_o,
    output wire [(BE_WIDTH*32)-1:0]                         rob_alloc_instruction_o,
    output wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0]             rob_alloc_op_o,
    output wire [BE_WIDTH-1:0]                              rob_alloc_writes_rd_o,
    output wire [(BE_WIDTH*5)-1:0]                          rob_alloc_rd_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        rob_alloc_new_phys_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        rob_alloc_old_phys_o,
    output wire [(BE_WIDTH*32)-1:0]
                                                            rob_alloc_predicted_next_pc_o,
    output wire [BE_WIDTH-1:0]                              rob_alloc_lsq_valid_o,
    output wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0]              rob_alloc_lsq_tag_o,
    output wire [BE_WIDTH-1:0]                              rob_alloc_complete_o,
    output wire [BE_WIDTH-1:0]                              rob_alloc_exception_valid_o,
    output wire [(BE_WIDTH*4)-1:0]                          rob_alloc_exception_cause_o,
    output wire [(BE_WIDTH*32)-1:0]                         rob_alloc_exception_tval_o,

    output wire [BE_WIDTH-1:0]                              lsq_alloc_valid_o,
    output wire [BE_WIDTH-1:0]                              lsq_alloc_store_o,
    output wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              lsq_alloc_rob_tag_o,
    output wire [(BE_WIDTH*`RV32_MEMORY_WIDTH)-1:0]         lsq_alloc_width_o,
    output wire [BE_WIDTH-1:0]                              lsq_alloc_unsigned_o,

    input  wire [BE_WIDTH-1:0]                              commit_valid_i,
    input  wire [BE_WIDTH-1:0]                              commit_writes_rd_i,
    input  wire [(BE_WIDTH*5)-1:0]                          commit_rd_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        commit_new_phys_i,
    input  wire [BE_WIDTH-1:0]                              rollback_valid_i,
    input  wire [BE_WIDTH-1:0]                              rollback_writes_rd_i,
    input  wire [(BE_WIDTH*5)-1:0]                          rollback_rd_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        rollback_new_phys_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        rollback_old_phys_i,
    input  wire [BE_WIDTH-1:0]                              writeback_valid_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        writeback_phys_i,
    input  wire [(BE_WIDTH*32)-1:0]                         writeback_value_i,
    output wire [PHYS_REG_ADDR_WIDTH:0]                     free_count_o
);

    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */

    wire [BE_WIDTH-1:0] decode_legal;
    wire [(BE_WIDTH*`RV32_OP_WIDTH)-1:0] decode_op;
    wire [(BE_WIDTH*`RV32_CLASS_WIDTH)-1:0] decode_class;
    wire [(BE_WIDTH*5)-1:0] decode_rd;
    wire [(BE_WIDTH*5)-1:0] decode_rs1;
    wire [(BE_WIDTH*5)-1:0] decode_rs2;
    wire [BE_WIDTH-1:0] decode_writes_rd;
    wire [(BE_WIDTH*32)-1:0] decode_immediate;
    wire [(BE_WIDTH*`RV32_MEMORY_WIDTH)-1:0] decode_memory_width;
    wire [BE_WIDTH-1:0] decode_load_unsigned;

    reg [BE_WIDTH-1:0] candidate_valid;
    reg [(BE_WIDTH*32)-1:0] candidate_pc;
    reg [(BE_WIDTH*32)-1:0] candidate_instruction;
    reg [(BE_WIDTH*32)-1:0] candidate_predicted_next_pc;
    reg [BE_WIDTH-1:0] candidate_error;
    reg [BE_WIDTH-1:0] selected_valid;
    reg [BE_WIDTH-1:0] int_valid_reg;
    reg [BE_WIDTH-1:0] mul_valid_reg;
    reg [BE_WIDTH-1:0] div_valid_reg;
    reg [BE_WIDTH-1:0] load_valid_reg;
    reg [BE_WIDTH-1:0] store_valid_reg;
    reg [BE_WIDTH-1:0] complete_reg;
    reg [BE_WIDTH-1:0] exception_valid_reg;
    reg [(BE_WIDTH*4)-1:0] exception_cause_reg;
    reg [(BE_WIDTH*32)-1:0] exception_tval_reg;
    reg [FE_WIDTH-1:0] fetch_ready_reg;
    reg dispatch_fire_reg;

    wire rename_ready;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rename_rs1_phys;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rename_rs2_phys;
    wire [BE_WIDTH-1:0] rename_rs1_ready;
    wire [BE_WIDTH-1:0] rename_rs2_ready;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rename_new_phys;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rename_old_phys;
    wire [(2*BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] prf_read_addr;
    wire [(2*BE_WIDTH*32)-1:0] prf_read_data;
    wire [BE_WIDTH-1:0] effective_writeback_valid;
    wire [BE_WIDTH-1:0] effective_writes_rd;
    wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] masked_rob_tag;
    wire [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] masked_lsq_tag;

    integer candidate_lane_index;
    integer selection_lane_index;
    integer ready_lane_index;
    integer rob_needed;
    integer phys_needed;
    integer int_needed;
    integer mul_needed;
    integer div_needed;
    integer load_needed;
    integer store_needed;
    integer lsq_needed;
    reg prefix_open;
    reg lane_fits;
    reg [`RV32_CLASS_WIDTH-1:0] lane_class;
    reg [`RV32_OP_WIDTH-1:0] lane_op;

    function integer index_width_for_count;
        input integer value;
        integer remaining;
        begin
            remaining = value - 1;
            index_width_for_count = 0;
            while (remaining > 0) begin
                index_width_for_count = index_width_for_count + 1;
                remaining = remaining >> 1;
            end
        end
    endfunction

    genvar decode_lane;
    /* verilator lint_off PINCONNECTEMPTY */
    generate
        for (decode_lane = 0; decode_lane < BE_WIDTH;
                decode_lane = decode_lane + 1) begin : generate_decode
            rv32im_decoder decoder (
                .instruction_i(candidate_instruction[decode_lane*32 +: 32]),
                .legal_o(decode_legal[decode_lane]),
                .op_o(decode_op[decode_lane*`RV32_OP_WIDTH +:
                    `RV32_OP_WIDTH]),
                .class_o(decode_class[decode_lane*`RV32_CLASS_WIDTH +:
                    `RV32_CLASS_WIDTH]),
                .rd_o(decode_rd[decode_lane*5 +: 5]),
                .rs1_o(decode_rs1[decode_lane*5 +: 5]),
                .rs2_o(decode_rs2[decode_lane*5 +: 5]),
                .uses_rs1_o(),
                .uses_rs2_o(),
                .writes_rd_o(decode_writes_rd[decode_lane]),
                .immediate_o(decode_immediate[decode_lane*32 +: 32]),
                .memory_width_o(decode_memory_width[
                    decode_lane*`RV32_MEMORY_WIDTH +: `RV32_MEMORY_WIDTH]),
                .load_unsigned_o(decode_load_unsigned[decode_lane]),
                .serialize_o()
            );
        end
    endgenerate
    /* verilator lint_on PINCONNECTEMPTY */

    assign effective_writeback_valid = writeback_valid_i &
        {BE_WIDTH{!flush_i && !recover_i}};
    assign effective_writes_rd = decode_writes_rd & decode_legal &
        ~candidate_error;

    genvar output_lane;
    generate
        for (output_lane = 0; output_lane < BE_WIDTH;
                output_lane = output_lane + 1) begin : generate_output_masks
            assign masked_rob_tag[output_lane*ROB_TAG_WIDTH +:
                ROB_TAG_WIDTH] = selected_valid[output_lane] ?
                rob_alloc_tag_i[output_lane*ROB_TAG_WIDTH +:
                    ROB_TAG_WIDTH] : {ROB_TAG_WIDTH{1'b0}};
            assign masked_lsq_tag[output_lane*LSQ_TAG_WIDTH +:
                LSQ_TAG_WIDTH] =
                (load_valid_reg[output_lane] ||
                 store_valid_reg[output_lane]) ?
                lsq_alloc_tag_i[output_lane*LSQ_TAG_WIDTH +:
                    LSQ_TAG_WIDTH] : {LSQ_TAG_WIDTH{1'b0}};
        end
    endgenerate

    rv32_rename_unit #(
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .BE_WIDTH(BE_WIDTH)
    ) rename_unit (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .rename_valid_i(selected_valid),
        .rename_fire_i(dispatch_fire_reg),
        .rename_rs1_i(decode_rs1),
        .rename_rs2_i(decode_rs2),
        .rename_writes_rd_i(effective_writes_rd),
        .rename_rd_i(decode_rd),
        .rename_ready_o(rename_ready),
        .rename_rs1_phys_o(rename_rs1_phys),
        .rename_rs2_phys_o(rename_rs2_phys),
        .rename_rs1_ready_o(rename_rs1_ready),
        .rename_rs2_ready_o(rename_rs2_ready),
        .rename_new_phys_o(rename_new_phys),
        .rename_old_phys_o(rename_old_phys),
        .free_count_o(free_count_o),
        .commit_valid_i(commit_valid_i &
            {BE_WIDTH{!flush_i && !recover_i}}),
        .commit_writes_rd_i(commit_writes_rd_i),
        .commit_rd_i(commit_rd_i),
        .commit_new_phys_i(commit_new_phys_i),
        .recover_i(recover_i),
        .rollback_valid_i(rollback_valid_i),
        .rollback_writes_rd_i(rollback_writes_rd_i),
        .rollback_rd_i(rollback_rd_i),
        .rollback_new_phys_i(rollback_new_phys_i),
        .rollback_old_phys_i(rollback_old_phys_i),
        .writeback_valid_i(effective_writeback_valid),
        .writeback_phys_i(writeback_phys_i)
    );

    assign prf_read_addr = {rename_rs2_phys, rename_rs1_phys};

    rv32_physical_register_file #(
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .BE_WIDTH(BE_WIDTH)
    ) physical_register_file (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .read_addr_i(prf_read_addr),
        .read_data_o(prf_read_data),
        .write_valid_i(effective_writeback_valid),
        .write_addr_i(writeback_phys_i),
        .write_data_i(writeback_value_i)
    );

    assign fetch_ready_o = fetch_ready_reg;
    assign dispatch_fire_o = dispatch_fire_reg;
    assign dispatch_valid_o = selected_valid;
    assign int_dispatch_valid_o = int_valid_reg;
    assign mul_dispatch_valid_o = mul_valid_reg;
    assign div_dispatch_valid_o = div_valid_reg;
    assign load_dispatch_valid_o = load_valid_reg;
    assign store_dispatch_valid_o = store_valid_reg;
    assign dispatch_op_o = decode_op;
    assign dispatch_pc_o = candidate_pc;
    assign dispatch_instruction_o = candidate_instruction;
    assign dispatch_immediate_o = decode_immediate;
    assign dispatch_predicted_next_pc_o = candidate_predicted_next_pc;
    assign dispatch_rob_tag_o = masked_rob_tag;
    assign dispatch_lsq_tag_o = masked_lsq_tag;
    assign dispatch_lhs_ready_o = rename_rs1_ready;
    assign dispatch_lhs_value_o = prf_read_data[0 +: BE_WIDTH*32];
    assign dispatch_lhs_phys_o = rename_rs1_phys;
    assign dispatch_rhs_ready_o = rename_rs2_ready;
    assign dispatch_rhs_value_o = prf_read_data[BE_WIDTH*32 +: BE_WIDTH*32];
    assign dispatch_rhs_phys_o = rename_rs2_phys;

    assign rob_alloc_valid_o = selected_valid;
    assign rob_alloc_pc_o = candidate_pc;
    assign rob_alloc_instruction_o = candidate_instruction;
    assign rob_alloc_op_o = decode_op;
    assign rob_alloc_writes_rd_o = effective_writes_rd & selected_valid;
    assign rob_alloc_rd_o = decode_rd;
    assign rob_alloc_new_phys_o = rename_new_phys;
    assign rob_alloc_old_phys_o = rename_old_phys;
    assign rob_alloc_predicted_next_pc_o = candidate_predicted_next_pc;
    assign rob_alloc_lsq_valid_o = load_valid_reg | store_valid_reg;
    assign rob_alloc_lsq_tag_o = masked_lsq_tag;
    assign rob_alloc_complete_o = complete_reg;
    assign rob_alloc_exception_valid_o = exception_valid_reg;
    assign rob_alloc_exception_cause_o = exception_cause_reg;
    assign rob_alloc_exception_tval_o = exception_tval_reg;

    assign lsq_alloc_valid_o = load_valid_reg | store_valid_reg;
    assign lsq_alloc_store_o = store_valid_reg;
    assign lsq_alloc_rob_tag_o = masked_rob_tag;
    assign lsq_alloc_width_o = decode_memory_width;
    assign lsq_alloc_unsigned_o = decode_load_unsigned;

    initial begin
        if ((FE_WIDTH != 1 && FE_WIDTH != 2 && FE_WIDTH != 4) ||
                (BE_WIDTH != 1 && BE_WIDTH != 2 && BE_WIDTH != 4) ||
                PHYS_REGS < 33 ||
                PHYS_REG_ADDR_WIDTH != index_width_for_count(PHYS_REGS) ||
                ROB_ENTRIES < BE_WIDTH ||
                (ROB_ENTRIES & (ROB_ENTRIES-1)) != 0 ||
                ROB_INDEX_WIDTH != index_width_for_count(ROB_ENTRIES) ||
                ROB_TAG_WIDTH <= ROB_INDEX_WIDTH ||
                INT_RS_ENTRIES < BE_WIDTH ||
                (INT_RS_ENTRIES & (INT_RS_ENTRIES-1)) != 0 ||
                INT_RS_INDEX_WIDTH != index_width_for_count(INT_RS_ENTRIES) ||
                MUL_RS_ENTRIES < BE_WIDTH ||
                (MUL_RS_ENTRIES & (MUL_RS_ENTRIES-1)) != 0 ||
                MUL_RS_INDEX_WIDTH != index_width_for_count(MUL_RS_ENTRIES) ||
                DIV_RS_ENTRIES < BE_WIDTH ||
                (DIV_RS_ENTRIES & (DIV_RS_ENTRIES-1)) != 0 ||
                DIV_RS_INDEX_WIDTH != index_width_for_count(DIV_RS_ENTRIES) ||
                LOAD_RS_ENTRIES < BE_WIDTH ||
                (LOAD_RS_ENTRIES & (LOAD_RS_ENTRIES-1)) != 0 ||
                LOAD_RS_INDEX_WIDTH != index_width_for_count(LOAD_RS_ENTRIES) ||
                STORE_RS_ENTRIES < BE_WIDTH ||
                (STORE_RS_ENTRIES & (STORE_RS_ENTRIES-1)) != 0 ||
                STORE_RS_INDEX_WIDTH != index_width_for_count(STORE_RS_ENTRIES) ||
                LSQ_ENTRIES < BE_WIDTH ||
                (LSQ_ENTRIES & (LSQ_ENTRIES-1)) != 0 ||
                LSQ_INDEX_WIDTH != index_width_for_count(LSQ_ENTRIES) ||
                LSQ_TAG_WIDTH <= LSQ_INDEX_WIDTH) begin
            $display("ERROR rv32_decode_rename_dispatch invalid parameters");
            $finish(1);
        end
    end

    always @* begin
        candidate_valid = {BE_WIDTH{1'b0}};
        candidate_pc = {(BE_WIDTH*32){1'b0}};
        candidate_instruction = {(BE_WIDTH*32){1'b0}};
        candidate_predicted_next_pc = {(BE_WIDTH*32){1'b0}};
        candidate_error = {BE_WIDTH{1'b0}};
        for (candidate_lane_index = 0; candidate_lane_index < BE_WIDTH;
                candidate_lane_index = candidate_lane_index + 1) begin
            if (candidate_lane_index < FE_WIDTH) begin
                candidate_valid[candidate_lane_index] =
                    fetch_valid_i[candidate_lane_index];
                candidate_pc[candidate_lane_index*32 +: 32] =
                    fetch_pc_i[candidate_lane_index*32 +: 32];
                candidate_instruction[candidate_lane_index*32 +: 32] =
                    fetch_instruction_i[candidate_lane_index*32 +: 32];
                candidate_predicted_next_pc[
                    candidate_lane_index*32 +: 32] =
                    fetch_predicted_next_pc_i[
                        candidate_lane_index*32 +: 32];
                candidate_error[candidate_lane_index] =
                    fetch_error_i[candidate_lane_index];
            end
        end
    end

    always @* begin
        selected_valid = {BE_WIDTH{1'b0}};
        int_valid_reg = {BE_WIDTH{1'b0}};
        mul_valid_reg = {BE_WIDTH{1'b0}};
        div_valid_reg = {BE_WIDTH{1'b0}};
        load_valid_reg = {BE_WIDTH{1'b0}};
        store_valid_reg = {BE_WIDTH{1'b0}};
        complete_reg = {BE_WIDTH{1'b0}};
        exception_valid_reg = {BE_WIDTH{1'b0}};
        exception_cause_reg = {(BE_WIDTH*4){1'b0}};
        exception_tval_reg = {(BE_WIDTH*32){1'b0}};
        rob_needed = 0;
        phys_needed = 0;
        int_needed = 0;
        mul_needed = 0;
        div_needed = 0;
        load_needed = 0;
        store_needed = 0;
        lsq_needed = 0;
        prefix_open = !reset_i && !flush_i && !recover_i;
        lane_fits = 1'b0;
        lane_class = `RV32_CLASS_INVALID;
        lane_op = `RV32_OP_INVALID;

        for (selection_lane_index = 0; selection_lane_index < BE_WIDTH;
                selection_lane_index = selection_lane_index + 1) begin
            if (prefix_open && candidate_valid[selection_lane_index]) begin
                lane_class = decode_class[
                    selection_lane_index*`RV32_CLASS_WIDTH +:
                    `RV32_CLASS_WIDTH];
                lane_op = decode_op[
                    selection_lane_index*`RV32_OP_WIDTH +: `RV32_OP_WIDTH];
                lane_fits =
                    (rob_needed + 1 <= ROB_ENTRIES - rob_occupancy_i) &&
                    (phys_needed +
                        (effective_writes_rd[selection_lane_index] ? 1 : 0) <=
                        free_count_o) &&
                    (int_needed + ((!candidate_error[selection_lane_index] &&
                        decode_legal[selection_lane_index] &&
                        (lane_class == `RV32_CLASS_INT ||
                         lane_class == `RV32_CLASS_BRANCH ||
                         lane_class == `RV32_CLASS_JUMP)) ? 1 : 0) <=
                        INT_RS_ENTRIES - int_occupancy_i) &&
                    (mul_needed + ((!candidate_error[selection_lane_index] &&
                        decode_legal[selection_lane_index] &&
                        lane_class == `RV32_CLASS_MUL) ? 1 : 0) <=
                        MUL_RS_ENTRIES - mul_occupancy_i) &&
                    (div_needed + ((!candidate_error[selection_lane_index] &&
                        decode_legal[selection_lane_index] &&
                        lane_class == `RV32_CLASS_DIV) ? 1 : 0) <=
                        DIV_RS_ENTRIES - div_occupancy_i) &&
                    (load_needed + ((!candidate_error[selection_lane_index] &&
                        decode_legal[selection_lane_index] &&
                        lane_class == `RV32_CLASS_LOAD) ? 1 : 0) <=
                        LOAD_RS_ENTRIES - load_occupancy_i) &&
                    (store_needed + ((!candidate_error[selection_lane_index] &&
                        decode_legal[selection_lane_index] &&
                        lane_class == `RV32_CLASS_STORE) ? 1 : 0) <=
                        STORE_RS_ENTRIES - store_occupancy_i) &&
                    (lsq_needed + ((!candidate_error[selection_lane_index] &&
                        decode_legal[selection_lane_index] &&
                        (lane_class == `RV32_CLASS_LOAD ||
                         lane_class == `RV32_CLASS_STORE)) ? 1 : 0) <=
                        LSQ_ENTRIES - lsq_occupancy_i);
                if (lane_fits) begin
                    selected_valid[selection_lane_index] = 1'b1;
                    rob_needed = rob_needed + 1;
                    if (effective_writes_rd[selection_lane_index])
                        phys_needed = phys_needed + 1;
                    if (!candidate_error[selection_lane_index] &&
                            decode_legal[selection_lane_index]) begin
                        case (lane_class)
                            `RV32_CLASS_INT,
                            `RV32_CLASS_BRANCH,
                            `RV32_CLASS_JUMP: begin
                                int_valid_reg[selection_lane_index] = 1'b1;
                                int_needed = int_needed + 1;
                            end
                            `RV32_CLASS_MUL: begin
                                mul_valid_reg[selection_lane_index] = 1'b1;
                                mul_needed = mul_needed + 1;
                            end
                            `RV32_CLASS_DIV: begin
                                div_valid_reg[selection_lane_index] = 1'b1;
                                div_needed = div_needed + 1;
                            end
                            `RV32_CLASS_LOAD: begin
                                load_valid_reg[selection_lane_index] = 1'b1;
                                load_needed = load_needed + 1;
                                lsq_needed = lsq_needed + 1;
                            end
                            `RV32_CLASS_STORE: begin
                                store_valid_reg[selection_lane_index] = 1'b1;
                                store_needed = store_needed + 1;
                                lsq_needed = lsq_needed + 1;
                            end
                            default: begin
                            end
                        endcase
                    end
                    if (candidate_error[selection_lane_index]) begin
                        complete_reg[selection_lane_index] = 1'b1;
                        exception_valid_reg[selection_lane_index] = 1'b1;
                        exception_cause_reg[selection_lane_index*4 +: 4] =
                            `RV32_EXCEPTION_INSTRUCTION_ACCESS_FAULT;
                        exception_tval_reg[selection_lane_index*32 +: 32] =
                            candidate_pc[selection_lane_index*32 +: 32];
                    end else if (!decode_legal[selection_lane_index]) begin
                        complete_reg[selection_lane_index] = 1'b1;
                        exception_valid_reg[selection_lane_index] = 1'b1;
                        exception_cause_reg[selection_lane_index*4 +: 4] =
                            `RV32_EXCEPTION_ILLEGAL_INSTRUCTION;
                        exception_tval_reg[selection_lane_index*32 +: 32] =
                            candidate_instruction[
                                selection_lane_index*32 +: 32];
                    end else if (lane_class == `RV32_CLASS_SYSTEM ||
                            lane_class == `RV32_CLASS_HALT) begin
                        complete_reg[selection_lane_index] = 1'b1;
                        if (lane_op == `RV32_OP_ECALL) begin
                            exception_valid_reg[selection_lane_index] = 1'b1;
                            exception_cause_reg[
                                selection_lane_index*4 +: 4] =
                                `RV32_EXCEPTION_ENVIRONMENT_CALL;
                        end else if (lane_op == `RV32_OP_EBREAK) begin
                            exception_valid_reg[selection_lane_index] = 1'b1;
                            exception_cause_reg[
                                selection_lane_index*4 +: 4] =
                                `RV32_EXCEPTION_BREAKPOINT;
                            exception_tval_reg[
                                selection_lane_index*32 +: 32] =
                                candidate_pc[
                                    selection_lane_index*32 +: 32];
                        end
                    end
                end else begin
                    prefix_open = 1'b0;
                end
            end else begin
                prefix_open = 1'b0;
            end
        end
    end

    always @* begin
        dispatch_fire_reg = 1'b0;
        fetch_ready_reg = {FE_WIDTH{1'b0}};
        ready_lane_index = 0;
        if (!reset_i && !flush_i && !recover_i &&
                (|selected_valid) && rename_ready && rob_alloc_ready_i &&
                (!(|int_valid_reg) || int_dispatch_ready_i) &&
                (!(|mul_valid_reg) || mul_dispatch_ready_i) &&
                (!(|div_valid_reg) || div_dispatch_ready_i) &&
                (!(|load_valid_reg) || load_dispatch_ready_i) &&
                (!(|store_valid_reg) || store_dispatch_ready_i) &&
                (!(|(load_valid_reg | store_valid_reg)) ||
                    lsq_alloc_ready_i)) begin
            dispatch_fire_reg = 1'b1;
            for (ready_lane_index = 0; ready_lane_index < FE_WIDTH;
                    ready_lane_index = ready_lane_index + 1)
                if (ready_lane_index < BE_WIDTH)
                    fetch_ready_reg[ready_lane_index] =
                        selected_valid[ready_lane_index];
        end
    end

`ifndef SYNTHESIS
    /* verilator lint_off BLKSEQ */
    integer assertion_lane;
    integer assertion_seen_gap;
    always @(posedge clk_i) begin
        if (!reset_i) begin
            assertion_seen_gap = 0;
            for (assertion_lane = 0; assertion_lane < FE_WIDTH;
                    assertion_lane = assertion_lane + 1) begin
                if (!fetch_valid_i[assertion_lane])
                    assertion_seen_gap = 1;
                else if (assertion_seen_gap) begin
                    $display("ERROR rv32_decode_rename_dispatch non-prefix fetch valid");
                    $finish(1);
                end
            end
            assertion_seen_gap = 0;
            for (assertion_lane = 0; assertion_lane < BE_WIDTH;
                    assertion_lane = assertion_lane + 1) begin
                if (!selected_valid[assertion_lane])
                    assertion_seen_gap = 1;
                else if (assertion_seen_gap) begin
                    $display("ERROR rv32_decode_rename_dispatch non-prefix selection");
                    $finish(1);
                end
            end
            if (dispatch_fire_reg && (!rename_ready || !rob_alloc_ready_i)) begin
                $display("ERROR rv32_decode_rename_dispatch fired without common ready");
                $finish(1);
            end
        end
    end
    /* verilator lint_on BLKSEQ */
`endif

    /* verilator lint_on WIDTHTRUNC */
    /* verilator lint_on WIDTHEXPAND */

endmodule
