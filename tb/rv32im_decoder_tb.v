`timescale 1ns/1ps
`include "rv32im_defs.vh"

module rv32im_decoder_tb;

    reg [31:0] instruction_i;

    wire legal_o;
    wire [`RV32_OP_WIDTH-1:0] op_o;
    wire [`RV32_CLASS_WIDTH-1:0] class_o;
    wire [4:0] rd_o;
    wire [4:0] rs1_o;
    wire [4:0] rs2_o;
    wire uses_rs1_o;
    wire uses_rs2_o;
    wire writes_rd_o;
    wire [31:0] immediate_o;
    wire [`RV32_MEMORY_WIDTH-1:0] memory_width_o;
    wire load_unsigned_o;
    wire serialize_o;

    integer test_count;
    integer error_count;
    integer seed;
    integer i;
    reg [31:0] random_word;
    reg [12:0] random_b_imm;
    reg [20:0] random_j_imm;

    rv32im_decoder dut (
        .instruction_i(instruction_i),
        .legal_o(legal_o),
        .op_o(op_o),
        .class_o(class_o),
        .rd_o(rd_o),
        .rs1_o(rs1_o),
        .rs2_o(rs2_o),
        .uses_rs1_o(uses_rs1_o),
        .uses_rs2_o(uses_rs2_o),
        .writes_rd_o(writes_rd_o),
        .immediate_o(immediate_o),
        .memory_width_o(memory_width_o),
        .load_unsigned_o(load_unsigned_o),
        .serialize_o(serialize_o)
    );

    function [31:0] encode_r;
        input [6:0] funct7_value;
        input [4:0] rs2_value;
        input [4:0] rs1_value;
        input [2:0] funct3_value;
        input [4:0] rd_value;
        input [6:0] opcode_value;
        begin
            encode_r = {
                funct7_value, rs2_value, rs1_value,
                funct3_value, rd_value, opcode_value
            };
        end
    endfunction

    function [31:0] encode_i;
        input [11:0] immediate_value;
        input [4:0] rs1_value;
        input [2:0] funct3_value;
        input [4:0] rd_value;
        input [6:0] opcode_value;
        begin
            encode_i = {
                immediate_value, rs1_value,
                funct3_value, rd_value, opcode_value
            };
        end
    endfunction

    function [31:0] encode_s;
        input [11:0] immediate_value;
        input [4:0] rs2_value;
        input [4:0] rs1_value;
        input [2:0] funct3_value;
        begin
            encode_s = {
                immediate_value[11:5], rs2_value, rs1_value,
                funct3_value, immediate_value[4:0], 7'b0100011
            };
        end
    endfunction

    function [31:0] encode_b;
        input [12:0] immediate_value;
        input [4:0] rs2_value;
        input [4:0] rs1_value;
        input [2:0] funct3_value;
        begin
            encode_b = {
                immediate_value[12], immediate_value[10:5],
                rs2_value, rs1_value, funct3_value,
                immediate_value[4:1], immediate_value[11],
                7'b1100011
            };
        end
    endfunction

    function [31:0] encode_u;
        input [19:0] immediate_value;
        input [4:0] rd_value;
        input [6:0] opcode_value;
        begin
            encode_u = {immediate_value, rd_value, opcode_value};
        end
    endfunction

    function [31:0] encode_j;
        input [20:0] immediate_value;
        input [4:0] rd_value;
        begin
            encode_j = {
                immediate_value[20], immediate_value[10:1],
                immediate_value[11], immediate_value[19:12],
                rd_value, 7'b1101111
            };
        end
    endfunction

    task check_decode;
        input [31:0] instruction;
        input [`RV32_OP_WIDTH-1:0] expected_op;
        input [`RV32_CLASS_WIDTH-1:0] expected_class;
        input [31:0] expected_immediate;
        input [4:0] expected_rd;
        input [4:0] expected_rs1;
        input [4:0] expected_rs2;
        input expected_uses_rs1;
        input expected_uses_rs2;
        input expected_writes_rd;
        input [`RV32_MEMORY_WIDTH-1:0] expected_memory_width;
        input expected_load_unsigned;
        input expected_serialize;
        input expected_legal;
        begin
            instruction_i = instruction;
            #1;
            test_count = test_count + 1;
            if ((legal_o !== expected_legal) ||
                (op_o !== expected_op) ||
                (class_o !== expected_class) ||
                (rd_o !== expected_rd) ||
                (rs1_o !== expected_rs1) ||
                (rs2_o !== expected_rs2) ||
                (uses_rs1_o !== expected_uses_rs1) ||
                (uses_rs2_o !== expected_uses_rs2) ||
                (writes_rd_o !== expected_writes_rd) ||
                (immediate_o !== expected_immediate) ||
                (memory_width_o !== expected_memory_width) ||
                (load_unsigned_o !== expected_load_unsigned) ||
                (serialize_o !== expected_serialize)) begin
                error_count = error_count + 1;
                $display("FAIL instruction=%08x", instruction);
                $display("  legal op class: got %b %0d %0d expected %b %0d %0d",
                    legal_o, op_o, class_o,
                    expected_legal, expected_op, expected_class);
                $display("  rd rs1 rs2 use1 use2 write: got %0d %0d %0d %b %b %b expected %0d %0d %0d %b %b %b",
                    rd_o, rs1_o, rs2_o,
                    uses_rs1_o, uses_rs2_o, writes_rd_o,
                    expected_rd, expected_rs1, expected_rs2,
                    expected_uses_rs1, expected_uses_rs2,
                    expected_writes_rd);
                $display("  imm width unsigned serialize: got %08x %0d %b %b expected %08x %0d %b %b",
                    immediate_o, memory_width_o,
                    load_unsigned_o, serialize_o,
                    expected_immediate, expected_memory_width,
                    expected_load_unsigned, expected_serialize);
            end
        end
    endtask

    task check_invalid;
        input [31:0] instruction;
        begin
            check_decode(
                instruction,
                `RV32_OP_INVALID, `RV32_CLASS_INVALID, 32'd0,
                5'd0, 5'd0, 5'd0,
                1'b0, 1'b0, 1'b0,
                `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b0
            );
        end
    endtask

    task check_r_operation;
        input [6:0] funct7_value;
        input [2:0] funct3_value;
        input [`RV32_OP_WIDTH-1:0] expected_op;
        input [`RV32_CLASS_WIDTH-1:0] expected_class;
        begin
            check_decode(
                encode_r(funct7_value, 5'd5, 5'd4,
                    funct3_value, 5'd3, 7'b0110011),
                expected_op, expected_class, 32'd0,
                5'd3, 5'd4, 5'd5,
                1'b1, 1'b1, 1'b1,
                `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
            );
        end
    endtask

    task check_i_operation;
        input [11:0] immediate_value;
        input [2:0] funct3_value;
        input [`RV32_OP_WIDTH-1:0] expected_op;
        input [31:0] expected_immediate;
        begin
            check_decode(
                encode_i(immediate_value, 5'd4,
                    funct3_value, 5'd3, 7'b0010011),
                expected_op, `RV32_CLASS_INT, expected_immediate,
                5'd3, 5'd4, 5'd0,
                1'b1, 1'b0, 1'b1,
                `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
            );
        end
    endtask

    task check_load;
        input [2:0] funct3_value;
        input [`RV32_OP_WIDTH-1:0] expected_op;
        input [`RV32_MEMORY_WIDTH-1:0] expected_width;
        input expected_unsigned;
        begin
            check_decode(
                encode_i(12'h805, 5'd4,
                    funct3_value, 5'd3, 7'b0000011),
                expected_op, `RV32_CLASS_LOAD, 32'hfffff805,
                5'd3, 5'd4, 5'd0,
                1'b1, 1'b0, 1'b1,
                expected_width, expected_unsigned, 1'b0, 1'b1
            );
        end
    endtask

    task check_store;
        input [2:0] funct3_value;
        input [`RV32_OP_WIDTH-1:0] expected_op;
        input [`RV32_MEMORY_WIDTH-1:0] expected_width;
        begin
            check_decode(
                encode_s(12'h923, 5'd5, 5'd4, funct3_value),
                expected_op, `RV32_CLASS_STORE, 32'hfffff923,
                5'd0, 5'd4, 5'd5,
                1'b1, 1'b1, 1'b0,
                expected_width, 1'b0, 1'b0, 1'b1
            );
        end
    endtask

    task check_branch;
        input [2:0] funct3_value;
        input [`RV32_OP_WIDTH-1:0] expected_op;
        begin
            check_decode(
                encode_b(13'h1ffc, 5'd5, 5'd4, funct3_value),
                expected_op, `RV32_CLASS_BRANCH, 32'hfffffffc,
                5'd0, 5'd4, 5'd5,
                1'b1, 1'b1, 1'b0,
                `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
            );
        end
    endtask

    initial begin
        instruction_i = 32'd0;
        test_count = 0;
        error_count = 0;
        seed = 32'h13579bdf;

        check_decode(
            encode_u(20'habcde, 5'd3, 7'b0110111),
            `RV32_OP_LUI, `RV32_CLASS_INT, 32'habcde000,
            5'd3, 5'd0, 5'd0, 1'b0, 1'b0, 1'b1,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_u(20'h80000, 5'd3, 7'b0010111),
            `RV32_OP_AUIPC, `RV32_CLASS_INT, 32'h80000000,
            5'd3, 5'd0, 5'd0, 1'b0, 1'b0, 1'b1,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_j(21'h1ffffc, 5'd3),
            `RV32_OP_JAL, `RV32_CLASS_JUMP, 32'hfffffffc,
            5'd3, 5'd0, 5'd0, 1'b0, 1'b0, 1'b1,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_i(12'h801, 5'd4, 3'b000, 5'd3, 7'b1100111),
            `RV32_OP_JALR, `RV32_CLASS_JUMP, 32'hfffff801,
            5'd3, 5'd4, 5'd0, 1'b1, 1'b0, 1'b1,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );

        check_branch(3'b000, `RV32_OP_BEQ);
        check_branch(3'b001, `RV32_OP_BNE);
        check_branch(3'b100, `RV32_OP_BLT);
        check_branch(3'b101, `RV32_OP_BGE);
        check_branch(3'b110, `RV32_OP_BLTU);
        check_branch(3'b111, `RV32_OP_BGEU);

        check_load(3'b000, `RV32_OP_LB, `RV32_MEMORY_BYTE, 1'b0);
        check_load(3'b001, `RV32_OP_LH, `RV32_MEMORY_HALF, 1'b0);
        check_load(3'b010, `RV32_OP_LW, `RV32_MEMORY_WORD, 1'b0);
        check_load(3'b100, `RV32_OP_LBU, `RV32_MEMORY_BYTE, 1'b1);
        check_load(3'b101, `RV32_OP_LHU, `RV32_MEMORY_HALF, 1'b1);

        check_store(3'b000, `RV32_OP_SB, `RV32_MEMORY_BYTE);
        check_store(3'b001, `RV32_OP_SH, `RV32_MEMORY_HALF);
        check_store(3'b010, `RV32_OP_SW, `RV32_MEMORY_WORD);

        check_i_operation(12'h801, 3'b000, `RV32_OP_ADDI, 32'hfffff801);
        check_i_operation(12'h801, 3'b010, `RV32_OP_SLTI, 32'hfffff801);
        check_i_operation(12'h801, 3'b011, `RV32_OP_SLTIU, 32'hfffff801);
        check_i_operation(12'h801, 3'b100, `RV32_OP_XORI, 32'hfffff801);
        check_i_operation(12'h801, 3'b110, `RV32_OP_ORI, 32'hfffff801);
        check_i_operation(12'h801, 3'b111, `RV32_OP_ANDI, 32'hfffff801);
        check_i_operation(12'h01f, 3'b001, `RV32_OP_SLLI, 32'd31);
        check_i_operation(12'h01f, 3'b101, `RV32_OP_SRLI, 32'd31);
        check_i_operation(12'h41f, 3'b101, `RV32_OP_SRAI, 32'd31);

        check_r_operation(7'b0000000, 3'b000, `RV32_OP_ADD, `RV32_CLASS_INT);
        check_r_operation(7'b0100000, 3'b000, `RV32_OP_SUB, `RV32_CLASS_INT);
        check_r_operation(7'b0000000, 3'b001, `RV32_OP_SLL, `RV32_CLASS_INT);
        check_r_operation(7'b0000000, 3'b010, `RV32_OP_SLT, `RV32_CLASS_INT);
        check_r_operation(7'b0000000, 3'b011, `RV32_OP_SLTU, `RV32_CLASS_INT);
        check_r_operation(7'b0000000, 3'b100, `RV32_OP_XOR, `RV32_CLASS_INT);
        check_r_operation(7'b0000000, 3'b101, `RV32_OP_SRL, `RV32_CLASS_INT);
        check_r_operation(7'b0100000, 3'b101, `RV32_OP_SRA, `RV32_CLASS_INT);
        check_r_operation(7'b0000000, 3'b110, `RV32_OP_OR, `RV32_CLASS_INT);
        check_r_operation(7'b0000000, 3'b111, `RV32_OP_AND, `RV32_CLASS_INT);

        check_decode(
            {4'hf, 4'ha, 4'h5, 5'd17, 3'b000, 5'd23, 7'b0001111},
            `RV32_OP_FENCE, `RV32_CLASS_SYSTEM, 32'd0,
            5'd0, 5'd0, 5'd0, 1'b0, 1'b0, 1'b0,
            `RV32_MEMORY_NONE, 1'b0, 1'b1, 1'b1
        );
        check_decode(
            32'h00000073,
            `RV32_OP_ECALL, `RV32_CLASS_SYSTEM, 32'd0,
            5'd0, 5'd0, 5'd0, 1'b0, 1'b0, 1'b0,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            32'h00100073,
            `RV32_OP_EBREAK, `RV32_CLASS_SYSTEM, 32'd0,
            5'd0, 5'd0, 5'd0, 1'b0, 1'b0, 1'b0,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );

        check_r_operation(7'b0000001, 3'b000, `RV32_OP_MUL, `RV32_CLASS_MUL);
        check_r_operation(7'b0000001, 3'b001, `RV32_OP_MULH, `RV32_CLASS_MUL);
        check_r_operation(7'b0000001, 3'b010, `RV32_OP_MULHSU, `RV32_CLASS_MUL);
        check_r_operation(7'b0000001, 3'b011, `RV32_OP_MULHU, `RV32_CLASS_MUL);
        check_r_operation(7'b0000001, 3'b100, `RV32_OP_DIV, `RV32_CLASS_DIV);
        check_r_operation(7'b0000001, 3'b101, `RV32_OP_DIVU, `RV32_CLASS_DIV);
        check_r_operation(7'b0000001, 3'b110, `RV32_OP_REM, `RV32_CLASS_DIV);
        check_r_operation(7'b0000001, 3'b111, `RV32_OP_REMU, `RV32_CLASS_DIV);

        check_decode(
            32'h0ff00513,
            `RV32_OP_HALT, `RV32_CLASS_HALT, 32'd0,
            5'd0, 5'd0, 5'd0, 1'b0, 1'b0, 1'b0,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            32'h0fe00513,
            `RV32_OP_ADDI, `RV32_CLASS_INT, 32'd254,
            5'd10, 5'd0, 5'd0, 1'b1, 1'b0, 1'b1,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            32'h10000513,
            `RV32_OP_ADDI, `RV32_CLASS_INT, 32'd256,
            5'd10, 5'd0, 5'd0, 1'b1, 1'b0, 1'b1,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );

        check_decode(
            encode_i(12'd0, 5'd0, 3'b000, 5'd0, 7'b0010011),
            `RV32_OP_ADDI, `RV32_CLASS_INT, 32'd0,
            5'd0, 5'd0, 5'd0, 1'b1, 1'b0, 1'b0,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_r(7'd0, 5'd5, 5'd4, 3'b000, 5'd0, 7'b0110011),
            `RV32_OP_ADD, `RV32_CLASS_INT, 32'd0,
            5'd0, 5'd4, 5'd5, 1'b1, 1'b1, 1'b0,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_i(12'd0, 5'd4, 3'b010, 5'd0, 7'b0000011),
            `RV32_OP_LW, `RV32_CLASS_LOAD, 32'd0,
            5'd0, 5'd4, 5'd0, 1'b1, 1'b0, 1'b0,
            `RV32_MEMORY_WORD, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_j(21'd4, 5'd0),
            `RV32_OP_JAL, `RV32_CLASS_JUMP, 32'd4,
            5'd0, 5'd0, 5'd0, 1'b0, 1'b0, 1'b0,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_r(7'b0000001, 5'd5, 5'd4, 3'b000, 5'd0, 7'b0110011),
            `RV32_OP_MUL, `RV32_CLASS_MUL, 32'd0,
            5'd0, 5'd4, 5'd5, 1'b1, 1'b1, 1'b0,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );

        check_i_operation(12'h7ff, 3'b000, `RV32_OP_ADDI, 32'h000007ff);
        check_i_operation(12'h800, 3'b000, `RV32_OP_ADDI, 32'hfffff800);
        check_decode(
            encode_s(12'h7ff, 5'd5, 5'd4, 3'b010),
            `RV32_OP_SW, `RV32_CLASS_STORE, 32'h000007ff,
            5'd0, 5'd4, 5'd5, 1'b1, 1'b1, 1'b0,
            `RV32_MEMORY_WORD, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_s(12'h800, 5'd5, 5'd4, 3'b010),
            `RV32_OP_SW, `RV32_CLASS_STORE, 32'hfffff800,
            5'd0, 5'd4, 5'd5, 1'b1, 1'b1, 1'b0,
            `RV32_MEMORY_WORD, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_b(13'h0ffe, 5'd5, 5'd4, 3'b000),
            `RV32_OP_BEQ, `RV32_CLASS_BRANCH, 32'h00000ffe,
            5'd0, 5'd4, 5'd5, 1'b1, 1'b1, 1'b0,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_b(13'h1000, 5'd5, 5'd4, 3'b000),
            `RV32_OP_BEQ, `RV32_CLASS_BRANCH, 32'hfffff000,
            5'd0, 5'd4, 5'd5, 1'b1, 1'b1, 1'b0,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_j(21'h0ffffe, 5'd3),
            `RV32_OP_JAL, `RV32_CLASS_JUMP, 32'h000ffffe,
            5'd3, 5'd0, 5'd0, 1'b0, 1'b0, 1'b1,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_j(21'h100000, 5'd3),
            `RV32_OP_JAL, `RV32_CLASS_JUMP, 32'hfff00000,
            5'd3, 5'd0, 5'd0, 1'b0, 1'b0, 1'b1,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_decode(
            encode_u(20'hfffff, 5'd3, 7'b0110111),
            `RV32_OP_LUI, `RV32_CLASS_INT, 32'hfffff000,
            5'd3, 5'd0, 5'd0, 1'b0, 1'b0, 1'b1,
            `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
        );
        check_i_operation(12'h000, 3'b001, `RV32_OP_SLLI, 32'd0);

        check_invalid(32'h00000000);
        check_invalid(32'h00000001);
        check_invalid(32'hffffffff);
        check_invalid(encode_r(7'b0000010, 5'd5, 5'd4, 3'b000, 5'd3, 7'b0110011));
        check_invalid(encode_r(7'b0100000, 5'd5, 5'd4, 3'b001, 5'd3, 7'b0110011));
        check_invalid(encode_i(12'h020, 5'd4, 3'b001, 5'd3, 7'b0010011));
        check_invalid(encode_i(12'h201, 5'd4, 3'b101, 5'd3, 7'b0010011));
        check_invalid(encode_i(12'd0, 5'd4, 3'b011, 5'd3, 7'b0000011));
        check_invalid(encode_s(12'd0, 5'd5, 5'd4, 3'b011));
        check_invalid(encode_b(13'd4, 5'd5, 5'd4, 3'b010));
        check_invalid(encode_b(13'd4, 5'd5, 5'd4, 3'b011));
        check_invalid(encode_i(12'd0, 5'd4, 3'b001, 5'd3, 7'b1100111));
        check_invalid(encode_i(12'd0, 5'd0, 3'b001, 5'd0, 7'b0001111));
        check_invalid(32'h00200073);
        check_invalid(32'h300110f3);
        check_invalid(32'h0000001b);
        check_invalid(32'h0000202f);

        for (i = 0; i < 64; i = i + 1) begin
            random_word = $random(seed);
            random_b_imm = {random_word[12:1], 1'b0};
            random_j_imm = {random_word[20:1], 1'b0};

            check_decode(
                encode_r(7'd0, random_word[14:10], random_word[9:5],
                    3'b000, random_word[4:0], 7'b0110011),
                `RV32_OP_ADD, `RV32_CLASS_INT, 32'd0,
                random_word[4:0], random_word[9:5], random_word[14:10],
                1'b1, 1'b1, random_word[4:0] != 5'd0,
                `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
            );
            check_decode(
                encode_i(random_word[31:20], random_word[9:5],
                    3'b000, random_word[4:0], 7'b0010011),
                `RV32_OP_ADDI, `RV32_CLASS_INT,
                {{20{random_word[31]}}, random_word[31:20]},
                random_word[4:0], random_word[9:5], 5'd0,
                1'b1, 1'b0, random_word[4:0] != 5'd0,
                `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
            );
            check_decode(
                encode_s(random_word[31:20], random_word[14:10],
                    random_word[9:5], 3'b010),
                `RV32_OP_SW, `RV32_CLASS_STORE,
                {{20{random_word[31]}}, random_word[31:20]},
                5'd0, random_word[9:5], random_word[14:10],
                1'b1, 1'b1, 1'b0,
                `RV32_MEMORY_WORD, 1'b0, 1'b0, 1'b1
            );
            check_decode(
                encode_b(random_b_imm, random_word[14:10],
                    random_word[9:5], 3'b000),
                `RV32_OP_BEQ, `RV32_CLASS_BRANCH,
                {{19{random_b_imm[12]}}, random_b_imm},
                5'd0, random_word[9:5], random_word[14:10],
                1'b1, 1'b1, 1'b0,
                `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
            );
            check_decode(
                encode_u(random_word[19:0], random_word[4:0], 7'b0110111),
                `RV32_OP_LUI, `RV32_CLASS_INT,
                {random_word[19:0], 12'd0},
                random_word[4:0], 5'd0, 5'd0,
                1'b0, 1'b0, random_word[4:0] != 5'd0,
                `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
            );
            check_decode(
                encode_j(random_j_imm, random_word[4:0]),
                `RV32_OP_JAL, `RV32_CLASS_JUMP,
                {{11{random_j_imm[20]}}, random_j_imm},
                random_word[4:0], 5'd0, 5'd0,
                1'b0, 1'b0, random_word[4:0] != 5'd0,
                `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
            );
            check_decode(
                encode_r(7'b0000001, random_word[14:10], random_word[9:5],
                    3'b000, random_word[4:0], 7'b0110011),
                `RV32_OP_MUL, `RV32_CLASS_MUL, 32'd0,
                random_word[4:0], random_word[9:5], random_word[14:10],
                1'b1, 1'b1, random_word[4:0] != 5'd0,
                `RV32_MEMORY_NONE, 1'b0, 1'b0, 1'b1
            );
        end

        if (error_count == 0) begin
            $display("PASS rv32im_decoder (%0d checks)", test_count);
            $finish;
        end

        $display("FAIL rv32im_decoder: %0d of %0d checks failed",
            error_count, test_count);
        $stop;
    end

endmodule
