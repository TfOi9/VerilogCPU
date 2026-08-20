`timescale 1ns/1ps

module rv32_physical_register_file_tb #(
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter BE_WIDTH = 1
);

    localparam READ_PORTS = 2 * BE_WIDTH;
    localparam ADDRESS_CAPACITY = 1 << PHYS_REG_ADDR_WIDTH;
    localparam [PHYS_REG_ADDR_WIDTH:0] PHYS_REGS_LIMIT =
        PHYS_REGS[PHYS_REG_ADDR_WIDTH:0];

    reg clk_i;
    reg reset_i;
    reg [(READ_PORTS*PHYS_REG_ADDR_WIDTH)-1:0] read_addr_i;
    wire [(READ_PORTS*32)-1:0] read_data_o;
    reg [BE_WIDTH-1:0] write_valid_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] write_addr_i;
    reg [(BE_WIDTH*32)-1:0] write_data_i;

    reg [31:0] model [0:PHYS_REGS-1];
    integer test_count;
    integer error_count;
    integer seed;

    rv32_physical_register_file #(
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .BE_WIDTH(BE_WIDTH)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .read_addr_i(read_addr_i),
        .read_data_o(read_data_o),
        .write_valid_i(write_valid_i),
        .write_addr_i(write_addr_i),
        .write_data_i(write_data_i)
    );

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    function [31:0] expected_read;
        input [PHYS_REG_ADDR_WIDTH-1:0] address;
        integer lane;
        begin
            expected_read = 32'd0;
            if (!reset_i &&
                    (address != {PHYS_REG_ADDR_WIDTH{1'b0}}) &&
                    ({1'b0, address} < PHYS_REGS_LIMIT)) begin
                expected_read = model[address];
                for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                    if (write_valid_i[lane] &&
                            (write_addr_i[
                                lane*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] == address)) begin
                        expected_read = write_data_i[lane*32 +: 32];
                    end
                end
            end
        end
    endfunction

    task clear_write_inputs;
        begin
            write_valid_i = {BE_WIDTH{1'b0}};
            write_addr_i = {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            write_data_i = {(BE_WIDTH*32){1'b0}};
        end
    endtask

    task clear_model;
        integer index;
        begin
            for (index = 0; index < PHYS_REGS; index = index + 1) begin
                model[index] = 32'd0;
            end
        end
    endtask

    task apply_model_writes;
        integer lane;
        reg [PHYS_REG_ADDR_WIDTH-1:0] address;
        begin
            for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                address = write_addr_i[
                    lane*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH];
                if (write_valid_i[lane] &&
                        (address != {PHYS_REG_ADDR_WIDTH{1'b0}}) &&
                        ({1'b0, address} < PHYS_REGS_LIMIT)) begin
                    model[address] = write_data_i[lane*32 +: 32];
                end
            end
            model[0] = 32'd0;
        end
    endtask

    task check_all_reads;
        integer port_index;
        reg [PHYS_REG_ADDR_WIDTH-1:0] address;
        reg [31:0] expected;
        reg [31:0] actual;
        begin
            #1;
            for (port_index = 0; port_index < READ_PORTS;
                    port_index = port_index + 1) begin
                address = read_addr_i[
                    port_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH];
                expected = expected_read(address);
                actual = read_data_o[port_index*32 +: 32];
                test_count = test_count + 1;
                if (actual !== expected) begin
                    error_count = error_count + 1;
                    $display("FAIL read port=%0d address=%0d got=%08x expected=%08x",
                        port_index, address, actual, expected);
                end
            end
        end
    endtask

    task set_read_addresses;
        input integer first_address;
        integer port_index;
        integer selected_address;
        begin
            for (port_index = 0; port_index < READ_PORTS;
                    port_index = port_index + 1) begin
                selected_address = first_address + port_index;
                if (selected_address >= ADDRESS_CAPACITY) begin
                    selected_address = 0;
                end
                read_addr_i[
                    port_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = selected_address;
            end
        end
    endtask

    task reset_dut;
        integer lane;
        begin
            @(negedge clk_i);
            reset_i = 1'b1;
            write_valid_i = {BE_WIDTH{1'b1}};
            for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                write_addr_i[
                    lane*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = lane + 1;
                write_data_i[lane*32 +: 32] = 32'hdead0000 + lane;
            end
            set_read_addresses(0);
            check_all_reads;
            @(posedge clk_i);
            clear_model;
            check_all_reads;
            @(negedge clk_i);
            reset_i = 1'b0;
            clear_write_inputs;
            check_all_reads;
        end
    endtask

    task test_posedge_update_and_bypass;
        begin
            reset_dut;

            @(posedge clk_i);
            #1;
            read_addr_i[0 +: PHYS_REG_ADDR_WIDTH] = 5;
            write_valid_i[0] = 1'b1;
            write_addr_i[0 +: PHYS_REG_ADDR_WIDTH] = 5;
            write_data_i[0 +: 32] = 32'h12345678;
            check_all_reads;
            @(negedge clk_i);
            clear_write_inputs;
            check_all_reads;

            write_valid_i[0] = 1'b1;
            write_addr_i[0 +: PHYS_REG_ADDR_WIDTH] = 5;
            write_data_i[0 +: 32] = 32'h89abcdef;
            check_all_reads;
            @(posedge clk_i);
            apply_model_writes;
            check_all_reads;
            @(negedge clk_i);
            clear_write_inputs;
            check_all_reads;
        end
    endtask

    task test_independent_ports;
        integer lane;
        begin
            reset_dut;
            @(negedge clk_i);
            clear_write_inputs;
            for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                write_valid_i[lane] = 1'b1;
                write_addr_i[
                    lane*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = 10 + lane;
                write_data_i[lane*32 +: 32] =
                    32'h10000000 + lane;
            end
            set_read_addresses(10);
            check_all_reads;
            @(posedge clk_i);
            apply_model_writes;
            check_all_reads;
            @(negedge clk_i);
            clear_write_inputs;
            check_all_reads;
        end
    endtask

    task test_write_collision;
        integer lane;
        integer port_index;
        begin
            reset_dut;
            @(negedge clk_i);
            for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                write_valid_i[lane] = 1'b1;
                write_addr_i[
                    lane*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = 20;
                write_data_i[lane*32 +: 32] =
                    32'h20000000 + lane;
            end
            for (port_index = 0; port_index < READ_PORTS;
                    port_index = port_index + 1) begin
                read_addr_i[
                    port_index*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = 20;
            end
            check_all_reads;
            @(posedge clk_i);
            apply_model_writes;
            check_all_reads;
            @(negedge clk_i);
            clear_write_inputs;
            check_all_reads;
        end
    endtask

    task test_zero_register;
        integer lane;
        begin
            reset_dut;
            @(negedge clk_i);
            read_addr_i = {(READ_PORTS*PHYS_REG_ADDR_WIDTH){1'b0}};
            for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                write_valid_i[lane] = 1'b1;
                write_addr_i[
                    lane*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = 0;
                write_data_i[lane*32 +: 32] =
                    32'hffffffff - lane;
            end
            check_all_reads;
            @(posedge clk_i);
            apply_model_writes;
            check_all_reads;
            @(negedge clk_i);
            clear_write_inputs;
            check_all_reads;
        end
    endtask

    task test_out_of_range_address;
        integer lane;
        begin
            if (ADDRESS_CAPACITY > PHYS_REGS) begin
                reset_dut;
                @(negedge clk_i);
                read_addr_i =
                    {(READ_PORTS*PHYS_REG_ADDR_WIDTH){1'b1}};
                for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                    write_valid_i[lane] = 1'b1;
                    write_addr_i[
                        lane*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] =
                        {PHYS_REG_ADDR_WIDTH{1'b1}};
                    write_data_i[lane*32 +: 32] =
                        32'hbad00000 + lane;
                end
                check_all_reads;
                @(posedge clk_i);
                apply_model_writes;
                check_all_reads;
                @(negedge clk_i);
                clear_write_inputs;
                check_all_reads;
            end
        end
    endtask

    task test_reset_priority_and_full_clear;
        integer address;
        integer port_index;
        integer selected_address;
        begin
            reset_dut;
            for (address = 1; address < PHYS_REGS; address = address + 1) begin
                @(negedge clk_i);
                clear_write_inputs;
                write_valid_i[0] = 1'b1;
                write_addr_i[0 +: PHYS_REG_ADDR_WIDTH] = address;
                write_data_i[0 +: 32] = 32'h60000000 + address;
                @(posedge clk_i);
                apply_model_writes;
            end

            @(negedge clk_i);
            reset_i = 1'b1;
            write_valid_i = {BE_WIDTH{1'b1}};
            write_addr_i = {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
            write_data_i = {(BE_WIDTH*32){1'b1}};
            set_read_addresses(1);
            check_all_reads;
            @(posedge clk_i);
            clear_model;
            check_all_reads;
            @(negedge clk_i);
            reset_i = 1'b0;
            clear_write_inputs;

            for (address = 0; address < PHYS_REGS;
                    address = address + READ_PORTS) begin
                for (port_index = 0; port_index < READ_PORTS;
                        port_index = port_index + 1) begin
                    selected_address = address + port_index;
                    if (selected_address >= PHYS_REGS) begin
                        selected_address = 0;
                    end
                    read_addr_i[
                        port_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] = selected_address;
                end
                check_all_reads;
            end
        end
    endtask

    task run_random_stress;
        integer cycle_index;
        integer lane;
        integer port_index;
        reg [31:0] random_bits;
        begin
            reset_dut;
            for (cycle_index = 0; cycle_index < 500;
                    cycle_index = cycle_index + 1) begin
                @(negedge clk_i);
                for (port_index = 0; port_index < READ_PORTS;
                        port_index = port_index + 1) begin
                    random_bits = $random(seed);
                    read_addr_i[
                        port_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] =
                        random_bits % ADDRESS_CAPACITY;
                end
                for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                    random_bits = $random(seed);
                    write_valid_i[lane] = random_bits[0];
                    random_bits = $random(seed);
                    write_addr_i[
                        lane*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] =
                        random_bits % ADDRESS_CAPACITY;
                    random_bits = $random(seed);
                    write_data_i[lane*32 +: 32] =
                        random_bits ^ (cycle_index << lane);
                end
                check_all_reads;
                @(posedge clk_i);
                apply_model_writes;
                check_all_reads;
            end
            @(negedge clk_i);
            clear_write_inputs;
            check_all_reads;
        end
    endtask

    initial begin
        reset_i = 1'b0;
        read_addr_i = {(READ_PORTS*PHYS_REG_ADDR_WIDTH){1'b0}};
        write_valid_i = {BE_WIDTH{1'b0}};
        write_addr_i = {(BE_WIDTH*PHYS_REG_ADDR_WIDTH){1'b0}};
        write_data_i = {(BE_WIDTH*32){1'b0}};
        test_count = 0;
        error_count = 0;
        seed = 32'h50524631 ^ PHYS_REGS ^ BE_WIDTH;
        clear_model;

        test_posedge_update_and_bypass;
        test_independent_ports;
        test_write_collision;
        test_zero_register;
        test_out_of_range_address;
        run_random_stress;
        test_reset_priority_and_full_clear;

        if (error_count != 0) begin
            $display("FAIL rv32_physical_register_file_tb phys=%0d be=%0d tests=%0d errors=%0d",
                PHYS_REGS, BE_WIDTH, test_count, error_count);
            $finish(1);
        end
        $display("PASS rv32_physical_register_file_tb phys=%0d be=%0d tests=%0d",
            PHYS_REGS, BE_WIDTH, test_count);
        $finish(0);
    end

endmodule
