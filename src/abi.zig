//! 系统调用约定，内核和用户程序共用这个文件（build.zig 把它作为 abi 模块交给用户程序）。
//!
//! 用户程序把调用号放进 a7、参数放进 a0..a5，执行 ecall 陷入内核；内核把返回值写回 a0，
//! 其他寄存器原样恢复。返回值按有符号数理解：>= 0 表示成功，-4095..-1 是错误码的相反数
//! （和 Linux 一样，错误码也沿用 Linux 的编号）。

pub const Syscall = enum(usize) {
    /// exit(code: u8) 结束当前进程，不返回
    exit = 0,
    /// write(ptr, len) 把用户内存里的 len 个字节输出到串口，返回写出的字节数
    write = 1,
    /// getpid() 返回当前进程号
    getpid = 2,
    /// uptime() 返回开机以来的毫秒数
    uptime = 3,
    _,
};

pub const Errno = enum(usize) {
    /// 指针指向的内存不属于用户空间，或者没有映射
    fault = 14,
    /// 没有这个系统调用
    nosys = 38,
    _,
};

const max_errno = 4095;

/// 把错误码编码成返回值。
pub fn fail(e: Errno) usize {
    return 0 -% @backingInt(e);
}

/// 返回值表示错误时取出错误码，否则返回 null。
pub fn errnoOf(ret: usize) ?Errno {
    if (ret < 0 -% @as(usize, max_errno)) return null;
    return @fromBackingInt(0 -% ret);
}

test "错误码编码成返回值，再取回来" {
    const expectEqual = @import("std").testing.expectEqual;
    try expectEqual(@as(?Errno, .fault), errnoOf(fail(.fault)));
    try expectEqual(@as(?Errno, .nosys), errnoOf(0 -% @as(usize, 38)));
    // 普通返回值不是错误；-4096 超出了错误码的范围，也当成普通返回值
    try expectEqual(@as(?Errno, null), errnoOf(42));
    try expectEqual(@as(?Errno, null), errnoOf(0 -% @as(usize, 4096)));
}
