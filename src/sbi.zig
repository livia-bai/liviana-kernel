//! SBI（Supervisor Binary Interface）调用。
//! 内核运行在 S 模式，需要 M 模式才能做的事（设置定时器、关机）通过 ecall 请 OpenSBI 代办。
//! 调用约定：a7 = 扩展号 EID，a6 = 功能号 FID，a0..a5 = 参数；返回 a0 = 错误码，a1 = 返回值。

const Extension = enum(usize) {
    base = 0x10,
    time = 0x54494D45, // "TIME"
    srst = 0x53525354, // "SRST"：系统复位
};

const Ret = struct {
    err: isize,
    value: usize,
};

fn call(ext: Extension, fid: usize, arg0: usize, arg1: usize) Ret {
    var err: isize = undefined;
    var value: usize = undefined;
    asm volatile ("ecall"
        : [err] "={a0}" (err),
          [value] "={a1}" (value),
        : [eid] "{a7}" (@backingInt(ext)),
          [fid] "{a6}" (fid),
          [arg0] "{a0}" (arg0),
          [arg1] "{a1}" (arg1),
        : .{ .memory = true });
    return .{ .err = err, .value = value };
}

pub const Version = struct {
    major: usize,
    minor: usize,
};

pub fn specVersion() Version {
    const v = call(.base, 0, 0, 0).value;
    return .{ .major = (v >> 24) & 0x7f, .minor = v & 0xff_ffff };
}

/// SBI 实现的名字，例如 QEMU 自带的 OpenSBI 编号为 1。
pub fn implName() []const u8 {
    return switch (call(.base, 1, 0, 0).value) {
        0 => "BBL",
        1 => "OpenSBI",
        2 => "Xvisor",
        3 => "KVM",
        4 => "RustSBI",
        5 => "Diosix",
        else => "unknown",
    };
}

/// 在 time CSR 达到 `deadline` 时触发一次 S 模式时钟中断，同时清除当前挂起的时钟中断。
pub fn setTimer(deadline: u64) void {
    _ = call(.time, 0, deadline, 0);
}

pub fn shutdown() noreturn {
    _ = call(.srst, 0, 0, 0); // type 0 = 关机，reason 0 = 无原因
    // 成功时不会返回；走到这里说明固件不支持 SRST，只能原地停机
    while (true) riscv.wfi();
}

const riscv = @import("riscv.zig");
