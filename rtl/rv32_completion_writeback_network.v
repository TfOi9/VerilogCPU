`timescale 1ns/1ps

module rv32_completion_writeback_network #(
    parameter BE_WIDTH = 1,
    parameter SOURCE_COUNT = BE_WIDTH + 2,
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter ROB_TAG_WIDTH = 7,
    parameter FALLTHROUGH = 0,
    parameter SOURCE_AUTH = 0
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

    output wire [(SOURCE_COUNT*ROB_TAG_WIDTH)-1:0]          source_lookup_tag_o,
    input  wire [SOURCE_COUNT-1:0]                          source_lookup_write_valid_i,
    input  wire [(SOURCE_COUNT*PHYS_REG_ADDR_WIDTH)-1:0]   source_lookup_phys_i,

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

    localparam TREE_SLOT_WIDTH = SOURCE_COUNT <= 1 ? 1 : address_width_for_count(SOURCE_COUNT);

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
    reg [BE_WIDTH-1:0] stalled_lane;
    reg [(BE_WIDTH*TREE_SLOT_WIDTH)-1:0] stalled_slot;
    wire [(BE_WIDTH*TREE_SLOT_WIDTH)-1:0] selected_slot;

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
    integer arb_start_index;
    integer pop_lane_index;
    integer pop_selected_index;
    integer ready_source_index;
    integer writeback_lane_index;
    integer writeback_prior_lane;
    reg writeback_duplicate;
    reg [BE_WIDTH-1:0] selected_write_valid;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] selected_phys;
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

    localparam TREE_DATA_WIDTH = ROB_TAG_WIDTH + 104 + PHYS_REG_ADDR_WIDTH;
    wire [SOURCE_COUNT-1:0] tree_valid;
    wire [(SOURCE_COUNT*TREE_SLOT_WIDTH)-1:0] tree_age;
    wire [(SOURCE_COUNT*TREE_DATA_WIDTH)-1:0] tree_input;
    wire [(BE_WIDTH*TREE_DATA_WIDTH)-1:0] tree_output;
    wire [BE_WIDTH-1:0] tree_selected_valid;
    wire [(BE_WIDTH*SOURCE_COUNT)-1:0] tree_selected_mask;

    genvar tree_source;
    generate
        for (tree_source = 0; tree_source < SOURCE_COUNT;
                tree_source = tree_source + 1) begin: tree_source_data
            wire [31:0] unused_age_full;
            assign tree_valid[tree_source] = buffer_valid[tree_source] ||
                (FALLTHROUGH != 0 && source_valid_i[tree_source]);
            assign unused_age_full =
                tree_source >= arb_start_index ? tree_source-arb_start_index :
                tree_source+SOURCE_COUNT-arb_start_index;
            assign tree_age[tree_source*TREE_SLOT_WIDTH +: TREE_SLOT_WIDTH] =
                unused_age_full[TREE_SLOT_WIDTH-1:0];
            assign source_lookup_tag_o[tree_source*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] =
                buffer_valid[tree_source] ? buffer_rob_tag[tree_source] :
                source_rob_tag_i[tree_source*ROB_TAG_WIDTH +: ROB_TAG_WIDTH];
            assign tree_input[tree_source*TREE_DATA_WIDTH +: TREE_DATA_WIDTH] =
                {SOURCE_AUTH != 0 && source_lookup_write_valid_i[tree_source],
                 SOURCE_AUTH != 0 ? source_lookup_phys_i[
                    tree_source*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] :
                    {PHYS_REG_ADDR_WIDTH{1'b0}},
                 (FALLTHROUGH != 0 && !buffer_valid[tree_source]) ?
                {source_exception_tval_i[tree_source*32 +: 32],
                 source_exception_cause_i[tree_source*4 +: 4],
                 source_exception_valid_i[tree_source],
                 source_next_pc_i[tree_source*32 +: 32],
                 source_control_taken_i[tree_source], source_control_valid_i[tree_source],
                 source_value_i[tree_source*32 +: 32],
                 source_rob_tag_i[tree_source*ROB_TAG_WIDTH +: ROB_TAG_WIDTH]} :
                {buffer_exception_tval[tree_source], buffer_exception_cause[tree_source],
                 buffer_exception_valid[tree_source], buffer_next_pc[tree_source],
                 buffer_control_taken[tree_source], buffer_control_valid[tree_source],
                 buffer_value[tree_source], buffer_rob_tag[tree_source]}};
        end
    endgenerate
    rv32_ranked_select #(.ENTRIES(SOURCE_COUNT), .PORTS(BE_WIDTH),
        .SLOT_WIDTH(TREE_SLOT_WIDTH), .AGE_WIDTH(TREE_SLOT_WIDTH),
        .DATA_WIDTH(TREE_DATA_WIDTH)) tree_completion (
        .enable_i(!reset_i && !flush_i && !recover_i), .valid_i(tree_valid),
        .age_i(tree_age), .data_i(tree_input), .locked_i(stalled_lane),
        .locked_slot_i(stalled_slot),
        .valid_o(tree_selected_valid), .slot_o(selected_slot),
        .mask_o(tree_selected_mask), .data_o(tree_output));

    always @* begin
        arb_start_index = 0;
        for (arb_source_index = 0; arb_source_index < SOURCE_COUNT;
                arb_source_index = arb_source_index + 1)
            if (round_robin_start_reg[arb_source_index])
                arb_start_index = arb_source_index;
    end

    always @* begin
        completion_valid_reg = tree_selected_valid;
        selected_source_lane_reg = tree_selected_mask;
        for (arb_scan_offset = 0; arb_scan_offset < BE_WIDTH;
                arb_scan_offset = arb_scan_offset + 1) begin
            {selected_write_valid[arb_scan_offset],
             selected_phys[arb_scan_offset*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH],
             completion_exception_tval_reg[arb_scan_offset*32 +: 32],
             completion_exception_cause_reg[arb_scan_offset*4 +: 4],
             completion_exception_valid_reg[arb_scan_offset],
             completion_next_pc_reg[arb_scan_offset*32 +: 32],
             completion_control_taken_reg[arb_scan_offset],
             completion_control_valid_reg[arb_scan_offset],
             completion_value_reg[arb_scan_offset*32 +: 32],
             completion_tag_reg[arb_scan_offset*ROB_TAG_WIDTH +: ROB_TAG_WIDTH]} =
                tree_output[arb_scan_offset*TREE_DATA_WIDTH +: TREE_DATA_WIDTH];
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
        writeback_prior_lane = 0;
        writeback_duplicate = 1'b0;
        for (writeback_lane_index = 0;
                writeback_lane_index < BE_WIDTH;
                writeback_lane_index = writeback_lane_index + 1) begin
            writeback_duplicate = 1'b0;
            for (writeback_prior_lane = 0; writeback_prior_lane < writeback_lane_index;
                    writeback_prior_lane = writeback_prior_lane + 1)
                if (completion_valid_reg[writeback_prior_lane] &&
                        completion_tag_reg[writeback_prior_lane*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] ==
                        completion_tag_reg[writeback_lane_index*ROB_TAG_WIDTH +: ROB_TAG_WIDTH])
                    writeback_duplicate = 1'b1;
            if (SOURCE_AUTH != 0) begin
                if (completion_valid_reg[writeback_lane_index] &&
                        completion_ready_i[writeback_lane_index] &&
                        selected_write_valid[writeback_lane_index] && !writeback_duplicate &&
                        !completion_exception_valid_reg[writeback_lane_index] &&
                        selected_phys[writeback_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] != 0) begin
                    writeback_valid_reg[writeback_lane_index] = 1'b1;
                    writeback_phys_reg[writeback_lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] = selected_phys[
                        writeback_lane_index*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH];
                    writeback_value_reg[writeback_lane_index*32 +: 32] =
                        completion_value_reg[writeback_lane_index*32 +: 32];
                end
            end else if (completion_valid_reg[writeback_lane_index] &&
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
            stalled_lane <= 0;
            stalled_slot <= 0;
            for (sequential_source_index = 0;
                    sequential_source_index < SOURCE_COUNT;
                    sequential_source_index = sequential_source_index + 1) begin
                buffer_valid[sequential_source_index] <= 1'b0;
            end
        end else if (!recover_i) begin
            round_robin_start_reg <= round_robin_next_reg;
            stalled_lane <= (FALLTHROUGH != 0) ?
                completion_valid_reg & ~completion_ready_i : {BE_WIDTH{1'b0}};
            stalled_slot <= selected_slot;
            for (sequential_source_index = 0;
                    sequential_source_index < SOURCE_COUNT;
                    sequential_source_index = sequential_source_index + 1) begin
                if (source_ready_reg[sequential_source_index] &&
                        source_valid_i[sequential_source_index]) begin
                    buffer_valid[sequential_source_index] <= !(FALLTHROUGH != 0 &&
                        !buffer_valid[sequential_source_index] &&
                        source_pop_mask_reg[sequential_source_index]);
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
                if (SOURCE_AUTH != 0 && writeback_valid_reg[assertion_lane_index] &&
                        (!completion_accept_i[assertion_lane_index] ||
                         !completion_writes_rd_i[assertion_lane_index] ||
                         writeback_phys_reg[assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] != completion_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH])) begin
                    $display("ERROR rv32_completion_writeback_network source authorization mismatch");
                    $stop;
                end
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
