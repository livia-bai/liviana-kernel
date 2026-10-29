//! 打开的文件，照 xv6 的 file.c 写。进程用 fd（Process.files 的下标）指代一个 File，
//! File 是串口（console）或者管道的一端。
//!
//! - 文件表 table 是全局的，File 带引用计数：fork 复制 fd 表、dup 复制 fd，都只是让两个 fd
//!   指向同一个 File（ref 加 1），所以父子进程共用读写位置、共用管道的一端。
//!   最后一个引用关掉时（close、进程结束）才真正关掉：管道的一端关了，另一端会读到结尾或写失败。
//! - 没有文件系统，所以文件只有这两种：init 打开串口作为 0、1、2 号 fd，其他进程都从它那里 fork 继承；
//!   pipe 系统调用创建管道。
//!
//! 文件表由 lock 保护（多核时几个 hart 会同时打开、关闭文件）。File 本身的 kind、readable 等字段
//! 在分配出来之后就不变了，读写时不用拿 lock；管道的状态由管道自己的锁保护（pipe.zig）。

const std = @import("std");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page = @import("page.zig");
const proc = @import("proc.zig");
const pipe = @import("pipe.zig");
const Spinlock = @import("spinlock.zig").Spinlock;

/// 整个系统最多同时有多少个打开的文件。每个进程最多 abi.max_fds 个 fd，但它们大多指向同一个串口。
pub const max_files = 32;

pub const Kind = enum { none, console, pipe };

pub const File = struct {
    /// 引用数：有多少个 fd 指向它。为 0 表示这个槽位空着
    ref: u32 = 0,
    kind: Kind = .none,
    readable: bool = false,
    writable: bool = false,
    pipe: *pipe.Pipe = undefined,
};

var lock: Spinlock = .init("file");
var table: [max_files]File = @splat(.{});

pub const Error = error{ NotReadable, NotWritable, BadAddress, BrokenPipe };

/// 分配一个空的 File（ref = 1），由调用方填好其他字段。
fn alloc() error{TooManyFiles}!*File {
    lock.acquire();
    defer lock.release();
    for (&table) |*f| {
        if (f.ref == 0) {
            f.* = .{ .ref = 1 };
            return f;
        }
    }
    return error.TooManyFiles;
}

/// 打开串口，可读可写。
pub fn openConsole() error{TooManyFiles}!*File {
    const f = try alloc();
    f.kind = .console;
    f.readable = true;
    f.writable = true;
    return f;
}

/// 创建一个管道，返回读端和写端。
pub fn openPipe() error{ TooManyFiles, OutOfMemory }![2]*File {
    const r = try alloc();
    errdefer close(r);
    const w = try alloc();
    errdefer close(w);
    const p = try pipe.create();
    r.* = .{ .ref = 1, .kind = .pipe, .readable = true, .pipe = p };
    w.* = .{ .ref = 1, .kind = .pipe, .writable = true, .pipe = p };
    return .{ r, w };
}

/// 多一个引用（dup、fork），返回同一个 File。
pub fn dup(f: *File) *File {
    lock.acquire();
    defer lock.release();
    std.debug.assert(f.ref > 0);
    f.ref += 1;
    return f;
}

/// 少一个引用。是最后一个的话腾出槽位，再关掉底下的东西（管道的一端）。
pub fn close(f: *File) void {
    lock.acquire();
    std.debug.assert(f.ref > 0);
    f.ref -= 1;
    if (f.ref > 0) {
        lock.release();
        return;
    }
    const old = f.*;
    f.* = .{};
    lock.release();
    // 放开文件表的锁之后再关管道：管道的锁和文件表的锁不嵌套，就不用规定加锁的顺序
    if (old.kind == .pipe) pipe.close(old.pipe, old.writable);
}

/// 从 f 读最多 len 个字节到用户地址空间 space 的 ptr，返回读到的字节数，0 表示读到了结尾。
/// 调用方先检查过 [ptr, ptr+len) 可写（见 syscall.read）。
pub fn read(f: *File, space: *vm.PageTable, ptr: usize, len: usize) Error!usize {
    if (!f.readable) return error.NotReadable;
    return switch (f.kind) {
        .none => unreachable,
        .console => consoleRead(space, ptr, len),
        .pipe => pipe.read(f.pipe, space, ptr, len),
    };
}

