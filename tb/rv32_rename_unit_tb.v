`timescale 1ns/1ps

module rv32_rename_unit_tb #(
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter BE_WIDTH = 1
);

    localparam FREE_CAPACITY = PHYS_REGS - 32;
    localparam HISTORY_CAPACITY = 2048;

    reg clk_i;
    reg reset_i;
    reg [BE_WIDTH-1:0] rename_valid_i;
    reg rename_fire_i;
    reg [(BE_WIDTH*5)-1:0] rename_rs1_i;
    reg [(BE_WIDTH*5)-1:0] rename_rs2_i;
    reg [BE_WIDTH-1:0] rename_writes_rd_i;
    reg [(BE_WIDTH*5)-1:0] rename_rd_i;
    wire rename_ready_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rename_rs1_phys_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rename_rs2_phys_o;
    wire [BE_WIDTH-1:0] rename_rs1_ready_o;
    wire [BE_WIDTH-1:0] rename_rs2_ready_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rename_new_phys_o;
    wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rename_old_phys_o;
    wire [PHYS_REG_ADDR_WIDTH:0] free_count_o;

    reg [BE_WIDTH-1:0] commit_valid_i;
    reg [BE_WIDTH-1:0] commit_writes_rd_i;
    reg [(BE_WIDTH*5)-1:0] commit_rd_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] commit_new_phys_i;

    reg recover_i;
    reg [BE_WIDTH-1:0] rollback_valid_i;
    reg [BE_WIDTH-1:0] rollback_writes_rd_i;
    reg [(BE_WIDTH*5)-1:0] rollback_rd_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rollback_new_phys_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] rollback_old_phys_i;

    reg [BE_WIDTH-1:0] writeback_valid_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] writeback_phys_i;

    reg [PHYS_REG_ADDR_WIDTH-1:0] model_rat [0:31];
    reg [PHYS_REG_ADDR_WIDTH-1:0] model_rrat [0:31];
    reg model_ready [0:PHYS_REGS-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0] model_free [0:FREE_CAPACITY-1];
    integer model_head;
    integer model_tail;
    integer model_count;

    reg [4:0] history_rd [0:HISTORY_CAPACITY-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0] history_new [0:HISTORY_CAPACITY-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0] history_old [0:HISTORY_CAPACITY-1];
    integer history_head;
    integer history_tail;
    integer history_count;

    reg [PHYS_REG_ADDR_WIDTH-1:0] captured_new [0:BE_WIDTH-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0] captured_old [0:BE_WIDTH-1];
    reg [PHYS_REG_ADDR_WIDTH-1:0] temporary_rat [0:31];
    reg temporary_ready [0:PHYS_REGS-1];

    integer test_count;
    integer error_count;
    integer seed;
    integer lane_index;
    integer model_index;
    integer other_index;
    integer writer_count;
    integer writer_ordinal;
    integer release_ordinal;
    integer random_value;
    integer random_action;
    integer action_count;
    integer expected_ready;
    reg [4:0] selected_arch;
    reg [PHYS_REG_ADDR_WIDTH-1:0] selected_phys;
    reg [PHYS_REG_ADDR_WIDTH-1:0] expected_phys;

    rv32_rename_unit #(
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .BE_WIDTH(BE_WIDTH)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .rename_valid_i(rename_valid_i),
        .rename_fire_i(rename_fire_i),
        .rename_rs1_i(rename_rs1_i),
        .rename_rs2_i(rename_rs2_i),
        .rename_writes_rd_i(rename_writes_rd_i),
        .rename_rd_i(rename_rd_i),
        .rename_ready_o(rename_ready_o),
        .rename_rs1_phys_o(rename_rs1_phys_o),
        .rename_rs2_phys_o(rename_rs2_phys_o),
        .rename_rs1_ready_o(rename_rs1_ready_o),
        .rename_rs2_ready_o(rename_rs2_ready_o),
        .rename_new_phys_o(rename_new_phys_o),
        .rename_old_phys_o(rename_old_phys_o),
        .free_count_o(free_count_o),
        .commit_valid_i(commit_valid_i),
        .commit_writes_rd_i(commit_writes_rd_i),
        .commit_rd_i(commit_rd_i),
        .commit_new_phys_i(commit_new_phys_i),
        .recover_i(recover_i),
        .rollback_valid_i(rollback_valid_i),
        .rollback_writes_rd_i(rollback_writes_rd_i),
        .rollback_rd_i(rollback_rd_i),
        .rollback_new_phys_i(rollback_new_phys_i),
        .rollback_old_phys_i(rollback_old_phys_i),
        .writeback_valid_i(writeback_valid_i),
        .writeback_phys_i(writeback_phys_i)
    );

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    function integer wrap_free;
        input integer base;
        input integer offset;
        begin
            wrap_free = (base + offset) % FREE_CAPACITY;
        end
    endfunction

    function integer wrap_history;
        input integer base;
        input integer offset;
        integer result;
        begin
            result = (base + offset) % HISTORY_CAPACITY;
            if (result < 0) begin
                result = result + HISTORY_CAPACITY;
            end
            wrap_history = result;
        end
    endfunction

    task fail;
        input [1023:0] message;
        begin
            error_count = error_count + 1;
            $display("FAIL %0s", message);
        end
    endtask

    task clear_inputs;
        begin
            rename_valid_i = {BE_WIDTH{1'b0}};
            rename_fire_i = 1'b0;
            rename_rs1_i = {(BE_WIDTH*5){1'b0}};
            rename_rs2_i = {(BE_WIDTH*5){1'b0}};
            rename_writes_rd_i = {BE_WIDTH{1'b0}};
            rename_rd_i = {(BE_WIDTH*5){1'b0}};
            commit_valid_i = {BE_WIDTH{1'b0}};
            commit_writes_rd_i = {BE_WIDTH{1'b0}};
            commit_rd_i = {(BE_WIDTH*5){1'b0}};
            commit_new_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            recover_i = 1'b0;
            rollback_valid_i = {BE_WIDTH{1'b0}};
            rollback_writes_rd_i = {BE_WIDTH{1'b0}};
            rollback_rd_i = {(BE_WIDTH*5){1'b0}};
            rollback_new_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            rollback_old_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            writeback_valid_i = {BE_WIDTH{1'b0}};
            writeback_phys_i =
                {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        end
    endtask

    task reset_model;
        begin
            for (model_index = 0; model_index < 32;
                    model_index = model_index + 1) begin
                model_rat[model_index] = model_index;
                model_rrat[model_index] = model_index;
            end
            for (model_index = 0; model_index < PHYS_REGS;
                    model_index = model_index + 1) begin
                model_ready[model_index] = model_index < 32;
            end
            for (model_index = 0; model_index < FREE_CAPACITY;
                    model_index = model_index + 1) begin
                model_free[model_index] = model_index + 32;
            end
            model_head = 0;
            model_tail = 0;
            model_count = FREE_CAPACITY;
            history_head = 0;
            history_tail = 0;
            history_count = 0;
        end
    endtask

    task check_state;
        integer queue_index;
        begin
            test_count = test_count + 1;
            if (free_count_o !== model_count) begin
                fail("free count differs from model");
            end
            if (dut.free_head_reg !== model_head) begin
                fail("free head differs from model");
            end
            if (dut.free_tail_reg !== model_tail) begin
                fail("free tail differs from model");
            end
            for (model_index = 0; model_index < 32;
                    model_index = model_index + 1) begin
                test_count = test_count + 1;
                if (dut.rat[model_index] !== model_rat[model_index]) begin
                    fail("RAT entry differs from model");
                end
                test_count = test_count + 1;
                if (dut.rrat[model_index] !== model_rrat[model_index]) begin
                    fail("RRAT entry differs from model");
                end
            end
            for (model_index = 0; model_index < PHYS_REGS;
                    model_index = model_index + 1) begin
                test_count = test_count + 1;
                if (dut.phys_ready[model_index] !==
                        model_ready[model_index]) begin
                    fail("ready scoreboard differs from model");
                end
            end
            for (model_index = 0; model_index < model_count;
                    model_index = model_index + 1) begin
                queue_index = wrap_free(model_head, model_index);
                expected_phys = model_free[queue_index];
                test_count = test_count + 1;
                if (dut.free_list[queue_index] !== expected_phys) begin
                    fail("free list entry differs from model");
                end
                if ((expected_phys == 0) ||
                        (expected_phys >= PHYS_REGS)) begin
                    fail("free list contains an invalid physical register");
                end
                for (other_index = model_index + 1;
                        other_index < model_count;
                        other_index = other_index + 1) begin
                    if (expected_phys == model_free[
                            wrap_free(model_head, other_index)]) begin
                        fail("free list contains a duplicate register");
                    end
                end
                for (other_index = 0; other_index < 32;
                        other_index = other_index + 1) begin
                    if ((model_rat[other_index] == expected_phys) ||
                            (model_rrat[other_index] == expected_phys)) begin
                        fail("free register is present in a rename map");
                    end
                end
            end
            if ((model_rat[0] != 0) || (model_rrat[0] != 0) ||
                    !model_ready[0]) begin
                fail("x0 invariant failed in model");
            end
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk_i);
            clear_inputs;
            reset_i = 1'b1;
            #1;
            test_count = test_count + 1;
            if ((rename_ready_o !== 1'b0) ||
                    (free_count_o !== 0)) begin
                fail("outputs were not masked during reset");
            end
            @(posedge clk_i);
            #1;
            reset_model;
            @(negedge clk_i);
            reset_i = 1'b0;
            #1;
            check_state;
        end
    endtask

    task count_rename_writers;
        begin
            writer_count = 0;
            for (lane_index = 0; lane_index < BE_WIDTH;
                    lane_index = lane_index + 1) begin
                if (rename_valid_i[lane_index] &&
                        rename_writes_rd_i[lane_index] &&
                        (rename_rd_i[lane_index*5 +: 5] != 0)) begin
                    writer_count = writer_count + 1;
                end
            end
        end
    endtask

    task check_combinational;
        begin
            count_rename_writers;
            expected_ready = !recover_i && (model_count >= writer_count);
            test_count = test_count + 1;
            if (rename_ready_o !== expected_ready) begin
                fail("rename ready differs from model");
            end
            test_count = test_count + 1;
            if (free_count_o !== model_count) begin
                fail("combinational free count differs from model");
            end

            for (model_index = 0; model_index < 32;
                    model_index = model_index + 1) begin
                temporary_rat[model_index] = model_rat[model_index];
            end
            for (model_index = 0; model_index < PHYS_REGS;
                    model_index = model_index + 1) begin
                temporary_ready[model_index] = model_ready[model_index];
            end
            if (!recover_i) begin
                for (lane_index = 0; lane_index < BE_WIDTH;
                        lane_index = lane_index + 1) begin
                    selected_phys = writeback_phys_i[
                        lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH];
                    if (writeback_valid_i[lane_index] &&
                            (selected_phys != 0) &&
                            (selected_phys < PHYS_REGS)) begin
                        temporary_ready[selected_phys] = 1'b1;
                    end
                end
            end
            temporary_ready[0] = 1'b1;

            writer_ordinal = 0;
            for (lane_index = 0; lane_index < BE_WIDTH;
                    lane_index = lane_index + 1) begin
                captured_new[lane_index] = 0;
                captured_old[lane_index] = 0;
                if (!recover_i && rename_valid_i[lane_index]) begin
                    selected_arch = rename_rs1_i[lane_index*5 +: 5];
                    expected_phys = temporary_rat[selected_arch];
                    test_count = test_count + 1;
                    if (rename_rs1_phys_o[
                            lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] !== expected_phys) begin
                        fail("rs1 physical mapping differs from model");
                    end
                    test_count = test_count + 1;
                    if (rename_rs1_ready_o[lane_index] !==
                            temporary_ready[expected_phys]) begin
                        fail("rs1 ready differs from model");
                    end

                    selected_arch = rename_rs2_i[lane_index*5 +: 5];
                    expected_phys = temporary_rat[selected_arch];
                    test_count = test_count + 1;
                    if (rename_rs2_phys_o[
                            lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] !== expected_phys) begin
                        fail("rs2 physical mapping differs from model");
                    end
                    test_count = test_count + 1;
                    if (rename_rs2_ready_o[lane_index] !==
                            temporary_ready[expected_phys]) begin
                        fail("rs2 ready differs from model");
                    end

                    selected_arch = rename_rd_i[lane_index*5 +: 5];
                    if (expected_ready && rename_writes_rd_i[lane_index] &&
                            (selected_arch != 0)) begin
                        expected_phys = model_free[
                            wrap_free(model_head, writer_ordinal)];
                        captured_new[lane_index] = expected_phys;
                        captured_old[lane_index] =
                            temporary_rat[selected_arch];
                        test_count = test_count + 1;
                        if (rename_new_phys_o[
                                lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] !== expected_phys) begin
                            fail("allocated physical register differs from model");
                        end
                        test_count = test_count + 1;
                        if (rename_old_phys_o[
                                lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] !==
                                temporary_rat[selected_arch]) begin
                            fail("old physical mapping differs from model");
                        end
                        temporary_rat[selected_arch] = expected_phys;
                        temporary_ready[expected_phys] = 1'b0;
                        writer_ordinal = writer_ordinal + 1;
                    end else begin
                        test_count = test_count + 1;
                        if ((rename_new_phys_o[
                                lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] !== 0) ||
                                (rename_old_phys_o[
                                lane_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] !== 0)) begin
                            fail("non-writing lane produced rename tags");
                        end
                    end
                end
            end
        end
    endtask

    task apply_model;
        integer history_slot;
        begin
            if (recover_i) begin
                release_ordinal = 0;
                for (lane_index = 0; lane_index < BE_WIDTH;
                        lane_index = lane_index + 1) begin
                    if (rollback_valid_i[lane_index] &&
                            rollback_writes_rd_i[lane_index] &&
                            (rollback_rd_i[lane_index*5 +: 5] != 0)) begin
                        history_slot = wrap_history(history_tail, -1);
                        if ((history_count <= 0) ||
                                (history_rd[history_slot] !=
                                    rollback_rd_i[lane_index*5 +: 5]) ||
                                (history_new[history_slot] !=
                                    rollback_new_phys_i[
                                    lane_index*PHYS_REG_ADDR_WIDTH +:
                                    PHYS_REG_ADDR_WIDTH]) ||
                                (history_old[history_slot] !=
                                    rollback_old_phys_i[
                                    lane_index*PHYS_REG_ADDR_WIDTH +:
                                    PHYS_REG_ADDR_WIDTH])) begin
                            fail("rollback does not match youngest history item");
                        end
                        history_tail = history_slot;
                        history_count = history_count - 1;
                        selected_arch = rollback_rd_i[lane_index*5 +: 5];
                        model_rat[selected_arch] = rollback_old_phys_i[
                            lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH];
                        model_free[wrap_free(model_tail,
                            release_ordinal)] = rollback_new_phys_i[
                            lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH];
                        release_ordinal = release_ordinal + 1;
                    end
                end
                model_tail = wrap_free(model_tail, release_ordinal);
                model_count = model_count + release_ordinal;
            end else begin
                for (lane_index = 0; lane_index < BE_WIDTH;
                        lane_index = lane_index + 1) begin
                    selected_phys = writeback_phys_i[
                        lane_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH];
                    if (writeback_valid_i[lane_index] &&
                            (selected_phys != 0) &&
                            (selected_phys < PHYS_REGS)) begin
                        model_ready[selected_phys] = 1'b1;
                    end
                end

                release_ordinal = 0;
                for (lane_index = 0; lane_index < BE_WIDTH;
                        lane_index = lane_index + 1) begin
                    if (commit_valid_i[lane_index] &&
                            commit_writes_rd_i[lane_index] &&
                            (commit_rd_i[lane_index*5 +: 5] != 0)) begin
                        history_slot = history_head;
                        if ((history_count <= 0) ||
                                (history_rd[history_slot] !=
                                    commit_rd_i[lane_index*5 +: 5]) ||
                                (history_new[history_slot] !=
                                    commit_new_phys_i[
                                    lane_index*PHYS_REG_ADDR_WIDTH +:
                                    PHYS_REG_ADDR_WIDTH])) begin
                            fail("commit does not match oldest history item");
                        end
                        history_head = wrap_history(history_head, 1);
                        history_count = history_count - 1;
                        selected_arch = commit_rd_i[lane_index*5 +: 5];
                        model_free[wrap_free(model_tail,
                            release_ordinal)] = model_rrat[selected_arch];
                        model_rrat[selected_arch] = commit_new_phys_i[
                            lane_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH];
                        release_ordinal = release_ordinal + 1;
                    end
                end
                model_tail = wrap_free(model_tail, release_ordinal);
                model_count = model_count + release_ordinal;

                count_rename_writers;
                if (rename_fire_i && expected_ready) begin
                    for (lane_index = 0; lane_index < BE_WIDTH;
                            lane_index = lane_index + 1) begin
                        if (rename_valid_i[lane_index] &&
                                rename_writes_rd_i[lane_index] &&
                                (rename_rd_i[lane_index*5 +: 5] != 0)) begin
                            selected_arch =
                                rename_rd_i[lane_index*5 +: 5];
                            model_rat[selected_arch] = captured_new[lane_index];
                            model_ready[captured_new[lane_index]] = 1'b0;
                            history_rd[history_tail] = selected_arch;
                            history_new[history_tail] =
                                captured_new[lane_index];
                            history_old[history_tail] =
                                captured_old[lane_index];
                            history_tail = wrap_history(history_tail, 1);
                            history_count = history_count + 1;
                        end
                    end
                    model_head = wrap_free(model_head, writer_count);
                    model_count = model_count - writer_count;
                end
            end
            model_rat[0] = 0;
            model_rrat[0] = 0;
            model_ready[0] = 1'b1;
        end
    endtask

    task run_cycle;
        begin
            #1;
            check_combinational;
            @(posedge clk_i);
            apply_model;
            #1;
            check_state;
            @(negedge clk_i);
            clear_inputs;
        end
    endtask

    task prepare_commit;
        input integer requested_count;
        integer history_slot;
        begin
            action_count = requested_count;
            if (action_count > BE_WIDTH) begin
                action_count = BE_WIDTH;
            end
            if (action_count > history_count) begin
                action_count = history_count;
            end
            for (lane_index = 0; lane_index < action_count;
                    lane_index = lane_index + 1) begin
                history_slot = wrap_history(history_head, lane_index);
                commit_valid_i[lane_index] = 1'b1;
                commit_writes_rd_i[lane_index] = 1'b1;
                commit_rd_i[lane_index*5 +: 5] = history_rd[history_slot];
                commit_new_phys_i[
                    lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = history_new[history_slot];
            end
        end
    endtask

    task prepare_rollback;
        input integer requested_count;
        integer history_slot;
        begin
            recover_i = 1'b1;
            action_count = requested_count;
            if (action_count > BE_WIDTH) begin
                action_count = BE_WIDTH;
            end
            if (action_count > history_count) begin
                action_count = history_count;
            end
            for (lane_index = 0; lane_index < action_count;
                    lane_index = lane_index + 1) begin
                history_slot = wrap_history(history_tail, -(lane_index + 1));
                rollback_valid_i[lane_index] = 1'b1;
                rollback_writes_rd_i[lane_index] = 1'b1;
                rollback_rd_i[lane_index*5 +: 5] = history_rd[history_slot];
                rollback_new_phys_i[
                    lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = history_new[history_slot];
                rollback_old_phys_i[
                    lane_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = history_old[history_slot];
            end
        end
    endtask

    task test_identity_and_x0;
        begin
            reset_dut;
            for (lane_index = 0; lane_index < BE_WIDTH;
                    lane_index = lane_index + 1) begin
                rename_valid_i[lane_index] = 1'b1;
                rename_rs1_i[lane_index*5 +: 5] = lane_index;
                rename_rs2_i[lane_index*5 +: 5] = 31 - lane_index;
                rename_writes_rd_i[lane_index] = 1'b1;
                rename_rd_i[lane_index*5 +: 5] = 5'd0;
            end
            rename_fire_i = 1'b1;
            run_cycle;
            if (model_count != FREE_CAPACITY) begin
                fail("x0 rename consumed a physical register");
            end
        end
    endtask

    task test_bundle_dependencies;
        begin
            reset_dut;
            rename_valid_i[0] = 1'b1;
            rename_writes_rd_i[0] = 1'b1;
            rename_rd_i[0 +: 5] = 5'd5;
            rename_rs1_i[0 +: 5] = 5'd1;
            rename_rs2_i[0 +: 5] = 5'd0;
            if (BE_WIDTH > 1) begin
                rename_valid_i[1] = 1'b1;
                rename_writes_rd_i[1] = 1'b1;
                rename_rd_i[5 +: 5] = 5'd5;
                rename_rs1_i[5 +: 5] = 5'd5;
                rename_rs2_i[5 +: 5] = 5'd2;
            end
            if (BE_WIDTH > 2) begin
                rename_valid_i[2] = 1'b1;
                rename_writes_rd_i[2] = 1'b1;
                rename_rd_i[10 +: 5] = 5'd6;
                rename_rs1_i[10 +: 5] = 5'd5;
                rename_rs2_i[10 +: 5] = 5'd5;
            end
            rename_fire_i = 1'b1;
            run_cycle;

            clear_inputs;
            rename_valid_i[0] = 1'b1;
            rename_rs1_i[0 +: 5] = 5'd5;
            writeback_valid_i[0] = 1'b1;
            writeback_phys_i[0 +: PHYS_REG_ADDR_WIDTH] = model_rat[5];
            run_cycle;
        end
    endtask

    task test_commit_and_rollback;
        begin
            reset_dut;
            rename_valid_i[0] = 1'b1;
            rename_writes_rd_i[0] = 1'b1;
            rename_rd_i[0 +: 5] = 5'd7;
            if (BE_WIDTH > 1) begin
                rename_valid_i[1] = 1'b1;
                rename_writes_rd_i[1] = 1'b1;
                rename_rd_i[5 +: 5] = 5'd7;
                rename_rs1_i[5 +: 5] = 5'd7;
            end
            rename_fire_i = 1'b1;
            run_cycle;

            clear_inputs;
            prepare_commit(BE_WIDTH);
            run_cycle;

            reset_dut;
            rename_valid_i[0] = 1'b1;
            rename_writes_rd_i[0] = 1'b1;
            rename_rd_i[0 +: 5] = 5'd9;
            if (BE_WIDTH > 1) begin
                rename_valid_i[1] = 1'b1;
                rename_writes_rd_i[1] = 1'b1;
                rename_rd_i[5 +: 5] = 5'd9;
            end
            rename_fire_i = 1'b1;
            run_cycle;
            clear_inputs;
            prepare_rollback(BE_WIDTH);
            run_cycle;
            if ((model_rat[9] != 9) ||
                    (model_rrat[9] != 9)) begin
                fail("rollback did not restore RAT or changed RRAT");
            end
        end
    endtask

    task test_full_and_wrap;
        integer cycle_index;
        begin
            reset_dut;
            for (cycle_index = 0; cycle_index < FREE_CAPACITY;
                    cycle_index = cycle_index + 1) begin
                rename_valid_i[0] = 1'b1;
                rename_writes_rd_i[0] = 1'b1;
                rename_rd_i[0 +: 5] = (cycle_index % 31) + 1;
                rename_fire_i = 1'b1;
                run_cycle;
            end
            rename_valid_i[0] = 1'b1;
            rename_writes_rd_i[0] = 1'b1;
            rename_rd_i[0 +: 5] = 5'd1;
            rename_fire_i = 1'b0;
            run_cycle;
            if (model_count != 0) begin
                fail("free list did not reach full allocation state");
            end

            for (cycle_index = 0; cycle_index < (2 * FREE_CAPACITY + 3);
                    cycle_index = cycle_index + 1) begin
                prepare_commit(1);
                run_cycle;
                rename_valid_i[0] = 1'b1;
                rename_writes_rd_i[0] = 1'b1;
                rename_rd_i[0 +: 5] = (cycle_index % 31) + 1;
                rename_fire_i = 1'b1;
                run_cycle;
            end
        end
    endtask

    task test_random_reference;
        integer cycle_index;
        integer available_writers;
        begin
            reset_dut;
            for (cycle_index = 0; cycle_index < 300;
                    cycle_index = cycle_index + 1) begin
                random_value = $random(seed) & 32'h7fffffff;
                random_action = random_value % 10;
                if ((random_action < 2) && (history_count > 0)) begin
                    prepare_rollback((random_value % BE_WIDTH) + 1);
                end else begin
                    if ((random_action < 6) && (history_count > 0)) begin
                        prepare_commit((random_value % BE_WIDTH) + 1);
                    end
                    available_writers = model_count;
                    if (available_writers > BE_WIDTH) begin
                        available_writers = BE_WIDTH;
                    end
                    for (lane_index = 0; lane_index < BE_WIDTH;
                            lane_index = lane_index + 1) begin
                        random_value = $random(seed) & 32'h7fffffff;
                        rename_valid_i[lane_index] = (random_value % 4) != 0;
                        rename_rs1_i[lane_index*5 +: 5] =
                            random_value % 32;
                        rename_rs2_i[lane_index*5 +: 5] =
                            (random_value / 37) % 32;
                        rename_rd_i[lane_index*5 +: 5] =
                            (random_value / 101) % 32;
                        rename_writes_rd_i[lane_index] =
                            rename_valid_i[lane_index] &&
                            ((random_value % 3) != 0) &&
                            (available_writers > 0);
                        if (rename_writes_rd_i[lane_index] &&
                                (rename_rd_i[lane_index*5 +: 5] != 0)) begin
                            available_writers = available_writers - 1;
                        end
                    end
                    rename_fire_i = 1'b1;
                    if (history_count > 0) begin
                        random_value = $random(seed) & 32'h7fffffff;
                        if ((random_value % 3) == 0) begin
                            writeback_valid_i[0] = 1'b1;
                            selected_phys = history_new[wrap_history(
                                history_head, random_value % history_count)];
                            writeback_phys_i[0 +:
                                PHYS_REG_ADDR_WIDTH] = selected_phys;
                        end
                    end
                end
                run_cycle;
            end

            while (history_count > 0) begin
                prepare_rollback(BE_WIDTH);
                run_cycle;
            end
            if (model_count != FREE_CAPACITY) begin
                fail("random rollback did not restore all free registers");
            end
        end
    endtask

    initial begin
        reset_i = 1'b0;
        clear_inputs;
        reset_model;
        test_count = 0;
        error_count = 0;
        seed = 32'h13579bdf ^ PHYS_REGS ^ BE_WIDTH;

        test_identity_and_x0;
        test_bundle_dependencies;
        test_commit_and_rollback;
        test_full_and_wrap;
        test_random_reference;

        if (error_count == 0) begin
            $display("PASS rv32_rename_unit PHYS_REGS=%0d BE_WIDTH=%0d checks=%0d",
                PHYS_REGS, BE_WIDTH, test_count);
            $finish(0);
        end else begin
            $display("FAIL rv32_rename_unit PHYS_REGS=%0d BE_WIDTH=%0d errors=%0d checks=%0d",
                PHYS_REGS, BE_WIDTH, error_count, test_count);
            $finish(1);
        end
    end

endmodule
