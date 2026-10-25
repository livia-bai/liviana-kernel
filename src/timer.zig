//! 时钟中断：每 10ms 触发一次，用来计时。

const riscv = @import("riscv.zig");
const sbi = @import("sbi.zig");

pub const tick_hz = 100;

/// time CSR 每秒增加的次数，来自设备树 /cpus 的 timebase-frequency（QEMU virt 上是 10MHz）。
var timebase_hz: u64 = undefined;

pub var ticks: u64 = 0;

pub fn init(hz: u64) void {
    timebase_hz = hz;
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

/// 开机以来的毫秒数（从打开时钟中断算起），精度是一个 tick。
pub fn uptimeMs() u64 {
    return ticks * 1000 / tick_hz;
}
