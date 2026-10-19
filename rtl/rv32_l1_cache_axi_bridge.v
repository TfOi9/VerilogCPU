`timescale 1ns/1ps

module rv32_l1_cache_arbiter #(
    parameter PARALLEL = 0,
    parameter D_TAGGED = 0,
    parameter D_ID_WIDTH = 1,
    parameter READ_ENTRIES = 2
) (
    input  wire clk_i,
    input  wire reset_i,
    input  wire i_request_valid_i,
    output wire i_request_ready_o,
    input  wire [31:0] i_request_address_i,
    output wire i_response_valid_o,
    input  wire i_response_ready_i,
    output wire [127:0] i_response_read_data_o,
    output wire i_response_error_o,
    input  wire d_request_valid_i,
    output wire d_request_ready_o,
    input  wire d_request_write_i,
    input wire [D_ID_WIDTH-1:0] d_request_id_i,
    input  wire [31:0] d_request_address_i,
    input  wire [127:0] d_request_write_data_i,
    input  wire [15:0] d_request_byte_enable_i,
    output wire d_response_valid_o,
    input  wire d_response_ready_i,
    output wire [127:0] d_response_read_data_o,
    output wire d_response_error_o,
    output wire d_response_write_o,
    output wire [D_ID_WIDTH-1:0] d_response_id_o,
    input  wire m_request_valid_i,
    output wire m_request_ready_o,
    input  wire [31:0] m_request_address_i,
    input  wire [31:0] m_request_write_data_i,
    input  wire [3:0] m_request_byte_enable_i,
    output wire m_response_valid_o,
    input  wire m_response_ready_i,
    output wire m_response_error_o,
    output wire memory_request_valid_o,
    input  wire memory_request_ready_i,
    output wire memory_request_write_o,
    output wire [31:0] memory_request_address_o,
    output wire [127:0] memory_request_write_data_o,
    output wire [15:0] memory_request_byte_enable_o,
    output wire memory_request_word_o,
    input  wire memory_response_valid_i,
    output wire memory_response_ready_o,
    input  wire [127:0] memory_response_read_data_i,
    input  wire memory_response_error_i,
    input wire memory_response_write_i
);
    reg busy;
    localparam OWNER_I = 2'd0;
    localparam OWNER_D = 2'd1;
    localparam OWNER_M = 2'd2;

    reg [1:0] owner;
    integer read_reset;
    reg [D_ID_WIDTH-1:0] owner_id;
    reg grant_locked;
    reg [1:0] grant_owner;
    wire [1:0] selected_owner;
    wire selected_valid;
    localparam READ_INDEX_WIDTH = $clog2(READ_ENTRIES);
    reg [1:0] read_owner [0:READ_ENTRIES-1];
    reg [D_ID_WIDTH-1:0] read_id [0:READ_ENTRIES-1];
    reg [READ_INDEX_WIDTH-1:0] read_head;
    reg [READ_INDEX_WIDTH-1:0] read_tail;
    reg [READ_INDEX_WIDTH:0] read_count;
    reg write_busy;
    reg [1:0] write_owner;
    reg [D_ID_WIDTH-1:0] write_id;
    wire request_fire = memory_request_valid_o && memory_request_ready_i;
    wire response_fire = memory_response_valid_i && memory_response_ready_o;
    wire parallel_busy = read_count != 0 || write_busy;
    wire [1:0] response_owner = PARALLEL != 0 ?
        (memory_response_write_i ? write_owner : read_owner[read_head]) : owner;
    wire response_owned = PARALLEL != 0 ?
        (memory_response_write_i ? write_busy : read_count != 0) : busy;
    wire request_available = PARALLEL != 0 ?
        (selected_owner == OWNER_M ? !parallel_busy :
            (memory_request_write_o ? !write_busy : read_count < READ_ENTRIES)) : !busy;


    assign selected_owner = grant_locked ? grant_owner :
        (m_request_valid_i ? OWNER_M :
         (d_request_valid_i ? OWNER_D : OWNER_I));
    assign selected_valid = selected_owner == OWNER_M ? m_request_valid_i :
        (selected_owner == OWNER_D ? d_request_valid_i : i_request_valid_i);

    assign memory_request_valid_o = !reset_i && request_available && selected_valid;
    assign memory_request_write_o = selected_owner == OWNER_I ? 1'b0 :
        (selected_owner == OWNER_D ? d_request_write_i : 1'b1);
    assign memory_request_address_o = selected_owner == OWNER_I ?
        i_request_address_i : (selected_owner == OWNER_D ?
        d_request_address_i : m_request_address_i);
    assign memory_request_write_data_o = selected_owner == OWNER_D ?
        d_request_write_data_i : (selected_owner == OWNER_M ?
        {96'd0, m_request_write_data_i} : 128'd0);
    assign memory_request_byte_enable_o = selected_owner == OWNER_D ?
        d_request_byte_enable_i : (selected_owner == OWNER_M ?
        {12'd0, m_request_byte_enable_i} : 16'd0);
    assign memory_request_word_o = selected_owner == OWNER_M;
    assign i_request_ready_o = !reset_i && request_available &&
        selected_owner == OWNER_I &&
        selected_valid && memory_request_ready_i;
    assign d_request_ready_o = !reset_i && request_available &&
        selected_owner == OWNER_D &&
        selected_valid && memory_request_ready_i;
    assign m_request_ready_o = !reset_i && request_available &&
        selected_owner == OWNER_M &&
        selected_valid && memory_request_ready_i;

    assign i_response_valid_o = !reset_i && response_owned && response_owner == OWNER_I &&
        memory_response_valid_i;
    assign d_response_valid_o = !reset_i && response_owned && response_owner == OWNER_D &&
        memory_response_valid_i;
    assign m_response_valid_o = !reset_i && response_owned && response_owner == OWNER_M &&
        memory_response_valid_i;
    assign i_response_read_data_o = memory_response_read_data_i;
    assign d_response_read_data_o = memory_response_read_data_i;
    assign i_response_error_o = memory_response_error_i;
    assign d_response_error_o = memory_response_error_i;
    assign m_response_error_o = memory_response_error_i;
    assign d_response_write_o = memory_response_write_i;
    assign d_response_id_o = D_TAGGED != 0 ? (PARALLEL != 0 ?
        (memory_response_write_i ? write_id : read_id[read_head]) : owner_id) : 0;
    assign memory_response_ready_o = !reset_i && response_owned &&
        (response_owner == OWNER_I ? i_response_ready_i :
         (response_owner == OWNER_D ? d_response_ready_i : m_response_ready_i));

    always @(posedge clk_i) begin
        if (reset_i) begin
            read_head <= {READ_INDEX_WIDTH{1'b0}};
            read_tail <= {READ_INDEX_WIDTH{1'b0}};
            read_count <= 0;
            for (read_reset = 0; read_reset < READ_ENTRIES; read_reset = read_reset + 1) begin
                read_owner[read_reset] <= OWNER_I;
                read_id[read_reset] <= 0;
            end
            write_busy <= 1'b0;
            write_owner <= OWNER_D;
            write_id <= 0;
        end else if (PARALLEL != 0) begin
            case ({request_fire && !memory_request_write_o,
                    response_fire && !memory_response_write_i})
                2'b10: read_count <= read_count + 1'b1;
                2'b01: read_count <= read_count - 1'b1;
                default: read_count <= read_count;
            endcase
            if (response_fire && memory_response_write_i)
                write_busy <= 1'b0;
            if (request_fire && memory_request_write_o) begin
                write_busy <= 1'b1;
                write_owner <= selected_owner;
                write_id <= selected_owner == OWNER_D ? d_request_id_i : 0;
            end
            if (request_fire && !memory_request_write_o) begin
                read_owner[read_tail] <= selected_owner;
                read_id[read_tail] <= selected_owner == OWNER_D ? d_request_id_i : 0;
                read_tail <= read_tail + 1'b1;
            end
            if (response_fire && !memory_response_write_i)
                read_head <= read_head + 1'b1;
        end
    end

    always @(posedge clk_i) begin
        if (reset_i) begin
            busy <= 1'b0;
            owner <= OWNER_I;
            owner_id <= 0;
            grant_locked <= 1'b0;
            grant_owner <= OWNER_I;
        end else if (PARALLEL != 0) begin
            if (request_fire) grant_locked <= 1'b0;
            else if (memory_request_valid_o && !grant_locked) begin
                grant_locked <= 1'b1;
                grant_owner <= selected_owner;
            end
        end else if (busy) begin
            if (memory_response_valid_i && memory_response_ready_o)
                busy <= 1'b0;
        end else if (memory_request_valid_o && memory_request_ready_i) begin
            busy <= 1'b1;
            owner <= selected_owner;
            owner_id <= selected_owner == OWNER_D ? d_request_id_i : 0;
            grant_locked <= 1'b0;
        end else if (memory_request_valid_o && !grant_locked) begin
            grant_locked <= 1'b1;
            grant_owner <= selected_owner;
        end
    end
endmodule

module rv32_cache_axi4_lite_adapter (
    input  wire clk_i,
    input  wire reset_i,
    input  wire request_valid_i,
    output wire request_ready_o,
    input  wire request_write_i,
    input  wire [31:0] request_address_i,
    input  wire [127:0] request_write_data_i,
    input  wire [15:0] request_byte_enable_i,
    input  wire request_word_i,
    output wire response_valid_o,
    input  wire response_ready_i,
    output wire [127:0] response_read_data_o,
    output wire response_error_o,
    output wire [31:0] araddr_o,
    output wire arvalid_o,
    input  wire arready_i,
    input  wire [31:0] rdata_i,
    input  wire [1:0] rresp_i,
    input  wire rvalid_i,
    output wire rready_o,
    output wire [31:0] awaddr_o,
    output wire awvalid_o,
    input  wire awready_i,
    output wire [31:0] wdata_o,
    output wire [3:0] wstrb_o,
    output wire wvalid_o,
    input  wire wready_i,
    input  wire [1:0] bresp_i,
    input  wire bvalid_i,
    output wire bready_o
);
    localparam STATE_IDLE = 2'd0;
    localparam STATE_READ = 2'd1;
    localparam STATE_WRITE = 2'd2;
    localparam STATE_RESPONSE = 2'd3;

    reg [1:0] state;
    reg [31:0] line_address;
    reg [127:0] line_write_data;
    reg [15:0] line_write_mask;
    reg [127:0] line_read_data;
    reg response_error;
    reg word_only;
    reg [2:0] ar_count;
    reg [2:0] r_count;
    reg [2:0] aw_count;
    reg [2:0] w_count;
    reg [2:0] b_count;

    wire [2:0] word_count;
    wire ar_fire;
    wire r_fire;
    wire aw_fire;
    wire w_fire;
    wire b_fire;

    assign word_count = word_only ? 3'd1 : 3'd4;
    assign request_ready_o = !reset_i && (state == STATE_IDLE);
    assign response_valid_o = !reset_i && (state == STATE_RESPONSE);
    assign response_read_data_o = response_error ? 128'd0 : line_read_data;
    assign response_error_o = response_error;

    assign araddr_o = line_address + {28'd0, ar_count[1:0], 2'b00};
    assign arvalid_o = !reset_i && (state == STATE_READ) &&
        (ar_count < word_count);
    assign rready_o = !reset_i && (state == STATE_READ) &&
        (r_count < ar_count);
    assign awaddr_o = line_address + {28'd0, aw_count[1:0], 2'b00};
    assign awvalid_o = !reset_i && (state == STATE_WRITE) &&
        (aw_count < word_count);
    assign wdata_o = line_write_data[w_count[1:0]*32 +: 32];
    assign wstrb_o = line_write_mask[w_count[1:0]*4 +: 4];
    assign wvalid_o = !reset_i && (state == STATE_WRITE) &&
        (w_count < word_count);
    assign bready_o = !reset_i && (state == STATE_WRITE) &&
        (b_count < aw_count) && (b_count < w_count);
    assign ar_fire = arvalid_o && arready_i;
    assign r_fire = rvalid_i && rready_o;
    assign aw_fire = awvalid_o && awready_i;
    assign w_fire = wvalid_o && wready_i;
    assign b_fire = bvalid_i && bready_o;

    always @(posedge clk_i) begin
        if (reset_i) begin
            state <= STATE_IDLE;
            line_address <= 32'd0;
            line_write_data <= 128'd0;
            line_write_mask <= 16'd0;
            line_read_data <= 128'd0;
            response_error <= 1'b0;
            word_only <= 1'b0;
            ar_count <= 3'd0;
            r_count <= 3'd0;
            aw_count <= 3'd0;
            w_count <= 3'd0;
            b_count <= 3'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (request_valid_i && request_ready_o) begin
                        line_address <= request_word_i ?
                            {request_address_i[31:2], 2'b00} :
                            {request_address_i[31:4], 4'b0000};
                        line_write_data <= request_write_data_i;
                        line_write_mask <= request_byte_enable_i;
                        line_read_data <= 128'd0;
                        response_error <= 1'b0;
                        word_only <= request_word_i;
                        ar_count <= 3'd0;
                        r_count <= 3'd0;
                        aw_count <= 3'd0;
                        w_count <= 3'd0;
                        b_count <= 3'd0;
                        if (request_write_i)
                            state <= STATE_WRITE;
                        else
                            state <= STATE_READ;
                    end
                end
                STATE_READ: begin
                    if (ar_fire)
                        ar_count <= ar_count + 1'b1;
                    if (r_fire) begin
                        r_count <= r_count + 1'b1;
                        if (rresp_i != 2'b00)
                            response_error <= 1'b1;
                        if (word_only)
                            line_read_data <= {rdata_i, 96'd0};
                        else
                            line_read_data[r_count[1:0]*32 +: 32] <= rdata_i;
                        // Drain the complete line, including after an error.
                        if (r_count + 3'd1 == word_count)
                            state <= STATE_RESPONSE;
                    end
                end
                STATE_WRITE: begin
                    if (aw_fire)
                        aw_count <= aw_count + 1'b1;
                    if (w_fire)
                        w_count <= w_count + 1'b1;
                    if (b_fire) begin
                        b_count <= b_count + 1'b1;
                        if (bresp_i != 2'b00)
                            response_error <= 1'b1;
                        // Keep AW/W independent and retire every response.
                        if (b_count + 3'd1 == word_count)
                            state <= STATE_RESPONSE;
                    end
                end
                STATE_RESPONSE: begin
                    if (response_valid_o && response_ready_i)
                        state <= STATE_IDLE;
                end
                default: state <= STATE_IDLE;
            endcase
        end
    end
endmodule

module rv32_l1_cache_axi_bridge #(
    parameter PARALLEL = 0,
    parameter D_TAGGED = 0,
    parameter D_ID_WIDTH = 1,
    parameter READ_ENTRIES = 2
) (
    input  wire clk_i,
    input  wire reset_i,
    input  wire i_request_valid_i,
    output wire i_request_ready_o,
    input  wire [31:0] i_request_address_i,
    output wire i_response_valid_o,
    input  wire i_response_ready_i,
    output wire [127:0] i_response_read_data_o,
    output wire i_response_error_o,
    input  wire d_request_valid_i,
    output wire d_request_ready_o,
    input  wire d_request_write_i,
    input wire [D_ID_WIDTH-1:0] d_request_id_i,
    input  wire [31:0] d_request_address_i,
    input  wire [127:0] d_request_write_data_i,
    input  wire [15:0] d_request_byte_enable_i,
    output wire d_response_valid_o,
    input  wire d_response_ready_i,
    output wire [127:0] d_response_read_data_o,
    output wire d_response_error_o,
    output wire d_response_write_o,
    output wire [D_ID_WIDTH-1:0] d_response_id_o,
    input  wire m_request_valid_i,
    output wire m_request_ready_o,
    input  wire [31:0] m_request_address_i,
    input  wire [31:0] m_request_write_data_i,
    input  wire [3:0] m_request_byte_enable_i,
    output wire m_response_valid_o,
    input  wire m_response_ready_i,
    output wire m_response_error_o,
    output wire [31:0] araddr_o,
    output wire arvalid_o,
    input  wire arready_i,
    input  wire [31:0] rdata_i,
    input  wire [1:0] rresp_i,
    input  wire rvalid_i,
    output wire rready_o,
    output wire [31:0] awaddr_o,
    output wire awvalid_o,
    input  wire awready_i,
    output wire [31:0] wdata_o,
    output wire [3:0] wstrb_o,
    output wire wvalid_o,
    input  wire wready_i,
    input  wire [1:0] bresp_i,
    input  wire bvalid_i,
    output wire bready_o
);
    wire memory_request_valid;
    wire memory_request_ready;
    wire memory_request_write;
    wire [31:0] memory_request_address;
    wire [127:0] memory_request_write_data;
    wire [15:0] memory_request_byte_enable;
    wire memory_request_word;
    wire memory_response_valid;
    wire memory_response_ready;
    wire [127:0] memory_response_read_data;
    wire memory_response_error;
    wire memory_response_write;

    rv32_l1_cache_arbiter #(.PARALLEL(PARALLEL), .D_TAGGED(D_TAGGED), .D_ID_WIDTH(D_ID_WIDTH), .READ_ENTRIES(READ_ENTRIES)) arbiter (
        .clk_i(clk_i), .reset_i(reset_i),
        .i_request_valid_i(i_request_valid_i),
        .i_request_ready_o(i_request_ready_o),
        .i_request_address_i(i_request_address_i),
        .i_response_valid_o(i_response_valid_o),
        .i_response_ready_i(i_response_ready_i),
        .i_response_read_data_o(i_response_read_data_o),
        .i_response_error_o(i_response_error_o),
        .d_request_valid_i(d_request_valid_i),
        .d_request_ready_o(d_request_ready_o),
        .d_request_write_i(d_request_write_i),
        .d_request_id_i(d_request_id_i),
        .d_request_address_i(d_request_address_i),
        .d_request_write_data_i(d_request_write_data_i),
        .d_request_byte_enable_i(d_request_byte_enable_i),
        .d_response_valid_o(d_response_valid_o),
        .d_response_ready_i(d_response_ready_i),
        .d_response_read_data_o(d_response_read_data_o),
        .d_response_error_o(d_response_error_o),
        .d_response_write_o(d_response_write_o),
        .d_response_id_o(d_response_id_o),
        .m_request_valid_i(m_request_valid_i),
        .m_request_ready_o(m_request_ready_o),
        .m_request_address_i(m_request_address_i),
        .m_request_write_data_i(m_request_write_data_i),
        .m_request_byte_enable_i(m_request_byte_enable_i),
        .m_response_valid_o(m_response_valid_o),
        .m_response_ready_i(m_response_ready_i),
        .m_response_error_o(m_response_error_o),
        .memory_request_valid_o(memory_request_valid),
        .memory_request_ready_i(memory_request_ready),
        .memory_request_write_o(memory_request_write),
        .memory_request_address_o(memory_request_address),
        .memory_request_write_data_o(memory_request_write_data),
        .memory_request_byte_enable_o(memory_request_byte_enable),
        .memory_request_word_o(memory_request_word),
        .memory_response_valid_i(memory_response_valid),
        .memory_response_ready_o(memory_response_ready),
        .memory_response_read_data_i(memory_response_read_data),
        .memory_response_error_i(memory_response_error),
        .memory_response_write_i(memory_response_write)
    );

    wire legacy_request_ready;
    wire parallel_request_ready;
    wire legacy_response_valid;
    wire parallel_response_valid;
    wire [127:0] legacy_response_read_data;
    wire [127:0] parallel_response_read_data;
    wire legacy_response_error;
    wire parallel_response_error;
    wire [31:0] legacy_araddr;
    wire [31:0] parallel_araddr;
    wire legacy_arvalid;
    wire parallel_arvalid;
    wire legacy_rready;
    wire parallel_rready;
    wire [31:0] legacy_awaddr;
    wire [31:0] parallel_awaddr;
    wire legacy_awvalid;
    wire parallel_awvalid;
    wire [31:0] legacy_wdata;
    wire [31:0] parallel_wdata;
    wire [3:0] legacy_wstrb;
    wire [3:0] parallel_wstrb;
    wire legacy_wvalid;
    wire parallel_wvalid;
    wire legacy_bready;
    wire parallel_bready;
    wire parallel_response_write;
    reg legacy_response_write;
    assign memory_request_ready = PARALLEL != 0 ? parallel_request_ready : legacy_request_ready;
    assign memory_response_valid = PARALLEL != 0 ? parallel_response_valid : legacy_response_valid;
    assign memory_response_read_data = PARALLEL != 0 ? parallel_response_read_data : legacy_response_read_data;
    assign memory_response_error = PARALLEL != 0 ? parallel_response_error : legacy_response_error;
    assign araddr_o = PARALLEL != 0 ? parallel_araddr : legacy_araddr;
    assign arvalid_o = PARALLEL != 0 ? parallel_arvalid : legacy_arvalid;
    assign rready_o = PARALLEL != 0 ? parallel_rready : legacy_rready;
    assign awaddr_o = PARALLEL != 0 ? parallel_awaddr : legacy_awaddr;
    assign awvalid_o = PARALLEL != 0 ? parallel_awvalid : legacy_awvalid;
    assign wdata_o = PARALLEL != 0 ? parallel_wdata : legacy_wdata;
    assign wstrb_o = PARALLEL != 0 ? parallel_wstrb : legacy_wstrb;
    assign wvalid_o = PARALLEL != 0 ? parallel_wvalid : legacy_wvalid;
    assign bready_o = PARALLEL != 0 ? parallel_bready : legacy_bready;
    assign memory_response_write = PARALLEL != 0 ?
        parallel_response_write : legacy_response_write;
    always @(posedge clk_i) begin
        if (reset_i) legacy_response_write <= 1'b0;
        else if (memory_request_valid && memory_request_ready)
            legacy_response_write <= memory_request_write;
    end
    rv32_cache_axi4_lite_adapter adapter (
        .clk_i(clk_i), .reset_i(reset_i || PARALLEL != 0),
        .request_valid_i(memory_request_valid && PARALLEL == 0),
        .request_ready_o(legacy_request_ready),
        .request_write_i(memory_request_write),
        .request_address_i(memory_request_address),
        .request_write_data_i(memory_request_write_data),
        .request_byte_enable_i(memory_request_byte_enable),
        .request_word_i(memory_request_word),
        .response_valid_o(legacy_response_valid),
        .response_ready_i(memory_response_ready),
        .response_read_data_o(legacy_response_read_data),
        .response_error_o(legacy_response_error),
        .araddr_o(legacy_araddr), .arvalid_o(legacy_arvalid),
        .arready_i(arready_i), .rdata_i(rdata_i), .rresp_i(rresp_i),
        .rvalid_i(rvalid_i), .rready_o(legacy_rready),
        .awaddr_o(legacy_awaddr), .awvalid_o(legacy_awvalid),
        .awready_i(awready_i), .wdata_o(legacy_wdata), .wstrb_o(legacy_wstrb),
        .wvalid_o(legacy_wvalid), .wready_i(wready_i),
        .bresp_i(bresp_i), .bvalid_i(bvalid_i), .bready_o(legacy_bready)
    );

    rv32_cache_axi4_lite_parallel_adapter #(.READ_ENTRIES(READ_ENTRIES)) parallel_adapter (
        .clk_i(clk_i), .reset_i(reset_i || PARALLEL == 0),
        .request_valid_i(memory_request_valid && PARALLEL != 0),
        .request_ready_o(parallel_request_ready),
        .request_write_i(memory_request_write),
        .request_address_i(memory_request_address),
        .request_write_data_i(memory_request_write_data),
        .request_byte_enable_i(memory_request_byte_enable),
        .request_word_i(memory_request_word),
        .response_valid_o(parallel_response_valid),
        .response_ready_i(memory_response_ready),
        .response_read_data_o(parallel_response_read_data),
        .response_error_o(parallel_response_error),
        .response_write_o(parallel_response_write),
        .araddr_o(parallel_araddr), .arvalid_o(parallel_arvalid),
        .arready_i(arready_i), .rdata_i(rdata_i), .rresp_i(rresp_i),
        .rvalid_i(rvalid_i), .rready_o(parallel_rready),
        .awaddr_o(parallel_awaddr), .awvalid_o(parallel_awvalid),
        .awready_i(awready_i), .wdata_o(parallel_wdata), .wstrb_o(parallel_wstrb),
        .wvalid_o(parallel_wvalid), .wready_i(wready_i),
        .bresp_i(bresp_i), .bvalid_i(bvalid_i), .bready_o(parallel_bready)
    );
endmodule

module rv32_cache_axi4_lite_parallel_adapter #(parameter READ_ENTRIES = 2) (
    input  wire clk_i,
    input  wire reset_i,
    input  wire request_valid_i,
    output wire request_ready_o,
    input  wire request_write_i,
    input  wire [31:0] request_address_i,
    input  wire [127:0] request_write_data_i,
    input  wire [15:0] request_byte_enable_i,
    input  wire request_word_i,
    output wire response_valid_o,
    input  wire response_ready_i,
    output wire [127:0] response_read_data_o,
    output wire response_error_o,
    output wire response_write_o,
    output wire [31:0] araddr_o,
    output wire arvalid_o,
    input  wire arready_i,
    input  wire [31:0] rdata_i,
    input  wire [1:0] rresp_i,
    input  wire rvalid_i,
    output wire rready_o,
    output wire [31:0] awaddr_o,
    output wire awvalid_o,
    input  wire awready_i,
    output wire [31:0] wdata_o,
    output wire [3:0] wstrb_o,
    output wire wvalid_o,
    input  wire wready_i,
    input  wire [1:0] bresp_i,
    input  wire bvalid_i,
    output wire bready_o
);
    localparam READ_INDEX_WIDTH = $clog2(READ_ENTRIES);
    reg [READ_ENTRIES-1:0] read_valid;
    reg [READ_ENTRIES-1:0] read_done;
    reg [READ_ENTRIES-1:0] read_error;
    reg [READ_ENTRIES-1:0] read_word;
    reg [31:0] read_address [0:READ_ENTRIES-1];
    reg [127:0] read_data [0:READ_ENTRIES-1];
    reg [2:0] ar_count [0:READ_ENTRIES-1];
    reg [2:0] r_count [0:READ_ENTRIES-1];
    reg [READ_INDEX_WIDTH-1:0] read_tail;
    reg [READ_INDEX_WIDTH-1:0] ar_head;
    reg [READ_INDEX_WIDTH-1:0] r_head;
    reg [READ_INDEX_WIDTH-1:0] response_head;
    reg [READ_INDEX_WIDTH:0] read_count;
    reg write_valid;
    reg write_done;
    reg write_error;
    reg write_word;
    reg [31:0] write_address;
    reg [127:0] write_data;
    reg [15:0] write_mask;
    reg [2:0] aw_count;
    reg [2:0] w_count;
    reg [2:0] b_count;
    reg response_locked;
    reg locked_write;
    wire select_write = response_locked ? locked_write : write_valid && write_done;
    wire read_response = read_valid[response_head] && read_done[response_head];
    wire write_response = write_valid && write_done;
    wire response_fire = response_valid_o && response_ready_i;
    wire request_fire = request_valid_i && request_ready_o;
    wire [2:0] write_words = write_word ? 3'd1 : 3'd4;
    wire [2:0] ar_words = read_word[ar_head] ? 3'd1 : 3'd4;
    wire [2:0] r_words = read_word[r_head] ? 3'd1 : 3'd4;
    integer index;

    assign request_ready_o = !reset_i && (request_write_i ?
        (!write_valid || (response_fire && select_write)) :
        (read_count < READ_ENTRIES || (response_fire && !select_write)));
    assign response_valid_o = !reset_i && (select_write ? write_response : read_response);
    assign response_write_o = select_write;
    assign response_error_o = select_write ? write_error : read_error[response_head];
    assign response_read_data_o = select_write || response_error_o ?
        128'd0 : read_data[response_head];
    assign arvalid_o = !reset_i && read_valid[ar_head] && ar_count[ar_head] < ar_words;
    assign araddr_o = read_address[ar_head] + {28'd0, ar_count[ar_head][1:0], 2'b00};
    assign rready_o = !reset_i && read_valid[r_head] && r_count[r_head] < ar_count[r_head];
    assign awvalid_o = !reset_i && write_valid && aw_count < write_words;
    assign awaddr_o = write_address + {28'd0, aw_count[1:0], 2'b00};
    assign wvalid_o = !reset_i && write_valid && w_count < write_words;
    assign wdata_o = write_data[w_count[1:0]*32 +: 32];
    assign wstrb_o = write_mask[w_count[1:0]*4 +: 4];
    assign bready_o = !reset_i && write_valid && b_count < aw_count && b_count < w_count;

    always @(posedge clk_i) begin
        if (reset_i) begin
            read_valid <= 0;
            read_done <= 0;
            read_error <= 0;
            read_word <= 0;
            read_tail <= 0;
            ar_head <= 0;
            r_head <= 0;
            response_head <= 0;
            read_count <= 0;
            write_valid <= 0;
            write_done <= 0;
            write_error <= 0;
            write_word <= 0;
            write_address <= 0;
            write_data <= 0;
            write_mask <= 0;
            aw_count <= 0;
            w_count <= 0;
            b_count <= 0;
            response_locked <= 0;
            locked_write <= 0;
            for (index = 0; index < READ_ENTRIES; index = index + 1) begin
                read_address[index] <= 0;
                read_data[index] <= 0;
                ar_count[index] <= 0;
                r_count[index] <= 0;
            end
        end else begin
            if (response_fire) response_locked <= 1'b0;
            else if (response_valid_o && !response_locked) begin
                response_locked <= 1'b1;
                locked_write <= select_write;
            end
            case ({request_fire && !request_write_i, response_fire && !select_write})
                2'b10: read_count <= read_count + 1'b1;
                2'b01: read_count <= read_count - 1'b1;
                default: read_count <= read_count;
            endcase
            if (arvalid_o && arready_i) begin
                ar_count[ar_head] <= ar_count[ar_head] + 1'b1;
                if (ar_count[ar_head] + 3'd1 == ar_words) ar_head <= ar_head + 1'b1;
            end
            if (rvalid_i && rready_o) begin
                r_count[r_head] <= r_count[r_head] + 1'b1;
                if (rresp_i != 0) read_error[r_head] <= 1'b1;
                if (read_word[r_head]) read_data[r_head] <= {rdata_i,96'd0};
                else read_data[r_head][r_count[r_head][1:0]*32 +: 32] <= rdata_i;
                if (r_count[r_head] + 3'd1 == r_words) begin
                    read_done[r_head] <= 1'b1;
                    r_head <= r_head + 1'b1;
                end
            end
            if (awvalid_o && awready_i) aw_count <= aw_count + 1'b1;
            if (wvalid_o && wready_i) w_count <= w_count + 1'b1;
            if (bvalid_i && bready_o) begin
                b_count <= b_count + 1'b1;
                if (bresp_i != 0) write_error <= 1'b1;
                if (b_count + 3'd1 == write_words) write_done <= 1'b1;
            end
            if (response_fire) begin
                if (select_write) write_valid <= 1'b0;
                else begin
                    read_valid[response_head] <= 1'b0;
                    response_head <= response_head + 1'b1;
                end
            end
            if (request_fire) begin
                if (request_write_i) begin
                    write_valid <= 1'b1;
                    write_done <= 1'b0;
                    write_error <= 1'b0;
                    write_word <= request_word_i;
                    write_address <= request_word_i ?
                        {request_address_i[31:2],2'b00} : {request_address_i[31:4],4'b0000};
                    write_data <= request_write_data_i;
                    write_mask <= request_byte_enable_i;
                    aw_count <= 0;
                    w_count <= 0;
                    b_count <= 0;
                end else begin
                    read_valid[read_tail] <= 1'b1;
                    read_done[read_tail] <= 1'b0;
                    read_error[read_tail] <= 1'b0;
                    read_word[read_tail] <= request_word_i;
                    read_address[read_tail] <= request_word_i ?
                        {request_address_i[31:2],2'b00} : {request_address_i[31:4],4'b0000};
                    read_data[read_tail] <= 0;
                    ar_count[read_tail] <= 0;
                    r_count[read_tail] <= 0;
                    read_tail <= read_tail + 1'b1;
                end
            end
        end
    end
endmodule
