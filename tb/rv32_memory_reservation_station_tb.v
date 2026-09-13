`timescale 1ns/1ps

module rv32_memory_reservation_station_tb;
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
    integer checks;
    integer lane;

    rv32_memory_reservation_station #(
        .IS_STORE(IS_STORE), .RS_ENTRIES(RS_ENTRIES),
        .RS_INDEX_WIDTH(RS_INDEX_WIDTH), .BE_WIDTH(BE_WIDTH),
        .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
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

    task tick;
        begin #5 clk_i = 1; #1; clk_i = 0; #1; end
    endtask

    task check;
        input condition;
        input [255:0] message;
        begin
            checks = checks + 1;
            if (!condition) begin
                $display("FAIL memory RS %0s store=%0d width=%0d",
                    message, IS_STORE, BE_WIDTH);
                $stop;
            end
        end
    endtask

    task clear_inputs;
        begin
            flush_i = 0; recover_i = 0; dispatch_valid_i = 0;
            dispatch_fire_i = 0; dispatch_rob_tag_i = 0;
            dispatch_lsq_tag_i = 0; dispatch_immediate_i = 0;
            dispatch_base_ready_i = 0; dispatch_base_value_i = 0;
            dispatch_base_phys_i = 0; dispatch_data_ready_i = 0;
            dispatch_data_value_i = 0; dispatch_data_phys_i = 0;
            broadcast_valid_i = 0; broadcast_phys_i = 0;
            broadcast_value_i = 0; rob_head_index_i = 0;
            rollback_valid_i = 0; rollback_tag_i = 0;
            address_ready_i = 0; data_ready_i = 0;
        end
    endtask

    initial begin
        clk_i = 0; checks = 0; clear_inputs(); reset_i = 1;
        tick(); reset_i = 0;
        dispatch_valid_i[0] = 1;
        dispatch_fire_i = 1;
        dispatch_rob_tag_i[0 +: ROB_TAG_WIDTH] = 0;
        dispatch_lsq_tag_i[0 +: LSQ_TAG_WIDTH] = 3;
        dispatch_immediate_i[0 +: 32] = 4;
        dispatch_base_phys_i[0 +: PHYS_REG_ADDR_WIDTH] = 5;
        dispatch_data_phys_i[0 +: PHYS_REG_ADDR_WIDTH] = 6;
        #1; check(dispatch_ready_o, "dispatch ready");
        tick(); dispatch_valid_i = 0; dispatch_fire_i = 0;
        check(occupancy_o == 1, "allocated");
        check(!address_valid_o, "base waits");
        broadcast_valid_i[0] = 1;
        broadcast_phys_i[0 +: PHYS_REG_ADDR_WIDTH] = 5;
        broadcast_value_i[0 +: 32] = 32'h100;
        #1; check(address_valid_o && address_o == 32'h104,
            "same cycle base wakeup");
        tick(); broadcast_valid_i = 0;
        repeat (3) begin
            check(address_valid_o && address_o == 32'h104,
                "address held on backpressure");
            tick();
        end
        if (IS_STORE) begin
            check(!data_valid_o, "store data waits");
            broadcast_valid_i[0] = 1;
            broadcast_phys_i[0 +: PHYS_REG_ADDR_WIDTH] = 6;
            broadcast_value_i[0 +: 32] = 32'hdeadbeef;
            #1; check(data_valid_o && data_o == 32'hdeadbeef,
                "store data independent wakeup");
            tick(); broadcast_valid_i = 0;
            data_ready_i = 1;
            tick(); data_ready_i = 0;
            check(occupancy_o == 1, "address still pending");
        end else begin
            check(!data_valid_o, "load has no data channel");
        end
        address_ready_i = 1;
        tick(); address_ready_i = 0;
        check(occupancy_o == 0, "entry released");

        dispatch_valid_i[0] = 1;
        dispatch_fire_i = 1;
        dispatch_rob_tag_i[0 +: ROB_TAG_WIDTH] = 1;
        dispatch_base_ready_i[0] = 1;
        dispatch_base_value_i[0 +: 32] = 32'h200;
        dispatch_data_ready_i[0] = 1;
        dispatch_data_value_i[0 +: 32] = 32'h1234;
        tick(); dispatch_valid_i = 0; dispatch_fire_i = 0;
        recover_i = 1; rollback_valid_i[0] = 1;
        rollback_tag_i[0 +: ROB_TAG_WIDTH] = 1;
        tick(); recover_i = 0; rollback_valid_i = 0;
        check(occupancy_o == 0, "rollback removes entry");

        if (BE_WIDTH > 1) begin
            clear_inputs();
            dispatch_fire_i = 1;
            for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
                dispatch_valid_i[lane] = 1;
                dispatch_rob_tag_i[lane*ROB_TAG_WIDTH +:
                    ROB_TAG_WIDTH] = lane;
                dispatch_lsq_tag_i[lane*LSQ_TAG_WIDTH +:
                    LSQ_TAG_WIDTH] = lane;
                dispatch_base_ready_i[lane] = 1;
                dispatch_data_ready_i[lane] = 1;
            end
            #1; check(dispatch_ready_o, "wide ready");
            tick(); dispatch_fire_i = 0; dispatch_valid_i = 0;
            check(occupancy_o == BE_WIDTH, "wide allocation");
        end
        $display("PASS rv32_memory_reservation_station_tb store=%0d width=%0d checks=%0d",
            IS_STORE, BE_WIDTH, checks);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL memory RS watchdog");
        $stop;
    end
endmodule
