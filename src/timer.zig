//! 时钟中断：每 10ms 触发一次，用来计时。

const riscv = @import("riscv.zig");
const sbi = @import("sbi.zig");

pub const tick_hz = 100;

/// time CSR 每秒增加的次数，来自设备树 /cpus 的 timebase-frequency（QEMU virt 上是 10MHz）。
var timebase_hz: u64 = undefined;

/// 下一次时钟中断预约在 time CSR 的哪个值。
var deadline: u64 = undefined;

pub var ticks: u64 = 0;

pub fn init(hz: u64) void {
    timebase_hz = hz;
    deadline = riscv.read(.time);
    arm();
    riscv.set(.sie, riscv.sie_stie);
}

/// 预约下一次时钟中断：在上一次的预约时刻上加一个周期，而不是在“现在”上加。
/// 中断从到期到被处理总有延迟，按“现在”算的话，每个 tick 都会把这段延迟丢掉，
/// 实测计时比 time CSR 慢 2%～3%。处理晚了超过一个周期时，新的预约时刻已经过去，
/// 中断会立刻再来一次，ticks 自己追上。
fn arm() void {
    deadline += timebase_hz / tick_hz;
    sbi.setTimer(deadline);
}

pub fn onInterrupt() void {
    ticks += 1;
    arm();
}

/// 开机以来的毫秒数（从打开时钟中断算起），精度是一个 tick。
pub fn uptimeMs() u64 {
    return ticks * 1000 / tick_hz;
}
