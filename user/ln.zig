//! 硬链接：`ln 旧 新`，或者 `ln 路径... 目录`（在这个已有的目录里建同名的链接）。
//! 每一个都是一次 link 系统调用：新名字和旧名字是同一个文件，改了内容两边都看得到，删掉一个另一个照常。
//! 目录不能链接（PermissionDenied），新名字已经有了是 Exists。

const std = @import("std");
const sys = @import("sys");

pub fn main() u8 {
    const args = sys.argv;
    if (args.len < 3) {
        sys.print("usage: ln OLD NEW, or ln PATH... DIR\n", .{});
        return 1;
    }
    const dst = args[args.len - 1].slice();
    const into_dir = isDir(dst);
    if (args.len > 3 and !into_dir) {
        sys.print("ln: {s}: not a directory\n", .{dst});
        return 1;
    }
    var status: u8 = 0;
    for (args[1 .. args.len - 1]) |a| {
        const src = a.slice();
        var buf: [sys.abi.max_path]u8 = undefined;
        // 链接进目录：新名字是 目录/旧名字的最后一段
        const new = if (into_dir) std.fmt.bufPrint(&buf, "{s}/{s}", .{ dst, std.fs.path.basenamePosix(src) }) catch {
            sys.print("ln: {s}: path too long\n", .{src});
            status = 1;
            continue;
        } else dst;
        sys.link(src, new) catch |err| {
            sys.print("ln: {s} -> {s}: {s}\n", .{ src, new, @errorName(err) });
            status = 1;
        };
    }
    return status;
}

fn isDir(path: []const u8) bool {
    const fd = sys.open(path, .{}) catch return false;
    defer sys.close(fd) catch {};
    const st = sys.fstat(fd) catch return false;
    return st.kind == .dir;
}
