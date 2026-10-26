//! 演示 sleep：每秒打印一行，共 5 行。睡眠期间不占 CPU，可以在后台同时跑几个，看它们的输出交错。

const sys = @import("sys");

pub fn main() u8 {
    const pid = sys.getpid();
    for (1..6) |i| {
        sys.sleep(1000);
        sys.print("[ticker pid {d}] tick {d} at {d} ms\n", .{ pid, i, sys.uptime() });
    }
    return 0;
}
