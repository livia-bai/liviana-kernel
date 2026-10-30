//! 回归测试：文件系统的系统调用（open、read、write、mkdir、unlink、chdir、fstat、readdir）。
//! - `run t_fs`：正常情况和边界情况，失败的项打印 "FAIL: ..."，最后打印检查了几项、失败了几项。
//!   所有东西建在 /t_fs 下面，结束时删干净（开始时也先删掉上一次留下的）。
//! - `run t_fs churn &`：掉电测试的写的一方，一直写到被杀（或者 QEMU 被杀）：往 /churn.dat 末尾追加记录，
//!   反复截断、重写 /churn/ 下面的几个文件。
//! - `run t_fs verify`：掉电之后重新启动时运行，检查 churn 写的东西：每个操作要么做完了、要么没做。
//! - `run t_fs scrubfile`：建 /scrub.dat 给 scrub 的测试用（见 scrubFile）。

const std = @import("std");
const sys = @import("sys");
const abi = sys.abi;

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

/// 打开，失败就算一项失败并退出（后面的检查都依赖它）。
fn mustOpen(path: []const u8, flags: sys.OpenFlags) sys.Fd {
    return sys.open(path, flags) catch |err| {
        sys.print("FAIL: open {s}: {s}\n", .{ path, @errorName(err) });
        sys.exit(201);
    };
}

fn sizeOf(fd: sys.Fd) u64 {
    const st = sys.fstat(fd) catch return 999_999_999;
    return st.size;
}

/// 整个文件读出来（最多 buf.len 字节），每次最多读 chunk 字节。
fn readAll(path: []const u8, buf: []u8, chunk: usize) usize {
    const fd = sys.open(path, .{}) catch return 0;
    defer sys.close(fd) catch {};
    var len: usize = 0;
    while (len < buf.len) {
        const n = sys.read(fd, buf[len..@min(buf.len, len + chunk)]) catch break;
        if (n == 0) break;
        len += n;
    }
    return len;
}

fn writeAll(fd: sys.Fd, bytes: []const u8) bool {
    const n = sys.write(fd, bytes) catch return false;
    return n == bytes.len;
}

/// 删掉 path 和它下面的所有东西（不存在就算了）。
fn removeTree(path: []const u8) void {
    if (sys.open(path, .{})) |fd| {
        defer sys.close(fd) catch {};
        if ((sys.fstat(fd) catch return).kind == .dir) {
            var ent: abi.Dirent = undefined;
            // 边列边删：readdir 的位置是键，删掉的名字不影响后面的
            while (sys.readdir(fd, &ent) catch false) {
                var buf: [abi.max_path]u8 = undefined;
                const child = std.fmt.bufPrint(&buf, "{s}/{s}", .{ path, ent.name[0..ent.name_len] }) catch continue;
                removeTree(child);
            }
        }
    } else |_| return;
    sys.unlink(path) catch {};
}

fn pattern(seed: u64, i: usize) u8 {
    return @truncate(seed *% 131 +% i *% 7 +% (i >> 8));
}

fn fillPattern(buf: []u8, seed: u64) void {
    for (buf, 0..) |*c, i| c.* = pattern(seed, i);
}

fn isPattern(buf: []const u8, seed: u64) bool {
    for (buf, 0..) |c, i| if (c != pattern(seed, i)) return false;
    return true;
}

/// 大文件：跨过内联的上限（512 字节），占好几页
const big = 40_000;
var big_buf: [big]u8 = undefined;
var read_buf: [big + 100]u8 = undefined;

