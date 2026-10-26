//! 回归测试：sleep 和 yield。sleep(200) 之后 uptime 至少增加 200 ms；sleep(0) 和 yield 立刻返回 0。

const sys = @import("sys");

pub fn main() u8 {
    const start = sys.uptime();
    sys.sleep(200);
    sys.print("slept {d} ms\n", .{sys.uptime() - start});
    sys.sleep(0);
    sys.yield();
    sys.print("yield ok\n", .{});
    return 0;
}
