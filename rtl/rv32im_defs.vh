`ifndef RV32IM_DEFS_VH
`define RV32IM_DEFS_VH

`define RV32_OP_WIDTH 6

`define RV32_OP_INVALID  6'd0
`define RV32_OP_LUI      6'd1
`define RV32_OP_AUIPC    6'd2
`define RV32_OP_JAL      6'd3
`define RV32_OP_JALR     6'd4
`define RV32_OP_BEQ      6'd5
`define RV32_OP_BNE      6'd6
`define RV32_OP_BLT      6'd7
`define RV32_OP_BGE      6'd8
`define RV32_OP_BLTU     6'd9
`define RV32_OP_BGEU     6'd10
`define RV32_OP_LB       6'd11
`define RV32_OP_LH       6'd12
`define RV32_OP_LW       6'd13
`define RV32_OP_LBU      6'd14
`define RV32_OP_LHU      6'd15
`define RV32_OP_SB       6'd16
`define RV32_OP_SH       6'd17
`define RV32_OP_SW       6'd18
`define RV32_OP_ADDI     6'd19
`define RV32_OP_SLTI     6'd20
`define RV32_OP_SLTIU    6'd21
`define RV32_OP_XORI     6'd22
`define RV32_OP_ORI      6'd23
`define RV32_OP_ANDI     6'd24
`define RV32_OP_SLLI     6'd25
`define RV32_OP_SRLI     6'd26
`define RV32_OP_SRAI     6'd27
`define RV32_OP_ADD      6'd28
`define RV32_OP_SUB      6'd29
`define RV32_OP_SLL      6'd30
`define RV32_OP_SLT      6'd31
`define RV32_OP_SLTU     6'd32
`define RV32_OP_XOR      6'd33
`define RV32_OP_SRL      6'd34
`define RV32_OP_SRA      6'd35
`define RV32_OP_OR       6'd36
`define RV32_OP_AND      6'd37
`define RV32_OP_FENCE    6'd38
`define RV32_OP_ECALL    6'd39
`define RV32_OP_EBREAK   6'd40
`define RV32_OP_MUL      6'd41
`define RV32_OP_MULH     6'd42
`define RV32_OP_MULHSU   6'd43
`define RV32_OP_MULHU    6'd44
`define RV32_OP_DIV      6'd45
`define RV32_OP_DIVU     6'd46
`define RV32_OP_REM      6'd47
`define RV32_OP_REMU     6'd48
`define RV32_OP_HALT     6'd49

`define RV32_CLASS_WIDTH 4

`define RV32_CLASS_INVALID 4'd0
`define RV32_CLASS_INT     4'd1
`define RV32_CLASS_LOAD    4'd2
`define RV32_CLASS_STORE   4'd3
`define RV32_CLASS_BRANCH  4'd4
`define RV32_CLASS_JUMP    4'd5
`define RV32_CLASS_MUL     4'd6
`define RV32_CLASS_DIV     4'd7
`define RV32_CLASS_SYSTEM  4'd8
`define RV32_CLASS_HALT    4'd9

`define RV32_MEMORY_WIDTH 2

`define RV32_MEMORY_BYTE 2'd0
`define RV32_MEMORY_HALF 2'd1
`define RV32_MEMORY_WORD 2'd2
`define RV32_MEMORY_NONE 2'd3

`endif
