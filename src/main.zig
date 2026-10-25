//! 内核入口。OpenSBI 以 S 模式跳到 _start，此时 a0 = 当前 hart 编号，a1 = 设备树（DTB）地址；
//! 分页关闭（虚拟地址 = 物理地址），中断关闭，还没有栈。

const std = @import("std");
const riscv = @import("riscv.zig");
const sbi = @import("sbi.zig");
const uart = @import("uart.zig");
const trap = @import("trap.zig");
const plic = @import("plic.zig");
const timer = @import("timer.zig");
const shell = @import("shell.zig");

/// 替换标准库默认的 panic 处理。@panic、std.debug.panic 以及
/// Debug 模式下的安全检查失败（整数溢出、数组越界等）都会走到这里。
pub const panic = std.debug.FullPanic(kernelPanic);

fn kernelPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    riscv.disableInterrupts();
    uart.print("\n!!! KERNEL PANIC: {s}\n", .{msg});
    uart.write("system halted.\n");
    while (true) riscv.wfi();
}

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\la sp, __stack_top
        // 清零 .bss：初值为 0 的全局变量都在这里，ELF 文件里不占空间，需要自己清
        \\la t0, __bss_start
        \\la t1, __bss_end
        \\1:
        \\bgeu t0, t1, 2f
        \\sd zero, 0(t0)
        \\addi t0, t0, 8
        \\j 1b
        \\2:
        // a0、a1 没动过，原样作为参数传给 kmain
        \\tail %[kmain]
        :
        : [kmain] "X" (&kmain),
    );
}

fn kmain(hartid: usize, dtb: usize) callconv(.c) noreturn {
    uart.init();
    uart.write("\nHello from a Zig kernel on RISC-V!\n");
    const version = sbi.specVersion();
    uart.print("SBI: {s}, spec v{d}.{d} | hart {d} | device tree at 0x{x}\n", .{
        sbi.implName(), version.major, version.minor, hartid, dtb,
    });

    trap.init();
    uart.write("[ok] trap vector installed\n");
    // 自检：主动触发一次断点异常，确认陷阱能进能出
    asm volatile ("ebreak");

    plic.init(hartid);
    timer.init();
    riscv.enableInterrupts();
    uart.print("[ok] interrupts enabled: timer at {d} Hz, keyboard via UART + PLIC\n", .{timer.tick_hz});

    uart.write("Type 'help' for commands.\n");
    shell.prompt();
    while (true) {
        // 先关中断再查缓冲区：如果查完发现为空、正要 wfi 时恰好来了字符，
        // 中断会保持挂起，wfi 立即返回，不会白睡一轮。
        // （wfi 只看 sie，不看 sstatus.SIE，所以关着中断也能被唤醒。）
        riscv.disableInterrupts();
        const c = uart.read();
        if (c == null) riscv.wfi();
        riscv.enableInterrupts(); // 挂起的中断在这里立刻被处理
        if (c) |ch| shell.feed(ch);
    }
}
