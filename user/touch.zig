//! 文件没有就建一个空的：`touch FILE...`。已经有的不动（这个文件系统没有时间戳，没什么可更新的）。

const sys = @import("sys");

pub fn main() u8 {
    if (sys.argv.len <= 1) {
        sys.fprint(sys.stderr, "usage: touch FILE...\n", .{});
        return 2;
    }
    var status: u8 = 0;
    for (sys.argv[1..]) |a| {
        const fd = sys.open(a.slice(), .{ .create = true }) catch |err| {
            sys.fprint(sys.stderr, "touch: {s}: {s}\n", .{ a.slice(), @errorName(err) });
            status = 1;
            continue;
        };
        sys.close(fd) catch {};
    }
    return status;
}
