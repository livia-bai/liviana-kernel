//! 陷阱（trap）处理。RISC-V 里异常（除零以外的各种错误、ebreak、ecall）和中断（时钟、外设）
//! 统一叫陷阱，发生时 CPU 跳到 stvec 指向的地址，并在 scause 里说明原因。
//! 相当于 x86 上 IDT 的角色。

const std = @import("std");
const riscv = @import("riscv.zig");
const uart = @import("uart.zig");
const plic = @import("plic.zig");
const timer = @import("timer.zig");
const proc = @import("proc.zig");
const vm = @import("vm.zig");
const ipi = @import("ipi.zig");
const syscall = @import("syscall.zig");
const spinlock = @import("spinlock.zig");

/// 陷阱发生时被打断的上下文。regs[i] 就是寄存器 xi（x0 恒为 0，它的槽位不用）。
/// 布局必须和 trapEntry、trapExit 里的汇编一致。
pub const TrapFrame = extern struct {
    regs: [32]usize,
    sepc: usize,
    sstatus: usize,
    /// 回到 U 模式时内核的 tp（当前 hart 的编号，见 hart.zig），下次从 U 模式陷入时换回来
    kernel_tp: usize = 0,
    /// 补齐到 16 字节：TrapFrame 放在内核栈顶，它的下沿就是 handleTrap 开始用的 sp，要 16 字节对齐
    _pad: usize = 0,
};

comptime {
    std.debug.assert(@sizeOf(TrapFrame) % 16 == 0);
}

/// scause 最高位为 1 时，低位是中断编号。
const Interrupt = enum(usize) {
    supervisor_software = 1,
    supervisor_timer = 5,
    supervisor_external = 9,
    _,
};

/// scause 最高位为 0 时，低位是异常编号。
const Exception = enum(usize) {
    instruction_misaligned = 0,
    instruction_access_fault = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_misaligned = 4,
    load_access_fault = 5,
    store_misaligned = 6,
    store_access_fault = 7,
    ecall_from_u = 8,
    ecall_from_s = 9,
    instruction_page_fault = 12,
    load_page_fault = 13,
    store_page_fault = 15,
    _,
};

pub fn init() void {
    // stvec 低 2 位是模式，0 = Direct：所有陷阱都进同一个入口。
    // trapEntry 按 4 字节对齐，所以地址低 2 位天然是 0。
    riscv.write(.stvec, @intFromPtr(&trapEntry));
    // sscratch 为 0 表示 CPU 正在内核里（见 trapEntry）。固件不保证它的初值。
    riscv.write(.sscratch, 0);
}

/// 在编译期生成保存/恢复 x1、x3..x31 的 30 条指令（x0 恒为 0 不用存，sp 单独处理）。
fn regsAsm(comptime op: []const u8) []const u8 {
    var s: []const u8 = "";
    for (1..32) |i| {
        if (i == 2) continue;
        s = s ++ std.fmt.comptimePrint("{s} x{d}, {d}(sp)\n", .{ op, i, i * @sizeOf(usize) });
    }
    return s;
}

const save_regs = regsAsm("sd");
const restore_regs = regsAsm("ld");

const asm_offsets = .{
    .size = @sizeOf(TrapFrame),
    .sp = 2 * @sizeOf(usize),
    .sepc = @offsetOf(TrapFrame, "sepc"),
    .sstatus = @offsetOf(TrapFrame, "sstatus"),
    .kernel_tp = @offsetOf(TrapFrame, "kernel_tp"),
};

/// 陷阱入口。在 TrapFrame 里保存被打断的上下文，然后调用 handleTrap。
///
/// 陷阱可能来自 S 模式（内核自己），也可能来自 U 模式（用户程序）。来自 U 模式时 sp 是用户栈，
/// 不能用，要换成内核栈。约定：在 U 模式运行时 sscratch 存着内核栈顶，在内核里时 sscratch 为 0。
/// 入口先交换 sp 和 sscratch：交换后 sp 不为 0 说明来自 U 模式，sp 已经是内核栈；
/// 为 0 说明来自内核，原来的 sp 就在 sscratch 里，取回来接着用。
/// 两种情况下 sscratch 最后都存着被打断时的 sp，保存进 TrapFrame 之后清零。
///
/// 内核用 tp 存当前 hart 的编号（hart.zig）。来自 U 模式时 tp 是用户程序的，存进 TrapFrame 之后
/// 换成 trapExit 回到 U 模式时留下的 kernel_tp；来自内核时 tp 本来就是对的，不动。
/// 内核不使用 gp（不做 gp 相对寻址），用户程序留在里面的值不用换掉。
fn trapEntry() align(4) callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint(
            \\csrrw sp, sscratch, sp
            \\bnez sp, 1f
            \\csrr sp, sscratch
            \\1:
            \\addi sp, sp, -{[size]d}
            \\
        ++ save_regs ++
            \\csrrw t0, sscratch, zero
            \\sd t0, {[sp]d}(sp)
            \\csrr t0, sepc
            \\sd t0, {[sepc]d}(sp)
            \\csrr t0, sstatus
            \\sd t0, {[sstatus]d}(sp)
            \\andi t0, t0, %[spp]
            \\bnez t0, 2f
            \\ld tp, {[kernel_tp]d}(sp)
            \\2:
            \\mv a0, sp
            \\call %[handleTrap]
            \\tail %[trapExit]
        , asm_offsets)
        :
        : [handleTrap] "X" (&handleTrap),
          [trapExit] "X" (&trapExit),
          [spp] "i" (riscv.sstatus_spp),
    );
}

