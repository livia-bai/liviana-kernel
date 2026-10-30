//! 改名、挪地方：`mv 旧 新`，或者 `mv 路径... 目录`（挪进这个已有的目录，名字不变）。
//! 每一个都是一次 rename 系统调用：新名字已经有了的话换掉它（文件换文件、目录换空目录）。

const std = @import("std");
const sys = @import("sys");

pub fn main() u8 {
    const args = sys.argv;
    if (args.len < 3) {
        sys.print("usage: mv OLD NEW, or mv PATH... DIR\n", .{});
        return 1;
    }
    const dst = args[args.len - 1].slice();
    const into_dir = isDir(dst);
    if (args.len > 3 and !into_dir) {
        sys.print("mv: {s}: not a directory\n", .{dst});
        return 1;
    }
    var status: u8 = 0;
    for (args[1 .. args.len - 1]) |a| {
        const src = a.slice();
        var buf: [sys.abi.max_path]u8 = undefined;
        // 挪进目录：新名字是 目录/旧名字的最后一段
        const new = if (into_dir) std.fmt.bufPrint(&buf, "{s}/{s}", .{ dst, std.fs.path.basenamePosix(src) }) catch {
            sys.print("mv: {s}: path too long\n", .{src});
            status = 1;
            continue;
        } else dst;
        sys.rename(src, new) catch |err| {
            sys.print("mv: {s} -> {s}: {s}\n", .{ src, new, @errorName(err) });
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
