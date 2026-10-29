//! 回归测试：pipe、read、write、close、dup 的正常情况和边界情况，包括写满了阻塞、读到结尾、
//! 读端关了写失败、在管道上睡着时被 kill。失败的项打印 "FAIL: ..."，最后打印通过的项数。
//! 由 shell 前台运行，fd 0、1、2 是串口。打开的文件没关好、管道没释放的话，qemu_test.py 比较前后的 mem 会发现。

const std = @import("std");
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

fn errno(ret: usize) ?abi.Errno {
    return abi.errnoOf(ret);
}

fn newPipe() [2]sys.Fd {
    return sys.pipe() catch |err| {
        sys.print("FAIL: pipe: {s}\n", .{@errorName(err)});
        sys.exit(200);
    };
}

fn fork() usize {
    return sys.fork() catch |err| {
        sys.print("FAIL: fork: {s}\n", .{@errorName(err)});
        sys.exit(200);
    };
}

/// 比管道的缓冲区（2048 字节）大，写的一方一定要等读的一方读走一些
const big = 5000;
var pattern: [big]u8 = undefined;

pub fn main() u8 {
    for (&pattern, 0..) |*b, i| b.* = @truncate(i * 7);

    // 基本读写；fd 是最小的空闲编号
    {
        const p = newPipe();
        expect(p[0] == 3 and p[1] == 4, "pipe fds {d} {d}", .{ p[0], p[1] });
        expect((sys.write(p[1], "hello") catch 0) == 5, "write to a pipe", .{});
        var buf: [16]u8 = undefined;
        const n = sys.read(p[0], &buf) catch 0;
        expect(std.mem.eql(u8, buf[0..n], "hello"), "read back \"{s}\"", .{buf[0..n]});
        // 方向不对
        expect(sys.write(p[0], "x") == error.BadFd, "write to the read end", .{});
        expect(sys.read(p[1], &buf) == error.BadFd, "read from the write end", .{});
        // 写端关了：读到结尾
        sys.close(p[1]) catch {};
        expect((sys.read(p[0], &buf) catch 99) == 0, "read after the write end closed", .{});
        sys.close(p[0]) catch {};
    }

    // 子进程写 5000 字节（写满了就等），父进程读到结尾，内容一字不差；子进程结束时写端自动关上
    {
        const p = newPipe();
        const pid = fork();
        if (pid == 0) {
            sys.close(p[0]) catch {};
            sys.exit(if ((sys.write(p[1], &pattern) catch 0) == big) 0 else 1);
        }
        sys.close(p[1]) catch {};
        sys.sleep(50); // 让子进程先写满、睡下
        var buf: [big + 100]u8 = undefined;
        var len: usize = 0;
        var reads: usize = 0;
        while (len < buf.len) : (reads += 1) {
            const n = sys.read(p[0], buf[len..]) catch break;
            if (n == 0) break;
            len += n;
        }
        expect(len == big and std.mem.eql(u8, buf[0..len], &pattern), "read {d} bytes through the pipe", .{len});
        expect(reads >= 3, "{d} bytes in {d} reads: the writer should have blocked", .{ len, reads });
        const r = (sys.wait(pid, false) catch null).?;
        expect(r.status == 0, "writer exited with {d}", .{r.status});
        sys.close(p[0]) catch {};
    }

    // 读的一方先睡下，写的一方过一会儿才写
    {
        const p = newPipe();
        const pid = fork();
        if (pid == 0) {
            sys.sleep(50);
            _ = sys.write(p[1], "late") catch {};
            sys.exit(0);
        }
        var buf: [16]u8 = undefined;
        const start = sys.uptime();
        const n = sys.read(p[0], &buf) catch 0;
        expect(std.mem.eql(u8, buf[0..n], "late") and sys.uptime() - start >= 40, "blocking read got \"{s}\"", .{buf[0..n]});
        _ = sys.wait(pid, false) catch {};
        sys.close(p[0]) catch {};
        sys.close(p[1]) catch {};
    }

    // 读端都关了：写返回 BrokenPipe；写满之后读端才关，睡着的写者被叫醒、写出一部分
    {
        const p = newPipe();
        sys.close(p[0]) catch {};
        expect(sys.write(p[1], "x") == error.BrokenPipe, "write with no reader", .{});
        sys.close(p[1]) catch {};

        const q = newPipe();
        const pid = fork();
        if (pid == 0) {
            sys.close(q[0]) catch {};
            const n = sys.write(q[1], &pattern) catch 0;
            sys.exit(if (n > 0 and n < big) 0 else 1);
        }
        sys.close(q[1]) catch {};
        sys.sleep(50);
        sys.close(q[0]) catch {};
        const r = (sys.wait(pid, false) catch null).?;
        expect(r.status == 0, "writer woken by closing the read end exited with {d}", .{r.status});
    }

    // 在管道上睡着时被 kill：读的、写的都能叫醒、结束
    for ([_]bool{ false, true }) |writer| {
        const p = newPipe();
        const pid = fork();
        if (pid == 0) {
            if (writer) {
                _ = sys.write(p[1], &pattern) catch {};
            } else {
                var buf: [1]u8 = undefined;
                _ = sys.read(p[0], &buf) catch {};
            }
            sys.exit(0);
        }
        sys.sleep(50);
        sys.kill(pid) catch {};
        const r = (sys.wait(pid, false) catch null).?;
        expect(r.status == abi.killed_status, "killed {s}: status {d}", .{ if (writer) "writer" else "reader", r.status });
        sys.close(p[0]) catch {};
        sys.close(p[1]) catch {};
    }

    // 坏的 fd
    {
        var buf: [4]u8 = undefined;
        expect(sys.read(99, &buf) == error.BadFd, "read fd 99", .{});
        expect(sys.read(abi.max_fds, &buf) == error.BadFd, "read fd max_fds", .{});
        expect(sys.write(7, "x") == error.BadFd, "write a closed fd", .{});
        expect(errno(sys.syscall(.write, std.math.maxInt(usize), 0, 0)) == .badf, "write fd -1", .{});
        expect(sys.close(5) == error.BadFd, "close a closed fd", .{});
        expect(sys.dup(9) == error.BadFd, "dup a closed fd", .{});
        expect(errno(sys.syscall(.pipe, 0x8020_0000, 0, 0)) == .fault, "pipe with a bad pointer", .{});
        // 坏地址：先检查 fd 再检查地址；管道里的数据不动
        const p = newPipe();
        expect(sys.write(p[1], @as([*]const u8, @ptrFromInt(0x8020_0000))[0..4]) == error.BadAddress, "write from kernel memory", .{});
        _ = sys.write(p[1], "ab") catch {};
        expect(sys.read(p[0], @as([*]u8, @ptrFromInt(0x8020_0000))[0..4]) == error.BadAddress, "read into kernel memory", .{});
        expect((sys.read(p[0], &buf) catch 0) == 2, "data stays in the pipe after a bad read", .{});
        sys.close(p[0]) catch {};
        sys.close(p[1]) catch {};
    }

    // dup：编号最小的空闲 fd；fd 表满了返回 TooManyOpenFiles，pipe 也一样，而且不漏
    {
        const d = sys.dup(sys.stdout) catch 0;
        expect(d == 3, "dup -> {d}", .{d});
        sys.close(d) catch {};
        var n: usize = 0;
        while (sys.dup(sys.stdout)) |_| n += 1 else |err| expect(err == error.TooManyOpenFiles, "dup error {s}", .{@errorName(err)});
        expect(n == abi.max_fds - 3, "dup'd {d} fds", .{n});
        expect(sys.pipe() == error.TooManyOpenFiles, "pipe with a full fd table", .{});
        sys.close(abi.max_fds - 1) catch {};
        expect(sys.pipe() == error.TooManyOpenFiles, "pipe with one free fd", .{});
        for (3..abi.max_fds - 1) |fd| sys.close(fd) catch {};
        const p = newPipe();
        expect(p[0] == 3 and p[1] == 4, "pipe fds {d} {d} after closing everything", .{ p[0], p[1] });
        sys.close(p[0]) catch {};
        sys.close(p[1]) catch {};
    }

    // fork 继承打开的文件：子进程关掉自己的 stdout，父进程的不受影响
    {
        const pid = fork();
        if (pid == 0) {
            sys.close(sys.stdout) catch {};
            sys.exit(if (sys.write(sys.stdout, "x") == error.BadFd) 0 else 1);
        }
        const r = (sys.wait(pid, false) catch null).?;
        expect(r.status == 0, "child closing stdout: status {d}", .{r.status});
    }

    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}
