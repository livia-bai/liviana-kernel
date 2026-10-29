//! 把文件（没给文件名时是标准输入）原样复制到标准输出：`cat [文件...]`。
//! 也常放在管道中间：`run echo hi | cat | wc`。直接从键盘读时输入不回显，按 Ctrl-D 结束。

const sys = @import("sys");

pub fn main() u8 {
    if (sys.argv.len <= 1) return copy(sys.stdin, "stdin");
    var status: u8 = 0;
    for (sys.argv[1..]) |a| {
        const fd = sys.open(a.slice(), .{}) catch |err| {
            sys.print("cat: {s}: {s}\n", .{ a.slice(), @errorName(err) });
            status = 1;
            continue;
        };
        status |= copy(fd, a.slice());
        sys.close(fd) catch {};
    }
    return status;
}

fn copy(fd: sys.Fd, name: []const u8) u8 {
    var buf: [512]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf) catch |err| {
            sys.print("cat: {s}: {s}\n", .{ name, @errorName(err) });
            return 1;
        };
        if (n == 0) return 0;
        sys.writeAll(sys.stdout, buf[0..n]) catch return 1;
    }
}
