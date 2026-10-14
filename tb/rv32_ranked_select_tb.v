`timescale 1ns/1ps
module rv32_ranked_select_tb;
    parameter ENTRIES = 8;
    parameter PORTS = 4;
    parameter SLOT_WIDTH = 3;
    localparam AGE_WIDTH = 5;
    localparam DATA_WIDTH = 17;
    reg enable;
    reg [ENTRIES-1:0] valid;
    reg [ENTRIES*AGE_WIDTH-1:0] age;
    reg [ENTRIES*DATA_WIDTH-1:0] data;
    reg [PORTS-1:0] locked;
    reg [PORTS*SLOT_WIDTH-1:0] locked_slot;
    wire [PORTS-1:0] actual_valid;
    wire [PORTS*SLOT_WIDTH-1:0] actual_slot;
    wire [PORTS*ENTRIES-1:0] actual_mask;
    wire [PORTS*DATA_WIDTH-1:0] actual_data;
    reg [PORTS-1:0] expected_valid;
    reg [PORTS*SLOT_WIDTH-1:0] expected_slot;
    reg [PORTS*ENTRIES-1:0] expected_mask;
    reg [PORTS*DATA_WIDTH-1:0] expected_data;
    reg [ENTRIES-1:0] used;
    integer seed, trial, entry_index, port_index, winner, random_value;
    rv32_ranked_select #(.ENTRIES(ENTRIES), .PORTS(PORTS), .SLOT_WIDTH(SLOT_WIDTH),
        .AGE_WIDTH(AGE_WIDTH), .DATA_WIDTH(DATA_WIDTH)) dut (
        .enable_i(enable), .valid_i(valid), .age_i(age), .data_i(data),
        .locked_i(locked), .locked_slot_i(locked_slot), .valid_o(actual_valid),
        .slot_o(actual_slot), .mask_o(actual_mask), .data_o(actual_data));
    initial begin
        seed = 730021 + ENTRIES*101 + PORTS;
        for (trial = 0; trial < 1000; trial = trial + 1) begin
            random_value = $random(seed);
            enable = (random_value & 3) != 0;
            valid = $random(seed);
            for (entry_index = 0; entry_index < ENTRIES; entry_index = entry_index + 1) begin
                random_value = $random(seed) & 32'h7fffffff;
                age[entry_index*AGE_WIDTH +: AGE_WIDTH] = random_value % 8;
                data[entry_index*DATA_WIDTH +: DATA_WIDTH] = $random(seed);
            end
            used = {ENTRIES{1'b0}};
            for (port_index = 0; port_index < PORTS; port_index = port_index + 1) begin
                random_value = $random(seed);
                locked[port_index] = (random_value & 3) == 0;
                random_value = $random(seed) & 32'h7fffffff;
                locked_slot[port_index*SLOT_WIDTH +: SLOT_WIDTH] = random_value % ENTRIES;
                if (locked[port_index])
                    used[locked_slot[port_index*SLOT_WIDTH +: SLOT_WIDTH]] = 1'b1;
            end
            expected_valid = {PORTS{1'b0}};
            expected_slot = {(PORTS*SLOT_WIDTH){1'b0}};
            expected_mask = {(PORTS*ENTRIES){1'b0}};
            expected_data = {(PORTS*DATA_WIDTH){1'b0}};
            if (enable) begin
                for (port_index = 0; port_index < PORTS; port_index = port_index + 1) begin
                    winner = -1;
                    if (locked[port_index]) begin
                        winner = locked_slot[port_index*SLOT_WIDTH +: SLOT_WIDTH];
                    end else begin
                        for (entry_index = 0; entry_index < ENTRIES; entry_index = entry_index + 1)
                            if (valid[entry_index] && !used[entry_index] &&
                                    ((winner < 0) ||
                                     (age[entry_index*AGE_WIDTH +: AGE_WIDTH] <
                                      age[winner*AGE_WIDTH +: AGE_WIDTH])))
                                winner = entry_index;
                    end
                    if (winner >= 0) begin
                        used[winner] = 1'b1;
                        expected_valid[port_index] = 1'b1;
                        expected_slot[port_index*SLOT_WIDTH +: SLOT_WIDTH] = winner;
                        expected_mask[port_index*ENTRIES+winner] = 1'b1;
                        expected_data[port_index*DATA_WIDTH +: DATA_WIDTH] = data[winner*DATA_WIDTH +: DATA_WIDTH];
                    end
                end
            end
            #1;
            if ({actual_valid, actual_slot, actual_mask, actual_data} !==
                    {expected_valid, expected_slot, expected_mask, expected_data}) begin
                $display("FAIL ranked_select ENTRIES=%0d PORTS=%0d trial=%0d", ENTRIES, PORTS, trial);
                $finish(1);
            end
        end
        $display("PASS ranked_select ENTRIES=%0d PORTS=%0d trials=1000", ENTRIES, PORTS);
        $finish;
    end
endmodule
