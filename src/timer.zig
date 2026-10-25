//! 时钟中断：每 10ms 触发一次，用来计时。

const riscv = @import("riscv.zig");
const sbi = @import("sbi.zig");

/// time CSR 每秒增加的次数。QEMU virt 固定为 10MHz（设备树 /cpus 的 timebase-frequency）。
const timebase_hz = 10_000_000;
pub const tick_hz = 100;

pub var ticks: u64 = 0;

pub fn init() void {
    arm();
    riscv.set(.sie, riscv.sie_stie);
}

/// 预约下一次时钟中断。
fn arm() void {
    sbi.setTimer(riscv.read(.time) + timebase_hz / tick_hz);
}

pub fn onInterrupt() void {
    ticks += 1;
    arm();
}
