OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    /* OpenSBI (fw_dynamic) 约定：内核从 0x80200000 开始执行 */
    . = 0x80200000;
    __text_start = .;

    .text : {
        /* _start 必须排在最前面，也就是正好在 0x80200000 */
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    /* 后面各段都从新的一页开始，这样每一页只属于一个段，
       开分页时可以分别设置权限：代码 R-X、只读数据 R--、其余 RW-（见 src/vm.zig） */
    .rodata : ALIGN(4K) {
        __rodata_start = .;
        *(.srodata .srodata.*)
        *(.rodata .rodata.*)
    }

    .data : ALIGN(4K) {
        __data_start = .;
        *(.sdata .sdata.*)
        *(.data .data.*)
    }

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;

        /* 内核栈：64 KiB，紧跟在 .bss 后面；栈向下增长，所以 sp 从 __stack_top 开始 */
        . = ALIGN(16);
        . += 64K;
        __stack_top = .;

        /* 内核镜像到此为止，之后的内存交给页分配器 */
        . = ALIGN(4K);
        __kernel_end = .;
    }
}
