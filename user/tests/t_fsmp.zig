//! 回归测试：多核下文件系统的并发。读者在快照上读，不挡着修改，修改之间还是一个一个来（docs/fs.md）。
//! - 2 个写者各自反复整个改写一个 3 页多的文件，每次一个 write（一个事务），换一个版本号；
//! - 1 个进程在 /t_fsmp/dir 下不停地建、改名、删文件和目录，树的结构一直在变；
//! - 3 个读者同时反复：一次 read 读出整个文件，检查读到的是某一个完整的版本（不会半新半旧），
//!   而且版本号不倒退；列目录；fork + exec 自己（`t_fsmp noop`），程序从文件系统加载。
//!   一直读到两个文件都是最后一个版本，所以写者写的整个过程中都有读者在读。
//! 失败的项打印 "FAIL: ..."，最后打印检查了几项、失败了几项。所有东西建在 /t_fsmp 下面，结束时删干净。
//! - `run t_fsmp noop`：什么都不做，返回 0（读者 exec 它）。

const std = @import("std");
const sys = @import("sys");

var failures: u8 = 0;
var checks: usize = 0;

fn expect(ok: bool, comptime what: []const u8, args: anytype) void {
    checks += 1;
    if (!ok) {
        failures += 1;
        sys.print("FAIL: " ++ what ++ "\n", args);
    }
}

fn fork() usize {
    return sys.fork() catch |err| {
        sys.print("FAIL: fork: {s}\n", .{@errorName(err)});
        sys.exit(200);
    };
}

fn waitStatus(pid: usize) u32 {
    const r = (sys.wait(pid, false) catch null) orelse return 999;
    return r.status;
}

/// 每个文件的长度：3 个整页加一点，内容在数据块里（不是内联的），一次 write 改 4 个数据块
const file_size = 3 * 4096 + 700;
const writers = 2;
const readers = 3;
const rounds = 30;
/// 读者最多读多久（毫秒）：写者都写完了读者就停，这只是防止出错时一直读下去
const max_read_ms = 40_000;
const paths = [writers][]const u8{ "/t_fsmp/a", "/t_fsmp/b" };

/// 版本 v 的内容：开头 8 字节是 v，之后每个字节都由 v 和位置决定
fn fill(buf: *[file_size]u8, v: u64) void {
    std.mem.writeInt(u64, buf[0..8], v, .little);
    for (buf[8..], 8..) |*c, i| c.* = @truncate((v *% 31 +% i *% 7) % 251);
}

/// buf 是不是某个完整的版本，是的话返回版本号
fn versionOf(buf: *const [file_size]u8) ?u64 {
    const v = std.mem.readInt(u64, buf[0..8], .little);
    for (buf[8..], 8..) |c, i| if (c != @as(u8, @truncate((v *% 31 +% i *% 7) % 251))) return null;
    return v;
}

var wbuf: [file_size]u8 = undefined;
var rbuf: [file_size + 1]u8 = undefined;

fn writeVersion(fd: sys.Fd, v: u64) bool {
    fill(&wbuf, v);
    _ = sys.lseek(fd, 0, .set) catch return false;
    const n = sys.write(fd, &wbuf) catch return false;
    return n == wbuf.len;
}

/// 写者 k：把自己的文件依次改写成版本 1..rounds。
fn writer(k: usize) u8 {
    const fd = sys.open(paths[k], .{ .write = true }) catch return 1;
    for (1..rounds + 1) |v| {
        if (!writeVersion(fd, v)) return 2;
        if (v % 8 == 0) sys.yield();
    }
    return 0;
}

/// 在 /t_fsmp/dir 下建、改名、删。NotFound、Exists 是正常的（名字可能已经被上一轮挪走了），别的错误算失败。
fn churn() u8 {
    var nb: [32]u8 = undefined;
    var mb: [32]u8 = undefined;
    for (0..rounds * 2) |j| {
        const f = std.fmt.bufPrint(&nb, "/t_fsmp/dir/f{d}", .{j % 5}) catch unreachable;
        const g = std.fmt.bufPrint(&mb, "/t_fsmp/dir/g{d}", .{j % 3}) catch unreachable;
        const fd = sys.open(f, .{ .write = true, .create = true, .truncate = true }) catch return 1;
        fill(&wbuf, j);
        _ = sys.write(fd, wbuf[0 .. 100 + j * 97 % 6000]) catch return 2;
        sys.close(fd) catch return 3;
        sys.rename(f, g) catch return 4;
        const h = std.fmt.bufPrint(&mb, "/t_fsmp/dir/g{d}", .{(j + 1) % 3}) catch unreachable;
        sys.unlink(h) catch |err| if (err != error.NotFound) return 5;
        if (j % 4 == 0) sys.mkdir("/t_fsmp/dir/d") catch |err| if (err != error.Exists) return 6;
        if (j % 4 == 2) sys.unlink("/t_fsmp/dir/d") catch |err| if (err != error.NotFound) return 7;
    }
    return 0;
}