pub fn main() u8 {
    if (sys.arg(1)) |a| {
        if (std.mem.eql(u8, a, "churn")) churn();
        if (std.mem.eql(u8, a, "verify")) return verify();
        if (std.mem.eql(u8, a, "scrubfile")) return scrubFile();
    }

    // 串口、管道的 fstat
    {
        const st = sys.fstat(sys.stdout) catch abi.Stat{ .ino = 9, .size = 9, .kind = .file };
        expect(st.kind == .console and st.ino == 0, "fstat stdout: kind {d} ino {d}", .{ @backingInt(st.kind), st.ino });
        const p = sys.pipe() catch .{ 0, 0 };
        expect((sys.fstat(p[0]) catch abi.Stat{ .ino = 0, .size = 0, .kind = .file }).kind == .pipe, "fstat pipe", .{});
        sys.close(p[0]) catch {};
        sys.close(p[1]) catch {};
        expect(sys.readdir(sys.stdin, @ptrFromInt(0x1000)) == error.NotDir, "readdir on the console", .{});
    }

    removeTree("/t_fs");
    sys.mkdir("/t_fs") catch |err| {
        sys.print("FAIL: mkdir /t_fs: {s}\n", .{@errorName(err)});
        return 1;
    };

    // 建文件、写、读回来；关掉再打开，内容还在
    {
        expect(sys.open("/t_fs/a", .{}) == error.NotFound, "open a missing file", .{});
        const fd = mustOpen("/t_fs/a", .{ .read = false, .write = true, .create = true });
        expect(sizeOf(fd) == 0, "new file size {d}", .{sizeOf(fd)});
        expect(writeAll(fd, "hello"), "write hello", .{});
        const st = sys.fstat(fd) catch abi.Stat{ .ino = 0, .size = 0, .kind = .dir };
        expect(st.kind == .file and st.size == 5 and st.ino > 1, "fstat: kind {d} size {d} ino {d}", .{ @backingInt(st.kind), st.size, st.ino });
        var buf: [16]u8 = undefined;
        expect(sys.read(fd, &buf) == error.BadFd, "read a write-only fd", .{});
        sys.close(fd) catch {};

        const r = mustOpen("/t_fs/a", .{});
        expect(sys.write(r, "x") == error.BadFd, "write a read-only fd", .{});
        var n = sys.read(r, &buf) catch 0;
        expect(std.mem.eql(u8, buf[0..n], "hello"), "read back \"{s}\"", .{buf[0..n]});
        n = sys.read(r, &buf) catch 99;
        expect(n == 0, "read at the end: {d}", .{n});
        sys.close(r) catch {};

        // 已经有了的话 create 不截断，trunc 才截
        const c = mustOpen("/t_fs/a", .{ .write = true, .create = true });
        expect(sizeOf(c) == 5, "create on an existing file kept {d} bytes", .{sizeOf(c)});
        sys.close(c) catch {};
        const t = mustOpen("/t_fs/a", .{ .write = true, .truncate = true });
        expect(sizeOf(t) == 0, "truncate: size {d}", .{sizeOf(t)});
        expect(writeAll(t, "abc"), "write after truncate", .{});
        sys.close(t) catch {};
        n = readAll("/t_fs/a", &buf, 16);
        expect(std.mem.eql(u8, buf[0..n], "abc"), "after truncate: \"{s}\"", .{buf[0..n]});
    }

    // 读写位置：dup、fork 出来的 fd 共用一个位置；各自 open 的各有各的
    {
        const fd = mustOpen("/t_fs/b", .{ .read = true, .write = true, .create = true });
        const d = sys.dup(fd) catch fd;
        expect(writeAll(fd, "ab") and writeAll(d, "cd"), "write through dup", .{});
        sys.close(d) catch {};
        const pid = fork();
        if (pid == 0) sys.exit(if (writeAll(fd, "ef")) 0 else 1);
        expect(waitStatus(pid) == 0, "child writes through the inherited fd", .{});
        expect(writeAll(fd, "gh"), "write after the child", .{});
        var buf: [16]u8 = undefined;
        var n = readAll("/t_fs/b", &buf, 3);
        expect(std.mem.eql(u8, buf[0..n], "abcdefgh"), "shared offset: \"{s}\"", .{buf[0..n]});
        // 位置在末尾，读到 0
        n = sys.read(fd, &buf) catch 99;
        expect(n == 0, "read at the shared offset: {d}", .{n});
        sys.close(fd) catch {};

        // 两个各自打开的 fd：第二个从 0 开始，覆盖前面的字节
        const x = mustOpen("/t_fs/b", .{ .write = true });
        expect(writeAll(x, "XY"), "overwrite", .{});
        sys.close(x) catch {};
        n = readAll("/t_fs/b", &buf, 16);
        expect(std.mem.eql(u8, buf[0..n], "XYcdefgh"), "overwrite at 0: \"{s}\"", .{buf[0..n]});
    }

    // 大文件：分几次写（中途从内联换成数据块），换几种大小读回来
    {
        fillPattern(&big_buf, 1);
        const fd = mustOpen("/t_fs/big", .{ .write = true, .create = true });
        var off: usize = 0;
        var ok = true;
        while (off < big) : (off += 3000) ok = ok and writeAll(fd, big_buf[off..@min(big, off + 3000)]);
        expect(ok, "write {d} bytes in 3000-byte pieces", .{big});
        expect(sizeOf(fd) == big, "big file size {d}", .{sizeOf(fd)});
        sys.close(fd) catch {};
        for ([_]usize{ 1, 100, 4096, 5000, big + 100 }) |chunk| {
            if (chunk == 1) continue; // 一次一个字节太慢（每次一个系统调用），下面单独读一段
            @memset(&read_buf, 0);
            const n = readAll("/t_fs/big", &read_buf, chunk);
            expect(n == big and isPattern(read_buf[0..n], 1), "read big back in {d}-byte pieces: {d} bytes", .{ chunk, n });
        }
        // 一次写 40000 字节（一个事务写 10 页），再整个读回来
        fillPattern(&big_buf, 2);
        const w = mustOpen("/t_fs/big", .{ .write = true, .truncate = true });
        expect(writeAll(w, &big_buf), "write {d} bytes at once", .{big});
        sys.close(w) catch {};
        const n = readAll("/t_fs/big", &read_buf, read_buf.len);
        expect(n == big and isPattern(read_buf[0..n], 2), "read big back at once: {d} bytes", .{n});
    }

    // 坏指针：路径、读写的缓冲区、fstat、readdir 的结果都不能指到内核里
    {
        const kernel: usize = 0x80200000;
        const bad_path: [*]const u8 = @ptrFromInt(kernel);
        expect(sys.open(bad_path[0..4], .{}) == error.BadAddress, "open with a kernel pointer", .{});
        expect(sys.mkdir(bad_path[0..4]) == error.BadAddress, "mkdir with a kernel pointer", .{});
        const fd = mustOpen("/t_fs/b", .{ .read = true, .write = true });
        const bad: [*]u8 = @ptrFromInt(kernel);
        expect(sys.read(fd, bad[0..8]) == error.BadAddress, "read into kernel memory", .{});
        // 读失败不挪位置
        var buf: [16]u8 = undefined;
        var n = sys.read(fd, &buf) catch 0;
        expect(std.mem.eql(u8, buf[0..n], "XYcdefgh"), "offset after a failed read: \"{s}\"", .{buf[0..n]});
        // 写到一半出错（前一半是好的用户内存，后一半是没映射的地址）：整个写作废，文件不变
        const stack_top: usize = 0x80000000; // 用户地址空间的末尾，再往上不是用户内存
        const half: [*]const u8 = @ptrFromInt(stack_top - 2000);
        expect(sys.write(fd, half[0..6000]) == error.BadAddress, "write running off the end of the stack", .{});
        expect(sizeOf(fd) == 8, "size after a failed write: {d}", .{sizeOf(fd)});
        expect(sys.fstat(fd) != error.BadAddress, "fstat", .{});
        const ret = sys.syscall(.fstat, fd, kernel, 0);
        expect(abi.errnoOf(ret) == .fault, "fstat into kernel memory", .{});
        sys.close(fd) catch {};
        n = readAll("/t_fs/b", &buf, 16);
        expect(std.mem.eql(u8, buf[0..n], "XYcdefgh"), "content after a failed write: \"{s}\"", .{buf[0..n]});
    }

    // 目录：mkdir、错误、readdir、chdir
    {
        expect(sys.mkdir("/t_fs/d") != error.Exists, "mkdir /t_fs/d", .{});
        expect(sys.mkdir("/t_fs/d") == error.Exists, "mkdir twice", .{});
        expect(sys.mkdir("/t_fs/a/x") == error.NotDir, "mkdir under a file", .{});
        expect(sys.mkdir("/t_fs/nope/x") == error.NotFound, "mkdir under a missing directory", .{});
        expect(sys.mkdir("/t_fs/d/..") == error.InvalidArgument, "mkdir ..", .{});
        expect(sys.open("/t_fs/d", .{ .write = true }) == error.IsDir, "open a directory for writing", .{});
        expect(sys.open("/t_fs/d", .{ .write = true, .create = true }) == error.IsDir, "create over a directory", .{});
        expect(sys.open("/t_fs", .{ .read = true }) != error.IsDir, "open a directory read-only", .{});
        const dfd = mustOpen("/t_fs/d", .{});
        var buf: [16]u8 = undefined;
        expect(sys.read(dfd, &buf) == error.IsDir, "read a directory", .{});
        const st = sys.fstat(dfd) catch abi.Stat{ .ino = 0, .size = 1, .kind = .file };
        expect(st.kind == .dir and st.size == 0, "fstat a directory: kind {d} size {d}", .{ @backingInt(st.kind), st.size });
        var ent: abi.Dirent = undefined;
        expect((sys.readdir(dfd, &ent) catch true) == false, "readdir an empty directory", .{});
        sys.close(dfd) catch {};
        const ffd = mustOpen("/t_fs/a", .{});
        expect(sys.readdir(ffd, &ent) == error.NotDir, "readdir a file", .{});
        sys.close(ffd) catch {};

        // 名字太长
        var long: [abi.max_name + 1]u8 = @splat('n');
        expect(sys.mkdir(&long) == error.NameTooLong, "mkdir a 256-byte name", .{});
        expect(sys.open(&long, .{ .write = true, .create = true }) == error.NameTooLong, "create a 256-byte name", .{});
        var longest: [abi.max_name]u8 = @splat('m');
        @memcpy(longest[0..7], "/t_fs/d");
        longest[7] = '/';
        expect(sys.mkdir(&longest) != error.NameTooLong, "mkdir a name of {d} bytes", .{longest.len - 8});
        var path: [abi.max_path + 1]u8 = @splat('/');
        expect(sys.open(&path, .{}) == error.NameTooLong, "a 257-byte path", .{});
        expect(sys.open(path[0..abi.max_path], .{}) != error.NameTooLong, "a 256-byte path (the root)", .{});

        // 一个目录里 30 个文件，readdir 每个名字正好列出一次；readdir 写结果失败时不挪位置
        sys.mkdir("/t_fs/many") catch {};
        var i: usize = 0;
        while (i < 30) : (i += 1) {
            var nb: [32]u8 = undefined;
            const p = std.fmt.bufPrint(&nb, "/t_fs/many/f{d}", .{i}) catch unreachable;
            const fd = mustOpen(p, .{ .write = true, .create = true });
            _ = writeAll(fd, p);
            sys.close(fd) catch {};
        }
        var seen: u32 = 0;
        var dup_seen = false;
        const mfd = mustOpen("/t_fs/many", .{});
        expect(abi.errnoOf(sys.syscall(.readdir, mfd, 0x80200000, 0)) == .fault, "readdir into kernel memory", .{});
        var count: usize = 0;
        while (sys.readdir(mfd, &ent) catch false) : (count += 1) {
            const name = ent.name[0..ent.name_len];
            const k = std.fmt.parseUnsigned(u5, name[1..], 10) catch 31;
            if (k < 30 and name[0] == 'f' and ent.kind == .file) {
                if (seen & (@as(u32, 1) << k) != 0) dup_seen = true;
                seen |= @as(u32, 1) << k;
            }
        }
        sys.close(mfd) catch {};
        expect(count == 30 and seen == (1 << 30) - 1 and !dup_seen, "readdir listed {d} names, mask 0x{x}", .{ count, seen });

        // chdir：相对路径从当前目录开始；子进程 chdir 不影响父进程
        expect(sys.chdir("/t_fs/a") == error.NotDir, "chdir to a file", .{});
        expect(sys.chdir("/t_fs/nope") == error.NotFound, "chdir to a missing directory", .{});
        expect(sys.chdir("/t_fs/many") != error.NotFound, "chdir /t_fs/many", .{});
        const n = readAll("f7", &buf, 16);
        expect(std.mem.eql(u8, buf[0..n], "/t_fs/many/f7"), "relative open: \"{s}\"", .{buf[0..n]});
        const pid = fork();
        if (pid == 0) {
            sys.chdir("..") catch sys.exit(1);
            sys.exit(if (readAll("b", &buf, 16) == 8) 0 else 2);
        }
        expect(waitStatus(pid) == 0, "child chdir ..", .{});
        expect(readAll("f8", &buf, 16) == 13, "parent's cwd after the child's chdir", .{});
        expect(sys.mkdir("./sub/../sub2") == error.NotFound, "path through a missing directory", .{});
        expect(sys.mkdir("sub") != error.NotFound, "relative mkdir", .{});
        expect(sys.chdir("../../t_fs/./many/sub") != error.NotFound, "chdir with .. and .", .{});
        expect(sys.chdir("/") != error.NotFound, "chdir /", .{});
        expect(readAll("t_fs/b", &buf, 16) == 8, "relative to /", .{});

        // 删除
        expect(sys.unlink("/t_fs/many") == error.NotEmpty, "unlink a non-empty directory", .{});
        expect(sys.unlink("/t_fs/many/.") == error.InvalidArgument, "unlink .", .{});
        expect(sys.unlink("/t_fs/zzz") == error.NotFound, "unlink a missing file", .{});
        expect(sys.unlink("/") == error.InvalidArgument, "unlink /", .{});
        // 打开着的文件被删了：之后读它是 NotFound（没有 Unix 的“最后一个关掉才删”）
        const ofd = mustOpen("/t_fs/many/f0", .{});
        expect(sys.unlink("/t_fs/many/f0") != error.NotFound, "unlink an open file", .{});
        expect(sys.read(ofd, &buf) == error.NotFound, "read a deleted file", .{});
        sys.close(ofd) catch {};
        expect(sys.open("/t_fs/many/f0", .{}) == error.NotFound, "open after unlink", .{});
    }

    // 并发：4 个进程同时往同一个 fd（共用位置）追加 100 字节的记录，同时各自写自己的文件。
    // 每次 write 是一个事务、拿着文件系统的锁，所以记录不会交错、不会互相覆盖
    {
        const procs = 4;
        const records = 20;
        const rec = 100;
        const shared = mustOpen("/t_fs/shared", .{ .write = true, .create = true });
        var pids: [procs]usize = undefined;
        for (&pids, 0..) |*pid, k| {
            pid.* = fork();
            if (pid.* != 0) continue;
            var nb: [32]u8 = undefined;
            const own = std.fmt.bufPrint(&nb, "/t_fs/own{d}", .{k}) catch unreachable;
            const fd = sys.open(own, .{ .write = true, .create = true }) catch sys.exit(1);
            var r: [rec]u8 = @splat(@intCast('A' + k));
            var j: usize = 0;
            while (j < records) : (j += 1) {
                r[1] = @intCast(j);
                if (!writeAll(shared, &r)) sys.exit(2);
                var page: [1500]u8 = undefined;
                fillPattern(&page, k * 100 + j);
                if (!writeAll(fd, &page)) sys.exit(3);
                if (j % 4 == 0) sys.yield();
            }
            sys.exit(0);
        }
        var ok = true;
        for (pids) |pid| ok = ok and waitStatus(pid) == 0;
        expect(ok, "concurrent writers exited with 0", .{});
        expect(sizeOf(shared) == procs * records * rec, "shared file size {d}", .{sizeOf(shared)});
        sys.close(shared) catch {};
        const n = readAll("/t_fs/shared", &read_buf, read_buf.len);
        var next: [procs]u8 = @splat(0);
        var bad: usize = 0;
        var i: usize = 0;
        while (i + rec <= n) : (i += rec) {
            const r = read_buf[i..][0..rec];
            const k = r[0] -% 'A';
            if (k >= procs or r[1] != next[k]) {
                bad += 1;
                continue;
            }
            next[k] += 1;
            for (r[2..]) |c| if (c != r[0]) {
                bad += 1;
                break;
            };
        }
        expect(n == procs * records * rec and bad == 0, "shared records: {d} bytes, {d} bad", .{ n, bad });
        for (0..procs) |k| {
            var nb: [32]u8 = undefined;
            const own = std.fmt.bufPrint(&nb, "/t_fs/own{d}", .{k}) catch unreachable;
            const m = readAll(own, &read_buf, read_buf.len);
            var good = m == records * 1500;
            var j: usize = 0;
            while (good and j < records) : (j += 1) good = isPattern(read_buf[j * 1500 ..][0..1500], k * 100 + j);
            expect(good, "{s}: {d} bytes", .{ own, m });
        }
    }

    removeTree("/t_fs");
    expect(sys.open("/t_fs", .{}) == error.NotFound, "everything removed", .{});

    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}

