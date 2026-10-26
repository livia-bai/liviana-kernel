//! 极简命令行：逐字符接收键盘输入并回显，回车后执行命令。
//!
//! `run NAME` 在前台运行程序：shell 等它结束才打印下一个提示符，这期间主循环不把键盘输入交给 shell，
//! Ctrl-C 结束这个前台进程。`run NAME &` 在后台运行，马上回到提示符。

const std = @import("std");
const uart = @import("uart.zig");
const timer = @import("timer.zig");
const sbi = @import("sbi.zig");
const page = @import("page.zig");
const proc = @import("proc.zig");

const Command = enum { help, uptime, mem, run, ps, kill, ebreak, crash, shutdown };

var line: [64]u8 = undefined;
var len: usize = 0;

/// 前台进程的 pid，没有时为 null。
var foreground: ?usize = null;

pub fn prompt() void {
    uart.write("> ");
}

pub fn feed(c: u8) void {
    switch (c) {
        '\r', '\n' => {
            uart.putc('\n');
            execute(line[0..len]);
            len = 0;
            if (foreground == null) prompt(); // 否则等前台进程结束，由 waiting() 打印
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

/// 主循环每一轮调用（关着中断）。前台进程还在就返回 true，这时主循环不读键盘输入；
/// 发现前台进程结束了就打印提示符，返回 false。
pub fn waiting() bool {
    const pid = foreground orelse return false;
    if (proc.findPid(pid) != null) return true;
    foreground = null;
    prompt();
    return false;
}

/// 用户按了 Ctrl-C：结束前台进程。没有前台进程时什么也不做。主循环调用（关着中断）。
pub fn interrupt() void {
    const pid = foreground orelse return;
    uart.write("^C\n");
    _ = proc.kill(pid, "interrupted by Ctrl-C");
}

fn execute(input: []const u8) void {
    const trimmed = std.mem.trim(u8, input, " ");
    if (trimmed.len == 0) return;
    // 第一个空格之前是命令名，之后是参数
    const name, const arg = std.mem.cutScalar(u8, trimmed, ' ') orelse .{ trimmed, "" };
    const cmd = std.meta.stringToEnum(Command, name) orelse {
        uart.print("unknown command: {s} (try 'help')\n", .{name});
        return;
    };
    switch (cmd) {
        .help => uart.write(
            \\help        show this message
            \\uptime      time since boot, counted by timer interrupts
            \\mem         free physical pages
            \\run NAME    run a user program in U-mode and wait for it (without NAME: list them)
            \\run NAME &  run it in the background
            \\ps          list processes
            \\kill PID    kill a process
            \\ebreak      trigger a breakpoint exception and recover from it
            \\crash       read from address 0 -> unhandled exception -> panic
            \\shutdown    power off through SBI
            \\
        ),
        .uptime => {
            const t = timer.ticks;
            uart.print("up {d}.{d:0>2}s ({d} timer interrupts)\n", .{ t / timer.tick_hz, t % timer.tick_hz, t });
        },
        .mem => uart.print("{d} of {d} pages free ({d} KiB), 4 KiB each\n", .{
            page.free_pages, page.total_pages, page.free_pages * page.size / 1024,
        }),
        .run => run(arg),
        .ps => ps(),
        .kill => kill(arg),
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

fn run(arg: []const u8) void {
    // 末尾的 & 表示后台运行
    const background = std.mem.endsWith(u8, arg, "&");
    const name = std.mem.trim(u8, if (background) arg[0 .. arg.len - 1] else arg, " ");
    const program = proc.find(name) orelse {
        if (name.len != 0) uart.print("no such program: {s}\n", .{name});
        uart.write("programs:");
        for (proc.programs) |p| uart.print(" {s}", .{p.name});
        uart.write("\n");
        return;
    };
    const pid = proc.spawn(program) catch |err| {
        switch (err) {
            error.TooManyProcesses => uart.print("run: too many processes (at most {d})\n", .{proc.max_procs}),
            else => uart.print("run: cannot load {s}: {s}\n", .{ name, @errorName(err) }),
        }
        return;
    };
    if (background) {
        uart.print("[proc] pid {d} ({s}) started in the background\n", .{ pid, name });
    } else {
        foreground = pid;
    }
}

fn ps() void {
    uart.write("  PID STATE     TICKS NAME\n");
    for (proc.table) |p| {
        if (p.state == .unused) continue;
        uart.print("{d:>5} {s:<8} {d:>6} {s}\n", .{ p.pid, @tagName(p.state), p.ticks, p.name });
    }
}

fn kill(arg: []const u8) void {
    const pid = std.fmt.parseInt(usize, std.mem.trim(u8, arg, " "), 10) catch {
        uart.write("usage: kill PID\n");
        return;
    };
    if (!proc.kill(pid, "kill command")) uart.print("kill: no such process: {d}\n", .{pid});
}
