//! 用户程序的系统调用封装和格式化输出，用户程序通过 `@import("sys")` 使用。

const std = @import("std");
const abi = @import("abi");

fn syscall(n: abi.Syscall, arg0: usize, arg1: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [n] "{a7}" (@backingInt(n)),
          [arg0] "{a0}" (arg0),
          [arg1] "{a1}" (arg1),
        : .{ .memory = true });
}

pub fn exit(code: u8) noreturn {
    _ = syscall(.exit, code, 0);
    unreachable;
}

pub const WriteError = error{ BadAddress, Unexpected };

pub fn write(bytes: []const u8) WriteError!usize {
    const ret = syscall(.write, @intFromPtr(bytes.ptr), bytes.len);
    if (abi.errnoOf(ret)) |e| return switch (e) {
        .fault => error.BadAddress,
        else => error.Unexpected,
    };
    return ret;
}

pub fn getpid() usize {
    return syscall(.getpid, 0, 0);
}

/// 开机以来的毫秒数。
pub fn uptime() u64 {
    return syscall(.uptime, 0, 0);
}

/// 让出 CPU，让别的进程先运行。
pub fn yield() void {
    _ = syscall(.yield, 0, 0);
}

/// 睡至少 ms 毫秒（精度 10 ms），期间不占 CPU。
pub fn sleep(ms: u64) void {
    _ = syscall(.sleep, ms, 0);
}

// 和内核的 uart.zig 一样，接入 std.Io.Writer，用标准库做格式化，输出走 write 系统调用
var writer: std.Io.Writer = .{
    .vtable = &.{ .drain = drain },
    .buffer = &.{},
};

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    _ = w;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        n += write(bytes) catch return error.WriteFailed;
    }
    const pattern = data[data.len - 1];
    for (0..splat) |_| n += write(pattern) catch return error.WriteFailed;
    return n;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch {};
}