// ---- 掉电测试 ----

/// /churn.dat 的一条记录：前 8 字节是序号，其余是和序号有关的图案
const churn_rec = 300;
/// /churn/ 下面的文件：每个都是 slots 个里的一个，长度只能是 0（刚建、还没写）或者 churn_file
const slots = 3;
const churn_file = 5000;

fn churnRecord(buf: *[churn_rec]u8, seq: u64) void {
    fillPattern(buf, seq);
    std.mem.writeInt(u64, buf[0..8], seq, .little);
}

fn churnPath(buf: []u8, slot: u64) []const u8 {
    return std.fmt.bufPrint(buf, "/churn/s{d}", .{slot}) catch unreachable;
}

/// 一直写，直到被杀。
fn churn() noreturn {
    removeTree("/churn");
    sys.unlink("/churn.dat") catch {};
    sys.mkdir("/churn") catch {};
    const log = mustOpen("/churn.dat", .{ .write = true, .create = true });
    sys.print("churn: started\n", .{});
    var seq: u64 = 0;
    while (true) : (seq += 1) {
        var r: [churn_rec]u8 = undefined;
        churnRecord(&r, seq);
        if (!writeAll(log, &r)) {
            sys.print("FAIL: churn: append {d}\n", .{seq});
            sys.exit(1);
        }
        var nb: [32]u8 = undefined;
        const p = churnPath(&nb, seq % slots);
        switch (seq % 3) {
            0 => sys.unlink(p) catch {},
            else => {
                const fd = sys.open(p, .{ .write = true, .create = true, .truncate = true }) catch continue;
                fillPattern(big_buf[0..churn_file], seq % slots);
                _ = writeAll(fd, big_buf[0..churn_file]);
                sys.close(fd) catch {};
            },
        }
    }
}

