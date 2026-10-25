OUTPUT_ARCH(riscv)
ENTRY(_start)

/* 用户程序链接到用户地址空间的起点（src/vm.zig 的 user_base）。
   每种权限一个段，段的起点按页对齐，内核加载时按段给每一页设置 R/W/X 权限（见 src/proc.zig）。 */
PHDRS
{
    text PT_LOAD FLAGS(5);   /* R + X */
    rodata PT_LOAD FLAGS(4); /* R */
    data PT_LOAD FLAGS(6);   /* R + W */
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
