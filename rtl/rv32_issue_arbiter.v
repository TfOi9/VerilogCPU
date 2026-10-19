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
    output wire [BE_WIDTH+3:0] grant_o
);
    localparam CANDIDATES = BE_WIDTH + 4;
    localparam [3:0] ISSUE_LIMIT = BE_WIDTH[3:0];
    wire [ROB_INDEX_WIDTH-1:0] age [0:CANDIDATES-1];
    wire [CANDIDATES-1:0] eligible;
    /* verilator lint_off UNUSEDSIGNAL */
    function [ROB_INDEX_WIDTH-1:0] age_from_tag;
        input [ROB_TAG_WIDTH-1:0] tag;
        input [ROB_INDEX_WIDTH-1:0] head;
        begin age_from_tag = tag[ROB_INDEX_WIDTH-1:0] - head; end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    genvar candidate, other, node;
    generate
        for (candidate = 0; candidate < CANDIDATES; candidate = candidate + 1) begin: rank_candidate
            wire [CANDIDATES-1:0] older;
            wire [3:0] count_tree [1:15];
            assign age[candidate] = age_from_tag(
                candidate_tag_i[candidate*ROB_TAG_WIDTH +: ROB_TAG_WIDTH], rob_head_index_i);
            if (candidate >= BE_WIDTH+2) begin: memory_candidate
                localparam OTHER_MEMORY = candidate == BE_WIDTH+2 ? BE_WIDTH+3 : BE_WIDTH+2;
                wire older_memory = candidate_valid_i[OTHER_MEMORY] && candidate_ready_i[OTHER_MEMORY] &&
                    (age[OTHER_MEMORY] < age[candidate] ||
                        (age[OTHER_MEMORY] == age[candidate] && OTHER_MEMORY < candidate));
                assign eligible[candidate] = !hold_i && candidate_valid_i[candidate] &&
                    candidate_ready_i[candidate] && !older_memory;
            end else begin: execution_candidate
                assign eligible[candidate] = !hold_i && candidate_valid_i[candidate] && candidate_ready_i[candidate];
            end
            for (other = 0; other < CANDIDATES; other = other + 1) begin: compare_age
                assign older[other] = eligible[other] &&
                    (age[other] < age[candidate] || (age[other] == age[candidate] && other < candidate));
            end
            for (node = 0; node < 8; node = node + 1) begin: count_leaf
                if (node < CANDIDATES) begin: valid_leaf
                    assign count_tree[8+node] = {3'd0, older[node]};
                end else begin: empty_leaf
                    assign count_tree[8+node] = 4'd0;
                end
            end
            for (node = 1; node < 8; node = node + 1) begin: count_node
                assign count_tree[node] = count_tree[2*node] + count_tree[2*node+1];
            end
            assign grant_o[candidate] = eligible[candidate] && count_tree[1] < ISSUE_LIMIT;
        end
    endgenerate

    initial begin
        if ((BE_WIDTH != 1 && BE_WIDTH != 2 && BE_WIDTH != 4) ||
                ROB_ENTRIES != (1 << ROB_INDEX_WIDTH) ||
                ROB_TAG_WIDTH <= ROB_INDEX_WIDTH) begin
            $display("ERROR rv32_issue_arbiter invalid parameters");
            $finish(1);
        end
    end

endmodule
