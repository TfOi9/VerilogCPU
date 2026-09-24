/* Exercise dependencies, M extension, LSQ forwarding, and recovery. */
int main(void)
{
    int result;
    volatile int storage = 0;

    __asm__ volatile (
        "li t0, 7\n"
        "addi t0, t0, 5\n"
        "addi t0, t0, 3\n"
        "li t1, 6\n"
        "mul t2, t0, t1\n"
        "li t3, 9\n"
        "div t4, t2, t3\n"
        "sw t4, 0(%1)\n"
        "lw %0, 0(%1)\n"
        "li t5, 1\n"
        "bnez t5, 1f\n"
        "lui t6, 0x80000\n"
        "sw zero, 0(t6)\n"
        "1:\n"
        "addi %0, %0, 32\n"
        : "=&r" (result)
        : "r" (&storage)
        : "t0", "t1", "t2", "t3", "t4", "t5", "t6", "memory"
    );

    return result;
}
