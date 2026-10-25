//! 极简命令行：逐字符接收键盘输入并回显，回车后执行命令。

const std = @import("std");
const uart = @import("uart.zig");
const timer = @import("timer.zig");
const sbi = @import("sbi.zig");

const Command = enum { help, uptime, ebreak, crash, shutdown };

var line: [64]u8 = undefined;
var len: usize = 0;

pub fn prompt() void {
    uart.write("> ");
}

pub fn feed(c: u8) void {
    switch (c) {
        '\r', '\n' => {
            uart.putc('\n');
            execute(line[0..len]);
            len = 0;
            prompt();
        },
        // 退格：光标左移，用空格盖掉，再左移
        0x08, 0x7f => if (len > 0) {
            len -= 1;
            uart.write("\x08 \x08");
        },
        ' '...'~' => if (len < line.len) {
            line[len] = c;
            len += 1;
            uart.putc(c);
        },
        else => {},
    }
}

fn execute(input: []const u8) void {
    const name = std.mem.trim(u8, input, " ");
    if (name.len == 0) return;
    const cmd = std.meta.stringToEnum(Command, name) orelse {
        uart.print("unknown command: {s} (try 'help')\n", .{name});
        return;
    };
    switch (cmd) {
        .help => uart.write(
            \\help      show this message
            \\uptime    time since boot, counted by timer interrupts
            \\ebreak    trigger a breakpoint exception and recover from it
            \\crash     read from address 0 -> unhandled exception -> panic
            \\shutdown  power off through SBI
            \\
        ),
        .uptime => {
            const t = timer.ticks;
            uart.print("up {d}.{d:0>2}s ({d} timer interrupts)\n", .{ t / timer.tick_hz, t % timer.tick_hz, t });
        },
        .ebreak => asm volatile ("ebreak"),
        .crash => {
            const bad: *allowzero volatile u64 = @ptrFromInt(0);
            _ = bad.*;
        },
        .shutdown => {
            uart.write("bye!\n");
            sbi.shutdown();
        },
    }
}
