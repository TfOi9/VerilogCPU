`timescale 1ns/1ps

module rv32_issue_arbiter #(
    parameter BE_WIDTH = 1,
    parameter ROB_ENTRIES = 32,
    parameter ROB_INDEX_WIDTH = 5,
    parameter ROB_TAG_WIDTH = 7
) (
    input wire hold_i,
    input wire [ROB_INDEX_WIDTH-1:0] rob_head_index_i,
    input wire [BE_WIDTH+3:0] candidate_valid_i,
    input wire [BE_WIDTH+3:0] candidate_ready_i,
    input wire [((BE_WIDTH+4)*ROB_TAG_WIDTH)-1:0] candidate_tag_i,
    output reg [BE_WIDTH+3:0] grant_o
);
    localparam CANDIDATES = BE_WIDTH + 4;
    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */
    integer lane;
    integer source;
    integer winner;
    integer best_distance;
    integer distance;
    reg memory_selected;

    /* verilator lint_off UNUSEDSIGNAL */
    function integer distance_from_head;
        input [ROB_TAG_WIDTH-1:0] tag;
        input [ROB_INDEX_WIDTH-1:0] head;
        integer index_value;
        begin
            index_value = tag[ROB_INDEX_WIDTH-1:0];
            distance_from_head = index_value - head;
            if (distance_from_head < 0)
                distance_from_head = distance_from_head + ROB_ENTRIES;
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    initial begin
        if ((BE_WIDTH != 1 && BE_WIDTH != 2 && BE_WIDTH != 4) ||
                ROB_ENTRIES != (1 << ROB_INDEX_WIDTH) ||
                ROB_TAG_WIDTH <= ROB_INDEX_WIDTH) begin
            $display("ERROR rv32_issue_arbiter invalid parameters");
            $finish(1);
        end
    end

    always @* begin
        grant_o = 0;
        memory_selected = 1'b0;
        winner = -1;
        best_distance = ROB_ENTRIES;
        distance = 0;
        for (lane = 0; lane < BE_WIDTH; lane = lane + 1) begin
            winner = -1;
            best_distance = ROB_ENTRIES;
            for (source = 0; source < CANDIDATES; source = source + 1) begin
                distance = distance_from_head(candidate_tag_i[
                    source*ROB_TAG_WIDTH +: ROB_TAG_WIDTH], rob_head_index_i);
                if (!hold_i && candidate_valid_i[source] &&
                        candidate_ready_i[source] && !grant_o[source] &&
                        !(memory_selected && source >= BE_WIDTH+2) &&
                        distance < best_distance) begin
                    winner = source;
                    best_distance = distance;
                end
            end
            if (winner >= 0) begin
                grant_o[winner] = 1'b1;
                if (winner >= BE_WIDTH+2)
                    memory_selected = 1'b1;
            end
        end
    end
    /* verilator lint_on WIDTHTRUNC */
    /* verilator lint_on WIDTHEXPAND */
endmodule