/// 读者：反复读两个文件，每次都得是一个完整的版本，版本号不倒退；两个都读到最后一个版本就停。
fn reader() u8 {
    var last: [writers]u64 = @splat(0);
    const deadline = sys.uptime() + max_read_ms;
    var r: usize = 0;
    while (sys.uptime() < deadline) : (r += 1) {
        if (last[0] == rounds and last[1] == rounds) return 0;
        // 单核时读者都在 U 模式里忙，写者每等完一次磁盘都要排到读者的时间片之后：让一下，免得写者写得太慢
        sys.yield();
        for (paths, &last) |path, *l| {
            const fd = sys.open(path, .{}) catch return 1;
            defer sys.close(fd) catch {};
            const n = sys.read(fd, &rbuf) catch return 2;
            if (n != file_size) return 3; // 一次 read 读完整个文件（文件系统的 read 不会只读一部分）
            const v = versionOf(rbuf[0..file_size]) orelse return 4;
            if (v < l.*) return 5;
            l.* = v;
        }
        if (r % 8 == 0) {
            const fd = sys.open("/t_fsmp/dir", .{}) catch return 6;
            defer sys.close(fd) catch {};
            var ent: sys.abi.Dirent = undefined;
            var n: usize = 0;
            while (sys.readdir(fd, &ent) catch return 7) n += 1;
            if (n > 5 + 3 + 1) return 8;
        }
        if (r % 16 == 5) {
            const pid = sys.fork() catch return 9;
            if (pid == 0) {
                sys.exec("t_fsmp", &.{ "t_fsmp", "noop" }) catch {};
                sys.exit(77);
            }
            if (waitStatus(pid) != 0) return 10;
        }
    }
    return 11;
}

fn cleanup() void {
    for (paths) |p| sys.unlink(p) catch {};
    var nb: [32]u8 = undefined;
    for (0..5) |i| sys.unlink(std.fmt.bufPrint(&nb, "/t_fsmp/dir/f{d}", .{i}) catch unreachable) catch {};
    for (0..3) |i| sys.unlink(std.fmt.bufPrint(&nb, "/t_fsmp/dir/g{d}", .{i}) catch unreachable) catch {};
    sys.unlink("/t_fsmp/dir/d") catch {};
    sys.unlink("/t_fsmp/dir") catch {};
    sys.unlink("/t_fsmp") catch {};
}

pub fn main() u8 {
    if (sys.arg(1)) |a| {
        if (std.mem.eql(u8, a, "noop")) return 0;
    }
    cleanup();
    sys.mkdir("/t_fsmp") catch |err| sys.print("FAIL: mkdir /t_fsmp: {s}\n", .{@errorName(err)});
    sys.mkdir("/t_fsmp/dir") catch |err| sys.print("FAIL: mkdir /t_fsmp/dir: {s}\n", .{@errorName(err)});
    for (paths) |p| {
        const fd = sys.open(p, .{ .write = true, .create = true }) catch |err| {
            sys.print("FAIL: open {s}: {s}\n", .{ p, @errorName(err) });
            return 201;
        };
        expect(writeVersion(fd, 0), "write version 0 of {s}", .{p});
        sys.close(fd) catch {};
    }

    var pids: [writers + 1 + readers]usize = undefined;
    for (&pids, 0..) |*pid, i| {
        pid.* = fork();
        if (pid.* != 0) continue;
        sys.exit(if (i < writers) writer(i) else if (i == writers) churn() else reader());
    }
    for (pids, 0..) |pid, i| {
        const st = waitStatus(pid);
        const who = if (i < writers) "writer" else if (i == writers) "churn" else "reader";
        expect(st == 0, "{s} {d} failed at step {d}", .{ who, i, st });
    }

    // 都结束之后：两个文件都是最后一个版本
    for (paths) |p| {
        const fd = sys.open(p, .{}) catch {
            expect(false, "open {s} at the end", .{p});
            continue;
        };
        const n = sys.read(fd, &rbuf) catch 0;
        sys.close(fd) catch {};
        const v = if (n == file_size) versionOf(rbuf[0..file_size]) else null;
        expect(v == rounds, "{s}: final version {?d}, size {d}", .{ p, v, n });
    }
    cleanup();
    expect(sys.open("/t_fsmp", .{}) == error.NotFound, "/t_fsmp removed", .{});
    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}
