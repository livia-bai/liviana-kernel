//! 内核入口。OpenSBI 以 S 模式跳到 _start，此时 a0 = 当前 hart 编号，a1 = 设备树（DTB）地址；
//! 分页关闭（虚拟地址 = 物理地址），中断关闭，还没有栈。

const std = @import("std");
const riscv = @import("riscv.zig");
const sbi = @import("sbi.zig");
const uart = @import("uart.zig");
const trap = @import("trap.zig");
const plic = @import("plic.zig");
const timer = @import("timer.zig");
const dtb = @import("dtb.zig");
const page = @import("page.zig");
const vm = @import("vm.zig");
const proc = @import("proc.zig");

/// 替换标准库默认的 panic 处理。@panic、std.debug.panic 以及
/// Debug 模式下的安全检查失败（整数溢出、数组越界等）都会走到这里。
pub const panic = std.debug.FullPanic(kernelPanic);

fn kernelPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    riscv.disableInterrupts();
    uart.print("\n!!! KERNEL PANIC: {s}\n", .{msg});
    uart.write("system halted.\n");
    // 把 sie 也清零再 wfi：时钟中断没人再预约，会一直挂着，它在 sie 里还使能的话，
    // wfi 每次都立刻返回，停机就成了忙等（QEMU 占满一个 CPU 核）
    riscv.write(.sie, 0);
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

fn kmain(hartid: usize, dtb_addr: usize) callconv(.c) noreturn {
    // OpenSBI 交过来时 FS 是 Dirty，浮点单元开着。这个内核不支持浮点（陷阱处理不保存浮点寄存器），
    // 关掉它：否则用户程序能直接用浮点寄存器，里面的值还会留给下一个进程
    riscv.clear(.sstatus, riscv.sstatus_fs);
    uart.init();
    uart.write("\nHello from a Zig kernel on RISC-V!\n");
    const version = sbi.specVersion();
    uart.print("SBI: {s}, spec v{d}.{d} | hart {d} | device tree at 0x{x}\n", .{
        sbi.implName(), version.major, version.minor, hartid, dtb_addr,
    });

    trap.init();
    uart.write("[ok] trap vector installed\n");
    // 自检：主动触发一次断点异常，确认陷阱能进能出
    asm volatile ("ebreak");

    const info = dtb.parse(dtb_addr) catch |err| {
        std.debug.panic("cannot parse device tree at 0x{x}: {s}", .{ dtb_addr, @errorName(err) });
    };
    uart.print("[ok] device tree: {d} MiB RAM at 0x{x}, timebase {d} Hz\n", .{
        info.memory.size >> 20, info.memory.base, info.timebase_hz,
    });

    page.init(vm.kernelEnd(), info.memory.end(), info.reserved());
    uart.print("[ok] page allocator: {d} free pages ({d} KiB)\n", .{ page.free_pages, page.free_pages * page.size / 1024 });

    vm.init(info.memory) catch |err| std.debug.panic("cannot set up paging: {s}", .{@errorName(err)});
    uart.write("[ok] Sv39 paging enabled: kernel mapped 1:1, text r-x, rodata r--, data rw-\n");

    plic.init(hartid);
    timer.init(info.timebase_hz);
    uart.print("[ok] interrupt sources enabled: timer at {d} Hz, keyboard via UART + PLIC\n", .{timer.tick_hz});

    // 和 xv6 的 main 一样：建好第一个进程 init，然后启动栈就交给调度器，永远不回来。
    // init 再启动 shell（user/init.zig、user/sh.zig）。
    // 全局的中断开关 sstatus.SIE 这里不开：内核代码都关着中断运行（拿锁时也要求这样，见 spinlock.zig），
    // 调度器每一轮开头才开一下。
    proc.userinit() catch |err| std.debug.panic("cannot start init: {s}", .{@errorName(err)});
    proc.scheduler();
}
