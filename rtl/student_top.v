`timescale 1ns/1ps

module student_top #(
    parameter FE_WIDTH = 2,
    parameter BE_WIDTH = 2,
    parameter RECOVERY_WIDTH = 4,
    parameter POSTED_STORES = 1,
    parameter RESULT_FALLTHROUGH = 1,
    parameter STORE_HINTS = 16,
    parameter STORE_DIRECTORY_ENTRIES = 128,
    parameter LATE_STORE_CONFIRM = 1,
    parameter NONBLOCKING_DCACHE = 1,
    parameter DCACHE_MSHR_ENTRIES = 2,
    parameter FAST_MEMORY_RETURNS = NONBLOCKING_DCACHE,
    parameter PARALLEL_BRIDGE = NONBLOCKING_DCACHE,
    parameter HIT_UNDER_MISS = NONBLOCKING_DCACHE,
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = address_width_for_count(PHYS_REGS),
    parameter ROB_ENTRIES = 32,
    parameter ROB_INDEX_WIDTH = address_width_for_count(ROB_ENTRIES),
    parameter ROB_TAG_WIDTH = ROB_INDEX_WIDTH + 2,
    parameter integer ICACHE_SIZE_BYTES = 1024,
    parameter integer ICACHE_NUM_SETS = 64,
    parameter integer ICACHE_NUM_WAYS = 1,
    parameter integer DCACHE_SIZE_BYTES = 16384,
    parameter integer DCACHE_NUM_SETS = 512,
    parameter integer DCACHE_NUM_WAYS = 2
) (
    input  wire clock,
    input  wire reset,
    output wire [31:0] araddr,
    output wire arvalid,
    input  wire arready,
    input  wire [31:0] rdata,
    input  wire [1:0] rresp,
    input  wire rvalid,
    output wire rready,
    output wire [31:0] awaddr,
    output wire awvalid,
    input  wire awready,
    output wire [31:0] wdata,
    output wire [3:0] wstrb,
    output wire wvalid,
    input  wire wready,
    input  wire [1:0] bresp,
    input  wire bvalid,
    output wire bready
);
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
            if (address_width_for_count < 1)
                address_width_for_count = 1;
        end
    endfunction

    wire icache_flush;
    wire core_i_request_valid;
    wire core_i_request_ready;
    wire [31:0] core_i_request_pc;
    wire core_i_response_valid;
    wire core_i_response_ready;
    wire [31:0] core_i_response_pc;
    wire [127:0] core_i_response_line;
    wire core_i_response_error;

    wire [ROB_TAG_WIDTH-1:0] core_d_request_rob_tag;
    wire [ROB_TAG_WIDTH-1:0] core_d_response_rob_tag;
    wire [ROB_TAG_WIDTH-1:0] dcache_response_rob_tag;
    wire dcache_store_confirm_valid;
    wire [1:0] dcache_store_confirm_id;
    wire [ROB_TAG_WIDTH-1:0] dcache_store_confirm_rob_tag;
    reg [ROB_TAG_WIDTH-1:0] mmio_response_rob_tag;
    wire [1:0] core_d_request_id;
    wire [1:0] core_d_response_id;
    wire [1:0] dcache_response_id;
    reg [1:0] mmio_response_id;
    wire d_memory_response_write;
    wire d_memory_request_id;
    wire d_memory_response_id;
    wire core_d_request_valid;
    wire core_d_request_ready;
    wire core_d_request_write;
    wire [31:0] core_d_request_address;
    wire [31:0] core_d_request_write_data;
    wire [3:0] core_d_request_byte_enable;
    wire core_d_request_mmio;
    wire core_d_response_valid;
    wire core_d_response_ready;
    wire [31:0] core_d_response_read_data;
    wire core_d_response_error;

    wire dcache_request_valid;
    wire dcache_request_ready;
    wire dcache_request_irrevocable;
    wire dcache_response_valid;
    wire dcache_response_ready;
    wire [31:0] dcache_response_read_data;
    wire dcache_response_error;

    wire i_memory_request_valid;
    wire i_memory_request_ready;
    wire [31:0] i_memory_request_address;
    wire i_memory_response_valid;
    wire i_memory_response_ready;
    wire [127:0] i_memory_response_read_data;
    wire i_memory_response_error;

    wire d_memory_request_valid;
    wire d_memory_request_ready;
    wire d_memory_request_write;
    wire [31:0] d_memory_request_address;
    wire [127:0] d_memory_request_write_data;
    wire [15:0] d_memory_request_byte_enable;
    wire d_memory_response_valid;
    wire d_memory_response_ready;
    wire [127:0] d_memory_response_read_data;
    wire d_memory_response_error;

    wire mmio_request_valid;
    wire mmio_request_ready;
    wire mmio_response_valid;
    wire mmio_response_ready;
    wire mmio_response_error;

    assign dcache_request_valid = core_d_request_valid &&
        !core_d_request_mmio;
    assign mmio_request_valid = core_d_request_valid &&
        core_d_request_mmio;
    assign core_d_request_ready = core_d_request_mmio ?
        mmio_request_ready : dcache_request_ready;
    assign core_d_response_valid = dcache_response_valid;
    assign core_d_response_read_data = dcache_response_read_data;
    assign core_d_response_error = dcache_response_error;
    assign dcache_response_ready = core_d_response_ready;
    assign core_d_response_rob_tag = dcache_response_rob_tag;
    assign core_d_response_id = dcache_response_id;
    always @(posedge clock) begin
        if (reset) begin mmio_response_id <= 0; mmio_response_rob_tag <= 0; end
        else if (mmio_request_valid && mmio_request_ready) begin
            mmio_response_id <= core_d_request_id;
            mmio_response_rob_tag <= core_d_request_rob_tag;
        end
    end

    rv32_cpu_core #(
        .LATE_STORE_CONFIRM(LATE_STORE_CONFIRM),
        .FE_WIDTH(FE_WIDTH), .BE_WIDTH(BE_WIDTH), .RECOVERY_WIDTH(RECOVERY_WIDTH), .OUT_OF_ORDER_MEMORY(NONBLOCKING_DCACHE), .ECHO_MEMORY_ROB_TAG(NONBLOCKING_DCACHE), .FAST_MEMORY_RETURNS(FAST_MEMORY_RETURNS), .POSTED_STORES(POSTED_STORES),
        .RESULT_FALLTHROUGH(RESULT_FALLTHROUGH),
        .PHYS_REGS(PHYS_REGS),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ROB_ENTRIES(ROB_ENTRIES), .ROB_INDEX_WIDTH(ROB_INDEX_WIDTH),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) core (
        .clk_i(clock), .reset_i(reset), .icache_flush_o(icache_flush),
        .icache_request_valid_o(core_i_request_valid),
        .icache_request_ready_i(core_i_request_ready),
        .icache_request_pc_o(core_i_request_pc),
        .icache_response_valid_i(core_i_response_valid),
        .icache_response_ready_o(core_i_response_ready),
        .icache_response_pc_i(core_i_response_pc),
        .icache_response_line_i(core_i_response_line),
        .icache_response_error_i(core_i_response_error),
        .dcache_request_valid_o(core_d_request_valid),
        .dcache_request_ready_i(core_d_request_ready),
        .dcache_request_id_o(core_d_request_id),
        .dcache_response_id_i(core_d_response_id),
        .dcache_request_rob_tag_o(core_d_request_rob_tag),
        .dcache_response_rob_tag_i(core_d_response_rob_tag),
        .dcache_request_irrevocable_i(!core_d_request_mmio && dcache_request_irrevocable),
        .dcache_store_confirm_valid_i(dcache_store_confirm_valid),
        .dcache_store_confirm_id_i(dcache_store_confirm_id),
        .dcache_store_confirm_rob_tag_i(dcache_store_confirm_rob_tag),
        .dcache_request_write_o(core_d_request_write),
        .dcache_request_address_o(core_d_request_address),
        .dcache_request_write_data_o(core_d_request_write_data),
        .dcache_request_byte_enable_o(core_d_request_byte_enable),
        .dcache_request_mmio_o(core_d_request_mmio),
        .dcache_response_valid_i(core_d_response_valid),
        .dcache_response_ready_o(core_d_response_ready),
        .dcache_response_read_data_i(core_d_response_read_data),
        .dcache_response_error_i(core_d_response_error)
    );

    rv32_l1_instruction_cache #(
        .CACHE_SIZE_BYTES(ICACHE_SIZE_BYTES),
        .NUM_SETS(ICACHE_NUM_SETS), .NUM_WAYS(ICACHE_NUM_WAYS)
    ) icache (
        .clk_i(clock), .reset_i(reset), .flush_i(icache_flush),
        .request_valid_i(core_i_request_valid),
        .request_ready_o(core_i_request_ready),
        .request_pc_i(core_i_request_pc),
        .response_valid_o(core_i_response_valid),
        .response_ready_i(core_i_response_ready),
        .response_pc_o(core_i_response_pc),
        .response_line_o(core_i_response_line),
        .response_error_o(core_i_response_error),
        .memory_request_valid_o(i_memory_request_valid),
        .memory_request_ready_i(i_memory_request_ready),
        .memory_request_address_o(i_memory_request_address),
        .memory_response_valid_i(i_memory_response_valid),
        .memory_response_ready_o(i_memory_response_ready),
        .memory_response_read_data_i(i_memory_response_read_data),
        .memory_response_error_i(i_memory_response_error),
        .hit_event_o(), .miss_event_o()
    );

    rv32_l1_data_cache #(
        .LATE_STORE_CONFIRM((LATE_STORE_CONFIRM && POSTED_STORES && NONBLOCKING_DCACHE) ? 1 : 0),
        .AUX_RETURNS(1),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH),
        .CACHE_SIZE_BYTES(DCACHE_SIZE_BYTES),
        .NUM_SETS(DCACHE_NUM_SETS), .NUM_WAYS(DCACHE_NUM_WAYS),
        .STORE_HINTS(STORE_HINTS), .STORE_DIRECTORY_ENTRIES(STORE_DIRECTORY_ENTRIES),
        .NONBLOCKING(NONBLOCKING_DCACHE), .HIT_UNDER_MISS(HIT_UNDER_MISS),
        .MSHR_ENTRIES((NONBLOCKING_DCACHE && HIT_UNDER_MISS) ? DCACHE_MSHR_ENTRIES : 1)
    ) dcache (
        .clk_i(clock), .reset_i(reset),
        .request_valid_i(dcache_request_valid),
        .request_ready_o(dcache_request_ready),
        .request_irrevocable_o(dcache_request_irrevocable),
        .store_confirm_valid_o(dcache_store_confirm_valid),
        .store_confirm_id_o(dcache_store_confirm_id),
        .store_confirm_rob_tag_o(dcache_store_confirm_rob_tag),
        .aux_response_valid_i(mmio_response_valid),
        .aux_response_ready_o(mmio_response_ready),
        .aux_response_id_i(mmio_response_id),
        .aux_response_rob_tag_i(mmio_response_rob_tag),
        .aux_response_error_i(mmio_response_error),
        .request_write_i(core_d_request_write),
        .request_id_i(core_d_request_id), .response_id_o(dcache_response_id),
        .request_rob_tag_i(core_d_request_rob_tag), .response_rob_tag_o(dcache_response_rob_tag),
        .request_address_i(core_d_request_address),
        .request_write_data_i(core_d_request_write_data),
        .request_byte_enable_i(core_d_request_byte_enable),
        .response_valid_o(dcache_response_valid),
        .response_ready_i(dcache_response_ready),
        .response_read_data_o(dcache_response_read_data),
        .response_error_o(dcache_response_error),
        .memory_request_valid_o(d_memory_request_valid),
        .memory_request_ready_i(d_memory_request_ready),
        .memory_request_write_o(d_memory_request_write),
        .memory_request_id_o(d_memory_request_id),
        .memory_request_address_o(d_memory_request_address),
        .memory_request_write_data_o(d_memory_request_write_data),
        .memory_request_byte_enable_o(d_memory_request_byte_enable),
        .memory_response_valid_i(d_memory_response_valid),
        .memory_response_ready_o(d_memory_response_ready),
        .memory_response_read_data_i(d_memory_response_read_data),
        .memory_response_error_i(d_memory_response_error),
        .memory_response_write_i(d_memory_response_write),
        .memory_response_id_i(d_memory_response_id),
        .hit_event_o(), .miss_event_o()
    );

    rv32_l1_cache_axi_bridge #(.PARALLEL(PARALLEL_BRIDGE),
        .D_TAGGED((DCACHE_MSHR_ENTRIES == 2 && NONBLOCKING_DCACHE && HIT_UNDER_MISS) ? 1 : 0)) bridge (
        .clk_i(clock), .reset_i(reset),
        .i_request_valid_i(i_memory_request_valid),
        .i_request_ready_o(i_memory_request_ready),
        .i_request_address_i(i_memory_request_address),
        .i_response_valid_o(i_memory_response_valid),
        .i_response_ready_i(i_memory_response_ready),
        .i_response_read_data_o(i_memory_response_read_data),
        .i_response_error_o(i_memory_response_error),
        .d_request_valid_i(d_memory_request_valid),
        .d_request_ready_o(d_memory_request_ready),
        .d_request_write_i(d_memory_request_write),
        .d_request_id_i(d_memory_request_id),
        .d_request_address_i(d_memory_request_address),
        .d_request_write_data_i(d_memory_request_write_data),
        .d_request_byte_enable_i(d_memory_request_byte_enable),
        .d_response_valid_o(d_memory_response_valid),
        .d_response_ready_i(d_memory_response_ready),
        .d_response_read_data_o(d_memory_response_read_data),
        .d_response_error_o(d_memory_response_error),
        .d_response_write_o(d_memory_response_write),
        .d_response_id_o(d_memory_response_id),
        .m_request_valid_i(mmio_request_valid),
        .m_request_ready_o(mmio_request_ready),
        .m_request_address_i(core_d_request_address),
        .m_request_write_data_i(core_d_request_write_data),
        .m_request_byte_enable_i(core_d_request_byte_enable),
        .m_response_valid_o(mmio_response_valid),
        .m_response_ready_i(mmio_response_ready),
        .m_response_error_o(mmio_response_error),
        .araddr_o(araddr), .arvalid_o(arvalid), .arready_i(arready),
        .rdata_i(rdata), .rresp_i(rresp), .rvalid_i(rvalid),
        .rready_o(rready), .awaddr_o(awaddr), .awvalid_o(awvalid),
        .awready_i(awready), .wdata_o(wdata), .wstrb_o(wstrb),
        .wvalid_o(wvalid), .wready_i(wready), .bresp_i(bresp),
        .bvalid_i(bvalid), .bready_o(bready)
    );
endmodule
