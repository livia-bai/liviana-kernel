//! 陷阱（trap）处理。RISC-V 里异常（除零以外的各种错误、ebreak、ecall）和中断（时钟、外设）
//! 统一叫陷阱，发生时 CPU 跳到 stvec 指向的地址，并在 scause 里说明原因。
//! 相当于 x86 上 IDT 的角色。

const std = @import("std");
const riscv = @import("riscv.zig");
const uart = @import("uart.zig");
const plic = @import("plic.zig");
const timer = @import("timer.zig");

/// 陷阱发生时被打断的上下文。regs[i] 就是寄存器 xi（x0 恒为 0，它的槽位不用）。
/// 布局必须和 trapEntry 里的汇编一致。
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

/// 陷阱入口。内核只在 S 模式运行，被打断时用的就是内核栈，直接在栈上压一个 TrapFrame。
fn trapEntry() align(4) callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint("addi sp, sp, -{d}\n", .{@sizeOf(TrapFrame)}) ++
            save_regs ++
            std.fmt.comptimePrint(
                \\addi t0, sp, {[size]d}
                \\sd t0, {[sp]d}(sp)
                \\csrr t0, sepc
                \\sd t0, {[sepc]d}(sp)
                \\csrr t0, sstatus
                \\sd t0, {[sstatus]d}(sp)
                \\mv a0, sp
                \\call %[handleTrap]
                \\ld t0, {[sepc]d}(sp)
                \\csrw sepc, t0
                \\ld t0, {[sstatus]d}(sp)
                \\csrw sstatus, t0
                \\
            , .{
                .size = @sizeOf(TrapFrame),
                .sp = 2 * @sizeOf(usize),
                .sepc = @offsetOf(TrapFrame, "sepc"),
                .sstatus = @offsetOf(TrapFrame, "sstatus"),
            }) ++
            restore_regs ++
            std.fmt.comptimePrint("addi sp, sp, {d}\nsret\n", .{@sizeOf(TrapFrame)})
        :
        : [handleTrap] "X" (&handleTrap),
    );
}

fn handleTrap(frame: *TrapFrame) callconv(.c) void {
    const scause = riscv.read(.scause);
    const is_interrupt = scause >> 63 != 0;
    const code = scause & ~(@as(usize, 1) << 63);

    if (is_interrupt) {
        const interrupt: Interrupt = @fromBackingInt(code);
        switch (interrupt) {
            .supervisor_timer => timer.onInterrupt(),
            .supervisor_external => handleExternal(),
            else => std.debug.panic("unexpected interrupt {d}", .{code}),
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
