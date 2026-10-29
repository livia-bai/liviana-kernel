//! 回归测试：命令行参数。
//! - `run t_args A B ...`：打印 argc、每个参数和总字节数，退出码是 argc。qemu_test.py 用它检查 shell 怎么拆参数。
//! - `run t_args check`：测 exec 传参数的边界情况，失败的项打印 "FAIL: ..."，最后打印通过的项数。
//!   要看子进程收到的参数时，把它的标准输出接到管道上，读回来检查（顺便测了 exec 保留打开的文件）。

const std = @import("std");
const sys = @import("sys");
const abi = sys.abi;

pub fn main() u8 {
    if (sys.arg(1)) |a| {
        if (std.mem.eql(u8, a, "check")) return check();
    }
    var total: usize = 0;
    sys.print("argc={d}\n", .{sys.argv.len});
    for (sys.argv, 0..) |a, i| {
        sys.print("argv[{d}]=\"{s}\"\n", .{ i, a.slice() });
        total += a.len;
    }
    sys.print("total {d} bytes\n", .{total});
    return @intCast(sys.argv.len);
}

var failures: u8 = 0;
var checks: usize = 0;

fn expect(ok: bool, comptime what: []const u8, args: anytype) void {
    checks += 1;
    if (!ok) {
        failures += 1;
        sys.print("FAIL: " ++ what ++ "\n", args);
    }
}

const kernel_addr: usize = 0x8020_0000;

fn check() u8 {
    // 栈上的参数：16 字节对齐，在用户栈的最顶上一页里
    const argv_addr = @intFromPtr(sys.argv.ptr);
    expect(argv_addr % 16 == 0 and argv_addr < 0x8000_0000 and argv_addr >= 0x8000_0000 - 4096, "argv at 0x{x}", .{argv_addr});

    // 参数太多、太长：exec 失败，原来的程序照常运行
    var many: [abi.max_args + 1]abi.Arg = @splat(abi.Arg.of("x"));
    expect(sys.execRaw("t_args", &many) == error.ArgsTooLong, "exec with {d} arguments", .{many.len});
    const long: [abi.max_arg_bytes / 2 + 1]u8 = @splat('y');
    expect(sys.exec("t_args", &.{ &long, &long }) == error.ArgsTooLong, "exec with {d} bytes of arguments", .{2 * long.len});
    // 坏指针：参数数组、参数本身
    expect(errnoOfExec(kernel_addr, 1) == .fault, "exec with a bad argv pointer", .{});
    const bad = [_]abi.Arg{ .of("t_args"), .{ .ptr = kernel_addr, .len = 4 } };
    expect(errnoOfExec(@intFromPtr(&bad), bad.len) == .fault, "exec with a bad argument pointer", .{});
    // 长度为 0 的参数不检查指针
    const empty = [_]abi.Arg{ .of("t_args"), .{ .ptr = 0, .len = 0 } };
    expectOutput(&empty, "argc=2\nargv[0]=\"t_args\"\nargv[1]=\"\"\ntotal 6 bytes\n", 2);

    // 正好 max_args 个参数、max_arg_bytes 字节：t_args 加 14 个 64 字节的，最后一个凑满（122 字节）
    {
        var args: [abi.max_args][]const u8 = undefined;
        const filler: [128]u8 = @splat('z');
        args[0] = "t_args";
        for (args[1 .. args.len - 1]) |*a| a.* = filler[0..64];
        args[args.len - 1] = filler[0 .. abi.max_arg_bytes - 6 - 64 * (abi.max_args - 2)];
        var a: [abi.max_args]abi.Arg = undefined;
        for (args, &a) |s, *x| x.* = .of(s);
        var expected: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&expected);
        w.print("argc={d}\n", .{abi.max_args}) catch unreachable;
        for (args, 0..) |s, i| w.print("argv[{d}]=\"{s}\"\n", .{ i, s }) catch unreachable;
        w.print("total {d} bytes\n", .{abi.max_arg_bytes}) catch unreachable;
        expectOutput(&a, w.buffered(), abi.max_args);
    }
    // 没有参数
    expectOutput(&.{}, "argc=0\ntotal 0 bytes\n", 0);

    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}

fn errnoOfExec(argv_ptr: usize, argc: usize) ?abi.Errno {
    const name = "t_args";
    return abi.errnoOf(sys.syscall4(.exec, @intFromPtr(name.ptr), name.len, argv_ptr, argc));
}

/// 子进程的标准输出换成管道的写端，exec t_args，参数是 args；读出它的全部输出，和 expected 比较。
fn expectOutput(args: []const abi.Arg, expected: []const u8, code: u32) void {
    const fds = sys.pipe() catch |err| return expect(false, "pipe: {s}", .{@errorName(err)});
    const pid = sys.fork() catch |err| return expect(false, "fork: {s}", .{@errorName(err)});
    if (pid == 0) {
        sys.close(sys.stdout) catch {};
        _ = sys.dup(fds[1]) catch {};
        sys.close(fds[0]) catch {};
        sys.close(fds[1]) catch {};
        sys.execRaw("t_args", args) catch {};
        sys.exit(200);
    }
    sys.close(fds[1]) catch {};
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = sys.read(fds[0], buf[len..]) catch break;
        if (n == 0) break;
        len += n;
    }
    sys.close(fds[0]) catch {};
    const r = (sys.wait(pid, false) catch null).?;
    expect(std.mem.eql(u8, buf[0..len], expected), "exec with {d} arguments printed:\n{s}", .{ args.len, buf[0..len] });
    expect(r.status == code, "exec with {d} arguments: status {d}", .{ args.len, r.status });
}
