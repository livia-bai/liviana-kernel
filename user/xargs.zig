//! 把标准输入里的词当成参数，运行一个程序：`xargs [-n N] [PROGRAM [ARGS...]]`，不给程序时是 echo。
//! 词按空格、制表符、换行分开（不认引号）。每次最多 N 个词（不给 -n 时能放多少放多少），
//! 接在 ARGS 后面运行一次 PROGRAM，等它结束再运行下一批。配合 seq 当循环用：
//! `seq 3 | xargs -n 1 echo hi` 打印三行 `hi 1`、`hi 2`、`hi 3`。
//! 程序和 shell 里一样在 /bin 里找（名字里没有 '/' 的话）。
//! 退出码：都成功是 0；有一次以非 0 结束（或者被杀了）是 123；程序运行不起来是 127（和 GNU xargs 一样）。

const std = @import("std");
const sys = @import("sys");
const abi = sys.abi;

var per_run: usize = abi.max_args;
/// 固定的部分（程序名和 ARGS），后面接上从标准输入读到的词
var argv: [abi.max_args]abi.Arg = undefined;
var fixed: usize = 0;
/// 这一批的词存在这里（Arg 指向它）
var words: [abi.max_arg_bytes]u8 = undefined;
var used: usize = 0;
var status: u8 = 0;

pub fn main() u8 {
    var i: usize = 1;
    if (sys.arg(1)) |a| {
        if (std.mem.eql(u8, a, "-n")) {
            const n = sys.arg(2) orelse return usage();
            per_run = std.fmt.parseInt(usize, n, 10) catch return usage();
            if (per_run == 0) return usage();
            i = 3;
        }
    }
    const cmd = sys.argv[@min(i, sys.argv.len)..];
    if (cmd.len == 0) {
        argv[0] = .of("echo");
        fixed = 1;
    } else {
        if (cmd.len >= abi.max_args) {
            sys.fprint(sys.stderr, "xargs: too many arguments\n", .{});
            return 2;
        }
        for (cmd, argv[0..cmd.len]) |c, *a| a.* = c;
        fixed = cmd.len;
    }
    var n: usize = fixed;
    var buf: [1024]u8 = undefined;
    var r = sys.LineReader.init(sys.stdin, &buf);
    while (r.next() catch return 1) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        while (it.next()) |w| {
            if (w.len > words.len) {
                sys.fprint(sys.stderr, "xargs: argument too long\n", .{});
                return 2;
            }
            // 这一批放不下了（个数、字节数）就先运行掉
            if (n - fixed == per_run or n == abi.max_args or used + w.len > words.len) {
                if (run(n) == .stop) return status;
                n = fixed;
            }
            @memcpy(words[used..][0..w.len], w);
            argv[n] = .{ .ptr = @intFromPtr(&words[used]), .len = w.len };
            used += w.len;
            n += 1;
        }
    }
    // 最后一批；一个词都没读到时，不给 -n 的话也运行一次（和 GNU xargs 一样，echo 打印一个空行）
    if (n > fixed or cmd.len == 0) _ = run(n);
    return status;
}

const Next = enum { go_on, stop };

/// 运行 argv[0..n]，等它结束。程序运行不起来时停下（后面的也一样运行不起来）。
fn run(n: usize) Next {
    defer used = 0;
    const pid = sys.fork() catch |err| {
        sys.fprint(sys.stderr, "xargs: cannot fork: {s}\n", .{@errorName(err)});
        status = 127;
        return .stop;
    };
    if (pid == 0) {
        const name = argv[0].slice();
        sys.execRaw(name, argv[0..n]) catch |err| {
            sys.fprint(sys.stderr, "xargs: {s}: {s}\n", .{ name, @errorName(err) });
            sys.exit(127);
        };
    }
    const r = (sys.wait(pid, false) catch return .stop) orelse return .stop;
    if (r.status == 127) {
        status = 127;
        return .stop;
    }
    if (r.status != 0) status = 123;
    return .go_on;
}

fn usage() u8 {
    sys.fprint(sys.stderr, "usage: xargs [-n N] [PROGRAM [ARGS...]]\n", .{});
    return 2;
}
