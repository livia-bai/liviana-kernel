//! 回归测试：U 模式直接读 time 计数器。OpenSBI 把 scounteren 设成了 7，应该能正常读到。

const sys = @import("sys");

pub fn main() u8 {
    const t = asm volatile ("rdtime %[r]"
        : [r] "=r" (-> usize),
    );
    sys.print("rdtime from U-mode = {d}\n", .{t});
    return 0;
}
