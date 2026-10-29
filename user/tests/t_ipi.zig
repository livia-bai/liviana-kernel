//! 回归测试：核间中断的延迟。用 U 模式能直接读的 time 计数器（rdtime）计时，各测 rounds 次，打印中位数：
//!
//! - kill：子进程在 U 模式里死循环（多核时在另一个 hart 上），父进程 kill 它、wait 它，量从 kill 到 wait 返回。
//!   那个 hart 要被核间中断打断才会进内核结束它；不发的话要等它自己的下一个时钟中断（最多 10 ms）。
//! - wakeup：子进程睡在管道的 read 里，父进程写一个字节之后在 U 模式里忙 20 ms（占着自己的 hart），
//!   量从写到子进程醒来。空闲的 hart 要被核间中断叫醒才会去运行它；不发的话要等某个 hart 的下一个时钟中断。
//!
//! 单核时只有一个 hart，第二项必然要等父进程的时间片用完，延迟由 qemu_test.py 只在多核时检查。

const std = @import("std");
const sys = @import("sys");

/// QEMU virt 的 time 计数器频率（设备树的 timebase-frequency），10 个计数是 1 µs
const ticks_per_us = 10;
const rounds = 15;

fn now() u64 {
    return asm volatile ("rdtime %[r]"
        : [r] "=r" (-> u64),
    );
}

fn fail(comptime what: []const u8, args: anytype) noreturn {
    sys.print("FAIL: " ++ what ++ "\n", args);
    sys.exit(1);
}

fn pipe() [2]sys.Fd {
    return sys.pipe() catch |err| fail("pipe: {s}", .{@errorName(err)});
}

fn fork() usize {
    return sys.fork() catch |err| fail("fork: {s}", .{@errorName(err)});
}

fn median(samples: *[rounds]u64) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[rounds / 2];
}

fn killLatency() u64 {
    var samples: [rounds]u64 = undefined;
    for (&samples) |*s| {
        const p = pipe();
        const pid = fork();
        if (pid == 0) {
            _ = sys.write(p[1], "!") catch {};
            while (true) {}
        }
        // 子进程写了这个字节之后就一直在 U 模式里转
        var b: [1]u8 = undefined;
        _ = sys.read(p[0], &b) catch {};
        const t0 = now();
        sys.kill(pid) catch |err| fail("kill: {s}", .{@errorName(err)});
        const r = (sys.wait(pid, false) catch null) orelse fail("wait", .{});
        s.* = (now() - t0) / ticks_per_us;
        if (r.status != sys.abi.killed_status) fail("killed child: status {d}", .{r.status});
        sys.close(p[0]) catch {};
        sys.close(p[1]) catch {};
    }
    return median(&samples);
}

fn wakeupLatency() u64 {
    const ping = pipe();
    const pong = pipe();
    const pid = fork();
    if (pid == 0) {
        // 每读到一个字节，把醒来的时刻写回去。自己关掉 ping 的写端，父进程关了它之后才读得到结尾
        sys.close(ping[1]) catch {};
        var b: [1]u8 = undefined;
        while ((sys.read(ping[0], &b) catch 0) == 1) {
            const t = now();
            sys.writeAll(pong[1], std.mem.asBytes(&t)) catch {};
        }
        sys.exit(0);
    }
    var samples: [rounds]u64 = undefined;
    for (&samples) |*s| {
        const t0 = now();
        _ = sys.write(ping[1], "!") catch {};
        while (now() - t0 < 20_000 * ticks_per_us) {}
        var t1: u64 = undefined;
        if ((sys.read(pong[0], std.mem.asBytes(&t1)) catch 0) != @sizeOf(u64)) fail("read pong", .{});
        s.* = (t1 -| t0) / ticks_per_us;
    }
    sys.close(ping[1]) catch {};
    _ = sys.wait(pid, false) catch {};
    for ([_]sys.Fd{ ping[0], pong[0], pong[1] }) |fd| sys.close(fd) catch {};
    return median(&samples);
}

pub fn main() u8 {
    const kill = killLatency();
    const wakeup = wakeupLatency();
    sys.print("ipi latency (median of {d}): kill {d} us, wakeup {d} us\n", .{ rounds, kill, wakeup });
    return 0;
}