/// 建 /scrub.dat：3 页，第 i 页是 "scrub test page i\n" 重复到填满。内容是独一无二的，
/// qemu_test.py 关机之后能在磁盘镜像里按内容找到第 1 页的数据块，改坏它，再启动看 scrub 能不能发现。
fn scrubFile() u8 {
    const fd = mustOpen("/scrub.dat", .{ .write = true, .create = true, .truncate = true });
    defer sys.close(fd) catch {};
    const page = big_buf[0..4096];
    for (0..3) |i| {
        var line_buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "scrub test page {d}\n", .{i}) catch unreachable;
        for (page, 0..) |*c, j| c.* = line[j % line.len];
        if (!writeAll(fd, page)) {
            sys.print("FAIL: scrubfile: write page {d}\n", .{i});
            return 1;
        }
    }
    sys.print("scrubfile: written\n", .{});
    return 0;
}

fn verify() u8 {
    const fd = mustOpen("/churn.dat", .{});
    const size = sizeOf(fd);
    sys.close(fd) catch {};
    expect(size % churn_rec == 0, "churn.dat size {d} is not a whole number of records", .{size});
    var records: u64 = 0;
    var bad: u64 = 0;
    {
        const f = mustOpen("/churn.dat", .{});
        defer sys.close(f) catch {};
        var r: [churn_rec]u8 = undefined;
        while (true) : (records += 1) {
            var got: usize = 0;
            while (got < churn_rec) {
                const m = sys.read(f, r[got..]) catch break;
                if (m == 0) break;
                got += m;
            }
            if (got == 0) break;
            var want: [churn_rec]u8 = undefined;
            churnRecord(&want, records);
            if (got != churn_rec or !std.mem.eql(u8, &r, &want)) bad += 1;
        }
    }
    expect(bad == 0, "churn.dat: {d} of {d} records wrong", .{ bad, records });
    for (0..slots) |slot| {
        var nb: [32]u8 = undefined;
        const p = churnPath(&nb, slot);
        const m = readAll(p, &read_buf, read_buf.len);
        if (sys.open(p, .{})) |f| sys.close(f) catch {} else |_| continue; // 删掉了
        expect(m == 0 or (m == churn_file and isPattern(read_buf[0..m], slot)), "{s}: {d} bytes", .{ p, m });
    }
    sys.print("churn: {d} records intact\n", .{records - bad});
    removeTree("/churn");
    sys.unlink("/churn.dat") catch {};
    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}
