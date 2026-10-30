//! 列出目录：`ls [路径...]`，不给路径时是当前目录。每个名字一行：种类、链接数、字节数（设备文件是设备号）、名字。
//! 给的是文件的话只列它自己。给了几个路径时，每个目录前面先打印一行 `路径:`。

const std = @import("std");
const sys = @import("sys");
const abi = sys.abi;

pub fn main() u8 {
    var status: u8 = 0;
    if (sys.argv.len <= 1) return list(".", false);
    for (sys.argv[1..]) |a| status |= list(a.slice(), sys.argv.len > 2);
    return status;
}

fn kindName(k: abi.FileKind) []const u8 {
    return switch (k) {
        .file => "file",
        .dir => "dir",
        .device => "dev",
        else => "?",
    };
}

fn list(path: []const u8, header: bool) u8 {
    const fd = sys.open(path, .{}) catch |err| {
        sys.print("ls: {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    defer sys.close(fd) catch {};
    const st = sys.fstat(fd) catch |err| {
        sys.print("ls: {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    if (st.kind != .dir) {
        printEntry(st.kind, st, path);
        return 0;
    }
    if (header) sys.print("{s}:\n", .{path});
    var ent: abi.Dirent = undefined;
    while (sys.readdir(fd, &ent) catch |err| {
        sys.print("ls: {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    }) {
        const name = ent.name[0..ent.name_len];
        // 文件的大小、链接数要打开它才知道：路径是 目录/名字。打不开的（比如内核不认识的设备）记成 0
        var buf: [abi.max_path]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ path, name }) catch name;
        const st_ent: abi.Stat = if (sys.open(full, .{})) |f| blk: {
            defer sys.close(f) catch {};
            break :blk sys.fstat(f) catch .{ .ino = 0, .size = 0, .kind = ent.kind };
        } else |_| .{ .ino = 0, .size = 0, .kind = ent.kind };
        printEntry(ent.kind, st_ent, name);
    }
    return 0;
}

fn printEntry(kind: abi.FileKind, st: abi.Stat, name: []const u8) void {
    const size = if (kind == .device) st.major else st.size;
    sys.print("{s:<4} {d:>2} {d:>8} {s}\n", .{ kindName(kind), st.nlink, size, name });
}
