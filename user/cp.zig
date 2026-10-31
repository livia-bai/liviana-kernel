//! 复制文件：`cp SRC DST`、`cp SRC... DIR`（最后一个参数是目录时，复制进去，名字不变）。
//! DST 已经有了就覆盖（先截成 0 字节）。只复制普通文件的内容，目录不能复制。
//! 正在运行的程序不能被覆盖（TextBusy，见 docs/process.md 的按需分页）。

const std = @import("std");
const sys = @import("sys");

pub fn main() u8 {
    if (sys.argv.len < 3) {
        sys.fprint(sys.stderr, "usage: cp SRC DST | cp SRC... DIR\n", .{});
        return 2;
    }
    const last = sys.argv[sys.argv.len - 1].slice();
    const srcs = sys.argv[1 .. sys.argv.len - 1];
    const into_dir = isDir(last);
    if (srcs.len > 1 and !into_dir) {
        sys.fprint(sys.stderr, "cp: {s}: not a directory\n", .{last});
        return 1;
    }
    var status: u8 = 0;
    for (srcs) |s| {
        var path: [sys.abi.max_path]u8 = undefined;
        const dst = if (into_dir)
            std.fmt.bufPrint(&path, "{s}/{s}", .{ last, std.fs.path.basenamePosix(s.slice()) }) catch {
                sys.fprint(sys.stderr, "cp: {s}: name too long\n", .{s.slice()});
                status = 1;
                continue;
            }
        else
            last;
        status |= copy(s.slice(), dst);
    }
    return status;
}

fn isDir(path: []const u8) bool {
    const fd = sys.open(path, .{}) catch return false;
    defer sys.close(fd) catch {};
    const st = sys.fstat(fd) catch return false;
    return st.kind == .dir;
}

var buf: [4096]u8 = undefined;

fn copy(from: []const u8, to: []const u8) u8 {
    const in = sys.open(from, .{}) catch |err| return fail(from, err);
    defer sys.close(in) catch {};
    const st = sys.fstat(in) catch |err| return fail(from, err);
    if (st.kind == .dir) return fail(from, error.IsDir);
    // 复制到自己（同一个 inode，比如 cp a a、cp a ./a）：截断之前就要发现，不然内容就没了。和 Unix 一样报错
    if (sys.open(to, .{})) |fd| {
        defer sys.close(fd) catch {};
        const ost = sys.fstat(fd) catch |err| return fail(to, err);
        if (ost.ino == st.ino) {
            sys.fprint(sys.stderr, "cp: {s} and {s} are the same file\n", .{ from, to });
            return 1;
        }
    } else |_| {}
    const out = sys.open(to, .{ .read = false, .write = true, .create = true, .truncate = true }) catch |err| return fail(to, err);
    defer sys.close(out) catch {};
    while (true) {
        const n = sys.read(in, &buf) catch |err| return fail(from, err);
        if (n == 0) return 0;
        sys.writeAll(out, buf[0..n]) catch |err| return fail(to, err);
    }
}

fn fail(name: []const u8, err: anyerror) u8 {
    sys.fprint(sys.stderr, "cp: {s}: {s}\n", .{ name, @errorName(err) });
    return 1;
}
