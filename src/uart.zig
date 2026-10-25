//! QEMU virt 机器上的 NS16550A 串口驱动，同时承担“屏幕”和“键盘”：
//! 输出用轮询，输入用中断——收到字符时串口经 PLIC 发来外部中断，中断处理程序把字符放进环形缓冲区。

const std = @import("std");

pub const base: usize = 0x1000_0000;
pub const mmio_size: usize = 0x100;

const Reg = enum(usize) {
    rbr_thr = 0, // 读：接收缓冲；写：发送保持
    ier = 1, // 中断使能
    fcr = 2, // FIFO 控制
    lcr = 3, // 线路控制
    lsr = 5, // 线路状态
};

const lsr_data_ready: u8 = 1 << 0;
const lsr_thr_empty: u8 = 1 << 5;

fn reg(r: Reg) *volatile u8 {
    return @ptrFromInt(base + @backingInt(r));
}

pub fn init() void {
    reg(.ier).* = 0x00; // 配置期间先关掉串口中断
    reg(.lcr).* = 0x03; // 8 位数据、无校验、1 位停止位
    reg(.fcr).* = 0x07; // 启用并清空收发 FIFO
    reg(.ier).* = 0x01; // 收到数据时产生中断
}

fn putRaw(c: u8) void {
    while (reg(.lsr).* & lsr_thr_empty == 0) {}
    reg(.rbr_thr).* = c;
}

pub fn putc(c: u8) void {
    // 终端需要 \r\n 才会回到行首
    if (c == '\n') putRaw('\r');
    putRaw(c);
}

pub fn write(bytes: []const u8) void {
    for (bytes) |c| putc(c);
}

fn getc() ?u8 {
    if (reg(.lsr).* & lsr_data_ready == 0) return null;
    return reg(.rbr_thr).*;
}

// 接收环形缓冲区：中断处理程序写入，主循环（关中断时）读出。
// 索引用 u8，+% 回绕正好对应 256 字节的缓冲区。
var rx_buf: [256]u8 = undefined;
var rx_head: u8 = 0;
var rx_tail: u8 = 0;

/// 串口中断处理：把硬件 FIFO 里的字符全部搬进环形缓冲区，满了就丢弃。
pub fn onInterrupt() void {
    while (getc()) |c| {
        if (rx_head +% 1 == rx_tail) continue;
        rx_buf[rx_head] = c;
        rx_head +%= 1;
    }
}

/// 取出一个已收到的字符。调用方需保证此时中断已关闭。
pub fn read() ?u8 {
    if (rx_tail == rx_head) return null;
    const c = rx_buf[rx_tail];
    rx_tail +%= 1;
    return c;
}

/// 接入 std.Io.Writer 接口，这样就能用标准库的格式化输出（{d}、{x}、{s} 等）。
/// buffer 为空，所以每次写入都直接走 drain，不需要 flush。
var writer: std.Io.Writer = .{
    .vtable = &.{ .drain = drain },
    .buffer = &.{},
};

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    _ = w;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        write(bytes);
        n += bytes.len;
    }
    // 最后一段要重复 splat 次（用于填充对齐等）
    const pattern = data[data.len - 1];
    for (0..splat) |_| write(pattern);
    return n + pattern.len * splat;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch {};
}
