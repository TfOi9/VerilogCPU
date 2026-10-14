`timescale 1ns/1ps

module rv32_ranked_select #(
    parameter ENTRIES = 8,
    parameter PORTS = 4,
    parameter SLOT_WIDTH = 3,
    parameter AGE_WIDTH = 5,
    parameter DATA_WIDTH = 32
) (
    input wire enable_i,
    input wire [ENTRIES-1:0] valid_i,
    input wire [(ENTRIES*AGE_WIDTH)-1:0] age_i,
    input wire [(ENTRIES*DATA_WIDTH)-1:0] data_i,
    input wire [PORTS-1:0] locked_i,
    input wire [(PORTS*SLOT_WIDTH)-1:0] locked_slot_i,
    output wire [PORTS-1:0] valid_o,
    output wire [(PORTS*SLOT_WIDTH)-1:0] slot_o,
    output wire [(PORTS*ENTRIES)-1:0] mask_o,
    output wire [(PORTS*DATA_WIDTH)-1:0] data_o
);
    localparam LEAVES = 1 << SLOT_WIDTH;
    localparam COUNT_WIDTH = SLOT_WIDTH + 1;
    wire [ENTRIES-1:0] eligible;
    wire [COUNT_WIDTH-1:0] rank [0:ENTRIES-1];
    genvar entry_index, other_index, node_index, port_index;
    generate
        for (entry_index = 0; entry_index < ENTRIES;
                entry_index = entry_index + 1) begin: candidate
            wire [PORTS-1:0] reserved;
            wire [COUNT_WIDTH-1:0] count [1:2*LEAVES-1];
            for (port_index = 0; port_index < PORTS;
                    port_index = port_index + 1) begin: lock_match
                assign reserved[port_index] = locked_i[port_index] &&
                    (locked_slot_i[port_index*SLOT_WIDTH +: SLOT_WIDTH] ==
                     entry_index);
            end
            assign eligible[entry_index] = valid_i[entry_index] && !(|reserved);
            for (other_index = 0; other_index < LEAVES;
                    other_index = other_index + 1) begin: older
                if (other_index < ENTRIES && other_index != entry_index) begin: present
                    wire precedes;
                    assign precedes =
                        (age_i[other_index*AGE_WIDTH +: AGE_WIDTH] <
                         age_i[entry_index*AGE_WIDTH +: AGE_WIDTH]) ||
                        ((age_i[other_index*AGE_WIDTH +: AGE_WIDTH] ==
                          age_i[entry_index*AGE_WIDTH +: AGE_WIDTH]) &&
                         (other_index < entry_index));
                    assign count[LEAVES+other_index] =
                        {{(COUNT_WIDTH-1){1'b0}},
                         eligible[other_index] && precedes};
                end else begin: absent
                    assign count[LEAVES+other_index] = {COUNT_WIDTH{1'b0}};
                end
            end
            for (node_index = 1; node_index < LEAVES;
                    node_index = node_index + 1) begin: sum_tree
                assign count[node_index] = count[2*node_index] + count[2*node_index+1];
            end
            assign rank[entry_index] = count[1];
        end
        for (port_index = 0; port_index < PORTS;
                port_index = port_index + 1) begin: output_port
            wire [COUNT_WIDTH-1:0] ordinal [0:PORTS];
            wire [DATA_WIDTH+SLOT_WIDTH-1:0] payload [1:2*LEAVES-1];
            assign ordinal[0] = {COUNT_WIDTH{1'b0}};
            for (other_index = 0; other_index < PORTS;
                    other_index = other_index + 1) begin: unlocked_prefix
                assign ordinal[other_index+1] = ordinal[other_index] +
                    {{(COUNT_WIDTH-1){1'b0}}, !locked_i[other_index]};
            end
            for (entry_index = 0; entry_index < LEAVES;
                    entry_index = entry_index + 1) begin: data_leaf
                if (entry_index < ENTRIES) begin: present
                    wire selected;
                    localparam [SLOT_WIDTH-1:0] SLOT = entry_index;
                    assign selected = enable_i &&
                        (locked_i[port_index] ?
                         locked_slot_i[port_index*SLOT_WIDTH +: SLOT_WIDTH] == SLOT :
                         eligible[entry_index] && rank[entry_index] == ordinal[port_index]);
                    assign mask_o[port_index*ENTRIES+entry_index] = selected;
                    assign payload[LEAVES+entry_index] =
                        {(DATA_WIDTH+SLOT_WIDTH){selected}} &
                        {SLOT, data_i[entry_index*DATA_WIDTH +: DATA_WIDTH]};
                end else begin: absent
                    assign payload[LEAVES+entry_index] = {(DATA_WIDTH+SLOT_WIDTH){1'b0}};
                end
            end
            for (node_index = 1; node_index < LEAVES;
                    node_index = node_index + 1) begin: data_tree
                assign payload[node_index] = payload[2*node_index] | payload[2*node_index+1];
            end
            assign valid_o[port_index] = enable_i &&
                (locked_i[port_index] || (|mask_o[port_index*ENTRIES +: ENTRIES]));
            assign slot_o[port_index*SLOT_WIDTH +: SLOT_WIDTH] =
                !enable_i ? {SLOT_WIDTH{1'b0}} : locked_i[port_index] ?
                locked_slot_i[port_index*SLOT_WIDTH +: SLOT_WIDTH] :
                payload[1][DATA_WIDTH +: SLOT_WIDTH];
            assign data_o[port_index*DATA_WIDTH +: DATA_WIDTH] = payload[1][DATA_WIDTH-1:0];
        end
    endgenerate
endmodule
