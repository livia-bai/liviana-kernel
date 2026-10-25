//! 回归测试：write 系统调用的边界情况，以及不存在的调用号。
//! 期望输出见 tools/qemu_test.py。

const std = @import("std");
const sys = @import("sys");

var page_buf: [8192]u8 align(4096) = undefined;

pub fn main() u8 {
    // 跨越用户空间的末尾：前 4 个字节在栈顶那一页里，后面超出了 0x8000_0000
    const top: [*]u8 = @ptrFromInt(0x8000_0000 - 4);
    @memcpy(top[0..4], "abcd");
    sys.print("\npartial write -> {any}\n", .{sys.write(top[0..10])});
    // 长度大到让地址溢出
    sys.print("huge write -> {any}\n", .{sys.write(top[0 .. std.math.maxInt(usize) - 0x8000_0000])});
    // 零长度：不检查指针
    sys.print("empty write -> {any}\n", .{sys.write(@as([*]const u8, @ptrFromInt(8))[0..0])});
    // 跨页的大块写入（.bss 里的两页）
    @memset(&page_buf, '.');
    page_buf[page_buf.len - 1] = '\n';
    sys.print("cross-page write -> {any}\n", .{sys.write(page_buf[4000..])});
    // 不存在的调用号
    const ret = asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [n] "{a7}" (@as(usize, 999)),
        : .{ .memory = true });
    sys.print("syscall 999 -> {d}\n", .{@as(isize, @bitCast(ret))});
    return 42;
}
