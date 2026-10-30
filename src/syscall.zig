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
const bio = @import("bio.zig");
const fsys = @import("fsys.zig");
const Fs = fsys.Fs;
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
        .shutdown => shutdown(),
        .close => close(args[0]),
        .dup => dup(args[0]),
        .pipe => pipe(args[0]),
        .sbrk => sbrk(args[0]),
        .blockcount => fsys.raw_count,
        .readblock => readBlock(args[0], args[1]),
        .writeblock => writeBlock(args[0], args[1]),
        .open => open(args[0], args[1], args[2]),
        .mkdir => pathOp(args[0], args[1], .mkdir),
        .unlink => pathOp(args[0], args[1], .unlink),
        .chdir => pathOp(args[0], args[1], .chdir),
        .fstat => fstat(args[0], args[1]),
        .readdir => readdir(args[0], args[1]),
        .scrub => scrub(args[0]),
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
        error.BrokenPipe => .pipe,
        else => fsys.errno(err), // 文件系统里的文件：磁盘满了、读到坏块等
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

fn blockError(err: bio.Error) usize {
    return abi.fail(switch (err) {
        error.NoDevice => .nodev,
        error.OutOfRange => .inval,
    });
}

/// 原始区域的第 blockno 块在磁盘上是第几块（fsys.raw_base 起）。
fn rawBlock(blockno: usize) bio.Error!u64 {
    if (fsys.raw_count == 0) return error.NoDevice;
    if (blockno >= fsys.raw_count) return error.OutOfRange;
    return fsys.raw_base + blockno;
}

/// 读原始区域的一块到用户内存。先检查整个目标范围可写（顺便复制好写时复制的页），之后的 copyToUser 一定成功。
fn readBlock(blockno: usize, ptr: usize) usize {
    vm.checkUser(space(), ptr, abi.block_size, true) catch return abi.fail(.fault);
    const n = rawBlock(blockno) catch |err| return blockError(err);
    const b = bio.read(n) catch |err| return blockError(err);
    defer bio.release(b);
    vm.copyToUser(space(), ptr, b.data) catch unreachable;
    return 0;
}

/// 用户内存的一块写到磁盘。整块覆盖，不用先读；先检查来源可读，复制到一半失败的话缓冲区里会留下半新半旧的内容。
fn writeBlock(blockno: usize, ptr: usize) usize {
    vm.checkUser(space(), ptr, abi.block_size, false) catch return abi.fail(.fault);
    const n = rawBlock(blockno) catch |err| return blockError(err);
    const b = bio.get(n) catch |err| return blockError(err);
    defer bio.release(b);
    vm.copyFromUser(space(), b.data, ptr) catch unreachable;
    b.valid = true;
    bio.write(b);
    return 0;
}

// ---- 文件系统 ----

/// 把用户给的路径复制进 buf。
fn userPath(ptr: usize, len: usize, buf: *[abi.max_path]u8) error{ NameTooLong, BadAddress }![]const u8 {
    if (len > buf.len) return error.NameTooLong;
    try vm.copyFromUser(space(), buf[0..len], ptr);
    return buf[0..len];
}

/// 打开路径 path，返回 fd（见 abi.Syscall.open）。
fn open(path_ptr: usize, path_len: usize, flags: usize) usize {
    const access = flags & 3;
    if (access == 3 or flags & ~(3 | abi.open_create | abi.open_trunc) != 0) return abi.fail(.inval);
    const readable = access != abi.open_write;
    const writable = access != abi.open_read;
    var buf: [abi.max_path]u8 = undefined;
    const path = userPath(path_ptr, path_len, &buf) catch |err| return abi.fail(fsys.errno(err));
    const root = fsys.get() catch return abi.fail(.nodev);
    const ino = openPath(root, proc.current().?.cwd, path, flags, writable) catch |err| {
        fsys.unlock();
        return abi.fail(fsys.errno(err));
    };
    fsys.unlock();
    const f = file.openInode(ino, readable, writable) catch return abi.fail(.nfile);
    return installFd(f) orelse {
        file.close(f);
        return abi.fail(.mfile);
    };
}

fn openPath(root: *Fs, cwd: u64, path: []const u8, flags: usize, writable: bool) @import("fs.zig").Error!u64 {
    const ino = root.resolve(cwd, path) catch |err| switch (err) {
        error.NotFound => if (flags & abi.open_create != 0) return root.run(Fs.create, .{ cwd, path, .file }) else return err,
        else => return err,
    };
    const st = try root.stat(ino);
    if (st.kind == .dir and writable) return error.IsDir;
    if (flags & abi.open_trunc != 0 and writable and st.size > 0) try root.run(Fs.truncate, .{ino});
    return ino;
}

const PathOp = enum { mkdir, unlink, chdir };