/// 把用户地址空间 space 里 [ptr, ptr+len) 的字节写进 f，返回写出的字节数。
/// 遇到坏地址时停下，返回已经写出的字节数；一个字节都没写出才返回 BadAddress。
pub fn write(f: *File, space: *vm.PageTable, ptr: usize, len: usize) Error!usize {
    if (!f.writable) return error.NotWritable;
    return switch (f.kind) {
        .none => unreachable,
        .console => consoleWrite(space, ptr, len),
        .pipe => pipe.write(f.pipe, space, ptr, len),
    };
}

/// 用户内存先分块复制到内核缓冲区再输出，每块都经过 vm.copyFromUser 检查。
/// 每块都不跨页：一块失败就说明这一页整个不能读，前面的字节都已经写出去了。
fn consoleWrite(space: *vm.PageTable, ptr: usize, len: usize) Error!usize {
    var buf: [128]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        const va = ptr + done;
        const chunk = buf[0..@min(buf.len, len - done, page.size - va % page.size)];
        vm.copyFromUser(space, chunk, va) catch return if (done == 0) error.BadAddress else done;
        uart.write(chunk);
        done += chunk.len;
    }
    return done;
}

/// Ctrl-D：在串口上表示“输入结束”，和 Unix 终端一样。
const ctrl_d = 0x04;

/// 从键盘缓冲区读最多 len 个字节。缓冲区为空时睡在 uart.rx_chan 上，串口中断叫醒它。
/// 读到 Ctrl-D 就停下：它前面有字符的话先返回这些字符，Ctrl-D 留到下一次 read，
/// 那一次读掉它、返回 0。所以单独按一次 Ctrl-D，read 返回 0。
fn consoleRead(space: *vm.PageTable, ptr: usize, len: usize) Error!usize {
    if (len == 0) return 0;
    uart.rx_lock.acquire();
    defer uart.rx_lock.release();
    while (!uart.hasInput()) {
        if (proc.isKilled()) return 0; // 回到陷阱处理程序后结束，返回值没人看
        proc.sleep(uart.rx_chan, &uart.rx_lock);
    }
    if (uart.peek() == ctrl_d) {
        _ = uart.read();
        return 0;
    }
    var buf: [64]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        var n: usize = 0;
        while (n < @min(buf.len, len - done)) : (n += 1) {
            const c = uart.peek() orelse break;
            if (c == ctrl_d) break;
            buf[n] = uart.read().?;
        }
        if (n == 0) break;
        vm.copyToUser(space, ptr + done, buf[0..n]) catch unreachable; // 调用方检查过了
        done += n;
    }
    return done;
}

test "文件表：dup 加引用，最后一个 close 才关掉管道；表满了返回 TooManyFiles 且不漏" {
    const expectEqual = std.testing.expectEqual;
    var test_memory: [4 * page.size]u8 align(page.size) = undefined;
    const base = @intFromPtr(&test_memory);
    page.init(base, base + test_memory.len, &.{});
    const before = page.free_pages;

    const r, const w = try openPipe();
    try expectEqual(before - 1, page.free_pages);
    _ = dup(w);
    close(w);
    try std.testing.expect(w.pipe.write_open); // 还有一个引用
    close(w);
    try std.testing.expect(!r.pipe.write_open);
    close(r);
    try expectEqual(before, page.free_pages);

    // 只剩一个空槽位：openPipe 分配第二个 File 时失败，第一个也还回去
    var held: [max_files - 1]*File = undefined;
    for (&held) |*f| f.* = try openConsole();
    try expectEqual(error.TooManyFiles, openPipe());
    const last = try openConsole();
    close(last);
    for (held) |f| close(f);
    try expectEqual(before, page.free_pages);
    for (table) |f| try expectEqual(0, f.ref);
}
