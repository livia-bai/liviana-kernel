//! 链接：`ln 旧 新`、`ln 路径... 目录`（在这个已有的目录里建同名的链接）；加 `-s` 建符号链接。
//!
//! - 硬链接：每一个都是一次 link 系统调用，新名字和旧名字是同一个文件，改了内容两边都看得到，删掉一个另一个照常。
//!   目录不能链接（PermissionDenied），新名字已经有了是 Exists。
//! - 符号链接（`ln -s 目标 新`）：每一个都是一次 symlink 系统调用，新名字里存的就是“目标”这个字符串，
//!   用到时才解析：目标可以还不存在，相对的目标从链接所在的目录算起（不是从当前目录），和 Unix 的 ln -s 一样。

const std = @import("std");
const sys = @import("sys");

pub fn main() u8 {
    var args = sys.argv[@min(1, sys.argv.len)..];
    const soft = args.len > 0 and std.mem.eql(u8, args[0].slice(), "-s");
    if (soft) args = args[1..];
    if (args.len < 2) {
        sys.print("usage: ln [-s] OLD NEW, or ln [-s] PATH... DIR\n", .{});
        return 1;
    }
    const dst = args[args.len - 1].slice();
    const into_dir = isDir(dst);
    if (args.len > 2 and !into_dir) {
        sys.print("ln: {s}: not a directory\n", .{dst});
        return 1;
    }
    var status: u8 = 0;
    for (args[0 .. args.len - 1]) |a| {
        const src = a.slice();
        var buf: [sys.abi.max_path]u8 = undefined;
        // 链接进目录：新名字是 目录/旧名字的最后一段
        const new = if (into_dir) std.fmt.bufPrint(&buf, "{s}/{s}", .{ dst, std.fs.path.basenamePosix(src) }) catch {
            sys.print("ln: {s}: path too long\n", .{src});
            status = 1;
            continue;
        } else dst;
        const result = if (soft) sys.symlink(src, new) else sys.link(src, new);
        result catch |err| {
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
