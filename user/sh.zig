//! shell：读一行命令，执行，再读下一行。由 init 启动，对应 xv6 的 user/sh.c（简化得多）。
//!
//! 它是一个普通的用户程序，内核里的功能都通过系统调用使用：`run` 用 fork + exec 启动程序（带上命令行参数），
//! 前台运行时用 setfg 告诉内核按 Ctrl-C 该杀谁，再 wait 它结束；`ps`、`mem` 用 procinfo、meminfo。
//! `run a | b | c` 用 pipe、dup、close 把前一个程序的标准输出接到后一个程序的标准输入。
//! 键盘输入用 read 一个字节一个字节地读，回显和退格都由 shell 自己做。

const std = @import("std");
const sys = @import("sys");
const abi = sys.abi;

const Command = enum { help, uptime, mem, disk, cd, run, ps, kill, shutdown };

var line: [128]u8 = undefined;

/// 一个管道最多几个程序。进程表只有 abi.max_procs 个槽位，init、shell 和管道的“组长”（见 runPipeline）占三个。
const max_stages = 4;

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
        // 缓冲区在自己的栈上，不会出错。读到 0 是按了 Ctrl-D，忽略
        if ((sys.read(sys.stdin, &c) catch 0) == 0) continue;
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
            \\disk        size of the raw disk area (the blocks after the file system)
            \\cd [DIR]    change the current directory (default: /)
            \\run NAME [ARGS...]
            \\            run a user program and wait for it (without NAME: list them)
            \\run A | B   run A and B with A's output piped into B (up to 4 programs)
            \\run ... > F write the output to file F (< F: read input from F)
            \\run ... &   run it in the background
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
        .cd => {
            const dir = std.mem.trim(u8, arg, " ");
            sys.chdir(if (dir.len == 0) "/" else dir) catch |err| sys.print("cd: {s}: {s}\n", .{ dir, @errorName(err) });
        },
        .disk => {
            const n = sys.blockCount();
            if (n == 0) {
                sys.print("no disk\n", .{});
            } else {
                sys.print("{d} blocks of {d} KiB ({d} MiB)\n", .{ n, sys.block_size / 1024, n * sys.block_size >> 20 });
            }
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

/// 一个要运行的程序：程序名是 args[0]。`< 文件`、`> 文件` 把标准输入、标准输出换成文件。
const Stage = struct {
    args: [sys.abi.max_args][]const u8 = undefined,
    argc: usize = 0,
    in: ?[]const u8 = null,
    out: ?[]const u8 = null,

    fn name(st: *const Stage) []const u8 {
        return st.args[0];
    }
};

const ParseError = error{ EmptyCommand, TooManyArguments, TooManyStages, MissingFileName };

/// 把 run 的参数拆成用 | 隔开的几段，每段按空格拆成命令行参数。参数是 line 里的切片。
/// `<`、`>` 后面（可以有空格，也可以没有）是重定向的文件名，不算参数。
fn parse(arg: []const u8, stages: *[max_stages]Stage) ParseError![]Stage {
    var n: usize = 0;
    var parts = std.mem.splitScalar(u8, arg, '|');
    while (parts.next()) |part| {
        if (n == max_stages) return error.TooManyStages;
        const st = &stages[n];
        st.* = .{};
        var words = std.mem.tokenizeScalar(u8, part, ' ');
        while (words.next()) |w| {
            if (w[0] == '<' or w[0] == '>') {
                const target = if (w.len > 1) w[1..] else words.next() orelse return error.MissingFileName;
                if (w[0] == '<') st.in = target else st.out = target;
                continue;
            }
            if (st.argc == st.args.len) return error.TooManyArguments;
            st.args[st.argc] = w;
            st.argc += 1;
        }
        if (st.argc == 0) return error.EmptyCommand;
        n += 1;
    }
    return stages[0..n];
}

fn run(input: []const u8) void {
    // 末尾的 & 表示后台运行
    const trimmed = std.mem.trim(u8, input, " ");
    const background = std.mem.endsWith(u8, trimmed, "&");
    const arg = std.mem.trim(u8, if (background) trimmed[0 .. trimmed.len - 1] else trimmed, " ");
    if (arg.len == 0) return listPrograms();
    var buf: [max_stages]Stage = undefined;
    const stages = parse(arg, &buf) catch |err| {
        sys.print("run: {s}\n", .{switch (err) {
            error.EmptyCommand => "empty command in the pipeline",
            error.TooManyArguments => std.fmt.comptimePrint("too many arguments (at most {d})", .{abi.max_args}),
            error.TooManyStages => std.fmt.comptimePrint("too many programs in the pipeline (at most {d})", .{max_stages}),
            error.MissingFileName => "missing file name after < or >",
        }});
        return;
    };
    for (stages) |*st| {
        if (!programExists(st.name())) {
            sys.print("no such program: {s}\n", .{st.name()});
            listPrograms();
            return;
        }
    }
    // 只有一个程序时子进程直接 exec 成它；管道由一个子进程（“组长”）去建，见 runPipeline
    const pid = sys.fork() catch |err| return forkFailed(err);
    if (pid == 0) {
        // 前台的话子进程自己先登记成前台进程，再 exec：父进程的 setfg 可能晚于子进程开始运行
        // （fork 之后先调度谁不一定），那样程序刚开始运行时按的 Ctrl-C 就没人管了
        if (!background) sys.setfg(sys.getpid()) catch {};
        if (stages.len == 1) {
            redirect(&stages[0]);
            execStage(&stages[0]);
        }
        sys.exit(runPipeline(stages));
    }
    const what = if (stages.len == 1) stages[0].name() else "pipeline";
    if (background) {
        sys.print("[proc] pid {d} ({s}) started in the background\n", .{ pid, what });
        return;
    }
    // 前台：按 Ctrl-C 时内核杀掉它（和它的子孙，也就是管道里的各个程序）。等它结束、回收之后再打印提示符
    sys.setfg(pid) catch {};
    _ = sys.wait(pid, false) catch {};
    sys.setfg(null) catch {};
}

fn forkFailed(err: sys.ForkError) void {
    switch (err) {
        error.TooManyProcesses => sys.print("run: too many processes (at most {d})\n", .{abi.max_procs}),
        else => sys.print("run: cannot fork: {s}\n", .{@errorName(err)}),
    }
}

/// 在子进程里按 `<`、`>` 换掉标准输入、标准输出（`>` 的文件没有就建，有就截成 0 字节）。打不开就以 1 结束。
fn redirect(st: *const Stage) void {
    if (st.in) |path| replaceFd(sys.stdin, path, .{});
    if (st.out) |path| replaceFd(sys.stdout, path, .{ .read = false, .write = true, .create = true, .truncate = true });
}

fn replaceFd(target: sys.Fd, path: []const u8, flags: sys.OpenFlags) void {
    const fd = sys.open(path, flags) catch |err| {
        sys.print("run: {s}: {s}\n", .{ path, @errorName(err) });
        sys.exit(1);
    };
    // close 再 dup：dup 返回最小的空闲 fd，正好是刚关掉的那个
    sys.close(target) catch {};
    _ = sys.dup(fd) catch {};
    sys.close(fd) catch {};
}

/// 在子进程里换成要运行的程序。失败时（比如 ELF 不合法）说明原因，以 127 结束。
fn execStage(st: *const Stage) noreturn {
    sys.exec(st.name(), st.args[0..st.argc]) catch |err| sys.print("run: cannot load {s}: {s}\n", .{ st.name(), @errorName(err) });
    sys.exit(127);
}

/// 管道的“组长”（shell fork 出来的子进程，和 xv6 的 sh 一样）：依次 fork 出每个程序，
/// 第 i 个程序的标准输出接到一个新管道的写端，第 i+1 个程序的标准输入接到它的读端，然后等它们全部结束。
/// 返回最后一个程序的退出码（被杀了是 255），出错时是 1。
///
/// 各个程序都是组长的子进程，shell 把组长设为前台进程，按 Ctrl-C 时内核把组长和它们一起杀掉。
/// 组长自己必须关掉管道的两端：写端还开着的话，后面的程序永远读不到结尾。
fn runPipeline(stages: []Stage) u8 {
    var prev: ?sys.Fd = null; // 上一个程序输出的管道的读端
    var started: usize = 0;
    var last: usize = 0;
    var failed = false;
    for (stages, 0..) |*st, i| {
        const is_last = i == stages.len - 1;
        var p: [2]sys.Fd = undefined;
        if (!is_last) p = sys.pipe() catch |err| {
            sys.print("run: cannot create a pipe: {s}\n", .{@errorName(err)});
            failed = true;
            break;
        };
        const pid = sys.fork() catch |err| {
            forkFailed(err);
            if (!is_last) {
                sys.close(p[0]) catch {};
                sys.close(p[1]) catch {};
            }
            failed = true;
            break;
        };
        if (pid == 0) {
            // close 再 dup：dup 返回最小的空闲 fd，正好是刚关掉的 0 或 1
            if (prev) |fd| {
                sys.close(sys.stdin) catch {};
                _ = sys.dup(fd) catch {};
                sys.close(fd) catch {};
            }
            if (!is_last) {
                sys.close(sys.stdout) catch {};
                _ = sys.dup(p[1]) catch {};
                sys.close(p[0]) catch {};
                sys.close(p[1]) catch {};
            }
            redirect(st); // 重定向优先于管道（和 Unix 的 sh 一样）
            execStage(st);
        }
        started += 1;
        last = pid;
        if (prev) |fd| sys.close(fd) catch {};
        prev = null;
        if (!is_last) {
            sys.close(p[1]) catch {};
            prev = p[0];
        }
    }
    if (prev) |fd| sys.close(fd) catch {};
    var code: u8 = 1;
    for (0..started) |_| {
        const r = (sys.wait(null, false) catch break) orelse break;
        if (r.pid == last and !failed) code = @intCast(@min(r.status, 255));
    }
    return code;
}

/// 程序文件在不在。和内核的 exec 一样：名字里没有 '/' 的在 /bin 里找，有的按路径找。
fn programExists(name: []const u8) bool {
    var buf: [abi.max_path]u8 = undefined;
    const path = if (std.mem.indexOfScalar(u8, name, '/') != null)
        name
    else
        std.fmt.bufPrint(&buf, "/bin/{s}", .{name}) catch return false;
    const fd = sys.open(path, .{}) catch return false;
    defer sys.close(fd) catch {};
    const st = sys.fstat(fd) catch return false;
    return st.kind == .file;
}

var name_bytes: [4096]u8 = undefined;
var names: [128][]const u8 = undefined;

/// 列出 /bin 里的程序，按名字排序（readdir 给的是名字的散列的顺序）。
fn listPrograms() void {
    const fd = sys.open("/bin", .{}) catch |err| {
        sys.print("run: /bin: {s}\n", .{@errorName(err)});
        return;
    };
    defer sys.close(fd) catch {};
    var n: usize = 0;
    var used: usize = 0;
    var ent: abi.Dirent = undefined;
    while (n < names.len and (sys.readdir(fd, &ent) catch false)) {
        const name = ent.name[0..ent.name_len];
        if (name.len > name_bytes.len - used) break;
        names[n] = name_bytes[used..][0..name.len];
        @memcpy(name_bytes[used..][0..name.len], name);
        used += name.len;
        n += 1;
    }
    // 插入排序：std.mem.sort 是块排序，栈上有一个 512 项的缓存（这里是 8 KiB 的切片），
    // Debug 模式下把 16 KiB 的用户栈撑爆过。几十个名字用插入排序就够了
    std.sort.insertion([]const u8, names[0..n], {}, lessThan);
    sys.print("programs:", .{});
    for (names[0..n]) |name| sys.print(" {s}", .{name});
    sys.print("\n", .{});
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
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
