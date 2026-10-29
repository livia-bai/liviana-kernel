//! 睡眠锁，照 xv6 的 sleeplock.c 写。和自旋锁的区别：等锁的进程睡下（proc.sleep），不占着 CPU 空转；
//! 拿着它可以睡觉、切换进程。用来保护要等磁盘 I/O 的东西（缓冲区缓存里的每一块，见 bio.zig）：
//! 拿着锁的进程可能正在等磁盘，拿着自旋锁等的话，别的 hart 上想要同一把锁的进程都得陪着空转。
//!
//! 约定：
//! - 只有进程能拿（要能睡下），调度器、kmain、中断处理程序都不能拿。
//! - 不能拿着它回到 U 模式（handleTrap 末尾检查当前进程拿着几把，proc.Process.sleeplocks）。
//! - 拿它之前可以拿着别的睡眠锁，但不能拿着自旋锁（会睡下：sched 只允许拿着自己的进程锁）。

const std = @import("std");
const proc = @import("proc.zig");
const Spinlock = @import("spinlock.zig").Spinlock;

pub const Sleeplock = struct {
    /// 调试用的名字
    name: []const u8,
    /// 保护 locked 和 holder；等锁的进程拿着它睡在这把睡眠锁上
    lk: Spinlock,
    locked: bool = false,
    /// 拿着它的进程（单元测试在主机上运行，没有当前进程，是 null）
    holder: ?*proc.Process = null,

    pub fn init(name: []const u8) Sleeplock {
        return .{ .name = name, .lk = .init("sleeplock") };
    }

    pub fn acquire(l: *Sleeplock) void {
        l.lk.acquire();
        defer l.lk.release();
        // 自己已经拿着的话，睡下去就永远醒不来了（和自旋锁一样，直接 panic）
        if (l.locked and l.holder == proc.current()) std.debug.panic("acquire: sleeplock {s} is already held by this process", .{l.name});
        while (l.locked) proc.sleep(l, &l.lk);
        l.locked = true;
        l.holder = proc.current();
        proc.countSleeplock(1);
    }

    pub fn release(l: *Sleeplock) void {
        l.lk.acquire();
        defer l.lk.release();
        if (!l.locked or l.holder != proc.current()) std.debug.panic("release: sleeplock {s} is not held by this process", .{l.name});
        l.locked = false;
        l.holder = null;
        proc.countSleeplock(-1);
        proc.wakeup(l);
    }

    /// 当前进程是否拿着它。
    pub fn holding(l: *Sleeplock) bool {
        l.lk.acquire();
        defer l.lk.release();
        return l.locked and l.holder == proc.current();
    }
};

test "睡眠锁：拿、放、holding" {
    var l = Sleeplock.init("test");
    try std.testing.expect(!l.holding());
    l.acquire();
    try std.testing.expect(l.holding());
    l.release();
    try std.testing.expect(!l.holding());
}