/// 按 sp 指向的 TrapFrame 恢复上下文，执行 sret 回到被打断的地方。
/// 除了陷阱返回，新进程第一次被调度时也从这里进入 U 模式（见 proc.forkret）。
///
/// 先写回 sstatus：其中 SIE 为 0，之后不会再被中断打断；SPP 决定 sret 回到哪个特权级。
/// 如果要回到 U 模式，把这个 TrapFrame 的上沿（也就是内核栈顶）存进 sscratch，
/// 下次从 U 模式陷入时 trapEntry 就从这里开始用内核栈；再把内核的 tp 存进 kernel_tp，
/// 下次陷入时换回来。进程可能在别的 hart 上被调度过，所以每次回到 U 模式都要重新存。
pub fn trapExit() callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint(
            \\ld t0, {[sstatus]d}(sp)
            \\csrw sstatus, t0
            \\andi t0, t0, %[spp]
            \\bnez t0, 1f
            \\addi t0, sp, {[size]d}
            \\csrw sscratch, t0
            \\sd tp, {[kernel_tp]d}(sp)
            \\1:
            \\ld t0, {[sepc]d}(sp)
            \\csrw sepc, t0
            \\
        ++ restore_regs ++
            \\ld sp, {[sp]d}(sp)
            \\sret
        , asm_offsets)
        :
        : [spp] "i" (riscv.sstatus_spp),
    );
}

fn handleTrap(frame: *TrapFrame) callconv(.c) void {
    const scause = riscv.read(.scause);
    const is_interrupt = scause >> 63 != 0;
    const code = scause & ~(@as(usize, 1) << 63);
    const from_user = frame.sstatus & riscv.sstatus_spp == 0;

    if (is_interrupt) {
        const interrupt: Interrupt = @fromBackingInt(code);
        switch (interrupt) {
            .supervisor_timer => {
                timer.onInterrupt();
                if (from_user) {
                    // 时间片用完了，让出 CPU（xv6 的 usertrap 也是这样）。用户程序就算在 U 模式里死循环，
                    // 时钟中断也会把 CPU 交回内核。下次轮到它时（可能在别的 hart 上）返回，经 trapExit 回到 U 模式。
                    // 放在中断处理全部完成之后：可能很久以后才返回。
                    // （内核代码都是关着中断执行的，所以中断打断的要么是 U 模式，要么是调度器。）
                    proc.yieldTimeslice();
                }
            },
            .supervisor_external => handleExternal(),
            // 核间中断：别的 hart 叫醒这个空闲的 hart，或者杀了正在这里运行的进程（末尾的 checkKilled 结束它）
            .supervisor_software => ipi.onInterrupt(),
            else => std.debug.panic("unexpected interrupt {d}", .{code}),
        }
    } else if (from_user) {
        const exception: Exception = @fromBackingInt(code);
        switch (exception) {
            .ecall_from_u => {
                // sepc 指向 ecall 本身（固定 4 字节，没有压缩形式），返回时要跳过它
                frame.sepc += 4;
                frame.regs[10] = syscall.dispatch(frame);
            },
            // 写了 fork 之后和别的进程共用的页（写时复制，见 vm.cloneUserSpace）：给它复制一份能写的，
            // 回到原来的地方重新执行这条写指令。别的写缺页（只读的段、没有映射的地址）照常结束进程
            .store_page_fault => {
                const stval = riscv.read(.stval);
                vm.breakCow(proc.current().?.space, stval) catch |err| switch (err) {
                    error.NotCow => killForFault(frame, exception),
                    error.OutOfMemory => proc.killCurrent("out of memory (copy-on-write) at 0x{x}, stval=0x{x}", .{ frame.sepc, stval }),
                };
            },
            else => killForFault(frame, exception),
        }
    } else {
        const exception: Exception = @fromBackingInt(code);
        switch (exception) {
            .breakpoint => {
                uart.print("[trap] breakpoint at 0x{x}, skipping it\n", .{frame.sepc});
                // sepc 指向 ebreak 本身，跳过它才不会无限循环
                frame.sepc += instructionLength(frame.sepc);
            },
            else => std.debug.panic("unhandled exception: {s} (scause={d}), sepc=0x{x}, stval=0x{x}", .{
                std.enums.tagName(Exception, exception) orelse "unknown",
                code,
                frame.sepc,
                riscv.read(.stval),
            }),
        }
    }
    // 回到 U 模式之前：被 kill 了（比如在 yield、sleep 里等着的时候，或者刚才的串口中断是 Ctrl-C）就在这里结束
    if (from_user) {
        proc.checkKilled();
        spinlock.assertNoneHeld();
    }
}

/// 来自 U 模式的异常（系统调用和写时复制以外的）都是用户程序自己的错：访问了没有映射或没有权限的地址、
/// 执行了非法指令等等。结束这个进程，内核照常运行。
fn killForFault(frame: *TrapFrame, exception: Exception) noreturn {
    proc.killCurrent("{s} at 0x{x}, stval=0x{x}", .{
        std.enums.tagName(Exception, exception) orelse "unknown exception",
        frame.sepc,
        riscv.read(.stval),
    });
}

fn handleExternal() void {
    const irq = plic.claim();
    switch (irq) {
        0 => return, // 没有待处理的中断
        plic.uart0_irq => {
            // 和 xv6 的 consoleintr 一样在中断里直接处理：Ctrl-C 杀掉前台进程，叫醒等输入的进程
            if (uart.onInterrupt()) proc.interruptForeground();
            proc.wakeup(uart.rx_chan);
        },
        else => uart.print("[trap] unexpected external interrupt {d}\n", .{irq}),
    }
    plic.complete(irq);
}

/// 低 2 位为 0b11 的是 4 字节标准指令，否则是 2 字节压缩指令（C 扩展）。
fn instructionLength(addr: usize) usize {
    const half: *const u16 = @ptrFromInt(addr);
    return if (half.* & 0b11 == 0b11) 4 else 2;
}
