OUTPUT_ARCH(riscv)
ENTRY(_start)

/* 回归测试 t_noperm 专用：和 user/linker.ld 一样，只是数据段的权限是 FLAGS(0)（R/W/X 全无）。
   内核的 ELF 加载器必须拒绝这样的段，见 src/proc.zig 的 loadSegment 和 docs/process.md。 */
PHDRS
{
    text PT_LOAD FLAGS(5);   /* R + X */
    rodata PT_LOAD FLAGS(4); /* R */
    data PT_LOAD FLAGS(0);   /* 故意不给任何权限 */
}

SECTIONS
{
    . = 0x40000000;

    .text : {
        *(.text .text.*)
    } :text

    .rodata : ALIGN(4K) {
        *(.srodata .srodata.*)
        *(.rodata .rodata.*)
    } :rodata

    .data : ALIGN(4K) {
        *(.sdata .sdata.*)
        *(.data .data.*)
    } :data

    .bss : {
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
    } :data
}
