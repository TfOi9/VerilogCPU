/* Linker layout for a 1 MiB, byte-addressed RV32 memory. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    rom (rx)  : ORIGIN = 0x00000000, LENGTH = 0x00001000
    ram (rwx) : ORIGIN = 0x00001000, LENGTH = 0x000FF000
}

SECTIONS
{
    . = ORIGIN(rom);
    .rom : ALIGN(4)
    {
        KEEP(*(.rom))
    } > rom
    ASSERT(SIZEOF(.rom) <= LENGTH(rom), "startup ROM exceeds 4 KiB")

    . = ORIGIN(ram);
    .text : ALIGN(4)
    {
        *(.text.unlikely .text.*_unlikely .text.unlikely.*)
        *(.text.exit .text.exit.*)
        *(.text.startup .text.startup.*)
        *(.text.hot .text.hot.*)
        *(.text .stub .text.* .gnu.linkonce.t.*)
    } > ram

    .rodata : ALIGN(4)
    {
        *(.rdata)
        *(.rodata .rodata.* .gnu.linkonce.r.*)
        *(.srodata.cst16)
        *(.srodata.cst8)
        *(.srodata.cst4)
        *(.srodata.cst2)
        *(.srodata .srodata.*)
    } > ram

    .data : ALIGN(4)
    {
        *(.data .data.* .gnu.linkonce.d.*)
        *(.sdata .sdata.* .gnu.linkonce.s.*)
    } > ram

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.sbss .sbss.* .gnu.linkonce.sb.*)
        *(.scommon)
        *(.dynbss)
        *(.bss .bss.* .gnu.linkonce.b.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > ram

    __stack_top = ORIGIN(ram) + LENGTH(ram);
    _end = .;
    ASSERT(__stack_top == 0x00100000, "stack top must match 1 MiB memory")
    ASSERT(_end <= __stack_top, "linked image exceeds 1 MiB memory")

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.riscv.attributes)
        *(.debug*)
    }
}
