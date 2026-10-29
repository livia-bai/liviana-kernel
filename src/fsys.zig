//! 内核里的文件系统：唯一的一个 Volume，一把睡眠锁，第一个进程启动时挂载（xv6 在 forkret 里调用 fsinit）。
//! 文件系统本身的逻辑在 fs.zig；这里是内核这一侧：加锁、用户内存、错误码、打开的文件（file.zig 的 .inode）。
//!
//! - 所有文件系统操作都拿着 lock（睡眠锁）：同一时刻只有一个进程在用文件系统，fs.zig、ctree.zig 不用自己加锁。
//!   读写文件时也拿着它，File 的 off（几个 fd 共用）也由它保护。
//! - 每个改动文件系统的操作是一个事务（fs.Fs.run）：成功就提交，出错就作废。
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
/// 挂载好的文件系统，mounted 为 false 时没有
var root: fs.Fs = undefined;
pub var mounted = false;
/// 保护上面这些和整个文件系统（见文件开头）
pub var lock: Sleeplock = .init("fs");

/// 原始区域：磁盘上文件系统之后的块
pub var raw_base: u64 = 0;
pub var raw_count: u64 = 0;

/// 挂载磁盘上的文件系统。第一个进程（init）第一次进入 U 模式之前调用一次（proc.forkretC）：
/// 读盘要睡着等，只有进程能做，kmain 不行。
pub fn init() void {
    raw_count = bio.blockCount();
    if (raw_count == 0) return;
    lock.acquire();
    defer lock.release();
    root = Fs.mount(&vol) catch |err| {
        uart.print("[warn] no file system on the disk: {s}\n", .{@errorName(err)});
        return;
    };
    mounted = true;
    raw_base = vol.blocks;
    raw_count -= vol.blocks;
    uart.print("[ok] file system: {d} of {d} blocks free, generation {d}\n", .{ vol.free_count, vol.blocks, vol.generation });
}

/// 拿着锁、确认挂载了，返回文件系统。调用方用完 unlock。
pub fn get() error{NoDevice}!*Fs {
    lock.acquire();
    if (!mounted) {
        lock.release();
        return error.NoDevice;
    }
    return &root;
}

pub fn unlock() void {
    lock.release();
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
