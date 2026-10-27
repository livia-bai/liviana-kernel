//! shell：读一行命令，执行，再读下一行。由 init 启动，对应 xv6 的 user/sh.c（简化得多）。
//!
//! 它是一个普通的用户程序，内核里的功能都通过系统调用使用：`run` 用 fork + exec 启动程序，
//! 前台运行时用 setfg 告诉内核按 Ctrl-C 该杀谁，再 wait 它结束；`ps`、`mem` 用 procinfo、meminfo。
//! 键盘输入用 read 一个字节一个字节地读，回显和退格都由 shell 自己做。

const std = @import("std");
const sys = @import("sys");
const abi = sys.abi;

const Command = enum { help, uptime, mem, run, ps, kill, shutdown };

var line: [64]u8 = undefined;

pub fn main() u8 {
    sys.print("Type 'help' for commands.\n", .{});
    while (true) {
        reapBackground();
        sys.print("> ", .{});
        execute(readLine());
    }
}

/// 读一行：可打印字符回显并追加（行满了就忽略），退格删掉最后一个字符，回车结束。
/// 其他字符（方向键的转义序列、Tab 等）忽略。Ctrl-C 不会读到：内核在串口中断里就把它截下了。
fn readLine() []const u8 {
    var len: usize = 0;
    while (true) {
        var c: [1]u8 = undefined;
        _ = sys.read(&c) catch continue; // 缓冲区在自己的栈上，不会出错
        switch (c[0]) {
            '\r', '\n' => {
                sys.print("\n", .{});
                return line[0..len];
            },
            // 退格：光标左移，用空格盖掉，再左移
            0x08, 0x7f => if (len > 0) {
                len -= 1;
                sys.print("\x08 \x08", .{});
            },
            ' '...'~' => if (len < line.len) {
                line[len] = c[0];
                len += 1;
                sys.print("{c}", .{c[0]});
            },
            else => {},
        }
    }
}

/// 回收已经结束的后台进程。它们结束时内核已经打印过信息了，不回收的话会一直占着进程表的槽位。
fn reapBackground() void {
    while (sys.wait(null, true) catch null) |_| {}
}

fn execute(input: []const u8) void {
    const trimmed = std.mem.trim(u8, input, " ");
    if (trimmed.len == 0) return;
    // 第一个空格之前是命令名，之后是参数
    const name, const arg = std.mem.cutScalar(u8, trimmed, ' ') orelse .{ trimmed, "" };
    const cmd = std.meta.stringToEnum(Command, name) orelse {
        sys.print("unknown command: {s} (try 'help')\n", .{name});
        return;
    };
    switch (cmd) {
        .help => sys.print(
            \\help        show this message
            \\uptime      time since boot
            \\mem         free physical pages
            \\run NAME    run a user program and wait for it (without NAME: list them)
            \\run NAME &  run it in the background
            \\ps          list processes
            \\kill PID    kill a process
            \\shutdown    power off through SBI
            \\
        , .{}),
        .uptime => {
            const ms = sys.uptime();
            sys.print("up {d}.{d:0>2}s\n", .{ ms / 1000, ms % 1000 / 10 });
        },
        .mem => {
            const m = sys.meminfo();
            sys.print("{d} of {d} pages free ({d} KiB), {d} KiB each\n", .{
                m.free_pages, m.total_pages, m.free_pages * m.page_size / 1024, m.page_size / 1024,
            });
        },
        .run => run(arg),
        .ps => ps(),
        .kill => kill(arg),
        .shutdown => {
            sys.print("bye!\n", .{});
            sys.shutdown();
        },
    }
}

fn run(arg: []const u8) void {
    // 末尾的 & 表示后台运行
    const background = std.mem.endsWith(u8, arg, "&");
    const name = std.mem.trim(u8, if (background) arg[0 .. arg.len - 1] else arg, " ");
    if (!programExists(name)) {
        if (name.len != 0) sys.print("no such program: {s}\n", .{name});
        listPrograms();
        return;
    }
    const pid = sys.fork() catch |err| {
        switch (err) {
            error.TooManyProcesses => sys.print("run: too many processes (at most {d})\n", .{abi.max_procs}),
            else => sys.print("run: cannot fork: {s}\n", .{@errorName(err)}),
        }
        return;
    };
    if (pid == 0) {
        // 子进程：换成要运行的程序。失败时（比如 ELF 不合法）说明原因，以 127 结束
        sys.exec(name) catch |err| sys.print("run: cannot load {s}: {s}\n", .{ name, @errorName(err) });
        sys.exit(127);
    }
    if (background) {
        sys.print("[proc] pid {d} ({s}) started in the background\n", .{ pid, name });
        return;
    }
    // 前台：按 Ctrl-C 时内核杀掉它。等它结束、回收之后再打印提示符
    sys.setfg(pid) catch {};
    _ = sys.wait(pid, false) catch {};
    sys.setfg(null) catch {};
}

fn programExists(name: []const u8) bool {
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (sys.listprog(i, &buf)) |p| : (i += 1) {
        if (std.mem.eql(u8, p, name)) return true;
    }
    return false;
}

fn listPrograms() void {
    var buf: [32]u8 = undefined;
    sys.print("programs:", .{});
    var i: usize = 0;
    while (sys.listprog(i, &buf)) |p| : (i += 1) sys.print(" {s}", .{p});
    sys.print("\n", .{});
}

fn ps() void {
    var buf: [abi.max_procs]abi.ProcInfo = undefined;
    const n = @min(sys.procinfo(&buf), buf.len);
    sys.print("  PID  PPID STATE     TICKS NAME\n", .{});
    for (buf[0..n]) |p| {
        sys.print("{d:>5} {d:>5} {s:<8} {d:>6} {s}\n", .{ p.pid, p.ppid, @tagName(p.state), p.ticks, p.name[0..p.name_len] });
    }
}

fn kill(arg: []const u8) void {
    const pid = std.fmt.parseInt(usize, std.mem.trim(u8, arg, " "), 10) catch {
        sys.print("usage: kill PID\n", .{});
        return;
    };
    sys.kill(pid) catch |err| {
        switch (err) {
            error.NoSuchProcess => sys.print("kill: no such process: {d}\n", .{pid}),
            error.PermissionDenied => sys.print("kill: cannot kill pid {d}: permission denied\n", .{pid}),
            else => sys.print("kill: {s}\n", .{@errorName(err)}),
        }
        return;
    };
    // kill 只做标记。是自己的子进程（后台进程）的话，等它真的结束、回收它，
    // 这样“killed”那一行在下一个提示符之前。不是自己的子进程时 wait 立刻返回 NoChildren
    _ = sys.wait(pid, false) catch {};
}
