`timescale 1ns/1ps

module rv32_issue_arbiter_tb;
    parameter BE_WIDTH = 1;
    reg hold;
    reg [4:0] head;
    reg [BE_WIDTH+3:0] valid;
    reg [BE_WIDTH+3:0] ready;
    reg [((BE_WIDTH+4)*7)-1:0] tags;
    wire [BE_WIDTH+3:0] grant;
    reg [BE_WIDTH+3:0] expected;
    reg [1023:0] path;
    integer vector_file;
    integer result;
    integer count;

    rv32_issue_arbiter #(.BE_WIDTH(BE_WIDTH)) dut (
        .hold_i(hold), .rob_head_index_i(head),
        .candidate_valid_i(valid), .candidate_ready_i(ready),
        .candidate_tag_i(tags), .grant_o(grant)
    );

    initial begin
        count = 0;
        if (!$value$plusargs("VECTOR_FILE=%s", path)) begin
            $display("FAIL missing VECTOR_FILE");
            $stop;
        end
        vector_file = $fopen(path, "r");
        if (!vector_file) begin
            $display("FAIL cannot open vector file");
            $stop;
        end
        while (!$feof(vector_file)) begin
            result = $fscanf(vector_file, "%d %h %h %h %h %h\n",
                hold, head, valid, ready, tags, expected);
            if (result != 6) begin
                $display("FAIL malformed vector row=%0d", count);
                $stop;
            end
            #1;
            if (grant !== expected) begin
                $display("FAIL issue width=%0d row=%0d actual=%h expected=%h",
                    BE_WIDTH, count, grant, expected);
                $stop;
            end
            count = count + 1;
        end
        $fclose(vector_file);
        $display("PASS issue arbitration width=%0d vectors=%0d", BE_WIDTH, count);
        $finish;
    end
endmodule
