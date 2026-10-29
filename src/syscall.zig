//! 系统调用。用户程序执行 ecall 陷入内核后，handleTrap 把它交给 dispatch。
//! 调用约定见 abi.zig。处理期间中断是关着的，系统调用都很短，不会长时间占着 CPU；
//! 要等待的（yield、sleep、read、write 管道、wait）在里面切回调度器，轮到这个进程时再从切走的地方返回。
//!
//! 文件相关的调用（read、write、close、dup、pipe）照 xv6 的 sysfile.c：fd 是当前进程 fd 表的下标，
//! 先在这里查出 File，再交给 file.zig。

const std = @import("std");
const abi = @import("abi.zig");
const uart = @import("uart.zig");
const timer = @import("timer.zig");
const vm = @import("vm.zig");
const page = @import("page.zig");
const sbi = @import("sbi.zig");
const proc = @import("proc.zig");
const file = @import("file.zig");
const TrapFrame = @import("trap.zig").TrapFrame;

/// 返回值会写回用户程序的 a0。
pub fn dispatch(frame: *TrapFrame) usize {
    const args = frame.regs[10..16]; // a0..a5
    const number: abi.Syscall = @fromBackingInt(frame.regs[17]); // a7
    return switch (number) {
        .exit => proc.exit(@truncate(args[0])),
        .write => write(args[0], args[1], args[2]),
        .getpid => proc.current().?.pid,
        .uptime => timer.uptimeMs(),
        .yield => yield(),
        .sleep => sleep(args[0]),
        .read => read(args[0], args[1], args[2]),
        .fork => fork(),
        .exec => exec(args[0], args[1], args[2], args[3]),
        .wait => wait(args[0], args[1], args[2]),
        .kill => kill(args[0]),
        .getppid => proc.parentPid(),
        .setfg => setfg(args[0]),
        .procinfo => procinfo(args[0], args[1]),
        .meminfo => meminfo(args[0]),
        .listprog => listprog(args[0], args[1], args[2]),
        .shutdown => shutdown(),
        .close => close(args[0]),
        .dup => dup(args[0]),
        .pipe => pipe(args[0]),
        .sbrk => sbrk(args[0]),
        _ => abi.fail(.nosys),
    };
}

fn space() *vm.PageTable {
    return proc.current().?.space;
}

fn yield() usize {
    proc.yield();
    return 0;
}

/// 睡至少 ms 毫秒，按 tick 向上取整（乘法和加法都是饱和的，ms 再大也不溢出）。
/// 和 xv6 的 sys_sleep 一样：拿着 timer.lock 睡在 &timer.ticks 上，每个 tick 叫醒一次，醒来自己数够了没有。
/// 被 kill 了就提前返回，回到陷阱处理程序后结束。
fn sleep(ms: usize) usize {
    const n = (ms *| timer.tick_hz +| 999) / 1000;
    timer.lock.acquire();
    defer timer.lock.release();
    const start = timer.ticks;
    while (timer.ticks - start < n and !proc.isKilled()) proc.sleep(&timer.ticks, &timer.lock);
    return 0;
}

/// fd 对应的打开的文件，fd 超出范围或者没有打开时返回 null。
fn fileOf(fd: usize) ?*file.File {
    if (fd >= abi.max_fds) return null;
    return proc.current().?.files[fd];
}

/// 当前进程最小的空闲 fd，指向 f（f 的引用已经算好了）。fd 表满了返回 null。
fn installFd(f: *file.File) ?usize {
    const files = &proc.current().?.files;
    for (files, 0..) |*slot, fd| {
        if (slot.* == null) {
            slot.* = f;
            return fd;
        }
    }
    return null;
}

fn fileError(err: file.Error) usize {
    return abi.fail(switch (err) {
        error.NotReadable, error.NotWritable => .badf,
        error.BadAddress => .fault,
        error.BrokenPipe => .pipe,
    });
}

/// 写 fd。中途遇到坏地址就停下，返回已经写出的字节数；一个字节都没写出才返回错误（见 file.write）。
fn write(fd: usize, ptr: usize, len: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    return file.write(f, space(), ptr, len) catch |err| fileError(err);
}

/// 读 fd。先检查整个目标范围可写：从串口的缓冲区取出来的字符放不回去，不能取出来之后才发现写不进去。
fn read(fd: usize, ptr: usize, len: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    if (len == 0) return 0;
    vm.checkUser(space(), ptr, len, true) catch return abi.fail(.fault);
    return file.read(f, space(), ptr, len) catch |err| fileError(err);
}

fn close(fd: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    proc.current().?.files[fd] = null;
    file.close(f);
    return 0;
}

fn dup(fd: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    const new = installFd(file.dup(f)) orelse {
        file.close(f);
        return abi.fail(.mfile);
    };
    return new;
}

