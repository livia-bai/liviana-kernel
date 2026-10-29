//! QEMU virt 机器上的 NS16550A 串口驱动，同时承担“屏幕”和“键盘”：
//! 输出用轮询，输入用中断——收到字符时串口经 PLIC 发来外部中断，中断处理程序把字符放进环形缓冲区。
//!
//! 输出没有加锁：多核时几个 hart 同时输出，字符会交错在一起，但不会出错；
//! panic 时也要能输出，不能去等一把可能永远拿不到的锁。

const std = @import("std");
const Spinlock = @import("spinlock.zig").Spinlock;

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

// 接收环形缓冲区：中断处理程序写入，read 系统调用读出（file.consoleRead）。
// 索引用 u8，+% 回绕正好对应 256 字节的缓冲区。
var rx_buf: [256]u8 = undefined;
var rx_head: u8 = 0;
var rx_tail: u8 = 0;

/// 保护接收缓冲区。中断处理程序也要拿它：拿着它的代码都关着中断，同一个 hart 上不会被中断打断，
/// 所以不会自己等自己；多核时串口中断可能在另一个 hart 上处理。
pub var rx_lock: Spinlock = .init("uart rx");

/// 等键盘输入的进程睡在这个通道上，收到字符后陷阱处理程序用它 proc.wakeup。
pub const rx_chan: *const anyopaque = &rx_buf;

/// Ctrl-C（ASCII 0x03）不进缓冲区，陷阱处理程序据此结束前台进程。
const ctrl_c = 0x03;

/// 串口中断处理：把硬件 FIFO 里的字符全部搬进环形缓冲区，满了就丢弃。返回这次有没有按过 Ctrl-C。
pub fn onInterrupt() bool {
    rx_lock.acquire();
    defer rx_lock.release();
    var ctrl_c_pressed = false;
    while (getc()) |c| {
        if (c == ctrl_c) {
            ctrl_c_pressed = true;
            continue;
        }
        if (rx_head +% 1 == rx_tail) continue;
        rx_buf[rx_head] = c;
        rx_head +%= 1;
    }
    return ctrl_c_pressed;
}

/// 缓冲区里有没有字符。调用方要拿着 rx_lock，下同。
pub fn hasInput() bool {
    std.debug.assert(rx_lock.holding());
    return rx_tail != rx_head;
}

/// 看一眼下一个字符，不取出来。
pub fn peek() ?u8 {
    std.debug.assert(rx_lock.holding());
    if (rx_tail == rx_head) return null;
    return rx_buf[rx_tail];
}

/// 取出一个已收到的字符。
pub fn read() ?u8 {
    const c = peek() orelse return null;
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
