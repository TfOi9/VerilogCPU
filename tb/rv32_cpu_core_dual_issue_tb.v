`timescale 1ns/1ps

module rv32_cpu_core_dual_issue_tb;
    reg clk;
    reg reset;

    wire icache_flush;
    wire icache_request_valid;
    wire icache_request_ready;
    wire [31:0] icache_request_pc;
    reg icache_response_valid;
    wire icache_response_ready;
    reg [31:0] icache_response_pc;
    reg [127:0] icache_response_line;

    wire dcache_request_valid;
    reg dcache_request_ready;
    wire dcache_request_write;
    wire [31:0] dcache_request_address;
    wire [31:0] dcache_request_write_data;
    wire [3:0] dcache_request_byte_enable;
    wire dcache_request_mmio;
    reg dcache_response_valid;
    wire dcache_response_ready;

    reg dual_issue_seen;
    reg dual_alu_completion_seen;
    reg dual_branch_completion_seen;
    reg completion_collision_seen;
    reg oldest_redirect_seen;
    reg exit_seen;
    integer cycle_count;
    integer exit_count;

    assign icache_request_ready = !icache_response_valid;

    rv32_cpu_core #(
        .FE_WIDTH(2), .BE_WIDTH(2)
    ) dut (
        .clk_i(clk), .reset_i(reset),
        .icache_flush_o(icache_flush),
        .icache_request_valid_o(icache_request_valid),
        .icache_request_ready_i(icache_request_ready),
        .icache_request_pc_o(icache_request_pc),
        .icache_response_valid_i(icache_response_valid),
        .icache_response_ready_o(icache_response_ready),
        .icache_response_pc_i(icache_response_pc),
        .icache_response_line_i(icache_response_line),
        .icache_response_error_i(1'b0),
        .dcache_request_valid_o(dcache_request_valid),
        .dcache_request_ready_i(dcache_request_ready),
        .dcache_request_write_o(dcache_request_write),
        .dcache_request_address_o(dcache_request_address),
        .dcache_request_write_data_o(dcache_request_write_data),
        .dcache_request_byte_enable_o(dcache_request_byte_enable),
        .dcache_request_mmio_o(dcache_request_mmio),
        .dcache_response_valid_i(dcache_response_valid),
        .dcache_response_ready_o(dcache_response_ready),
        .dcache_response_read_data_i(32'd0),
        .dcache_response_error_i(1'b0)
    );

    function [127:0] instruction_line;
        input [27:0] line_address;
        begin
            case (line_address)
                28'h0000000: instruction_line = {
                    32'h00300193,
                    32'h02208433,
                    32'h00108113,
                    32'h00600093
                };
                28'h0000001: instruction_line = {
                    32'h01428313,
                    32'h00a20313,
                    32'h00218293,
                    32'h00118213
                };
                28'h0000002: instruction_line = {
                    32'h00000463,
                    32'h00000863,
                    32'h800003b7,
                    32'h00640533
                };
                28'h0000003: instruction_line = {
                    32'h0000006f,
                    32'h00a3a023,
                    32'h0003a023,
                    32'h0003a023
                };
                default: instruction_line = {4{32'h0000006f}};
            endcase
        end
    endfunction

    task fail;
        input [511:0] message;
        begin
            $display("FAIL %0s", message);
            $finish(1);
        end
    endtask

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (reset || icache_flush) begin
            icache_response_valid <= 1'b0;
            icache_response_pc <= 32'd0;
            icache_response_line <= 128'd0;
        end else begin
            if (icache_response_valid && icache_response_ready)
                icache_response_valid <= 1'b0;
            if (icache_request_valid && icache_request_ready) begin
                icache_response_valid <= 1'b1;
                icache_response_pc <= icache_request_pc;
                icache_response_line <=
                    instruction_line(icache_request_pc[31:4]);
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            dcache_response_valid <= 1'b0;
        end else begin
            if (dcache_response_valid && dcache_response_ready)
                dcache_response_valid <= 1'b0;
            if (dcache_request_valid && dcache_request_ready)
                dcache_response_valid <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            dual_issue_seen <= 1'b0;
            dual_alu_completion_seen <= 1'b0;
            dual_branch_completion_seen <= 1'b0;
            completion_collision_seen <= 1'b0;
            oldest_redirect_seen <= 1'b0;
            exit_seen <= 1'b0;
            exit_count <= 0;
            cycle_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if ((dut.int_issue_valid & dut.int_issue_ready) == 2'b11)
                dual_issue_seen <= 1'b1;
            if ((dut.alu_response_valid & dut.alu_response_ready) == 2'b11)
                dual_alu_completion_seen <= 1'b1;
            if ((dut.alu_response_valid & dut.alu_response_ready &
                    dut.alu_response_control_valid) == 2'b11)
                dual_branch_completion_seen <= 1'b1;
            if ((|dut.source_valid[1:0]) &&
                    (dut.source_valid[2] || dut.source_valid[3]) &&
                    dut.source_valid[4])
                completion_collision_seen <= 1'b1;
            if (dut.recover_redirect_valid) begin
                if (dut.recover_redirect_pc != 32'h00000038)
                    fail("younger branch redirect selected");
                oldest_redirect_seen <= 1'b1;
            end

            if (dcache_request_valid && dcache_request_ready) begin
                exit_count <= exit_count + 1;
                if (!dcache_request_write || !dcache_request_mmio)
                    fail("unexpected data request type");
                if (dcache_request_address != 32'h80000000 ||
                        dcache_request_byte_enable != 4'hf)
                    fail("unexpected MMIO request shape");
                if (dcache_request_write_data != 32'd67)
                    fail("wrong-path MMIO request escaped");
                exit_seen <= 1'b1;
            end

            if (exit_seen && !dcache_response_valid) begin
                if (exit_count != 1)
                    fail("unexpected MMIO request count");
                if (!dual_issue_seen)
                    fail("no dual integer issue observed");
                if (!dual_alu_completion_seen)
                    fail("no dual ALU completion observed");
                if (!dual_branch_completion_seen)
                    fail("no dual branch completion observed");
                if (!completion_collision_seen)
                    fail("no ALU/MDU/LSQ completion collision observed");
                if (!oldest_redirect_seen)
                    fail("oldest branch recovery was not observed");
                $display("PASS dual-issue core integration cycles=%0d",
                    cycle_count);
                $finish;
            end

            if (cycle_count > 2000)
                fail("timeout");
        end
    end

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        icache_response_valid = 1'b0;
        icache_response_pc = 32'd0;
        icache_response_line = 128'd0;
        dcache_request_ready = 1'b1;
        dcache_response_valid = 1'b0;
        dual_issue_seen = 1'b0;
        dual_alu_completion_seen = 1'b0;
        dual_branch_completion_seen = 1'b0;
        completion_collision_seen = 1'b0;
        oldest_redirect_seen = 1'b0;
        exit_seen = 1'b0;
        cycle_count = 0;
        exit_count = 0;
        repeat (4) @(posedge clk);
        reset = 1'b0;
    end
endmodule
