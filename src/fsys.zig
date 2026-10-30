//! 内核里的文件系统：唯一的一个 Volume，第一个进程启动时挂载（xv6 在 forkret 里调用 fsinit）。
//! 文件系统本身的逻辑在 fs.zig；这里是内核这一侧：加锁、用户内存、错误码、打开的文件（file.zig 的 .inode）。
//!
//! - **读**（read、fstat、readdir、lseek、chdir、不建不截的 open、exec 加载程序）不拿锁：reader() 拿一个
//!   已提交的树的快照（ctree 的 beginRead），在它上面读，读完 end()。几个读者、读者和修改的一方都同时进行；
//!   读者看到的是开始读时最近一次提交的样子，修改的一方做到一半的东西看不到。
//! - **修改**（write、mkdir、unlink、rename、建文件、截断、scrub）拿 write_lock（睡眠锁）：
//!   B 树同一时刻只能有一个事务，所以修改之间还是一个一个来。每个修改是一个事务（fs.Fs.run）：
//!   成功就提交，出错就作废。
//! - 加锁顺序：File.pos_lock → write_lock → 缓冲区的睡眠锁。拿着快照时不能去等 pos_lock、write_lock：
//!   修改的一方可能拿着它们在等旧树的读者读完（ctree 的 limbo）。
//! - 磁盘的前一部分是文件系统（超级块里记着它有多少块），后一部分是原始区域，
//!   readblock/writeblock 系统调用只能读写原始区域（块号从原始区域的开头算），碰不到文件系统。
//!   磁盘上没有文件系统时整个磁盘都是原始区域。

const std = @import("std");
const abi = @import("abi.zig");
const fs = @import("fs.zig");
const ctree = @import("ctree.zig");
const bio = @import("bio.zig");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const Sleeplock = @import("sleeplock.zig").Sleeplock;

pub const Fs = fs.Fs;

var vol: ctree.Volume = .{};
/// 挂载好的文件系统（修改的一方用它）。mounted 为 false 时没有。
/// 两者都只在 init 里写一次，那时别的进程还没有，之后只读，所以读者不拿锁读它们
var root: fs.Fs = undefined;
pub var mounted = false;
/// 修改的一方拿着它（见文件开头），也保护 root.next_ino
var write_lock: Sleeplock = .init("fs write");

/// 原始区域：磁盘上文件系统之后的块
pub var raw_base: u64 = 0;
pub var raw_count: u64 = 0;

/// 挂载磁盘上的文件系统。第一个进程（init）第一次进入 U 模式之前调用一次（proc.forkretC）：
/// 读盘要睡着等，只有进程能做，kmain 不行。
pub fn init() void {
    raw_count = bio.blockCount();
    if (raw_count == 0) return;
    write_lock.acquire();
    defer write_lock.release();
    root = Fs.mount(&vol) catch |err| {
        uart.print("[warn] no file system on the disk: {s}\n", .{@errorName(err)});
        return;
    };
    mounted = true;
    raw_base = vol.blocks;
    raw_count -= vol.blocks;
    uart.print("[ok] file system: {d} of {d} blocks free, generation {d}\n", .{ vol.free_count, vol.blocks, vol.generation });
}

/// 读者：一个快照上的只读 Fs。用完调用 end。
pub const Reader = struct {
    fs: Fs,
    snap: ctree.Snapshot,

    pub fn end(r: *Reader) void {
        vol.endRead(r.snap);
    }
};

/// 开始读：拿最近一次提交的快照。没挂载是 NoDevice。
pub fn reader() error{NoDevice}!Reader {
    if (!mounted) return error.NoDevice;
    const snap = vol.beginRead();
    return .{ .fs = .{ .vol = &vol, .next_ino = 0, .view = snap.root }, .snap = snap };
}

/// 开始修改：拿着 write_lock、确认挂载了，返回文件系统。调用方用完 unlock。
pub fn writer() error{NoDevice}!*Fs {
    if (!mounted) return error.NoDevice;
    write_lock.acquire();
    return &root;
}

pub fn unlock() void {
    write_lock.release();
}

/// 文件系统的错误换成系统调用的错误码。
pub fn errno(err: anyerror) abi.Errno {
    return switch (err) {
        error.NotFound => .noent,
        error.Exists => .exist,
        error.NotDir => .notdir,
        error.IsDir => .isdir,
        error.NotEmpty => .notempty,
        error.NameTooLong => .nametoolong,
        error.InvalidName => .inval,
        error.NoSpace => .nospc,
        error.FileTooBig => .fbig,
        error.BadAddress => .fault,
        error.NoDevice => .nodev,
        else => .io, // Corrupt 等：磁盘上的东西不对
    };
}

/// fs.read 的 out：写进用户地址空间 space 的 ptr 开始的地方。
pub const UserOut = struct {
    space: *vm.PageTable,
    ptr: usize,
    pub fn put(o: UserOut, at: usize, bytes: []const u8) error{BadAddress}!void {
        const va = std.math.add(usize, o.ptr, at) catch return error.BadAddress;
        try vm.copyToUser(o.space, va, bytes);
    }
};

/// fs.write 的 in：从用户地址空间 space 的 ptr 开始的地方取。
pub const UserIn = struct {
    space: *vm.PageTable,
    ptr: usize,
    pub fn get(i: UserIn, at: usize, dst: []u8) error{BadAddress}!void {
        const va = std.math.add(usize, i.ptr, at) catch return error.BadAddress;
        try vm.copyFromUser(i.space, dst, va);
    }
};
