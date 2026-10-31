//! 打印文件（不给文件名时是标准输入）的前几行：`head [-n N] [FILE...]`，默认 10 行。
//! 给了几个文件时，每个前面先打印一行 `==> 名字 <==`。

const std = @import("std");
const sys = @import("sys");

pub fn main() u8 {
    var count: u64 = 10;
    var first: usize = 1;
    if (sys.arg(1)) |a| {
        if (std.mem.eql(u8, a, "-n")) {
            const n = sys.arg(2) orelse return usage();
            count = std.fmt.parseInt(u64, n, 10) catch return usage();
            first = 3;
        }
    }
    const files = sys.argv[@min(first, sys.argv.len)..];
    if (files.len == 0) return head(sys.stdin, "stdin", count);
    var status: u8 = 0;
    for (files, 0..) |f, i| {
        const fd = sys.open(f.slice(), .{}) catch |err| {
            sys.fprint(sys.stderr, "head: {s}: {s}\n", .{ f.slice(), @errorName(err) });
            status = 1;
            continue;
        };
        defer sys.close(fd) catch {};
        if (files.len > 1) sys.print("{s}==> {s} <==\n", .{ if (i > 0) "\n" else "", f.slice() });
        status |= head(fd, f.slice(), count);
    }
    return status;
}

var buf: [4096]u8 = undefined;

fn head(fd: sys.Fd, name: []const u8, count: u64) u8 {
    var r = sys.LineReader.init(fd, &buf);
    var n: u64 = 0;
    while (n < count) : (n += 1) {
        // 带着换行原样输出（一次写完整行；最后一行没有换行的话也照原样）
        const line = (r.nextRaw() catch |err| {
            sys.fprint(sys.stderr, "head: {s}: {s}\n", .{ name, @errorName(err) });
            return 1;
        }) orelse break;
        sys.writeAll(sys.stdout, line) catch return 1;
    }
    return 0;
}

fn usage() u8 {
    sys.fprint(sys.stderr, "usage: head [-n N] [FILE...]\n", .{});
    return 2;
}
