//! 打印文件（不给文件名时是标准输入）的最后几行：`tail [-n N] [FILE...]`，默认 10 行。
//! 给了几个文件时，每个前面先打印一行 `==> 名字 <==`。
//!
//! 要读到结尾才知道哪些是最后几行，所以整个输入先读进堆里（sbrk）：内核按需分配，读了多少才用多少内存，
//! 不用事先知道输入有多长。

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
    if (files.len == 0) return tail(sys.stdin, "stdin", count);
    var status: u8 = 0;
    for (files, 0..) |f, i| {
        const fd = sys.open(f.slice(), .{}) catch |err| {
            sys.fprint(sys.stderr, "tail: {s}: {s}\n", .{ f.slice(), @errorName(err) });
            status = 1;
            continue;
        };
        defer sys.close(fd) catch {};
        if (files.len > 1) sys.print("{s}==> {s} <==\n", .{ if (i > 0) "\n" else "", f.slice() });
        status |= tail(fd, f.slice(), count);
    }
    return status;
}

/// 堆每次长这么多。只是挪 brk，真正用到的页才分配
const grow_step = 1 << 20;
/// 每次最多读这么多：read 会先检查（也就分配好）整个目标范围，一次给它 1 MiB 的话，输入只有几个字节也要分配 1 MiB
const read_max = 64 * 1024;

fn tail(fd: sys.Fd, name: []const u8, count: u64) u8 {
    const base = sys.sbrk(0) catch return 1;
    defer _ = sys.sbrk(-@as(isize, @intCast((sys.sbrk(0) catch base) - base))) catch {};
    var cap: usize = 0;
    var len: usize = 0;
    while (true) {
        if (len == cap) {
            _ = sys.sbrk(grow_step) catch {
                sys.fprint(sys.stderr, "tail: {s}: out of memory\n", .{name});
                return 1;
            };
            cap += grow_step;
        }
        const data: [*]u8 = @ptrFromInt(base);
        const n = sys.read(fd, data[len..@min(cap, len + read_max)]) catch |err| {
            sys.fprint(sys.stderr, "tail: {s}: {s}\n", .{ name, @errorName(err) });
            return 1;
        };
        if (n == 0) break;
        len += n;
    }
    const data = @as([*]const u8, @ptrFromInt(base))[0..len];
    // 从后往前数 count 个换行（结尾的那个换行不算：它结束的是最后一行）
    var start = len;
    var lines: u64 = 0;
    var i = if (len > 0 and data[len - 1] == '\n') len - 1 else len;
    while (i > 0 and lines < count) {
        i -= 1;
        if (data[i] == '\n') {
            lines += 1;
            if (lines == count) break;
        }
        start = i;
    }
    if (count == 0) start = len;
    sys.writeAll(sys.stdout, data[start..]) catch return 1;
    return 0;
}

fn usage() u8 {
    sys.fprint(sys.stderr, "usage: tail [-n N] [FILE...]\n", .{});
    return 2;
}
