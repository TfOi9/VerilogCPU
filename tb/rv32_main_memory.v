`timescale 1ns/1ps

module rv32_main_memory (
    input  wire clk_i,
    input  wire reset_i,
    input  wire i_request_valid_i,
    output wire i_request_ready_o,
    input  wire [31:0] i_request_address_i,
    output reg i_response_valid_o,
    input  wire i_response_ready_i,
    output reg [127:0] i_response_read_data_o,
    output reg i_response_error_o,
    input  wire d_request_valid_i,
    output wire d_request_ready_o,
    input  wire d_request_write_i,
    input  wire [31:0] d_request_address_i,
    input  wire [127:0] d_request_write_data_i,
    input  wire [15:0] d_request_byte_enable_i,
    output reg d_response_valid_o,
    input  wire d_response_ready_i,
    output reg [127:0] d_response_read_data_o,
    output reg d_response_error_o
);
    localparam MEMORY_BYTES = 1048576;
    localparam RESPONSE_CYCLES = 50;

    reg [7:0] byte_memory [0:MEMORY_BYTES-1];
    reg i_busy;
    reg [5:0] i_cycles_left;
    reg [31:0] i_address;
    reg i_address_error;
    reg d_busy;
    reg [5:0] d_cycles_left;
    reg d_write;
    reg [31:0] d_address;
    reg [127:0] d_write_data;
    reg [15:0] d_byte_enable;
    reg d_address_error;
    reg [8*1024-1:0] image_path;
    integer byte_index;

    function address_error;
        input [31:0] address;
        begin
            address_error = (address > 32'h000ffff0) ||
                (address[3:0] != 0);
        end
    endfunction

    function [127:0] read_line;
        input [31:0] address;
        input overlay_write;
        input [31:0] overlay_address;
        input [127:0] overlay_data;
        input [15:0] overlay_enable;
        integer index;
        begin
            read_line = 128'd0;
            for (index = 0; index < 16; index = index + 1) begin
                if (overlay_write && address == overlay_address &&
                        overlay_enable[index])
                    read_line[index*8 +: 8] = overlay_data[index*8 +: 8];
                else
                    read_line[index*8 +: 8] =
                        byte_memory[address + index];
            end
        end
    endfunction

    assign i_request_ready_o = !reset_i && !i_busy && !i_response_valid_o;
    assign d_request_ready_o = !reset_i && !d_busy && !d_response_valid_o;

    initial begin
        for (byte_index = 0; byte_index < MEMORY_BYTES;
                byte_index = byte_index + 1)
            byte_memory[byte_index] = 8'd0;
        if ($value$plusargs("MEM_IMAGE=%s", image_path))
            $readmemh(image_path, byte_memory);
    end

    always @(posedge clk_i) begin
        if (reset_i) begin
            i_busy <= 1'b0;
            i_cycles_left <= 0;
            i_address <= 0;
            i_address_error <= 1'b0;
            i_response_valid_o <= 1'b0;
            i_response_read_data_o <= 0;
            i_response_error_o <= 1'b0;
            d_busy <= 1'b0;
            d_cycles_left <= 0;
            d_write <= 1'b0;
            d_address <= 0;
            d_write_data <= 0;
            d_byte_enable <= 0;
            d_address_error <= 1'b0;
            d_response_valid_o <= 1'b0;
            d_response_read_data_o <= 0;
            d_response_error_o <= 1'b0;
        end else begin
            if (i_response_valid_o && i_response_ready_i)
                i_response_valid_o <= 1'b0;
            if (d_response_valid_o && d_response_ready_i)
                d_response_valid_o <= 1'b0;

            if (i_request_valid_i && i_request_ready_o) begin
                i_busy <= 1'b1;
                i_cycles_left <= RESPONSE_CYCLES;
                i_address <= i_request_address_i;
                i_address_error <= address_error(i_request_address_i);
            end else if (i_busy) begin
                if (i_cycles_left == 1) begin
                    i_busy <= 1'b0;
                    i_response_valid_o <= 1'b1;
                    i_response_error_o <= i_address_error;
                    i_response_read_data_o <= i_address_error ? 128'd0 :
                        read_line(i_address,
                            d_busy && d_cycles_left == 1 && d_write &&
                                !d_address_error,
                            d_address, d_write_data, d_byte_enable);
                end else
                    i_cycles_left <= i_cycles_left - 1'b1;
            end

            if (d_request_valid_i && d_request_ready_o) begin
                d_busy <= 1'b1;
                d_cycles_left <= RESPONSE_CYCLES;
                d_write <= d_request_write_i;
                d_address <= d_request_address_i;
                d_write_data <= d_request_write_data_i;
                d_byte_enable <= d_request_byte_enable_i;
                d_address_error <= address_error(d_request_address_i);
            end else if (d_busy) begin
                if (d_cycles_left == 1) begin
                    d_busy <= 1'b0;
                    d_response_valid_o <= 1'b1;
                    d_response_error_o <= d_address_error;
                    d_response_read_data_o <=
                        (d_address_error || d_write) ? 128'd0 :
                        read_line(d_address, 1'b0, 32'd0, 128'd0, 16'd0);
                    if (d_write && !d_address_error)
                        for (byte_index = 0; byte_index < 16;
                                byte_index = byte_index + 1)
                            if (d_byte_enable[byte_index])
                                byte_memory[d_address + byte_index] <=
                                    d_write_data[byte_index*8 +: 8];
                end else
                    d_cycles_left <= d_cycles_left - 1'b1;
            end
        end
    end
endmodule
