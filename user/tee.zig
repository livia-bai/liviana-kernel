//! 把标准输入复制到标准输出，同时写进每个文件：`tee [-a] FILE...`（-a 追加，不截断）。
//! 放在管道中间看中间结果：`seq 3 | tee /log | wc`。打不开的文件报错、跳过，最后以 1 结束。

const std = @import("std");
const sys = @import("sys");

pub fn main() u8 {
    var append = false;
    var first: usize = 1;
    if (sys.arg(1)) |a| {
        if (std.mem.eql(u8, a, "-a")) {
            append = true;
            first = 2;
        }
    }
    var fds: [sys.abi.max_fds]sys.Fd = undefined;
    var nfds: usize = 0;
    var status: u8 = 0;
    for (sys.argv[@min(first, sys.argv.len)..]) |a| {
        if (nfds == fds.len) break;
        fds[nfds] = sys.open(a.slice(), .{ .read = false, .write = true, .create = true, .truncate = !append, .append = append }) catch |err| {
            sys.fprint(sys.stderr, "tee: {s}: {s}\n", .{ a.slice(), @errorName(err) });
            status = 1;
            continue;
        };
        nfds += 1;
    }
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.read(sys.stdin, &buf) catch return 1;
        if (n == 0) break;
        sys.writeAll(sys.stdout, buf[0..n]) catch {
            status = 1;
        };
        for (fds[0..nfds]) |fd| sys.writeAll(fd, buf[0..n]) catch {
            status = 1;
        };
    }
    for (fds[0..nfds]) |fd| sys.close(fd) catch {};
    return status;
}
