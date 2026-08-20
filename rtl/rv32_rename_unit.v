`timescale 1ns/1ps

module rv32_rename_unit #(
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter BE_WIDTH = 1
) (
    input  wire                                             clk_i,
    input  wire                                             reset_i,

    input  wire [BE_WIDTH-1:0]                              rename_valid_i,
    input  wire                                             rename_fire_i,
    input  wire [(BE_WIDTH*5)-1:0]                          rename_rs1_i,
    input  wire [(BE_WIDTH*5)-1:0]                          rename_rs2_i,
    input  wire [BE_WIDTH-1:0]                              rename_writes_rd_i,
    input  wire [(BE_WIDTH*5)-1:0]                          rename_rd_i,
    output wire                                             rename_ready_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        rename_rs1_phys_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        rename_rs2_phys_o,
    output wire [BE_WIDTH-1:0]                              rename_rs1_ready_o,
    output wire [BE_WIDTH-1:0]                              rename_rs2_ready_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        rename_new_phys_o,
    output wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        rename_old_phys_o,
    output wire [PHYS_REG_ADDR_WIDTH:0]                     free_count_o,

    input  wire [BE_WIDTH-1:0]                              commit_valid_i,
    input  wire [BE_WIDTH-1:0]                              commit_writes_rd_i,
    input  wire [(BE_WIDTH*5)-1:0]                          commit_rd_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        commit_new_phys_i,

    input  wire                                             recover_i,
    input  wire [BE_WIDTH-1:0]                              rollback_valid_i,
    input  wire [BE_WIDTH-1:0]                              rollback_writes_rd_i,
    input  wire [(BE_WIDTH*5)-1:0]                          rollback_rd_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        rollback_new_phys_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        rollback_old_phys_i,

    input  wire [BE_WIDTH-1:0]                              writeback_valid_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        writeback_phys_i
);

    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */

    localparam FREE_CAPACITY = PHYS_REGS - 32;
    localparam [PHYS_REG_ADDR_WIDTH:0] PHYS_REGS_LIMIT =
        PHYS_REGS[PHYS_REG_ADDR_WIDTH:0];
    localparam [PHYS_REG_ADDR_WIDTH:0] FREE_CAPACITY_LIMIT =
        FREE_CAPACITY[PHYS_REG_ADDR_WIDTH:0];

    reg [PHYS_REG_ADDR_WIDTH-1:0] rat [0:31];
    reg [PHYS_REG_ADDR_WIDTH-1:0] rrat [0:31];
    reg [PHYS_REG_ADDR_WIDTH-1:0] free_list [0:FREE_CAPACITY-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0] free_head_reg;
    reg [PHYS_REG_ADDR_WIDTH-1:0] free_tail_reg;
    reg [PHYS_REG_ADDR_WIDTH:0] free_count_reg;
    reg phys_ready [0:PHYS_REGS-1];

    reg [PHYS_REG_ADDR_WIDTH-1:0] rat_work [0:31];
    reg [PHYS_REG_ADDR_WIDTH-1:0] rrat_work [0:31];
    reg ready_work [0:PHYS_REGS-1];

    reg rename_ready_reg;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rename_rs1_phys_reg;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rename_rs2_phys_reg;
    reg [BE_WIDTH-1:0] rename_rs1_ready_reg;
    reg [BE_WIDTH-1:0] rename_rs2_ready_reg;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rename_new_phys_reg;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rename_old_phys_reg;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] commit_old_phys_reg;

    reg [4:0] rrat_arch_reg;
    reg [4:0] rename_arch_reg;
    reg [PHYS_REG_ADDR_WIDTH-1:0] rename_phys_reg;
    reg [PHYS_REG_ADDR_WIDTH-1:0] rename_allocated_phys_reg;

    integer count_lane_index;
    integer rrat_arch_index;
    integer rrat_lane_index;
    integer rename_arch_index;
    integer rename_phys_index;
    integer rename_lane_index;
    integer sequential_arch_index;
    integer sequential_phys_index;
    integer sequential_lane_index;
    integer assertion_lane_index;
    integer assertion_other_lane_index;
    integer rename_writer_count;
    integer commit_writer_count;
    integer rollback_writer_count;
    integer allocation_ordinal;
    integer release_ordinal;

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

    function [PHYS_REG_ADDR_WIDTH-1:0] free_index_add;
        input [PHYS_REG_ADDR_WIDTH-1:0] base;
        input integer offset;
        integer sum;
        integer wrap_step;
        begin
            sum = base + offset;
            for (wrap_step = 0; wrap_step < BE_WIDTH;
                    wrap_step = wrap_step + 1) begin
                if (sum >= FREE_CAPACITY) begin
                    sum = sum - FREE_CAPACITY;
                end
            end
            free_index_add = sum;
        end
    endfunction

    assign rename_ready_o = rename_ready_reg;
    assign rename_rs1_phys_o = rename_rs1_phys_reg;
    assign rename_rs2_phys_o = rename_rs2_phys_reg;
    assign rename_rs1_ready_o = rename_rs1_ready_reg;
    assign rename_rs2_ready_o = rename_rs2_ready_reg;
    assign rename_new_phys_o = rename_new_phys_reg;
    assign rename_old_phys_o = rename_old_phys_reg;
    assign free_count_o = reset_i ?
        {(PHYS_REG_ADDR_WIDTH+1){1'b0}} : free_count_reg;

    initial begin
        if ((BE_WIDTH != 1) && (BE_WIDTH != 2) && (BE_WIDTH != 4)) begin
            $display("ERROR rv32_rename_unit invalid BE_WIDTH=%0d", BE_WIDTH);
            $finish(1);
        end
        if (PHYS_REGS < 33) begin
            $display("ERROR rv32_rename_unit PHYS_REGS=%0d is below 33",
                PHYS_REGS);
            $finish(1);
        end
        if (PHYS_REG_ADDR_WIDTH != address_width_for_count(PHYS_REGS)) begin
            $display("ERROR rv32_rename_unit address width=%0d expected=%0d",
                PHYS_REG_ADDR_WIDTH, address_width_for_count(PHYS_REGS));
            $finish(1);
        end
    end

    always @* begin
        rename_writer_count = 0;
        commit_writer_count = 0;
        rollback_writer_count = 0;
        for (count_lane_index = 0; count_lane_index < BE_WIDTH;
                count_lane_index = count_lane_index + 1) begin
            if (rename_valid_i[count_lane_index] &&
                    rename_writes_rd_i[count_lane_index] &&
                    (rename_rd_i[count_lane_index*5 +: 5] != 5'd0)) begin
                rename_writer_count = rename_writer_count + 1;
            end
            if (commit_valid_i[count_lane_index] &&
                    commit_writes_rd_i[count_lane_index] &&
                    (commit_rd_i[count_lane_index*5 +: 5] != 5'd0)) begin
                commit_writer_count = commit_writer_count + 1;
            end
            if (rollback_valid_i[count_lane_index] &&
                    rollback_writes_rd_i[count_lane_index] &&
                    (rollback_rd_i[count_lane_index*5 +: 5] != 5'd0)) begin
                rollback_writer_count = rollback_writer_count + 1;
            end
        end
    end

    always @* begin
        rrat_arch_reg = 5'd0;
        for (rrat_arch_index = 0; rrat_arch_index < 32;
                rrat_arch_index = rrat_arch_index + 1) begin
            rrat_work[rrat_arch_index] = rrat[rrat_arch_index];
        end
        commit_old_phys_reg =
            {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        for (rrat_lane_index = 0; rrat_lane_index < BE_WIDTH;
                rrat_lane_index = rrat_lane_index + 1) begin
            rrat_arch_reg = commit_rd_i[rrat_lane_index*5 +: 5];
            if (commit_valid_i[rrat_lane_index] &&
                    commit_writes_rd_i[rrat_lane_index] &&
                    (rrat_arch_reg != 5'd0)) begin
                commit_old_phys_reg[
                    rrat_lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = rrat_work[rrat_arch_reg];
                rrat_work[rrat_arch_reg] = commit_new_phys_i[
                    rrat_lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH];
            end
        end
    end

    always @* begin
        rename_arch_reg = 5'd0;
        rename_phys_reg = {PHYS_REG_ADDR_WIDTH{1'b0}};
        rename_allocated_phys_reg = {PHYS_REG_ADDR_WIDTH{1'b0}};
        for (rename_arch_index = 0; rename_arch_index < 32;
                rename_arch_index = rename_arch_index + 1) begin
            rat_work[rename_arch_index] = rat[rename_arch_index];
        end
        for (rename_phys_index = 0; rename_phys_index < PHYS_REGS;
                rename_phys_index = rename_phys_index + 1) begin
            ready_work[rename_phys_index] = phys_ready[rename_phys_index];
        end

        if (!reset_i && !recover_i) begin
            for (rename_lane_index = 0; rename_lane_index < BE_WIDTH;
                    rename_lane_index = rename_lane_index + 1) begin
                rename_phys_reg = writeback_phys_i[
                    rename_lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH];
                if (writeback_valid_i[rename_lane_index] &&
                        (rename_phys_reg !=
                            {PHYS_REG_ADDR_WIDTH{1'b0}}) &&
                        ({1'b0, rename_phys_reg} < PHYS_REGS_LIMIT)) begin
                    ready_work[rename_phys_reg] = 1'b1;
                end
            end
        end
        ready_work[0] = 1'b1;

        rename_ready_reg = !reset_i && !recover_i &&
            (free_count_reg >= rename_writer_count);
        rename_rs1_phys_reg =
            {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        rename_rs2_phys_reg =
            {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        rename_rs1_ready_reg = {BE_WIDTH{1'b0}};
        rename_rs2_ready_reg = {BE_WIDTH{1'b0}};
        rename_new_phys_reg =
            {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        rename_old_phys_reg =
            {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        allocation_ordinal = 0;

        for (rename_lane_index = 0; rename_lane_index < BE_WIDTH;
                rename_lane_index = rename_lane_index + 1) begin
            if (!reset_i && !recover_i &&
                    rename_valid_i[rename_lane_index]) begin
                rename_arch_reg = rename_rs1_i[rename_lane_index*5 +: 5];
                rename_phys_reg = rat_work[rename_arch_reg];
                rename_rs1_phys_reg[
                    rename_lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = rename_phys_reg;
                rename_rs1_ready_reg[rename_lane_index] =
                    (rename_phys_reg ==
                        {PHYS_REG_ADDR_WIDTH{1'b0}}) ? 1'b1 :
                    ready_work[rename_phys_reg];

                rename_arch_reg = rename_rs2_i[rename_lane_index*5 +: 5];
                rename_phys_reg = rat_work[rename_arch_reg];
                rename_rs2_phys_reg[
                    rename_lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = rename_phys_reg;
                rename_rs2_ready_reg[rename_lane_index] =
                    (rename_phys_reg ==
                        {PHYS_REG_ADDR_WIDTH{1'b0}}) ? 1'b1 :
                    ready_work[rename_phys_reg];

                rename_arch_reg = rename_rd_i[rename_lane_index*5 +: 5];
                if (rename_ready_reg &&
                        rename_writes_rd_i[rename_lane_index] &&
                        (rename_arch_reg != 5'd0)) begin
                    rename_allocated_phys_reg = free_list[free_index_add(
                        free_head_reg, allocation_ordinal)];
                    rename_new_phys_reg[
                        rename_lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] = rename_allocated_phys_reg;
                    rename_old_phys_reg[
                        rename_lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] = rat_work[rename_arch_reg];
                    rat_work[rename_arch_reg] = rename_allocated_phys_reg;
                    ready_work[rename_allocated_phys_reg] = 1'b0;
                    allocation_ordinal = allocation_ordinal + 1;
                end
            end
        end
    end

    always @(posedge clk_i) begin
        if (reset_i) begin
            for (sequential_arch_index = 0; sequential_arch_index < 32;
                    sequential_arch_index = sequential_arch_index + 1) begin
                rat[sequential_arch_index] <= sequential_arch_index;
                rrat[sequential_arch_index] <= sequential_arch_index;
            end
            for (sequential_phys_index = 0;
                    sequential_phys_index < FREE_CAPACITY;
                    sequential_phys_index = sequential_phys_index + 1) begin
                free_list[sequential_phys_index] <=
                    sequential_phys_index + 32;
            end
            for (sequential_phys_index = 0;
                    sequential_phys_index < PHYS_REGS;
                    sequential_phys_index = sequential_phys_index + 1) begin
                phys_ready[sequential_phys_index] <=
                    sequential_phys_index < 32;
            end
            free_head_reg <= {PHYS_REG_ADDR_WIDTH{1'b0}};
            free_tail_reg <= {PHYS_REG_ADDR_WIDTH{1'b0}};
            free_count_reg <= FREE_CAPACITY_LIMIT;
        end else if (recover_i) begin
            /* verilator lint_off BLKSEQ */
            release_ordinal = 0;
            for (sequential_lane_index = 0;
                    sequential_lane_index < BE_WIDTH;
                    sequential_lane_index = sequential_lane_index + 1) begin
                if (rollback_valid_i[sequential_lane_index] &&
                        rollback_writes_rd_i[sequential_lane_index] &&
                        (rollback_rd_i[sequential_lane_index*5 +: 5] !=
                            5'd0)) begin
                    rat[rollback_rd_i[sequential_lane_index*5 +: 5]] <=
                        rollback_old_phys_i[
                        sequential_lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH];
                    free_list[free_index_add(free_tail_reg,
                        release_ordinal)] <= rollback_new_phys_i[
                        sequential_lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH];
                    release_ordinal = release_ordinal + 1;
                end
            end
            /* verilator lint_on BLKSEQ */
            free_tail_reg <= free_index_add(free_tail_reg,
                rollback_writer_count);
            free_count_reg <= free_count_reg + rollback_writer_count;
            rat[0] <= {PHYS_REG_ADDR_WIDTH{1'b0}};
            rrat[0] <= {PHYS_REG_ADDR_WIDTH{1'b0}};
            phys_ready[0] <= 1'b1;
        end else begin
            for (sequential_lane_index = 0;
                    sequential_lane_index < BE_WIDTH;
                    sequential_lane_index = sequential_lane_index + 1) begin
                if (writeback_valid_i[sequential_lane_index] &&
                        (writeback_phys_i[
                            sequential_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] !=
                            {PHYS_REG_ADDR_WIDTH{1'b0}}) &&
                        ({1'b0, writeback_phys_i[
                            sequential_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH]} < PHYS_REGS_LIMIT)) begin
                    phys_ready[writeback_phys_i[
                        sequential_lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH]] <= 1'b1;
                end
            end

            /* verilator lint_off BLKSEQ */
            release_ordinal = 0;
            for (sequential_lane_index = 0;
                    sequential_lane_index < BE_WIDTH;
                    sequential_lane_index = sequential_lane_index + 1) begin
                if (commit_valid_i[sequential_lane_index] &&
                        commit_writes_rd_i[sequential_lane_index] &&
                        (commit_rd_i[sequential_lane_index*5 +: 5] !=
                            5'd0)) begin
                    rrat[commit_rd_i[sequential_lane_index*5 +: 5]] <=
                        commit_new_phys_i[
                        sequential_lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH];
                    free_list[free_index_add(free_tail_reg,
                        release_ordinal)] <= commit_old_phys_reg[
                        sequential_lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH];
                    release_ordinal = release_ordinal + 1;
                end
            end
            /* verilator lint_on BLKSEQ */
            free_tail_reg <= free_index_add(free_tail_reg,
                commit_writer_count);

            if (rename_fire_i && rename_ready_reg) begin
                for (sequential_arch_index = 1;
                        sequential_arch_index < 32;
                        sequential_arch_index = sequential_arch_index + 1) begin
                    rat[sequential_arch_index] <=
                        rat_work[sequential_arch_index];
                end
                for (sequential_lane_index = 0;
                        sequential_lane_index < BE_WIDTH;
                        sequential_lane_index = sequential_lane_index + 1) begin
                    if (rename_valid_i[sequential_lane_index] &&
                            rename_writes_rd_i[sequential_lane_index] &&
                            (rename_rd_i[sequential_lane_index*5 +: 5] !=
                                5'd0)) begin
                        phys_ready[rename_new_phys_reg[
                            sequential_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH]] <= 1'b0;
                    end
                end
                free_head_reg <= free_index_add(free_head_reg,
                    rename_writer_count);
            end

            free_count_reg <= free_count_reg + commit_writer_count -
                ((rename_fire_i && rename_ready_reg) ?
                    rename_writer_count : 0);
            rat[0] <= {PHYS_REG_ADDR_WIDTH{1'b0}};
            rrat[0] <= {PHYS_REG_ADDR_WIDTH{1'b0}};
            phys_ready[0] <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (!reset_i) begin
            if (free_count_reg > FREE_CAPACITY_LIMIT) begin
                $display("ERROR rv32_rename_unit free count overflow count=%0d",
                    free_count_reg);
                $finish(1);
            end
            if (rename_fire_i && !rename_ready_reg) begin
                $display("ERROR rv32_rename_unit rename fired without resources");
                $finish(1);
            end
            if (recover_i && (rename_fire_i || (|commit_valid_i))) begin
                $display("ERROR rv32_rename_unit normal traffic during recovery");
                $finish(1);
            end
            if (recover_i &&
                    (free_count_reg + rollback_writer_count >
                        FREE_CAPACITY_LIMIT)) begin
                $display("ERROR rv32_rename_unit rollback free overflow");
                $finish(1);
            end
            if (!recover_i &&
                    (free_count_reg + commit_writer_count -
                        ((rename_fire_i && rename_ready_reg) ?
                            rename_writer_count : 0) >
                        FREE_CAPACITY_LIMIT)) begin
                $display("ERROR rv32_rename_unit commit free overflow");
                $finish(1);
            end

            for (assertion_lane_index = 0;
                    assertion_lane_index < BE_WIDTH;
                    assertion_lane_index = assertion_lane_index + 1) begin
                if (commit_valid_i[assertion_lane_index] &&
                        commit_writes_rd_i[assertion_lane_index] &&
                        (commit_rd_i[assertion_lane_index*5 +: 5] != 5'd0)) begin
                    if ((commit_new_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] ==
                            {PHYS_REG_ADDR_WIDTH{1'b0}}) ||
                            !({1'b0, commit_new_phys_i[
                                assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH]} < PHYS_REGS_LIMIT)) begin
                        $display("ERROR rv32_rename_unit invalid commit phys=%0d",
                            commit_new_phys_i[
                                assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH]);
                        $finish(1);
                    end
                    if (commit_old_phys_reg[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] ==
                            {PHYS_REG_ADDR_WIDTH{1'b0}}) begin
                        $display("ERROR rv32_rename_unit attempted to free p0");
                        $finish(1);
                    end
                end
                if (recover_i && rollback_valid_i[assertion_lane_index] &&
                        rollback_writes_rd_i[assertion_lane_index] &&
                        (rollback_rd_i[assertion_lane_index*5 +: 5] !=
                            5'd0)) begin
                    if ((rollback_new_phys_i[
                            assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] ==
                            {PHYS_REG_ADDR_WIDTH{1'b0}}) ||
                            !({1'b0, rollback_new_phys_i[
                                assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH]} < PHYS_REGS_LIMIT) ||
                            (rollback_old_phys_i[
                                assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                                {PHYS_REG_ADDR_WIDTH{1'b0}}) ||
                            !({1'b0, rollback_old_phys_i[
                                assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH]} < PHYS_REGS_LIMIT)) begin
                        $display("ERROR rv32_rename_unit invalid rollback mapping");
                        $finish(1);
                    end
                end
            end

            for (assertion_lane_index = 0;
                    assertion_lane_index < BE_WIDTH;
                    assertion_lane_index = assertion_lane_index + 1) begin
                for (assertion_other_lane_index = assertion_lane_index + 1;
                        assertion_other_lane_index < BE_WIDTH;
                        assertion_other_lane_index =
                            assertion_other_lane_index + 1) begin
                    if (commit_valid_i[assertion_lane_index] &&
                            commit_writes_rd_i[assertion_lane_index] &&
                            (commit_rd_i[assertion_lane_index*5 +: 5] !=
                                5'd0) &&
                            commit_valid_i[assertion_other_lane_index] &&
                            commit_writes_rd_i[assertion_other_lane_index] &&
                            (commit_rd_i[
                                assertion_other_lane_index*5 +: 5] != 5'd0) &&
                            (commit_old_phys_reg[
                                assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                             commit_old_phys_reg[
                                assertion_other_lane_index*
                                PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH])) begin
                        $display("ERROR rv32_rename_unit duplicate commit release");
                        $finish(1);
                    end
                    if (recover_i &&
                            rollback_valid_i[assertion_lane_index] &&
                            rollback_writes_rd_i[assertion_lane_index] &&
                            (rollback_rd_i[
                                assertion_lane_index*5 +: 5] != 5'd0) &&
                            rollback_valid_i[assertion_other_lane_index] &&
                            rollback_writes_rd_i[
                                assertion_other_lane_index] &&
                            (rollback_rd_i[
                                assertion_other_lane_index*5 +: 5] != 5'd0) &&
                            (rollback_new_phys_i[
                                assertion_lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                             rollback_new_phys_i[
                                assertion_other_lane_index*
                                PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH])) begin
                        $display("ERROR rv32_rename_unit duplicate rollback release");
                        $finish(1);
                    end
                end
            end
        end
    end
`endif

    /* verilator lint_on WIDTHTRUNC */
    /* verilator lint_on WIDTHEXPAND */

endmodule
