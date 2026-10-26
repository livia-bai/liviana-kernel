//! 回归测试：uptime 系统调用和 time 计数器走得一样快。
//! 先读一次 rdtime 和 uptime()，忙等到 uptime() 走过 3 秒，再读一次，打印两者各走了多少；
//! tools/qemu_test.py 按 timebase 把 rdtime 换算成毫秒，要求两者相差不超过一个小的容差。
//! 时钟中断按“处理中断的时刻 + 10 ms”预约下一次的话，uptime 会比 rdtime 慢 2%～3%（见 docs/changes/0010）。

const sys = @import("sys");

const window_ms = 3000;

fn rdtime() u64 {
    return asm volatile ("rdtime %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn main() u8 {
    const t0 = rdtime();
    const up0 = sys.uptime();
    while (sys.uptime() - up0 < window_ms) {}
    const up1 = sys.uptime();
    const t1 = rdtime();
    sys.print("uptime() advanced {d} ms, rdtime advanced {d}\n", .{ up1 - up0, t1 - t0 });
    return 0;
}