/// 创建管道，把读端、写端的 fd 写进 fds_ptr（两个 u32）。任何一步失败都把已经做了的撤销掉。
fn pipe(fds_ptr: usize) usize {
    // 先检查能写：fd 装进 fd 表以后再失败，就要再一个个撤销
    vm.checkUser(space(), fds_ptr, 2 * @sizeOf(u32), true) catch return abi.fail(.fault);
    const r, const w = file.openPipe() catch |err| return abi.fail(switch (err) {
        error.TooManyFiles => .nfile,
        error.OutOfMemory => .nomem,
    });
    const files = &proc.current().?.files;
    const rfd = installFd(r) orelse {
        file.close(r);
        file.close(w);
        return abi.fail(.mfile);
    };
    const wfd = installFd(w) orelse {
        files[rfd] = null;
        file.close(r);
        file.close(w);
        return abi.fail(.mfile);
    };
    const fds = [2]u32{ @intCast(rfd), @intCast(wfd) };
    vm.copyToUser(space(), fds_ptr, std.mem.asBytes(&fds)) catch unreachable; // 上面检查过了
    return 0;
}

fn sbrk(increment: usize) usize {
    return proc.sbrk(@bitCast(increment)) catch |err| abi.fail(switch (err) {
        error.OutOfMemory => .nomem,
        error.InvalidArgument => .inval,
    });
}

fn fork() usize {
    return proc.fork() catch |err| abi.fail(switch (err) {
        error.TooManyProcesses => .again,
        error.OutOfMemory => .nomem,
    });
}

/// 程序名最长多少字节。嵌在内核里的程序名都很短，更长的一定找不到。
const max_name = 32;

/// 把程序名和命令行参数都复制进内核（参数放在栈上的 buf 里），再交给 proc.exec：
/// 参数在旧的地址空间里，换掉地址空间之前就要取出来。
/// 成功时返回 argc：handleTrap 把返回值写进 a0，正好是新程序看到的 argc（a1 由 proc.exec 设好）。
fn exec(name_ptr: usize, name_len: usize, argv_ptr: usize, argc: usize) usize {
    if (name_len > max_name) return abi.fail(.noent);
    var name_buf: [max_name]u8 = undefined;
    const name = name_buf[0..name_len];
    vm.copyFromUser(space(), name, name_ptr) catch return abi.fail(.fault);

    if (argc > abi.max_args) return abi.fail(.toobig);
    var argv: [abi.max_args]abi.Arg = undefined;
    vm.copyFromUser(space(), std.mem.sliceAsBytes(argv[0..argc]), argv_ptr) catch return abi.fail(.fault);
    var buf: [abi.max_arg_bytes]u8 = undefined;
    var args: [abi.max_args][]const u8 = undefined;
    var used: usize = 0;
    for (argv[0..argc], args[0..argc]) |a, *arg| {
        if (a.len > buf.len - used) return abi.fail(.toobig);
        const dst = buf[used..][0..a.len];
        vm.copyFromUser(space(), dst, a.ptr) catch return abi.fail(.fault);
        arg.* = dst;
        used += a.len;
    }

    proc.exec(name, args[0..argc]) catch |err| return abi.fail(switch (err) {
        error.NoSuchProgram => .noent,
        error.OutOfMemory => .nomem,
        error.BadElf => .noexec,
    });
    return argc;
}

/// 等子进程结束，把结束状态写进 status_ptr（不为 0 时），回收它，返回它的 pid（见 proc.wait）。
/// 写状态失败时不回收，返回 -EFAULT：子进程还在，可以再 wait 一次。
fn wait(pid: usize, status_ptr: usize, options: usize) usize {
    if (options & ~abi.wait_nohang != 0) return abi.fail(.inval);
    const found = proc.wait(pid, options & abi.wait_nohang != 0, status_ptr) catch |err| return abi.fail(switch (err) {
        error.NoChildren => .child,
        error.BadAddress => .fault,
    });
    return found orelse 0;
}

fn kill(pid: usize) usize {
    proc.kill(pid, "kill()") catch |err| return abi.fail(switch (err) {
        error.NoSuchProcess => .srch,
        error.PermissionDenied => .perm,
    });
    return 0;
}

fn setfg(pid: usize) usize {
    proc.setForeground(pid) catch return abi.fail(.srch);
    return 0;
}

/// 把进程表里每个在用的槽位写成一个 ProcInfo，最多写 n 个，返回进程总数（可能比 n 大）。
/// 每个槽位单独拿锁取一份（proc.info），不是同一瞬间的快照：别的 hart 上的进程可能正在 fork、结束。
fn procinfo(ptr: usize, n: usize) usize {
    var count: usize = 0;
    for (0..proc.max_procs) |i| {
        const info = proc.info(i) orelse continue;
        if (count < n) {
            const va = std.math.add(usize, ptr, count * @sizeOf(abi.ProcInfo)) catch return abi.fail(.fault);
            vm.copyToUser(space(), va, std.mem.asBytes(&info)) catch return abi.fail(.fault);
        }
        count += 1;
    }
    return count;
}

fn meminfo(ptr: usize) usize {
    const info: abi.MemInfo = .{ .free_pages = page.free_pages, .total_pages = page.total_pages, .page_size = page.size };
    vm.copyToUser(space(), ptr, std.mem.asBytes(&info)) catch return abi.fail(.fault);
    return 0;
}

/// 把第 index 个程序名的前 len 个字节写进用户内存，返回名字的完整长度。
fn listprog(index: usize, ptr: usize, len: usize) usize {
    if (index >= proc.programs.len) return abi.fail(.noent);
    const name = proc.programs[index].name;
    vm.copyToUser(space(), ptr, name[0..@min(len, name.len)]) catch return abi.fail(.fault);
    return name.len;
}

fn shutdown() noreturn {
    sbi.shutdown();
}
