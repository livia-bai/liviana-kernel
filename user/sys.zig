//! 用户程序的系统调用封装和格式化输出，用户程序通过 `@import("sys")` 使用。

const std = @import("std");
/// 和内核共用的系统调用约定（调用号、错误码、ProcInfo 等），用户程序用 sys.abi 访问。
pub const abi = @import("abi");

/// 原始的系统调用：返回值原样返回（错误时是 -errno），回归测试用它测边界情况。
pub fn syscall(n: abi.Syscall, arg0: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [n] "{a7}" (@backingInt(n)),
          [arg0] "{a0}" (arg0),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
        : .{ .memory = true });
}

pub fn exit(code: u8) noreturn {
    _ = syscall(.exit, code, 0, 0);
    unreachable;
}

pub const WriteError = error{ BadAddress, Unexpected };

pub fn write(bytes: []const u8) WriteError!usize {
    const ret = syscall(.write, @intFromPtr(bytes.ptr), bytes.len, 0);
    if (abi.errnoOf(ret)) |e| return switch (e) {
        .fault => error.BadAddress,
        else => error.Unexpected,
    };
    return ret;
}

pub fn getpid() usize {
    return syscall(.getpid, 0, 0, 0);
}

/// 父进程的 pid，init 是 0。
pub fn getppid() usize {
    return syscall(.getppid, 0, 0, 0);
}

/// 开机以来的毫秒数。
pub fn uptime() u64 {
    return syscall(.uptime, 0, 0, 0);
}

/// 让出 CPU，让别的进程先运行。
pub fn yield() void {
    _ = syscall(.yield, 0, 0, 0);
}

/// 睡至少 ms 毫秒（精度 10 ms），期间不占 CPU。
pub fn sleep(ms: u64) void {
    _ = syscall(.sleep, ms, 0, 0);
}

pub const ReadError = error{ BadAddress, Unexpected };

/// 从键盘读最多 buf.len 个字节。没有输入时阻塞；不回显。
pub fn read(buf: []u8) ReadError!usize {
    const ret = syscall(.read, @intFromPtr(buf.ptr), buf.len, 0);
    if (abi.errnoOf(ret)) |e| return switch (e) {
        .fault => error.BadAddress,
        else => error.Unexpected,
    };
    return ret;
}

pub const ForkError = error{ TooManyProcesses, OutOfMemory, Unexpected };

/// 复制当前进程。父进程得到子进程的 pid，子进程得到 0。
pub fn fork() ForkError!usize {
    const ret = syscall(.fork, 0, 0, 0);
    if (abi.errnoOf(ret)) |e| return switch (e) {
        .again => error.TooManyProcesses,
        .nomem => error.OutOfMemory,
        else => error.Unexpected,
    };
    return ret;
}

pub const ExecError = error{ NoSuchProgram, OutOfMemory, BadElf, BadAddress, Unexpected };

/// 换成嵌在内核里的程序 name 运行。成功时不返回。
pub fn exec(name: []const u8) ExecError!noreturn {
    const ret = syscall(.exec, @intFromPtr(name.ptr), name.len, 0);
    return switch (abi.errnoOf(ret) orelse .inval) {
        .noent => error.NoSuchProgram,
        .nomem => error.OutOfMemory,
        .noexec => error.BadElf,
        .fault => error.BadAddress,
        else => error.Unexpected,
    };
}

pub const WaitResult = struct {
    pid: usize,
    /// 正常退出时是退出码（0..255），被杀时是 abi.killed_status
    status: u32,
};

pub const WaitError = error{ NoChildren, Unexpected };

/// 等子进程结束并回收它。pid 为 null 时等任意一个子进程。
/// nohang 为 true 时不阻塞：有子进程但都还没结束就返回 null。
pub fn wait(pid: ?usize, nohang: bool) WaitError!?WaitResult {
    var status: u32 = 0;
    const ret = syscall(.wait, pid orelse abi.wait_any, @intFromPtr(&status), if (nohang) abi.wait_nohang else 0);
    if (abi.errnoOf(ret)) |e| return switch (e) {
        .child => error.NoChildren,
        else => error.Unexpected,
    };
    if (ret == 0) return null;
    return .{ .pid = ret, .status = status };
}

pub const KillError = error{ NoSuchProcess, PermissionDenied, Unexpected };

/// 结束进程 pid。只做标记，它回到 U 模式之前才真正结束。
pub fn kill(pid: usize) KillError!void {
    const ret = syscall(.kill, pid, 0, 0);
    if (abi.errnoOf(ret)) |e| return switch (e) {
        .srch => error.NoSuchProcess,
        .perm => error.PermissionDenied,
        else => error.Unexpected,
    };
}

/// 设置前台进程（按 Ctrl-C 时内核结束它），null 表示没有。
pub fn setfg(pid: ?usize) error{ NoSuchProcess, Unexpected }!void {
    const ret = syscall(.setfg, pid orelse 0, 0, 0);
    if (abi.errnoOf(ret)) |e| return switch (e) {
        .srch => error.NoSuchProcess,
        else => error.Unexpected,
    };
}

/// 把进程信息写进 buf，返回进程总数（可能比 buf.len 大，多出来的没写）。
pub fn procinfo(buf: []abi.ProcInfo) usize {
    return syscall(.procinfo, @intFromPtr(buf.ptr), buf.len, 0);
}

pub fn meminfo() abi.MemInfo {
    var info: abi.MemInfo = undefined;
    _ = syscall(.meminfo, @intFromPtr(&info), 0, 0);
    return info;
}

/// 第 index 个嵌在内核里的程序名，写进 buf；index 超出范围时返回 null。名字比 buf 长时截断。
pub fn listprog(index: usize, buf: []u8) ?[]u8 {
    const ret = syscall(.listprog, index, @intFromPtr(buf.ptr), buf.len);
    if (abi.errnoOf(ret) != null) return null;
    return buf[0..@min(ret, buf.len)];
}

pub fn shutdown() noreturn {
    _ = syscall(.shutdown, 0, 0, 0);
    unreachable;
}

// 和内核的 uart.zig 一样，接入 std.Io.Writer，用标准库做格式化，输出走 write 系统调用。
// 一次 print 的输出先攒在缓冲区里，最后用一次 write 写出去：write 在内核里是关着中断整段输出的，
// 所以一行不会被别的进程的输出从中间打断（超过缓冲区大小的部分会多写几次）。
var buffer: [256]u8 = undefined;
var writer: std.Io.Writer = .{
    .vtable = &.{ .drain = drain },
    .buffer = &buffer,
};

/// 先写出缓冲区里攒着的内容，再写 data（缓冲区放不下时才会走到这里），返回写出的 data 字节数。
fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    try writeAll(w.buffered());
    w.end = 0;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        try writeAll(bytes);
        n += bytes.len;
    }
    // 最后一段要重复 splat 次（用于填充对齐等）
    const pattern = data[data.len - 1];
    for (0..splat) |_| try writeAll(pattern);
    return n + pattern.len * splat;
}

fn writeAll(bytes: []const u8) std.Io.Writer.Error!void {
    var done: usize = 0;
    while (done < bytes.len) done += write(bytes[done..]) catch return error.WriteFailed;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch {};
    writer.flush() catch {};
}
