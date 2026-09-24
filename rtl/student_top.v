`timescale 1ns/1ps

module student_top #(
    parameter FE_WIDTH = 1,
    parameter BE_WIDTH = 1,
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter ROB_ENTRIES = 32,
    parameter ROB_INDEX_WIDTH = 5,
    parameter ROB_TAG_WIDTH = 7,
    parameter integer ICACHE_SIZE_BYTES = 1024,
    parameter integer ICACHE_NUM_SETS = 64,
    parameter integer ICACHE_NUM_WAYS = 1,
    parameter integer DCACHE_SIZE_BYTES = 4096,
    parameter integer DCACHE_NUM_SETS = 256,
    parameter integer DCACHE_NUM_WAYS = 1
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
    wire icache_flush;
    wire core_i_request_valid;
    wire core_i_request_ready;
    wire [31:0] core_i_request_pc;
    wire core_i_response_valid;
    wire core_i_response_ready;
    wire [31:0] core_i_response_pc;
    wire [127:0] core_i_response_line;
    wire core_i_response_error;

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
    reg lsu_mmio_inflight;

    assign dcache_request_valid = core_d_request_valid &&
        !core_d_request_mmio;
    assign mmio_request_valid = core_d_request_valid &&
        core_d_request_mmio;
    assign core_d_request_ready = core_d_request_mmio ?
        mmio_request_ready : dcache_request_ready;
    assign core_d_response_valid = lsu_mmio_inflight ?
        mmio_response_valid : dcache_response_valid;
    assign core_d_response_read_data = lsu_mmio_inflight ?
        32'd0 : dcache_response_read_data;
    assign core_d_response_error = lsu_mmio_inflight ?
        mmio_response_error : dcache_response_error;
    assign mmio_response_ready = lsu_mmio_inflight &&
        core_d_response_ready;
    assign dcache_response_ready = !lsu_mmio_inflight &&
        core_d_response_ready;

    always @(posedge clock) begin
        if (reset) begin
            lsu_mmio_inflight <= 1'b0;
        end else begin
            if (core_d_request_valid && core_d_request_ready)
                lsu_mmio_inflight <= core_d_request_mmio;
            if (core_d_response_valid && core_d_response_ready)
                lsu_mmio_inflight <= 1'b0;
        end
    end

    rv32_cpu_core #(
        .FE_WIDTH(FE_WIDTH), .BE_WIDTH(BE_WIDTH),
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
        .CACHE_SIZE_BYTES(DCACHE_SIZE_BYTES),
        .NUM_SETS(DCACHE_NUM_SETS), .NUM_WAYS(DCACHE_NUM_WAYS)
    ) dcache (
        .clk_i(clock), .reset_i(reset),
        .request_valid_i(dcache_request_valid),
        .request_ready_o(dcache_request_ready),
        .request_write_i(core_d_request_write),
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
        .memory_request_address_o(d_memory_request_address),
        .memory_request_write_data_o(d_memory_request_write_data),
        .memory_request_byte_enable_o(d_memory_request_byte_enable),
        .memory_response_valid_i(d_memory_response_valid),
        .memory_response_ready_o(d_memory_response_ready),
        .memory_response_read_data_i(d_memory_response_read_data),
        .memory_response_error_i(d_memory_response_error),
        .hit_event_o(), .miss_event_o()
    );

    rv32_l1_cache_axi_bridge bridge (
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
        .d_request_address_i(d_memory_request_address),
        .d_request_write_data_i(d_memory_request_write_data),
        .d_request_byte_enable_i(d_memory_request_byte_enable),
        .d_response_valid_o(d_memory_response_valid),
        .d_response_ready_i(d_memory_response_ready),
        .d_response_read_data_o(d_memory_response_read_data),
        .d_response_error_o(d_memory_response_error),
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
