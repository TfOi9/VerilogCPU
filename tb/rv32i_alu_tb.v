`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32i_alu_tb;

    localparam ROB_TAG_WIDTH = 7;

    reg clk_i;
    reg reset_i;
    reg flush_i;
    reg request_valid_i;
    wire request_ready_o;
    reg [`RV32_OP_WIDTH-1:0] request_op_i;
    reg [31:0] request_lhs_i;
    reg [31:0] request_rhs_i;
    reg [31:0] request_pc_i;
    reg [31:0] request_immediate_i;
    reg [ROB_TAG_WIDTH-1:0] request_rob_tag_i;
    wire response_valid_o;
    reg response_ready_i;
    wire [31:0] response_value_o;
    wire [ROB_TAG_WIDTH-1:0] response_rob_tag_o;
    wire response_control_valid_o;
    wire response_control_taken_o;
    wire [31:0] response_next_pc_o;

    integer test_count;
    integer error_count;
    integer seed;
    integer i;
    reg [`RV32_OP_WIDTH-1:0] random_op;
    reg [31:0] random_lhs;
    reg [31:0] random_rhs;
    reg [31:0] random_pc;
    reg [31:0] random_immediate;

    rv32i_alu #(
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) dut (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .flush_i(flush_i),
        .request_valid_i(request_valid_i),
        .request_ready_o(request_ready_o),
        .request_op_i(request_op_i),
        .request_lhs_i(request_lhs_i),
        .request_rhs_i(request_rhs_i),
        .request_pc_i(request_pc_i),
        .request_immediate_i(request_immediate_i),
        .request_rob_tag_i(request_rob_tag_i),
        .response_valid_o(response_valid_o),
        .response_ready_i(response_ready_i),
        .response_value_o(response_value_o),
        .response_rob_tag_o(response_rob_tag_o),
        .response_control_valid_o(response_control_valid_o),
        .response_control_taken_o(response_control_taken_o),
        .response_next_pc_o(response_next_pc_o)
    );

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;
    end

    function [31:0] reference_value;
        input [`RV32_OP_WIDTH-1:0] op;
        input [31:0] lhs;
        input [31:0] rhs;
        input [31:0] pc;
        input [31:0] immediate;
        begin
            case (op)
                `RV32_OP_LUI:   reference_value = immediate;
                `RV32_OP_AUIPC: reference_value = pc + immediate;
                `RV32_OP_JAL:   reference_value = pc + 32'd4;
                `RV32_OP_JALR:  reference_value = pc + 32'd4;
                `RV32_OP_ADDI:  reference_value = lhs + immediate;
                `RV32_OP_SLTI:  reference_value =
                    {31'd0, $signed(lhs) < $signed(immediate)};
                `RV32_OP_SLTIU: reference_value =
                    {31'd0, lhs < immediate};
                `RV32_OP_XORI:  reference_value = lhs ^ immediate;
                `RV32_OP_ORI:   reference_value = lhs | immediate;
                `RV32_OP_ANDI:  reference_value = lhs & immediate;
                `RV32_OP_SLLI:  reference_value = lhs << immediate[4:0];
                `RV32_OP_SRLI:  reference_value = lhs >> immediate[4:0];
                `RV32_OP_SRAI:  reference_value =
                    $signed(lhs) >>> immediate[4:0];
                `RV32_OP_ADD:   reference_value = lhs + rhs;
                `RV32_OP_SUB:   reference_value = lhs - rhs;
                `RV32_OP_SLL:   reference_value = lhs << rhs[4:0];
                `RV32_OP_SLT:   reference_value =
                    {31'd0, $signed(lhs) < $signed(rhs)};
                `RV32_OP_SLTU:  reference_value = {31'd0, lhs < rhs};
                `RV32_OP_XOR:   reference_value = lhs ^ rhs;
                `RV32_OP_SRL:   reference_value = lhs >> rhs[4:0];
                `RV32_OP_SRA:   reference_value = $signed(lhs) >>> rhs[4:0];
                `RV32_OP_OR:    reference_value = lhs | rhs;
                `RV32_OP_AND:   reference_value = lhs & rhs;
                default:        reference_value = 32'd0;
            endcase
        end
    endfunction

    function reference_control_valid;
        input [`RV32_OP_WIDTH-1:0] op;
        begin
            case (op)
                `RV32_OP_JAL,
                `RV32_OP_JALR,
                `RV32_OP_BEQ,
                `RV32_OP_BNE,
                `RV32_OP_BLT,
                `RV32_OP_BGE,
                `RV32_OP_BLTU,
                `RV32_OP_BGEU: reference_control_valid = 1'b1;
                default: reference_control_valid = 1'b0;
            endcase
        end
    endfunction

    function reference_control_taken;
        input [`RV32_OP_WIDTH-1:0] op;
        input [31:0] lhs;
        input [31:0] rhs;
        begin
            case (op)
                `RV32_OP_JAL:  reference_control_taken = 1'b1;
                `RV32_OP_JALR: reference_control_taken = 1'b1;
                `RV32_OP_BEQ:  reference_control_taken = lhs == rhs;
                `RV32_OP_BNE:  reference_control_taken = lhs != rhs;
                `RV32_OP_BLT:  reference_control_taken =
                    $signed(lhs) < $signed(rhs);
                `RV32_OP_BGE:  reference_control_taken =
                    $signed(lhs) >= $signed(rhs);
                `RV32_OP_BLTU: reference_control_taken = lhs < rhs;
                `RV32_OP_BGEU: reference_control_taken = lhs >= rhs;
                default: reference_control_taken = 1'b0;
            endcase
        end
    endfunction

    function [31:0] reference_next_pc;
        input [`RV32_OP_WIDTH-1:0] op;
        input [31:0] lhs;
        input [31:0] rhs;
        input [31:0] pc;
        input [31:0] immediate;
        reg taken;
        begin
            taken = reference_control_taken(op, lhs, rhs);
            case (op)
                `RV32_OP_JAL: begin
                    reference_next_pc = pc + immediate;
                end
                `RV32_OP_JALR: begin
                    reference_next_pc =
                        (lhs + immediate) & 32'hfffffffe;
                end
                `RV32_OP_BEQ,
                `RV32_OP_BNE,
                `RV32_OP_BLT,
                `RV32_OP_BGE,
                `RV32_OP_BLTU,
                `RV32_OP_BGEU: begin
                    reference_next_pc = taken ?
                        pc + immediate : pc + 32'd4;
                end
                default: reference_next_pc = 32'd0;
            endcase
        end
    endfunction

    task check_response;
        input [`RV32_OP_WIDTH-1:0] op;
        input [31:0] lhs;
        input [31:0] rhs;
        input [31:0] pc;
        input [31:0] immediate;
        input [ROB_TAG_WIDTH-1:0] tag;
        reg [31:0] expected_value;
        reg expected_control_valid;
        reg expected_control_taken;
        reg [31:0] expected_next_pc;
        begin
            expected_value = reference_value(op, lhs, rhs, pc, immediate);
            expected_control_valid = reference_control_valid(op);
            expected_control_taken = reference_control_taken(op, lhs, rhs);
            expected_next_pc = reference_next_pc(op, lhs, rhs, pc, immediate);
            test_count = test_count + 1;
            if ((response_valid_o !== 1'b1) ||
                (response_value_o !== expected_value) ||
                (response_rob_tag_o !== tag) ||
                (response_control_valid_o !== expected_control_valid) ||
                (response_control_taken_o !== expected_control_taken) ||
                (response_next_pc_o !== expected_next_pc)) begin
                error_count = error_count + 1;
                $display("FAIL response op=%0d tag=%0d", op, tag);
                $display("  valid value tag: got %b %08x %0d expected 1 %08x %0d",
                    response_valid_o, response_value_o, response_rob_tag_o,
                    expected_value, tag);
                $display("  control taken next: got %b %b %08x expected %b %b %08x",
                    response_control_valid_o, response_control_taken_o,
                    response_next_pc_o, expected_control_valid,
                    expected_control_taken, expected_next_pc);
            end
        end
    endtask

    task check_empty;
        begin
            test_count = test_count + 1;
            if (response_valid_o !== 1'b0) begin
                error_count = error_count + 1;
                $display("FAIL expected empty response buffer");
            end
        end
    endtask

    task run_case;
        input [`RV32_OP_WIDTH-1:0] op;
        input [31:0] lhs;
        input [31:0] rhs;
        input [31:0] pc;
        input [31:0] immediate;
        input [ROB_TAG_WIDTH-1:0] tag;
        begin
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = op;
            request_lhs_i = lhs;
            request_rhs_i = rhs;
            request_pc_i = pc;
            request_immediate_i = immediate;
            request_rob_tag_i = tag;
            response_ready_i = 1'b0;
            #1;
            test_count = test_count + 1;
            if ((request_ready_o !== 1'b1) ||
                (response_valid_o !== 1'b0)) begin
                error_count = error_count + 1;
                $display("FAIL pre-edge state op=%0d ready=%b valid=%b",
                    op, request_ready_o, response_valid_o);
            end

            @(posedge clk_i);
            #1;
            check_response(op, lhs, rhs, pc, immediate, tag);

            @(negedge clk_i);
            request_valid_i = 1'b0;
            response_ready_i = 1'b1;
            @(posedge clk_i);
            #1;
            check_empty;
            response_ready_i = 1'b0;
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk_i);
            reset_i = 1'b1;
            flush_i = 1'b0;
            request_valid_i = 1'b0;
            response_ready_i = 1'b0;
            #1;
            test_count = test_count + 1;
            if ((request_ready_o !== 1'b0) ||
                (response_valid_o !== 1'b0)) begin
                error_count = error_count + 1;
                $display("FAIL reset did not mask handshake outputs");
            end
            @(posedge clk_i);
            #1;
            check_empty;
            @(negedge clk_i);
            reset_i = 1'b0;
        end
    endtask

    task test_backpressure;
        reg [31:0] held_value;
        reg [ROB_TAG_WIDTH-1:0] held_tag;
        begin
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_ADD;
            request_lhs_i = 32'h12345678;
            request_rhs_i = 32'h11111111;
            request_pc_i = 32'h00001000;
            request_immediate_i = 32'd0;
            request_rob_tag_i = 5'd7;
            response_ready_i = 1'b0;
            @(posedge clk_i);
            #1;
            check_response(`RV32_OP_ADD, 32'h12345678, 32'h11111111,
                32'h00001000, 32'd0, 5'd7);
            held_value = response_value_o;
            held_tag = response_rob_tag_o;

            @(negedge clk_i);
            request_valid_i = 1'b0;
            request_op_i = `RV32_OP_SUB;
            request_lhs_i = 32'hffffffff;
            request_rhs_i = 32'h00000001;
            #1;
            test_count = test_count + 1;
            if ((request_ready_o !== 1'b0) ||
                (response_value_o !== held_value) ||
                (response_rob_tag_o !== held_tag)) begin
                error_count = error_count + 1;
                $display("FAIL backpressure did not hold response");
            end
            @(posedge clk_i);
            #1;
            check_response(`RV32_OP_ADD, 32'h12345678, 32'h11111111,
                32'h00001000, 32'd0, 5'd7);

            @(negedge clk_i);
            response_ready_i = 1'b1;
            @(posedge clk_i);
            #1;
            check_empty;
            response_ready_i = 1'b0;
        end
    endtask

    task test_replacement;
        begin
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_ADD;
            request_lhs_i = 32'd10;
            request_rhs_i = 32'd20;
            request_pc_i = 32'd0;
            request_immediate_i = 32'd0;
            request_rob_tag_i = 5'd8;
            response_ready_i = 1'b0;
            @(posedge clk_i);
            #1;
            check_response(`RV32_OP_ADD, 32'd10, 32'd20,
                32'd0, 32'd0, 5'd8);

            @(negedge clk_i);
            request_op_i = `RV32_OP_SUB;
            request_lhs_i = 32'd50;
            request_rhs_i = 32'd8;
            request_rob_tag_i = 5'd9;
            response_ready_i = 1'b1;
            #1;
            test_count = test_count + 1;
            if (request_ready_o !== 1'b1) begin
                error_count = error_count + 1;
                $display("FAIL replacement request was not ready");
            end
            @(posedge clk_i);
            #1;
            check_response(`RV32_OP_SUB, 32'd50, 32'd8,
                32'd0, 32'd0, 5'd9);

            @(negedge clk_i);
            request_valid_i = 1'b0;
            @(posedge clk_i);
            #1;
            check_empty;
            response_ready_i = 1'b0;
        end
    endtask

    task test_flush;
        begin
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_OR;
            request_lhs_i = 32'h00ff0000;
            request_rhs_i = 32'h0000ff00;
            request_pc_i = 32'd0;
            request_immediate_i = 32'd0;
            request_rob_tag_i = 5'd10;
            response_ready_i = 1'b0;
            @(posedge clk_i);
            #1;
            check_response(`RV32_OP_OR, 32'h00ff0000, 32'h0000ff00,
                32'd0, 32'd0, 5'd10);

            @(negedge clk_i);
            flush_i = 1'b1;
            request_op_i = `RV32_OP_ADD;
            request_lhs_i = 32'd1;
            request_rhs_i = 32'd2;
            request_rob_tag_i = 5'd11;
            #1;
            test_count = test_count + 1;
            if ((request_ready_o !== 1'b0) ||
                (response_valid_o !== 1'b0) ||
                (response_value_o !== 32'd0) ||
                (response_rob_tag_o !== {ROB_TAG_WIDTH{1'b0}})) begin
                error_count = error_count + 1;
                $display("FAIL flush did not mask request and response");
            end
            @(posedge clk_i);
            #1;
            check_empty;

            @(negedge clk_i);
            flush_i = 1'b0;
            request_valid_i = 1'b0;
            #1;
            test_count = test_count + 1;
            if ((request_ready_o !== 1'b1) ||
                (response_valid_o !== 1'b0)) begin
                error_count = error_count + 1;
                $display("FAIL ALU did not recover after flush");
            end
        end
    endtask

    task test_reset_priority;
        begin
            @(negedge clk_i);
            request_valid_i = 1'b1;
            request_op_i = `RV32_OP_XOR;
            request_lhs_i = 32'h55aa55aa;
            request_rhs_i = 32'hffff0000;
            request_pc_i = 32'd0;
            request_immediate_i = 32'd0;
            request_rob_tag_i = 7'd70;
            response_ready_i = 1'b0;
            @(posedge clk_i);
            #1;
            check_response(`RV32_OP_XOR, 32'h55aa55aa, 32'hffff0000,
                32'd0, 32'd0, 7'd70);

            @(negedge clk_i);
            reset_i = 1'b1;
            flush_i = 1'b1;
            request_op_i = `RV32_OP_ADD;
            request_lhs_i = 32'd1;
            request_rhs_i = 32'd2;
            request_rob_tag_i = 7'd71;
            response_ready_i = 1'b1;
            #1;
            test_count = test_count + 1;
            if ((request_ready_o !== 1'b0) ||
                (response_valid_o !== 1'b0) ||
                (response_value_o !== 32'd0)) begin
                error_count = error_count + 1;
                $display("FAIL reset did not take priority over all traffic");
            end
            @(posedge clk_i);
            #1;
            check_empty;

            @(negedge clk_i);
            reset_i = 1'b0;
            flush_i = 1'b0;
            request_valid_i = 1'b0;
            response_ready_i = 1'b0;
            #1;
            test_count = test_count + 1;
            if ((request_ready_o !== 1'b1) ||
                (response_valid_o !== 1'b0)) begin
                error_count = error_count + 1;
                $display("FAIL ALU did not recover after reset");
            end
        end
    endtask

    initial begin
        reset_i = 1'b0;
        flush_i = 1'b0;
        request_valid_i = 1'b0;
        request_op_i = `RV32_OP_INVALID;
        request_lhs_i = 32'd0;
        request_rhs_i = 32'd0;
        request_pc_i = 32'd0;
        request_immediate_i = 32'd0;
        request_rob_tag_i = {ROB_TAG_WIDTH{1'b0}};
        response_ready_i = 1'b0;
        test_count = 0;
        error_count = 0;
        seed = 32'h2468ace1;

        reset_dut;

        run_case(`RV32_OP_LUI, 32'd0, 32'd0,
            32'h00001000, 32'hfffff000, 5'd1);
        run_case(`RV32_OP_AUIPC, 32'd0, 32'd0,
            32'hfffffff0, 32'h00000020, 5'd2);
        run_case(`RV32_OP_JAL, 32'd0, 32'd0,
            32'hfffffffc, 32'h00000008, 5'd3);
        run_case(`RV32_OP_JALR, 32'h00001000, 32'd0,
            32'h00002000, 32'h00000003, 5'd4);

        run_case(`RV32_OP_BEQ, 32'h80000000, 32'h80000000,
            32'h00001000, 32'hfffffffc, 5'd5);
        run_case(`RV32_OP_BEQ, 32'd1, 32'd2,
            32'hfffffffc, 32'd8, 5'd6);
        run_case(`RV32_OP_BNE, 32'd1, 32'd2,
            32'h00001000, 32'd16, 5'd7);
        run_case(`RV32_OP_BNE, 32'd3, 32'd3,
            32'h00001000, 32'd16, 5'd8);
        run_case(`RV32_OP_BLT, 32'h80000000, 32'h7fffffff,
            32'h00001000, 32'd12, 5'd9);
        run_case(`RV32_OP_BLT, 32'h7fffffff, 32'h80000000,
            32'h00001000, 32'd12, 5'd10);
        run_case(`RV32_OP_BGE, 32'hffffffff, 32'h80000000,
            32'h00001000, 32'd12, 5'd11);
        run_case(`RV32_OP_BGE, 32'h80000000, 32'd0,
            32'h00001000, 32'd12, 5'd12);
        run_case(`RV32_OP_BLTU, 32'd0, 32'hffffffff,
            32'h00001000, 32'd12, 5'd13);
        run_case(`RV32_OP_BLTU, 32'hffffffff, 32'd0,
            32'h00001000, 32'd12, 5'd14);
        run_case(`RV32_OP_BGEU, 32'hffffffff, 32'd0,
            32'h00001000, 32'd12, 5'd15);
        run_case(`RV32_OP_BGEU, 32'd0, 32'hffffffff,
            32'h00001000, 32'd12, 5'd16);

        run_case(`RV32_OP_ADDI, 32'hffffffff, 32'd0,
            32'd0, 32'd1, 5'd17);
        run_case(`RV32_OP_SLTI, 32'h80000000, 32'd0,
            32'd0, 32'hffffffff, 5'd18);
        run_case(`RV32_OP_SLTIU, 32'd0, 32'd0,
            32'd0, 32'hffffffff, 5'd19);
        run_case(`RV32_OP_XORI, 32'h55aa55aa, 32'd0,
            32'd0, 32'hffffffff, 5'd20);
        run_case(`RV32_OP_ORI, 32'h550000aa, 32'd0,
            32'd0, 32'h00ffff00, 5'd21);
        run_case(`RV32_OP_ANDI, 32'h55aa55aa, 32'd0,
            32'd0, 32'h0ff00ff0, 5'd22);
        run_case(`RV32_OP_SLLI, 32'd1, 32'd0,
            32'd0, 32'd31, 5'd23);
        run_case(`RV32_OP_SRLI, 32'h80000000, 32'd0,
            32'd0, 32'd31, 5'd24);
        run_case(`RV32_OP_SRAI, 32'h80000000, 32'd0,
            32'd0, 32'd31, 5'd25);

        run_case(`RV32_OP_ADD, 32'hffffffff, 32'd1,
            32'd0, 32'd0, 5'd26);
        run_case(`RV32_OP_SUB, 32'd0, 32'd1,
            32'd0, 32'd0, 5'd27);
        run_case(`RV32_OP_SLL, 32'h00000001, 32'd63,
            32'd0, 32'd0, 5'd28);
        run_case(`RV32_OP_SLT, 32'h80000000, 32'h7fffffff,
            32'd0, 32'd0, 5'd29);
        run_case(`RV32_OP_SLTU, 32'h80000000, 32'h7fffffff,
            32'd0, 32'd0, 5'd30);
        run_case(`RV32_OP_XOR, 32'h55aa55aa, 32'hffff0000,
            32'd0, 32'd0, 5'd31);
        run_case(`RV32_OP_SRL, 32'h80000000, 32'd33,
            32'd0, 32'd0, 5'd0);
        run_case(`RV32_OP_SRA, 32'h80000000, 32'd33,
            32'd0, 32'd0, 5'd1);
        run_case(`RV32_OP_OR, 32'h550000aa, 32'h00ffff00,
            32'd0, 32'd0, 5'd2);
        run_case(`RV32_OP_AND, 32'h55aa55aa, 32'h0ff00ff0,
            32'd0, 32'd0, 5'd3);

        run_case(`RV32_OP_SLL, 32'h87654321, 32'd32,
            32'd0, 32'd0, 5'd4);
        run_case(`RV32_OP_SRL, 32'h87654321, 32'd32,
            32'd0, 32'd0, 5'd5);
        run_case(`RV32_OP_SRA, 32'h87654321, 32'hffffffff,
            32'd0, 32'd0, 5'd6);
        run_case(`RV32_OP_SLLI, 32'h87654321, 32'd0,
            32'd0, 32'd32, 5'd7);
        run_case(`RV32_OP_SRLI, 32'h87654321, 32'd0,
            32'd0, 32'd33, 5'd8);
        run_case(`RV32_OP_SRAI, 32'h87654321, 32'd0,
            32'd0, 32'hffffffff, 5'd9);

        test_backpressure;
        test_replacement;
        test_flush;
        test_reset_priority;

        for (i = 0; i < 512; i = i + 1) begin
            case (i % 29)
                0:  random_op = `RV32_OP_LUI;
                1:  random_op = `RV32_OP_AUIPC;
                2:  random_op = `RV32_OP_JAL;
                3:  random_op = `RV32_OP_JALR;
                4:  random_op = `RV32_OP_BEQ;
                5:  random_op = `RV32_OP_BNE;
                6:  random_op = `RV32_OP_BLT;
                7:  random_op = `RV32_OP_BGE;
                8:  random_op = `RV32_OP_BLTU;
                9:  random_op = `RV32_OP_BGEU;
                10: random_op = `RV32_OP_ADDI;
                11: random_op = `RV32_OP_SLTI;
                12: random_op = `RV32_OP_SLTIU;
                13: random_op = `RV32_OP_XORI;
                14: random_op = `RV32_OP_ORI;
                15: random_op = `RV32_OP_ANDI;
                16: random_op = `RV32_OP_SLLI;
                17: random_op = `RV32_OP_SRLI;
                18: random_op = `RV32_OP_SRAI;
                19: random_op = `RV32_OP_ADD;
                20: random_op = `RV32_OP_SUB;
                21: random_op = `RV32_OP_SLL;
                22: random_op = `RV32_OP_SLT;
                23: random_op = `RV32_OP_SLTU;
                24: random_op = `RV32_OP_XOR;
                25: random_op = `RV32_OP_SRL;
                26: random_op = `RV32_OP_SRA;
                27: random_op = `RV32_OP_OR;
                default: random_op = `RV32_OP_AND;
            endcase
            random_lhs = $random(seed);
            random_rhs = $random(seed);
            random_pc = $random(seed);
            random_immediate = $random(seed);
            run_case(random_op, random_lhs, random_rhs,
                random_pc, random_immediate, i[ROB_TAG_WIDTH-1:0]);
        end

        reset_dut;

        if (error_count == 0) begin
            $display("PASS rv32i_alu (%0d checks)", test_count);
            $finish;
        end

        $display("FAIL rv32i_alu: %0d of %0d checks failed",
            error_count, test_count);
        $stop;
    end

endmodule
