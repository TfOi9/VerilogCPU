# Bare-metal startup for the Verilog CPU image format.
#
# The CPU starts at _start (address zero).  After main returns, its result in
# a0 is written once to the official exit MMIO address.

    .option norelax
    .section .rom, "ax", @progbits
    .align 2
    .globl _start
    .type _start, @function
_start:
    lui     sp, %hi(__stack_top)
    addi    sp, sp, %lo(__stack_top)

    lui     t0, %hi(__bss_start)
    addi    t0, t0, %lo(__bss_start)
    lui     t1, %hi(__bss_end)
    addi    t1, t1, %lo(__bss_end)
.Lbss_loop:
    beq     t0, t1, .Lcall_main
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, .Lbss_loop

.Lcall_main:
    jal     ra, main
    lui     t0, 0x80000
    sw      a0, 0(t0)
.Lhang:
    j       .Lhang
    .size _start, .-_start
