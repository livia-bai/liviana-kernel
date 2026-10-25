//! PLIC（Platform-Level Interrupt Controller）：把外设中断（这里只有串口）路由给 CPU。
//! 寄存器布局见 RISC-V PLIC 规范，地址和中断号来自 QEMU virt 机器。

const riscv = @import("riscv.zig");

const base: usize = 0x0c00_0000;

pub const uart0_irq: u32 = 10;

/// QEMU virt 上每个 hart 有两个 PLIC 上下文：2*hart 是 M 模式，2*hart+1 是 S 模式。
var context: usize = undefined;

fn reg(offset: usize) *volatile u32 {
    return @ptrFromInt(base + offset);
}

fn priority(irq: u32) *volatile u32 {
    return reg(4 * irq);
}

fn enable() *volatile u32 {
    return reg(0x2000 + 0x80 * context);
}

fn threshold() *volatile u32 {
    return reg(0x20_0000 + 0x1000 * context);
}

fn claimComplete() *volatile u32 {
    return reg(0x20_0004 + 0x1000 * context);
}

pub fn init(hartid: usize) void {
    context = 2 * hartid + 1;
    priority(uart0_irq).* = 1; // 优先级为 0 表示“永不触发”，所以至少设成 1
    enable().* = 1 << uart0_irq;
    threshold().* = 0; // 接收所有优先级 > 0 的中断
    riscv.set(.sie, riscv.sie_seie);
}

/// 领取当前优先级最高的待处理中断，返回中断号；0 表示没有。
pub fn claim() u32 {
    return claimComplete().*;
}

/// 告诉 PLIC 这个中断处理完了，之后它才会再次投递同一个中断。
pub fn complete(irq: u32) void {
    claimComplete().* = irq;
}
