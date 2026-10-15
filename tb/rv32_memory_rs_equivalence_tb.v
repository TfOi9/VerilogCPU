`timescale 1ns/1ps

module rv32_memory_rs_equivalence_tb;
    parameter SEED = 1;
    parameter CYCLES = 3000;
    parameter IS_STORE = 0;
    parameter BE_WIDTH = 1;
    parameter RS_ENTRIES = 8;
    parameter RS_INDEX_WIDTH = 3;
    parameter ROB_INDEX_WIDTH = 5;
    localparam ROB_TAG_WIDTH = ROB_INDEX_WIDTH + 2;
    localparam PHYS_REG_ADDR_WIDTH = 6;
    localparam LSQ_TAG_WIDTH = 5;

    reg clk_i;
    reg reset_i;
    reg flush_i;
    reg recover_i;
    reg [BE_WIDTH-1:0] dispatch_valid_i;
    reg dispatch_fire_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] dispatch_rob_tag_i;
    reg [(BE_WIDTH*LSQ_TAG_WIDTH)-1:0] dispatch_lsq_tag_i;
    reg [(BE_WIDTH*32)-1:0] dispatch_immediate_i;
    reg [BE_WIDTH-1:0] dispatch_base_ready_i;
    reg [(BE_WIDTH*32)-1:0] dispatch_base_value_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] dispatch_base_phys_i;
    reg [BE_WIDTH-1:0] dispatch_data_ready_i;
    reg [(BE_WIDTH*32)-1:0] dispatch_data_value_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] dispatch_data_phys_i;
    wire dispatch_ready_o;
    wire [RS_INDEX_WIDTH:0] occupancy_o;
    reg [BE_WIDTH-1:0] broadcast_valid_i;
    reg [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0] broadcast_phys_i;
    reg [(BE_WIDTH*32)-1:0] broadcast_value_i;
    reg [ROB_INDEX_WIDTH-1:0] rob_head_index_i;
    reg [BE_WIDTH-1:0] rollback_valid_i;
    reg [(BE_WIDTH*ROB_TAG_WIDTH)-1:0] rollback_tag_i;
    wire address_valid_o;
    reg address_ready_i;
    wire [31:0] address_o;
    wire [ROB_TAG_WIDTH-1:0] address_rob_tag_o;
    wire [LSQ_TAG_WIDTH-1:0] address_lsq_tag_o;
    wire data_valid_o;
    reg data_ready_i;
    wire [31:0] data_o;
    wire [ROB_TAG_WIDTH-1:0] data_rob_tag_o;
    wire [LSQ_TAG_WIDTH-1:0] data_lsq_tag_o;
    wire reference_dispatch_ready_o;
    wire [RS_INDEX_WIDTH:0] reference_occupancy_o;
    wire reference_address_valid_o;
    wire [31:0] reference_address_o;
    wire [ROB_TAG_WIDTH-1:0] reference_address_rob_tag_o;
    wire [LSQ_TAG_WIDTH-1:0] reference_address_lsq_tag_o;
    wire reference_data_valid_o;
    wire [31:0] reference_data_o;
    wire [ROB_TAG_WIDTH-1:0] reference_data_rob_tag_o;
    wire [LSQ_TAG_WIDTH-1:0] reference_data_lsq_tag_o;
    integer checks;
    integer lane;

    rv32_memory_reservation_station #(
        .IS_STORE(IS_STORE), .RS_ENTRIES(RS_ENTRIES),
        .RS_INDEX_WIDTH(RS_INDEX_WIDTH), .BE_WIDTH(BE_WIDTH),
        .ROB_ENTRIES(1 << ROB_INDEX_WIDTH), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .recover_i(recover_i),
        .dispatch_valid_i(dispatch_valid_i),
        .dispatch_fire_i(dispatch_fire_i),
        .dispatch_rob_tag_i(dispatch_rob_tag_i),
        .dispatch_lsq_tag_i(dispatch_lsq_tag_i),
        .dispatch_immediate_i(dispatch_immediate_i),
        .dispatch_base_ready_i(dispatch_base_ready_i),
        .dispatch_base_value_i(dispatch_base_value_i),
        .dispatch_base_phys_i(dispatch_base_phys_i),
        .dispatch_data_ready_i(dispatch_data_ready_i),
        .dispatch_data_value_i(dispatch_data_value_i),
        .dispatch_data_phys_i(dispatch_data_phys_i),
        .dispatch_ready_o(dispatch_ready_o),
        .occupancy_o(occupancy_o),
        .broadcast_valid_i(broadcast_valid_i),
        .broadcast_phys_i(broadcast_phys_i),
        .broadcast_value_i(broadcast_value_i),
        .rob_head_index_i(rob_head_index_i),
        .rollback_valid_i(rollback_valid_i),
        .rollback_tag_i(rollback_tag_i),
        .address_valid_o(address_valid_o),
        .address_ready_i(address_ready_i),
        .address_o(address_o),
        .address_rob_tag_o(address_rob_tag_o),
        .address_lsq_tag_o(address_lsq_tag_o),
        .data_valid_o(data_valid_o),
        .data_ready_i(data_ready_i),
        .data_o(data_o),
        .data_rob_tag_o(data_rob_tag_o),
        .data_lsq_tag_o(data_lsq_tag_o)
    );

    rv32_memory_reservation_station_reference #(
        .IS_STORE(IS_STORE), .RS_ENTRIES(RS_ENTRIES),
        .RS_INDEX_WIDTH(RS_INDEX_WIDTH), .BE_WIDTH(BE_WIDTH),
        .ROB_ENTRIES(1 << ROB_INDEX_WIDTH), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) reference (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .recover_i(recover_i),
        .dispatch_valid_i(dispatch_valid_i),
        .dispatch_fire_i(dispatch_fire_i),
        .dispatch_rob_tag_i(dispatch_rob_tag_i),
        .dispatch_lsq_tag_i(dispatch_lsq_tag_i),
        .dispatch_immediate_i(dispatch_immediate_i),
        .dispatch_base_ready_i(dispatch_base_ready_i),
        .dispatch_base_value_i(dispatch_base_value_i),
        .dispatch_base_phys_i(dispatch_base_phys_i),
        .dispatch_data_ready_i(dispatch_data_ready_i),
        .dispatch_data_value_i(dispatch_data_value_i),
        .dispatch_data_phys_i(dispatch_data_phys_i),
        .dispatch_ready_o(reference_dispatch_ready_o),
        .occupancy_o(reference_occupancy_o),
        .broadcast_valid_i(broadcast_valid_i),
        .broadcast_phys_i(broadcast_phys_i),
        .broadcast_value_i(broadcast_value_i),
        .rob_head_index_i(rob_head_index_i),
        .rollback_valid_i(rollback_valid_i),
        .rollback_tag_i(rollback_tag_i),
        .address_valid_o(reference_address_valid_o),
        .address_ready_i(address_ready_i),
        .address_o(reference_address_o),
        .address_rob_tag_o(reference_address_rob_tag_o),
        .address_lsq_tag_o(reference_address_lsq_tag_o),
        .data_valid_o(reference_data_valid_o),
        .data_ready_i(data_ready_i),
        .data_o(reference_data_o),
        .data_rob_tag_o(reference_data_rob_tag_o),
        .data_lsq_tag_o(reference_data_lsq_tag_o)
    );


    integer seed;
    integer cycle;
    integer selected_entry;
    task check_outputs;
        begin
            checks = checks + 1;
            if ({dispatch_ready_o, occupancy_o, address_valid_o, address_o,
                    address_rob_tag_o, address_lsq_tag_o, data_valid_o, data_o,
                    data_rob_tag_o, data_lsq_tag_o} !==
                    {reference_dispatch_ready_o, reference_occupancy_o,
                     reference_address_valid_o, reference_address_o,
                     reference_address_rob_tag_o, reference_address_lsq_tag_o,
                     reference_data_valid_o, reference_data_o,
                     reference_data_rob_tag_o, reference_data_lsq_tag_o}) begin
                $display("FAIL memory RS equivalence cycle=%0d seed=%0d store=%0d width=%0d rob=%0d entries=%0d",
                    cycle, SEED, IS_STORE, BE_WIDTH, 1 << ROB_INDEX_WIDTH, RS_ENTRIES);
                $stop;
            end
        end
    endtask

    initial begin
        seed = SEED; checks = 0; cycle = 0; clk_i = 0; reset_i = 1;
        flush_i = 0; recover_i = 0; dispatch_valid_i = 0; dispatch_fire_i = 0;
        dispatch_rob_tag_i = 0; dispatch_lsq_tag_i = 0; dispatch_immediate_i = 0;
        dispatch_base_ready_i = 0; dispatch_base_value_i = 0; dispatch_base_phys_i = 0;
        dispatch_data_ready_i = 0; dispatch_data_value_i = 0; dispatch_data_phys_i = 0;
        broadcast_valid_i = 0; broadcast_phys_i = 0; broadcast_value_i = 0;
        rob_head_index_i = 0; rollback_valid_i = 0; rollback_tag_i = 0;
        address_ready_i = 0; data_ready_i = 0;
        #5; clk_i = 1; #1; clk_i = 0; reset_i = 0;
        for (cycle = 0; cycle < CYCLES; cycle = cycle + 1) begin
            flush_i = cycle % 137 == 136;
            recover_i = cycle % 19 == 18;
            dispatch_valid_i = $random(seed);
            dispatch_base_ready_i = $random(seed);
            dispatch_data_ready_i = $random(seed);
            broadcast_valid_i = $random(seed);
            rob_head_index_i = $random(seed);
            address_ready_i = $random(seed);
            data_ready_i = $random(seed);
            rollback_valid_i = $random(seed);
            for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                dispatch_rob_tag_i[lane*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] = $random(seed);
                dispatch_lsq_tag_i[lane*LSQ_TAG_WIDTH +: LSQ_TAG_WIDTH] = $random(seed);
                dispatch_immediate_i[lane*32 +: 32] = $random(seed);
                dispatch_base_value_i[lane*32 +: 32] = $random(seed);
                dispatch_data_value_i[lane*32 +: 32] = $random(seed);
                dispatch_base_phys_i[lane*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] = cycle % 8;
                dispatch_data_phys_i[lane*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] = (cycle+lane) % 8;
                broadcast_phys_i[lane*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] = (cycle+lane*3) % 8;
                broadcast_value_i[lane*32 +: 32] = $random(seed);
                selected_entry = (cycle+lane) % RS_ENTRIES;
                rollback_tag_i[lane*ROB_TAG_WIDTH +: ROB_TAG_WIDTH] = dut.rob_tag[selected_entry];
            end
            dispatch_fire_i = 0;
            #1; dispatch_fire_i = dispatch_ready_o;
            #1; check_outputs();
            #3; clk_i = 1; #1; clk_i = 0;
            #1; check_outputs();
        end
        $display("PASS memory RS equivalence checks=%0d cycles=%0d seed=%0d store=%0d width=%0d rob=%0d entries=%0d",
            checks, CYCLES, SEED, IS_STORE, BE_WIDTH, 1 << ROB_INDEX_WIDTH, RS_ENTRIES);
        $finish;
    end
endmodule
