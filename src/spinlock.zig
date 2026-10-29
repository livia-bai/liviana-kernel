//! 自旋锁，照 xv6 的 spinlock.c 写，为多核做准备。
//!
//! 现在只有一个 hart，而且内核代码全程关着中断运行（见 docs/trap.md），所以锁实际上不会被争抢：
//! acquire 时锁一定是空的。这里先把锁加在共享的数据结构上（页分配器、文件表、管道、串口的输入缓冲区），
//! 写法和多核时一样，到时候只需要补上每个 hart 的状态（cpuId、held），不用再到处找漏掉的地方。
//!
//! 约定：
//! - 拿着锁时中断必须是关着的。否则中断处理程序在同一个 hart 上去拿同一把锁，就会永远自旋下去。
//!   内核代码本来就关着中断运行，所以 acquire 只检查，不负责关中断（xv6 的 push_off）。
//! - 不能拿着锁切换进程（sched）、回到 U 模式。要拿着锁等待的，用 proc.sleep(chan, lock)：
//!   它在睡下之后放开锁，醒来再重新拿上。
//! - 同一个 hart 重复拿同一把锁是死锁，直接 panic。

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("riscv.zig");

const no_cpu = std.math.maxInt(usize);

/// 当前 hart 的编号。现在只有一个 hart，总是 0；多核时改成从 tp 读。
pub fn cpuId() usize {
    return 0;
}

/// 当前 hart 拿着几把锁。多核时每个 hart 一个。
pub var held: usize = 0;

pub const Spinlock = struct {
    /// 调试用的名字，panic 信息里会打印
    name: []const u8,
    locked: std.atomic.Value(bool) = .init(false),
    /// 拿着锁的 hart，用来发现重复加锁
    cpu: usize = no_cpu,

    pub fn init(name: []const u8) Spinlock {
        return .{ .name = name };
    }

    pub fn acquire(l: *Spinlock) void {
        assertInterruptsOff();
        if (l.holding()) std.debug.panic("acquire: lock {s} is already held by this hart", .{l.name});
        // amoswap.w.aq：换进 true，换出来的是 false 才算拿到。acquire 语义保证临界区里的访存
        // 不会被提前到拿到锁之前
        while (l.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
        l.cpu = cpuId();
        held += 1;
    }

    pub fn release(l: *Spinlock) void {
        if (!l.holding()) std.debug.panic("release: lock {s} is not held by this hart", .{l.name});
        l.cpu = no_cpu;
        held -= 1;
        // release 语义保证临界区里的访存都在放开锁之前完成
        l.locked.store(false, .release);
    }

    /// 当前 hart 是否拿着这把锁。
    pub fn holding(l: *const Spinlock) bool {
        return l.locked.load(.monotonic) and l.cpu == cpuId();
    }
};

/// 切换进程、回到 U 模式之前调用：这时不能拿着任何锁。
pub fn assertNoneHeld() void {
    if (held != 0) std.debug.panic("{d} spinlock(s) still held", .{held});
}

fn assertInterruptsOff() void {
    // 单元测试在主机上运行，没有 sstatus
    if (comptime builtin.cpu.arch.isRISCV()) {
        if (riscv.read(.sstatus) & riscv.sstatus_sie != 0) @panic("acquire: interrupts are enabled");
    }
}

test "拿锁、放锁，记录拿着几把锁" {
    var a = Spinlock.init("a");
    var b = Spinlock.init("b");
    const before = held;
    a.acquire();
    b.acquire();
    try std.testing.expect(a.holding() and b.holding());
    try std.testing.expectEqual(before + 2, held);
    b.release();
    a.release();
    try std.testing.expect(!a.holding());
    try std.testing.expectEqual(before, held);
}
