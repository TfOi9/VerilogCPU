`timescale 1ns/1ps

module rv32_completion_writeback_network #(
    parameter BE_WIDTH = 1,
    parameter SOURCE_COUNT = BE_WIDTH + 2,
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter ROB_TAG_WIDTH = 7
) (
    input  wire                                             clk_i,
    input  wire                                             reset_i,
    input  wire                                             flush_i,
    input  wire                                             recover_i,

    input  wire [SOURCE_COUNT-1:0]                          source_valid_i,
    output wire [SOURCE_COUNT-1:0]                          source_ready_o,
    input  wire [(SOURCE_COUNT*ROB_TAG_WIDTH)-1:0]          source_rob_tag_i,
    input  wire [(SOURCE_COUNT*32)-1:0]                     source_value_i,
    input  wire [SOURCE_COUNT-1:0]                          source_control_valid_i,
    input  wire [SOURCE_COUNT-1:0]                          source_control_taken_i,
    input  wire [(SOURCE_COUNT*32)-1:0]                     source_next_pc_i,
    input  wire [SOURCE_COUNT-1:0]                          source_exception_valid_i,
    input  wire [(SOURCE_COUNT*4)-1:0]                      source_exception_cause_i,
    input  wire [(SOURCE_COUNT*32)-1:0]                     source_exception_tval_i,

    output wire [BE_WIDTH-1:0]                              completion_valid_o,
    output wire [(BE_WIDTH*ROB_TAG_WIDTH)-1:0]              completion_tag_o,
    output wire [(BE_WIDTH*32)-1:0]                         completion_value_o,
    output wire [BE_WIDTH-1:0]                              completion_control_valid_o,
    output wire [BE_WIDTH-1:0]                              completion_control_taken_o,
    output wire [(BE_WIDTH*32)-1:0]                         completion_next_pc_o,
    output wire [BE_WIDTH-1:0]                              completion_exception_valid_o,
    output wire [(BE_WIDTH*4)-1:0]                          completion_exception_cause_o,
    output wire [(BE_WIDTH*32)-1:0]                         completion_exception_tval_o,
    input  wire [BE_WIDTH-1:0]                              completion_ready_i,
    input  wire [BE_WIDTH-1:0]                              completion_accept_i,
    input  wire [BE_WIDTH-1:0]                              completion_writes_rd_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        completion_phys_i,

    output wire [BE_WIDTH-1:0]                              writeback_valid_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        writeback_phys_o,
    output wire [(BE_WIDTH*32)-1:0]                         writeback_value_o
);

    localparam [PHYS_REG_ADDR_WIDTH:0] PHYS_REGS_LIMIT =
        PHYS_REGS[PHYS_REG_ADDR_WIDTH:0];

    reg buffer_valid [0:SOURCE_COUNT-1];
    reg [ROB_TAG_WIDTH-1:0] buffer_rob_tag [0:SOURCE_COUNT-1];
    reg [31:0] buffer_value [0:SOURCE_COUNT-1];
    reg buffer_control_valid [0:SOURCE_COUNT-1];
    reg buffer_control_taken [0:SOURCE_COUNT-1];
    reg [31:0] buffer_next_pc [0:SOURCE_COUNT-1];
    reg buffer_exception_valid [0:SOURCE_COUNT-1];
    reg [3:0] buffer_exception_cause [0:SOURCE_COUNT-1];
    reg [31:0] buffer_exception_tval [0:SOURCE_COUNT-1];

    reg [SOURCE_COUNT-1:0] round_robin_start_reg;
    reg [SOURCE_COUNT-1:0] round_robin_next_reg;
    reg [(BE_WIDTH*SOURCE_COUNT)-1:0] selected_source_lane_reg;
    reg [SOURCE_COUNT-1:0] source_pop_mask_reg;
    reg [SOURCE_COUNT-1:0] source_ready_reg;

    reg [BE_WIDTH-1:0] completion_valid_reg;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] completion_tag_reg;
    reg [(BE_WIDTH*32)-1:0] completion_value_reg;
    reg [BE_WIDTH-1:0] completion_control_valid_reg;
    reg [BE_WIDTH-1:0] completion_control_taken_reg;
    reg [(BE_WIDTH*32)-1:0] completion_next_pc_reg;
    reg [BE_WIDTH-1:0] completion_exception_valid_reg;
    reg [(BE_WIDTH*4)-1:0] completion_exception_cause_reg;
    reg [(BE_WIDTH*32)-1:0] completion_exception_tval_reg;

    reg [BE_WIDTH-1:0] writeback_valid_reg;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] writeback_phys_reg;
    reg [(BE_WIDTH*32)-1:0] writeback_value_reg;

    integer arb_source_index;
    integer arb_scan_offset;
    integer arb_scan_index;
    integer arb_start_index;
    integer arb_selected_count;
    integer pop_lane_index;
    integer pop_selected_index;
    integer ready_source_index;
    integer writeback_lane_index;
    integer round_robin_lane_index;
    integer round_robin_selected_index;
    integer sequential_source_index;
    integer assertion_lane_index;
    integer assertion_other_lane_index;
    integer assertion_source_index;
    integer round_robin_one_count;
    reg completion_stalled_reg;

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
        end
    endfunction

    assign source_ready_o = source_ready_reg;
    assign completion_valid_o = completion_valid_reg;
    assign completion_tag_o = completion_tag_reg;
    assign completion_value_o = completion_value_reg;
    assign completion_control_valid_o = completion_control_valid_reg;
    assign completion_control_taken_o = completion_control_taken_reg;
    assign completion_next_pc_o = completion_next_pc_reg;
    assign completion_exception_valid_o = completion_exception_valid_reg;
    assign completion_exception_cause_o = completion_exception_cause_reg;
    assign completion_exception_tval_o = completion_exception_tval_reg;
    assign writeback_valid_o = writeback_valid_reg;
    assign writeback_phys_o = writeback_phys_reg;
    assign writeback_value_o = writeback_value_reg;

    initial begin
        if ((BE_WIDTH != 1) && (BE_WIDTH != 2) && (BE_WIDTH != 4)) begin
            $display("ERROR rv32_completion_writeback_network invalid BE_WIDTH=%0d",
                BE_WIDTH);
            $finish(1);
        end
        if (SOURCE_COUNT < 1) begin
            $display("ERROR rv32_completion_writeback_network invalid SOURCE_COUNT=%0d",
                SOURCE_COUNT);
            $finish(1);
        end
        if (PHYS_REGS < 33) begin
            $display("ERROR rv32_completion_writeback_network PHYS_REGS=%0d is below 33",
                PHYS_REGS);
            $finish(1);
        end
        if (PHYS_REG_ADDR_WIDTH != address_width_for_count(PHYS_REGS)) begin
            $display("ERROR rv32_completion_writeback_network physical address width=%0d expected=%0d",
                PHYS_REG_ADDR_WIDTH, address_width_for_count(PHYS_REGS));
            $finish(1);
        end
        if (ROB_TAG_WIDTH < 1) begin
            $display("ERROR rv32_completion_writeback_network invalid ROB_TAG_WIDTH=%0d",
                ROB_TAG_WIDTH);
            $finish(1);
        end
    end

    always @* begin
        completion_valid_reg = {BE_WIDTH{1'b0}};
        completion_tag_reg = {(BE_WIDTH*ROB_TAG_WIDTH){1'b0}};
        completion_value_reg = {(BE_WIDTH*32){1'b0}};
        completion_control_valid_reg = {BE_WIDTH{1'b0}};
        completion_control_taken_reg = {BE_WIDTH{1'b0}};
        completion_next_pc_reg = {(BE_WIDTH*32){1'b0}};
        completion_exception_valid_reg = {BE_WIDTH{1'b0}};
        completion_exception_cause_reg = {(BE_WIDTH*4){1'b0}};
        completion_exception_tval_reg = {(BE_WIDTH*32){1'b0}};
        selected_source_lane_reg = {(BE_WIDTH*SOURCE_COUNT){1'b0}};
        arb_source_index = 0;
        arb_scan_offset = 0;
        arb_scan_index = 0;
        arb_start_index = 0;
        arb_selected_count = 0;

        for (arb_source_index = 0; arb_source_index < SOURCE_COUNT;
                arb_source_index = arb_source_index + 1) begin
            if (round_robin_start_reg[arb_source_index]) begin
                arb_start_index = arb_source_index;
            end
        end

        if (!reset_i && !flush_i && !recover_i) begin
            for (arb_scan_offset = 0; arb_scan_offset < SOURCE_COUNT;
                    arb_scan_offset = arb_scan_offset + 1) begin
                arb_scan_index = arb_start_index + arb_scan_offset;
                if (arb_scan_index >= SOURCE_COUNT) begin
                    arb_scan_index = arb_scan_index - SOURCE_COUNT;
                end
                if (buffer_valid[arb_scan_index] &&
                        (arb_selected_count < BE_WIDTH)) begin
                    completion_valid_reg[arb_selected_count] = 1'b1;
                    completion_tag_reg[
                        arb_selected_count*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] =
                        buffer_rob_tag[arb_scan_index];
                    completion_value_reg[
                        arb_selected_count*32 +: 32] =
                        buffer_value[arb_scan_index];
                    completion_control_valid_reg[arb_selected_count] =
                        buffer_control_valid[arb_scan_index];
                    completion_control_taken_reg[arb_selected_count] =
                        buffer_control_taken[arb_scan_index];
                    completion_next_pc_reg[
                        arb_selected_count*32 +: 32] =
                        buffer_next_pc[arb_scan_index];
                    completion_exception_valid_reg[arb_selected_count] =
                        buffer_exception_valid[arb_scan_index];
                    completion_exception_cause_reg[
                        arb_selected_count*4 +: 4] =
                        buffer_exception_cause[arb_scan_index];
                    completion_exception_tval_reg[
                        arb_selected_count*32 +: 32] =
                        buffer_exception_tval[arb_scan_index];
                    selected_source_lane_reg[
                        arb_selected_count*SOURCE_COUNT +
                        arb_scan_index] = 1'b1;
                    arb_selected_count = arb_selected_count + 1;
                end
            end
        end
    end

    always @* begin
        source_pop_mask_reg = {SOURCE_COUNT{1'b0}};
        pop_lane_index = 0;
        pop_selected_index = 0;
        for (pop_lane_index = 0; pop_lane_index < BE_WIDTH;
                pop_lane_index = pop_lane_index + 1) begin
            if (completion_valid_reg[pop_lane_index] &&
                    completion_ready_i[pop_lane_index]) begin
                for (pop_selected_index = 0;
                        pop_selected_index < SOURCE_COUNT;
                        pop_selected_index = pop_selected_index + 1) begin
                    if (selected_source_lane_reg[
                            pop_lane_index*SOURCE_COUNT +
                            pop_selected_index]) begin
                        source_pop_mask_reg[pop_selected_index] = 1'b1;
                    end
                end
            end
        end

        completion_stalled_reg = (|completion_valid_reg) &&
            !completion_ready_i[0];
        source_ready_reg = {SOURCE_COUNT{1'b0}};
        ready_source_index = 0;
        if (!reset_i && !flush_i && !recover_i &&
                !completion_stalled_reg) begin
            for (ready_source_index = 0;
                    ready_source_index < SOURCE_COUNT;
                    ready_source_index = ready_source_index + 1) begin
                source_ready_reg[ready_source_index] =
                    !buffer_valid[ready_source_index] ||
                    source_pop_mask_reg[ready_source_index];
            end
        end
    end

    always @* begin
        writeback_valid_reg = {BE_WIDTH{1'b0}};
        writeback_phys_reg =
            {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        writeback_value_reg = {(BE_WIDTH*32){1'b0}};
        writeback_lane_index = 0;
        for (writeback_lane_index = 0;
                writeback_lane_index < BE_WIDTH;
                writeback_lane_index = writeback_lane_index + 1) begin
            if (completion_valid_reg[writeback_lane_index] &&
                    completion_ready_i[writeback_lane_index] &&
                    completion_accept_i[writeback_lane_index] &&
                    completion_writes_rd_i[writeback_lane_index] &&
                    !completion_exception_valid_reg[
                        writeback_lane_index] &&
                    (completion_phys_i[
                        writeback_lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] !=
                        {PHYS_REG_ADDR_WIDTH{1'b0}})) begin
                writeback_valid_reg[writeback_lane_index] = 1'b1;
                writeback_phys_reg[
                    writeback_lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = completion_phys_i[
                    writeback_lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH];
                writeback_value_reg[
                    writeback_lane_index*32 +: 32] =
                    completion_value_reg[
                    writeback_lane_index*32 +: 32];
            end
        end
    end

    always @* begin
        round_robin_next_reg = round_robin_start_reg;
        round_robin_lane_index = 0;
        round_robin_selected_index = 0;
        for (round_robin_lane_index = 0;
                round_robin_lane_index < BE_WIDTH;
                round_robin_lane_index =
                    round_robin_lane_index + 1) begin
            if (completion_valid_reg[round_robin_lane_index] &&
                    completion_ready_i[round_robin_lane_index]) begin
                for (round_robin_selected_index = 0;
                        round_robin_selected_index < SOURCE_COUNT;
                        round_robin_selected_index =
                            round_robin_selected_index + 1) begin
                    if (selected_source_lane_reg[
                            round_robin_lane_index*SOURCE_COUNT +
                            round_robin_selected_index]) begin
                        round_robin_next_reg = {SOURCE_COUNT{1'b0}};
                        if (round_robin_selected_index ==
                                SOURCE_COUNT - 1) begin
                            round_robin_next_reg[0] = 1'b1;
                        end else begin
                            round_robin_next_reg[
                                round_robin_selected_index + 1] = 1'b1;
                        end
                    end
                end
            end
        end
    end

    always @(posedge clk_i) begin
        if (reset_i || flush_i) begin
            round_robin_start_reg <= {{(SOURCE_COUNT-1){1'b0}}, 1'b1};
            for (sequential_source_index = 0;
                    sequential_source_index < SOURCE_COUNT;
                    sequential_source_index = sequential_source_index + 1) begin
                buffer_valid[sequential_source_index] <= 1'b0;
                buffer_rob_tag[sequential_source_index] <=
                    {ROB_TAG_WIDTH{1'b0}};
                buffer_value[sequential_source_index] <= 32'd0;
                buffer_control_valid[sequential_source_index] <= 1'b0;
                buffer_control_taken[sequential_source_index] <= 1'b0;
                buffer_next_pc[sequential_source_index] <= 32'd0;
                buffer_exception_valid[sequential_source_index] <= 1'b0;
                buffer_exception_cause[sequential_source_index] <= 4'd0;
                buffer_exception_tval[sequential_source_index] <= 32'd0;
            end
        end else if (!recover_i) begin
            round_robin_start_reg <= round_robin_next_reg;
            for (sequential_source_index = 0;
                    sequential_source_index < SOURCE_COUNT;
                    sequential_source_index = sequential_source_index + 1) begin
                if (source_ready_reg[sequential_source_index] &&
                        source_valid_i[sequential_source_index]) begin
                    buffer_valid[sequential_source_index] <= 1'b1;
                    buffer_rob_tag[sequential_source_index] <=
                        source_rob_tag_i[
                            sequential_source_index*ROB_TAG_WIDTH +:
                            ROB_TAG_WIDTH];
                    buffer_value[sequential_source_index] <=
                        source_value_i[sequential_source_index*32 +: 32];
                    buffer_control_valid[sequential_source_index] <=
                        source_control_valid_i[sequential_source_index];
                    buffer_control_taken[sequential_source_index] <=
                        source_control_taken_i[sequential_source_index];
                    buffer_next_pc[sequential_source_index] <=
                        source_next_pc_i[
                            sequential_source_index*32 +: 32];
                    buffer_exception_valid[sequential_source_index] <=
                        source_exception_valid_i[sequential_source_index];
                    buffer_exception_cause[sequential_source_index] <=
                        source_exception_cause_i[
                            sequential_source_index*4 +: 4];
                    buffer_exception_tval[sequential_source_index] <=
                        source_exception_tval_i[
                            sequential_source_index*32 +: 32];
                end else if (source_pop_mask_reg[sequential_source_index]) begin
                    buffer_valid[sequential_source_index] <= 1'b0;
                    buffer_rob_tag[sequential_source_index] <=
                        {ROB_TAG_WIDTH{1'b0}};
                    buffer_value[sequential_source_index] <= 32'd0;
                    buffer_control_valid[sequential_source_index] <= 1'b0;
                    buffer_control_taken[sequential_source_index] <= 1'b0;
                    buffer_next_pc[sequential_source_index] <= 32'd0;
                    buffer_exception_valid[sequential_source_index] <= 1'b0;
                    buffer_exception_cause[sequential_source_index] <= 4'd0;
                    buffer_exception_tval[sequential_source_index] <= 32'd0;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        /* verilator lint_off BLKSEQ */
        if (!reset_i && !flush_i) begin
            for (assertion_lane_index = 1;
                    assertion_lane_index < BE_WIDTH;
                    assertion_lane_index = assertion_lane_index + 1) begin
                if (completion_ready_i[assertion_lane_index] !=
                        completion_ready_i[0]) begin
                    $display("ERROR rv32_completion_writeback_network nonuniform completion ready");
                    $finish(1);
                end
            end
            for (assertion_lane_index = 0;
                    assertion_lane_index < BE_WIDTH;
                    assertion_lane_index = assertion_lane_index + 1) begin
                if (completion_accept_i[assertion_lane_index] &&
                        (!completion_valid_reg[assertion_lane_index] ||
                         !completion_ready_i[assertion_lane_index])) begin
                    $display("ERROR rv32_completion_writeback_network completion accepted without handshake");
                    $finish(1);
                end
                if (completion_accept_i[assertion_lane_index] &&
                        completion_writes_rd_i[assertion_lane_index] &&
                        (completion_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] != 0) &&
                        ({1'b0, completion_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH]} >= PHYS_REGS_LIMIT)) begin
                    $display("ERROR rv32_completion_writeback_network invalid physical register");
                    $finish(1);
                end
                for (assertion_other_lane_index = assertion_lane_index + 1;
                        assertion_other_lane_index < BE_WIDTH;
                        assertion_other_lane_index =
                            assertion_other_lane_index + 1) begin
                    if (writeback_valid_reg[assertion_lane_index] &&
                            writeback_valid_reg[assertion_other_lane_index] &&
                            (writeback_phys_reg[
                                assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                             writeback_phys_reg[
                                assertion_other_lane_index*
                                    PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH])) begin
                        $display("ERROR rv32_completion_writeback_network duplicate physical writeback");
                        $finish(1);
                    end
                end
            end
            round_robin_one_count = 0;
            for (assertion_source_index = 0;
                    assertion_source_index < SOURCE_COUNT;
                    assertion_source_index = assertion_source_index + 1) begin
                if (round_robin_start_reg[assertion_source_index]) begin
                    round_robin_one_count = round_robin_one_count + 1;
                end
            end
            if (round_robin_one_count != 1) begin
                $display("ERROR rv32_completion_writeback_network invalid round robin state");
                $finish(1);
            end
        end
        /* verilator lint_on BLKSEQ */
    end
`endif

endmodule