/// mkdir、unlink、chdir：只有一个路径参数。
fn pathOp(path_ptr: usize, path_len: usize, op: PathOp) usize {
    var buf: [abi.max_path]u8 = undefined;
    const path = userPath(path_ptr, path_len, &buf) catch |err| return abi.fail(fsys.errno(err));
    const p = proc.current().?;
    const root = fsys.get() catch return abi.fail(.nodev);
    defer fsys.unlock();
    switch (op) {
        .mkdir => _ = root.run(Fs.create, .{ p.cwd, path, .dir }) catch |err| return abi.fail(fsys.errno(err)),
        .unlink => root.run(Fs.unlink, .{ p.cwd, path }) catch |err| return abi.fail(fsys.errno(err)),
        .chdir => {
            const ino = root.resolve(p.cwd, path) catch |err| return abi.fail(fsys.errno(err));
            const st = root.stat(ino) catch |err| return abi.fail(fsys.errno(err));
            if (st.kind != .dir) return abi.fail(.notdir);
            p.cwd = ino;
        },
    }
    return 0;
}

fn fstat(fd: usize, ptr: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    var st: abi.Stat = .{ .ino = 0, .size = 0, .kind = .console };
    switch (f.kind) {
        .none => unreachable,
        .console => {},
        .pipe => st.kind = .pipe,
        .inode => {
            const root = fsys.get() catch return abi.fail(.nodev);
            defer fsys.unlock();
            const s = root.stat(f.ino) catch |err| return abi.fail(fsys.errno(err));
            st = .{ .ino = s.ino, .size = s.size, .kind = @fromBackingInt(@backingInt(s.kind)) };
        },
    }
    vm.copyToUser(space(), ptr, std.mem.asBytes(&st)) catch return abi.fail(.fault);
    return 0;
}

/// 目录 fd 的下一个目录项：读写位置 off 就是 fs.readdir 的 cookie。写进用户内存成功了才往后挪。
fn readdir(fd: usize, ptr: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    if (f.kind != .inode) return abi.fail(.notdir);
    const root = fsys.get() catch return abi.fail(.nodev);
    defer fsys.unlock();
    var ent: abi.Dirent = undefined;
    const found = root.readdir(f.ino, f.off, &ent.name) catch |err| return abi.fail(fsys.errno(err));
    const d = found orelse return 0;
    ent.ino = d.ino;
    ent.kind = @fromBackingInt(@backingInt(d.kind));
    ent.name_len = @intCast(d.name_len);
    ent._pad = @splat(0);
    @memset(ent.name[d.name_len..], 0);
    vm.copyToUser(space(), ptr, std.mem.asBytes(&ent)) catch return abi.fail(.fault);
    f.off = d.next;
    return 1;
}

/// 检查整个文件系统（fs.Fs.check）。先作废缓冲区缓存：要核对的是磁盘上的内容，校验和只在读盘时核对。
/// 拿着 fsys.lock，别的进程的文件操作都在等，缓存里也没有做到一半的操作。
fn scrub(ptr: usize) usize {
    vm.checkUser(space(), ptr, @sizeOf(abi.ScrubInfo), true) catch return abi.fail(.fault);
    const root = fsys.get() catch return abi.fail(.nodev);
    defer fsys.unlock();
    bio.invalidate();
    const st = root.check() catch |err| return abi.fail(fsys.errno(err));
    const info: abi.ScrubInfo = .{
        .files = st.files,
        .dirs = st.dirs,
        .data_blocks = st.data_blocks,
        .nodes = st.tree.nodes,
        .items = st.tree.items,
        .height = st.tree.height,
        .free_blocks = root.vol.free_count,
        .blocks = root.vol.blocks,
        .generation = root.vol.generation,
    };
    vm.copyToUser(space(), ptr, std.mem.asBytes(&info)) catch unreachable; // 上面检查过了
    return 0;
}

fn fork() usize {
    return proc.fork() catch |err| abi.fail(switch (err) {
        error.TooManyProcesses => .again,
        error.OutOfMemory => .nomem,
    });
}

/// 把程序的路径和命令行参数都复制进内核（参数放在栈上的 buf 里），再交给 proc.exec：
/// 参数在旧的地址空间里，换掉地址空间之前就要取出来。
/// 成功时返回 argc：handleTrap 把返回值写进 a0，正好是新程序看到的 argc（a1 由 proc.exec 设好）。
fn exec(path_ptr: usize, path_len: usize, argv_ptr: usize, argc: usize) usize {
    var path_buf: [abi.max_path]u8 = undefined;
    const path = userPath(path_ptr, path_len, &path_buf) catch |err| return abi.fail(fsys.errno(err));

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

    proc.exec(path, args[0..argc]) catch |err| return abi.fail(switch (err) {
        error.NoSuchProgram => .noent,
        error.OutOfMemory => .nomem,
        error.BadElf => .noexec,
        error.IoError => .io,
        error.NoDevice => .nodev,
        error.NotDir => .notdir,
        error.NameTooLong => .nametoolong,
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

fn shutdown() noreturn {
    sbi.shutdown();
}
