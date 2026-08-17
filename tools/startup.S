# Bare-metal startup for the Verilog CPU image format.
#
# The CPU starts at _start (address zero).  The instruction that loads 255
# into a0 is the simulator HALT marker; it must remain immediately after the
# call to main so the return value in a0 is observed before the marker runs.

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
.Lhalt:
    li      a0, 255
    j       .Lhalt
    .size _start, .-_start
