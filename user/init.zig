//! 第一个进程（pid 1），内核启动时创建（proc.userinit），对应 xv6 的 user/init.c。
//! 启动 shell，然后一直 wait：既回收 shell，也回收父进程先结束、被交给 init 的孤儿。
//! shell 结束了就再启动一个。init 自己不能结束（内核会 panic），出了错只打印，过一会儿再试。

const sys = @import("sys");

pub fn main() u8 {
    while (true) {
        const sh = startShell();
        while (true) {
            const child = (sys.wait(null, false) catch break) orelse continue;
            if (child.pid == sh) break;
        }
        sys.print("init: sh exited, restarting it\n", .{});
    }
}

fn startShell() usize {
    while (true) {
        const pid = sys.fork() catch |err| {
            sys.print("init: cannot fork: {s}\n", .{@errorName(err)});
            sys.sleep(1000);
            continue;
        };
        if (pid == 0) {
            sys.exec("sh") catch |err| sys.print("init: cannot exec sh: {s}\n", .{@errorName(err)});
            sys.exit(1);
        }
        return pid;
    }
}
