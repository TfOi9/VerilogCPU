`timescale 1ns/1ps

module rv32_physical_register_file #(
    parameter PHYS_REGS = 64,
    parameter PHYS_REG_ADDR_WIDTH = 6,
    parameter BE_WIDTH = 1
) (
    input  wire                                             clk_i,
    input  wire                                             reset_i,

    input  wire [(2*BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]      read_addr_i,
    output wire [(2*BE_WIDTH*32)-1:0]                       read_data_o,

    input  wire [BE_WIDTH-1:0]                              write_valid_i,
    input  wire [(BE_WIDTH*PHYS_REG_ADDR_WIDTH)-1:0]        write_addr_i,
    input  wire [(BE_WIDTH*32)-1:0]                         write_data_i
);

    localparam READ_PORTS = 2 * BE_WIDTH;
    localparam [PHYS_REG_ADDR_WIDTH:0] PHYS_REGS_LIMIT =
        PHYS_REGS[PHYS_REG_ADDR_WIDTH:0];

    reg [31:0] registers [0:PHYS_REGS-1];
    /* verilator lint_off UNUSEDSIGNAL */ reg [PHYS_REGS-1:0] initialized; /* verilator lint_on UNUSEDSIGNAL */
    reg [(READ_PORTS*32)-1:0] read_data_reg;
    reg [PHYS_REG_ADDR_WIDTH-1:0] current_read_address;

    integer read_index;
    integer bypass_index;
    integer write_index;

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
        end
    endfunction

    initial begin
        if ((BE_WIDTH != 1) && (BE_WIDTH != 2) && (BE_WIDTH != 4)) begin
            $display("ERROR rv32_physical_register_file invalid BE_WIDTH=%0d",
                BE_WIDTH);
            $finish(1);
        end
        if (PHYS_REGS < 33) begin
            $display("ERROR rv32_physical_register_file PHYS_REGS=%0d is below 33",
                PHYS_REGS);
            $finish(1);
        end
        if (PHYS_REG_ADDR_WIDTH != address_width_for_count(PHYS_REGS)) begin
            $display("ERROR rv32_physical_register_file address width=%0d expected=%0d",
                PHYS_REG_ADDR_WIDTH, address_width_for_count(PHYS_REGS));
            $finish(1);
        end
    end

    localparam READ_LEAVES = 1 << PHYS_REG_ADDR_WIDTH;
    wire [31:0] decoded_read [0:READ_PORTS-1];
    genvar read_port, read_leaf, read_node;
    generate
        for (read_port = 0; read_port < READ_PORTS; read_port = read_port + 1) begin: read_port_tree
            wire [31:0] tree [1:2*READ_LEAVES-1];
            for (read_leaf = 0; read_leaf < READ_LEAVES; read_leaf = read_leaf + 1) begin: read_word
                if (read_leaf > 0 && read_leaf < PHYS_REGS) begin: stored_word
                    localparam [PHYS_REG_ADDR_WIDTH-1:0] ADDRESS = read_leaf;
                    wire selected = initialized[read_leaf] &&
                        read_addr_i[read_port*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] == ADDRESS;
                    assign tree[READ_LEAVES+read_leaf] = {32{selected}} & registers[read_leaf];
                end else begin: empty_word
                    assign tree[READ_LEAVES+read_leaf] = 32'd0;
                end
            end
            for (read_node = 1; read_node < READ_LEAVES; read_node = read_node + 1) begin: merge_word
                assign tree[read_node] = tree[2*read_node] | tree[2*read_node+1];
            end
            assign decoded_read[read_port] = tree[1];
        end
    endgenerate

    assign read_data_o = read_data_reg;

    always @* begin
        read_data_reg = {(READ_PORTS*32){1'b0}};
        current_read_address = {PHYS_REG_ADDR_WIDTH{1'b0}};
        read_index = 0;
        bypass_index = 0;
        for (read_index = 0; read_index < READ_PORTS;
                read_index = read_index + 1) begin
            current_read_address = read_addr_i[
                read_index*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH];
            if (!reset_i &&
                    (current_read_address !=
                        {PHYS_REG_ADDR_WIDTH{1'b0}}) &&
                    ({1'b0, current_read_address} < PHYS_REGS_LIMIT)) begin
                read_data_reg[read_index*32 +: 32] = decoded_read[read_index];
                for (bypass_index = 0; bypass_index < BE_WIDTH;
                        bypass_index = bypass_index + 1) begin
                    if (write_valid_i[bypass_index] &&
                            (write_addr_i[
                                bypass_index*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] ==
                            current_read_address)) begin
                        read_data_reg[read_index*32 +: 32] =
                            write_data_i[bypass_index*32 +: 32];
                    end
                end
            end
        end
    end

    always @(posedge clk_i) begin
        if (reset_i) begin
            initialized <= {PHYS_REGS{1'b0}};
        end else begin
            registers[0] <= 32'd0;
            for (write_index = 0; write_index < BE_WIDTH;
                    write_index = write_index + 1) begin
                if (write_valid_i[write_index] &&
                        (write_addr_i[
                            write_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH] !=
                        {PHYS_REG_ADDR_WIDTH{1'b0}}) &&
                        ({1'b0, write_addr_i[
                            write_index*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH]} < PHYS_REGS_LIMIT)) begin
                    registers[write_addr_i[
                        write_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH]] <=
                        write_data_i[write_index*32 +: 32];
                    initialized[write_addr_i[
                        write_index*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH]] <= 1'b1;
                end
            end
        end
    end

endmodule
