//! 删除文件或空目录：`rm 路径...`。

const sys = @import("sys");

pub fn main() u8 {
    if (sys.argv.len <= 1) {
        sys.print("usage: rm PATH...\n", .{});
        return 1;
    }
    var status: u8 = 0;
    for (sys.argv[1..]) |a| {
        sys.unlink(a.slice()) catch |err| {
            sys.print("rm: {s}: {s}\n", .{ a.slice(), @errorName(err) });
            status = 1;
        };
    }
    return status;
}
