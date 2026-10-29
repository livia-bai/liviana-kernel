//! 建目录：`mkdir 目录...`。

const sys = @import("sys");

pub fn main() u8 {
    if (sys.argv.len <= 1) {
        sys.print("usage: mkdir DIR...\n", .{});
        return 1;
    }
    var status: u8 = 0;
    for (sys.argv[1..]) |a| {
        sys.mkdir(a.slice()) catch |err| {
            sys.print("mkdir: {s}: {s}\n", .{ a.slice(), @errorName(err) });
            status = 1;
        };
    }
    return status;
}
