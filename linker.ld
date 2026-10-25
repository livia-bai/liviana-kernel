OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    /* OpenSBI (fw_dynamic) 约定：内核从 0x80200000 开始执行 */
    . = 0x80200000;

    .text : {
        /* _start 必须排在最前面，也就是正好在 0x80200000 */
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    .rodata : ALIGN(16) {
        *(.srodata .srodata.*)
        *(.rodata .rodata.*)
    }

    .data : ALIGN(16) {
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
    }
}
