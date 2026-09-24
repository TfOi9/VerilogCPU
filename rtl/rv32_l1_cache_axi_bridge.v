`timescale 1ns/1ps

module rv32_l1_cache_arbiter (
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
    input  wire [31:0] d_request_address_i,
    input  wire [127:0] d_request_write_data_i,
    input  wire [15:0] d_request_byte_enable_i,
    output wire d_response_valid_o,
    input  wire d_response_ready_i,
    output wire [127:0] d_response_read_data_o,
    output wire d_response_error_o,
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
    input  wire memory_response_error_i
);
    reg busy;
    localparam OWNER_I = 2'd0;
    localparam OWNER_D = 2'd1;
    localparam OWNER_M = 2'd2;

    reg [1:0] owner;
    reg grant_locked;
    reg [1:0] grant_owner;
    wire [1:0] selected_owner;
    wire selected_valid;

    assign selected_owner = grant_locked ? grant_owner :
        (m_request_valid_i ? OWNER_M :
         (d_request_valid_i ? OWNER_D : OWNER_I));
    assign selected_valid = selected_owner == OWNER_M ? m_request_valid_i :
        (selected_owner == OWNER_D ? d_request_valid_i : i_request_valid_i);

    assign memory_request_valid_o = !reset_i && !busy && selected_valid;
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
    assign i_request_ready_o = !reset_i && !busy &&
        selected_owner == OWNER_I &&
        selected_valid && memory_request_ready_i;
    assign d_request_ready_o = !reset_i && !busy &&
        selected_owner == OWNER_D &&
        selected_valid && memory_request_ready_i;
    assign m_request_ready_o = !reset_i && !busy &&
        selected_owner == OWNER_M &&
        selected_valid && memory_request_ready_i;

    assign i_response_valid_o = !reset_i && busy && owner == OWNER_I &&
        memory_response_valid_i;
    assign d_response_valid_o = !reset_i && busy && owner == OWNER_D &&
        memory_response_valid_i;
    assign m_response_valid_o = !reset_i && busy && owner == OWNER_M &&
        memory_response_valid_i;
    assign i_response_read_data_o = memory_response_read_data_i;
    assign d_response_read_data_o = memory_response_read_data_i;
    assign i_response_error_o = memory_response_error_i;
    assign d_response_error_o = memory_response_error_i;
    assign m_response_error_o = memory_response_error_i;
    assign memory_response_ready_o = !reset_i && busy &&
        (owner == OWNER_I ? i_response_ready_i :
         (owner == OWNER_D ? d_response_ready_i : m_response_ready_i));

    always @(posedge clk_i) begin
        if (reset_i) begin
            busy <= 1'b0;
            owner <= OWNER_I;
            grant_locked <= 1'b0;
            grant_owner <= OWNER_I;
        end else if (busy) begin
            if (memory_response_valid_i && memory_response_ready_o)
                busy <= 1'b0;
        end else if (memory_request_valid_o && memory_request_ready_i) begin
            busy <= 1'b1;
            owner <= selected_owner;
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
    localparam STATE_IDLE = 3'd0;
    localparam STATE_READ_ADDRESS = 3'd1;
    localparam STATE_READ_DATA = 3'd2;
    localparam STATE_WRITE_SEND = 3'd3;
    localparam STATE_WRITE_RESPONSE = 3'd4;
    localparam STATE_RESPONSE = 3'd5;

    reg [2:0] state;
    reg [31:0] line_address;
    reg [127:0] line_write_data;
    reg [15:0] line_write_mask;
    reg [127:0] line_read_data;
    reg [127:0] response_read_data;
    reg response_error;
    reg [1:0] word_index;
    reg word_only;
    reg aw_done;
    reg w_done;

    wire aw_fire;
    wire w_fire;

    assign request_ready_o = !reset_i && (state == STATE_IDLE);
    assign response_valid_o = !reset_i && (state == STATE_RESPONSE);
    assign response_read_data_o = response_read_data;
    assign response_error_o = response_error;

    assign araddr_o = line_address + {28'd0, word_index, 2'b00};
    assign arvalid_o = !reset_i && (state == STATE_READ_ADDRESS);
    assign rready_o = !reset_i && (state == STATE_READ_DATA);
    assign awaddr_o = line_address + {28'd0, word_index, 2'b00};
    assign awvalid_o = !reset_i && (state == STATE_WRITE_SEND) && !aw_done;
    assign wdata_o = line_write_data[word_index*32 +: 32];
    assign wstrb_o = line_write_mask[word_index*4 +: 4];
    assign wvalid_o = !reset_i && (state == STATE_WRITE_SEND) && !w_done;
    assign bready_o = !reset_i && (state == STATE_WRITE_RESPONSE);
    assign aw_fire = awvalid_o && awready_i;
    assign w_fire = wvalid_o && wready_i;

    always @(posedge clk_i) begin
        if (reset_i) begin
            state <= STATE_IDLE;
            line_address <= 32'd0;
            line_write_data <= 128'd0;
            line_write_mask <= 16'd0;
            line_read_data <= 128'd0;
            response_read_data <= 128'd0;
            response_error <= 1'b0;
            word_index <= 2'd0;
            word_only <= 1'b0;
            aw_done <= 1'b0;
            w_done <= 1'b0;
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
                        response_read_data <= 128'd0;
                        response_error <= 1'b0;
                        word_index <= 2'd0;
                        word_only <= request_word_i;
                        aw_done <= 1'b0;
                        w_done <= 1'b0;
                        if (request_write_i)
                            state <= STATE_WRITE_SEND;
                        else
                            state <= STATE_READ_ADDRESS;
                    end
                end
                STATE_READ_ADDRESS: begin
                    if (arvalid_o && arready_i)
                        state <= STATE_READ_DATA;
                end
                STATE_READ_DATA: begin
                    if (rvalid_i && rready_o) begin
                        if (rresp_i != 2'b00) begin
                            response_read_data <= 128'd0;
                            response_error <= 1'b1;
                            state <= STATE_RESPONSE;
                        end else if (word_only || word_index == 2'd3) begin
                            response_read_data <= {rdata_i,
                                line_read_data[95:0]};
                            response_error <= 1'b0;
                            state <= STATE_RESPONSE;
                        end else begin
                            line_read_data[word_index*32 +: 32] <= rdata_i;
                            word_index <= word_index + 1'b1;
                            state <= STATE_READ_ADDRESS;
                        end
                    end
                end
                STATE_WRITE_SEND: begin
                    if (aw_fire)
                        aw_done <= 1'b1;
                    if (w_fire)
                        w_done <= 1'b1;
                    if ((aw_done || aw_fire) && (w_done || w_fire))
                        state <= STATE_WRITE_RESPONSE;
                end
                STATE_WRITE_RESPONSE: begin
                    if (bvalid_i && bready_o) begin
                        if (bresp_i != 2'b00) begin
                            response_read_data <= 128'd0;
                            response_error <= 1'b1;
                            state <= STATE_RESPONSE;
                        end else if (word_only || word_index == 2'd3) begin
                            response_read_data <= 128'd0;
                            response_error <= 1'b0;
                            state <= STATE_RESPONSE;
                        end else begin
                            word_index <= word_index + 1'b1;
                            aw_done <= 1'b0;
                            w_done <= 1'b0;
                            state <= STATE_WRITE_SEND;
                        end
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

module rv32_l1_cache_axi_bridge (
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
    input  wire [31:0] d_request_address_i,
    input  wire [127:0] d_request_write_data_i,
    input  wire [15:0] d_request_byte_enable_i,
    output wire d_response_valid_o,
    input  wire d_response_ready_i,
    output wire [127:0] d_response_read_data_o,
    output wire d_response_error_o,
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

    rv32_l1_cache_arbiter arbiter (
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
        .d_request_address_i(d_request_address_i),
        .d_request_write_data_i(d_request_write_data_i),
        .d_request_byte_enable_i(d_request_byte_enable_i),
        .d_response_valid_o(d_response_valid_o),
        .d_response_ready_i(d_response_ready_i),
        .d_response_read_data_o(d_response_read_data_o),
        .d_response_error_o(d_response_error_o),
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
        .memory_response_error_i(memory_response_error)
    );

    rv32_cache_axi4_lite_adapter adapter (
        .clk_i(clk_i), .reset_i(reset_i),
        .request_valid_i(memory_request_valid),
        .request_ready_o(memory_request_ready),
        .request_write_i(memory_request_write),
        .request_address_i(memory_request_address),
        .request_write_data_i(memory_request_write_data),
        .request_byte_enable_i(memory_request_byte_enable),
        .request_word_i(memory_request_word),
        .response_valid_o(memory_response_valid),
        .response_ready_i(memory_response_ready),
        .response_read_data_o(memory_response_read_data),
        .response_error_o(memory_response_error),
        .araddr_o(araddr_o), .arvalid_o(arvalid_o),
        .arready_i(arready_i), .rdata_i(rdata_i), .rresp_i(rresp_i),
        .rvalid_i(rvalid_i), .rready_o(rready_o),
        .awaddr_o(awaddr_o), .awvalid_o(awvalid_o),
        .awready_i(awready_i), .wdata_o(wdata_o), .wstrb_o(wstrb_o),
        .wvalid_o(wvalid_o), .wready_i(wready_i),
        .bresp_i(bresp_i), .bvalid_i(bvalid_i), .bready_o(bready_o)
    );
endmodule
