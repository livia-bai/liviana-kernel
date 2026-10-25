//! 陷阱（trap）处理。RISC-V 里异常（除零以外的各种错误、ebreak、ecall）和中断（时钟、外设）
//! 统一叫陷阱，发生时 CPU 跳到 stvec 指向的地址，并在 scause 里说明原因。
//! 相当于 x86 上 IDT 的角色。

const std = @import("std");
const riscv = @import("riscv.zig");
const uart = @import("uart.zig");
const plic = @import("plic.zig");
const timer = @import("timer.zig");
const proc = @import("proc.zig");
const syscall = @import("syscall.zig");

/// 陷阱发生时被打断的上下文。regs[i] 就是寄存器 xi（x0 恒为 0，它的槽位不用）。
/// 布局必须和 trapEntry、trapExit 里的汇编一致。
pub const TrapFrame = extern struct {
    regs: [32]usize,
    sepc: usize,
    sstatus: usize,
};

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

/// 在编译期生成保存/恢复 x1..x31 的 31 条指令（sp 单独处理）。
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
};

/// 陷阱入口。在 TrapFrame 里保存被打断的上下文，然后调用 handleTrap。
///
/// 陷阱可能来自 S 模式（内核自己），也可能来自 U 模式（用户程序）。来自 U 模式时 sp 是用户栈，
/// 不能用，要换成内核栈。约定：在 U 模式运行时 sscratch 存着内核栈顶，在内核里时 sscratch 为 0。
/// 入口先交换 sp 和 sscratch：交换后 sp 不为 0 说明来自 U 模式，sp 已经是内核栈；
/// 为 0 说明来自内核，原来的 sp 就在 sscratch 里，取回来接着用。
/// 两种情况下 sscratch 最后都存着被打断时的 sp，保存进 TrapFrame 之后清零。
/// 内核不使用 gp 和 tp（没有线程局部变量，也不做 gp 相对寻址），所以用户程序留在里面的值不用换掉。
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
            \\mv a0, sp
            \\call %[handleTrap]
            \\tail %[trapExit]
        , asm_offsets)
        :
        : [handleTrap] "X" (&handleTrap),
          [trapExit] "X" (&trapExit),
    );
}

/// 按 sp 指向的 TrapFrame 恢复上下文，执行 sret 回到被打断的地方。
/// 除了陷阱返回，proc.switchToUser 也从这里第一次进入 U 模式。
///
/// 先写回 sstatus：其中 SIE 为 0，之后不会再被中断打断；SPP 决定 sret 回到哪个特权级。
/// 如果要回到 U 模式，把这个 TrapFrame 的上沿（也就是内核栈顶）存进 sscratch，
/// 下次从 U 模式陷入时 trapEntry 就从这里开始用内核栈。
pub fn trapExit() callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint(
            \\ld t0, {[sstatus]d}(sp)
            \\csrw sstatus, t0
            \\andi t0, t0, %[spp]
            \\bnez t0, 1f
            \\addi t0, sp, {[size]d}
            \\csrw sscratch, t0
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
            .supervisor_timer => timer.onInterrupt(),
            .supervisor_external => handleExternal(),
            else => std.debug.panic("unexpected interrupt {d}", .{code}),
        }
        // 用户程序就算在 U 模式里死循环，时钟和串口中断也会把 CPU 交回内核，
        // 这时检查用户有没有按 Ctrl-C。（运行用户程序期间，内核代码都是关着中断执行的，
        // 所以中断只可能打断 U 模式。）
        if (from_user and uart.takeCtrlC()) {
            uart.write("^C\n");
            proc.kill("interrupted by Ctrl-C", .{});
        }
    } else if (from_user) {
        const exception: Exception = @fromBackingInt(code);
        switch (exception) {
            .ecall_from_u => {
                // sepc 指向 ecall 本身（固定 4 字节，没有压缩形式），返回时要跳过它
                frame.sepc += 4;
                frame.regs[10] = syscall.dispatch(frame);
            },
            // 其他异常都是用户程序自己的错：访问了没有映射或没有权限的地址、执行了非法指令等等。
            // 结束这个进程，内核照常运行。
            else => proc.kill("{s} at 0x{x}, stval=0x{x}", .{
                std.enums.tagName(Exception, exception) orelse "unknown exception",
                frame.sepc,
                riscv.read(.stval),
            }),
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
}

fn handleExternal() void {
    const irq = plic.claim();
    switch (irq) {
        0 => return, // 没有待处理的中断
        plic.uart0_irq => uart.onInterrupt(),
        else => uart.print("[trap] unexpected external interrupt {d}\n", .{irq}),
    }
    plic.complete(irq);
}

/// 低 2 位为 0b11 的是 4 字节标准指令，否则是 2 字节压缩指令（C 扩展）。
fn instructionLength(addr: usize) usize {
    const half: *const u16 = @ptrFromInt(addr);
    return if (half.* & 0b11 == 0b11) 4 else 2;
}
