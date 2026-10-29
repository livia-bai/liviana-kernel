//! 回归测试：多核下的并发。几个工作进程同时（多核时在不同的 hart 上）fork / exit / wait、
//! 往同一个管道里写、sbrk、留下交给 init 的孤儿；再杀掉几个正在 U 模式里死循环的进程。
//! 检查每一步的结果都对。单核时也能跑，只是没有真正的并发。
//! 失败的项打印 "FAIL: ..."，最后打印通过的项数。漏页由 qemu_test.py 比较前后的 mem 发现。

const sys = @import("sys");
const abi = sys.abi;

var failures: u8 = 0;
var checks: usize = 0;

fn expect(ok: bool, comptime what: []const u8, args: anytype) void {
    checks += 1;
    if (!ok) {
        failures += 1;
        sys.print("FAIL: " ++ what ++ "\n", args);
    }
}

fn fork() usize {
    return sys.fork() catch |err| {
        sys.print("FAIL: fork: {s}\n", .{@errorName(err)});
        sys.exit(200);
    };
}

/// 工作进程的个数。进程表 16 项：init、sh、t_smp 占 3 个，每个工作进程同时最多再有 1 个子进程
const workers = 6;
const rounds = 30;
const chunk = 64;

/// 工作进程 i：返回 0 表示一切正常，否则是出错的那一步。
fn worker(i: usize, wfd: sys.Fd) u8 {
    // 1. fork / exit / wait：别的工作进程在别的 hart 上同时做同样的事
    for (0..rounds) |r| {
        const pid = sys.fork() catch return 1;
        if (pid == 0) sys.exit(@truncate(r + i));
        const res = (sys.wait(pid, false) catch return 2) orelse return 3;
        if (res.pid != pid or res.status != r + i) return 4;
    }
    // 2. 都往同一个管道里写，写满了就等
    const bytes: [chunk]u8 = @splat(@truncate('a' + i));
    for (0..rounds) |_| sys.writeAll(wfd, &bytes) catch return 5;
    sys.close(wfd) catch return 6;
    // 3. sbrk：几个 hart 同时分配、释放物理页
    for (0..rounds) |_| {
        const old = sys.sbrk(3 * 4096) catch return 7;
        const p: [*]volatile u8 = @ptrFromInt(old);
        p[0] = 1;
        p[3 * 4096 - 1] = 2;
        _ = sys.sbrk(-3 * 4096) catch return 8;
    }
    // 4. 留下一个孤儿：自己先结束，它交给 init 回收
    const orphan = sys.fork() catch return 9;
    if (orphan == 0) {
        sys.sleep(20);
        sys.exit(0);
    }
    return 0;
}

fn spinForever() noreturn {
    while (true) {}
}

pub fn main() u8 {
    const fds = sys.pipe() catch |err| {
        sys.print("FAIL: pipe: {s}\n", .{@errorName(err)});
        return 200;
    };
    var pids: [workers]usize = undefined;
    for (&pids, 0..) |*pid, i| {
        pid.* = fork();
        if (pid.* == 0) {
            sys.close(fds[0]) catch {};
            sys.exit(worker(i, fds[1]));
        }
    }
    sys.close(fds[1]) catch {};

    // 读到结尾（所有工作进程都关了写端），数每个工作进程写了多少
    var counts: [workers]usize = @splat(0);
    var other: usize = 0;
    var buf: [256]u8 = undefined;
    while (true) {
        const n = sys.read(fds[0], &buf) catch break;
        if (n == 0) break;
        for (buf[0..n]) |c| {
            if (c >= 'a' and c < 'a' + workers) counts[c - 'a'] += 1 else other += 1;
        }
    }
    sys.close(fds[0]) catch {};
    for (counts, 0..) |n, i| expect(n == rounds * chunk, "worker {d} wrote {d} bytes", .{ i, n });
    expect(other == 0, "{d} unexpected bytes in the pipe", .{other});

    for (pids, 0..) |pid, i| {
        const res = (sys.wait(pid, false) catch null) orelse {
            expect(false, "wait for worker {d}", .{i});
            continue;
        };
        expect(res.status == 0, "worker {d} failed at step {d}", .{ i, res.status });
    }
    expect(sys.wait(null, true) == error.NoChildren, "children left after waiting for all workers", .{});

    // 杀掉正在 U 模式里死循环的进程：多核时它们在别的 hart 上运行，等那个 hart 的时钟中断才会结束
    var spinners: [3]usize = undefined;
    for (&spinners) |*pid| {
        pid.* = fork();
        if (pid.* == 0) spinForever();
    }
    sys.sleep(50);
    for (spinners) |pid| sys.kill(pid) catch expect(false, "kill {d}", .{pid});
    for (spinners) |pid| {
        const res = (sys.wait(pid, false) catch null) orelse {
            expect(false, "wait for spinner {d}", .{pid});
            continue;
        };
        expect(res.status == abi.killed_status, "spinner {d} status {d}", .{ pid, res.status });
    }

    sys.sleep(100); // 等孤儿结束、被 init 回收，免得 qemu_test.py 比较 mem 时它们还占着页
    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}
