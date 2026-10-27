//! 系统调用。用户程序执行 ecall 陷入内核后，handleTrap 把它交给 dispatch。
//! 调用约定见 abi.zig。处理期间中断是关着的，系统调用都很短，不会长时间占着 CPU；
//! 要等待的（yield、sleep、read、wait）在里面切回调度器，轮到这个进程时再从切走的地方返回。

const std = @import("std");
const abi = @import("abi.zig");
const uart = @import("uart.zig");
const timer = @import("timer.zig");
const vm = @import("vm.zig");
const page = @import("page.zig");
const sbi = @import("sbi.zig");
const proc = @import("proc.zig");
const TrapFrame = @import("trap.zig").TrapFrame;

/// 返回值会写回用户程序的 a0。
pub fn dispatch(frame: *TrapFrame) usize {
    const args = frame.regs[10..16]; // a0..a5
    const number: abi.Syscall = @fromBackingInt(frame.regs[17]); // a7
    return switch (number) {
        .exit => proc.exit(@truncate(args[0])),
        .write => write(args[0], args[1]),
        .getpid => proc.current.?.pid,
        .uptime => timer.uptimeMs(),
        .yield => yield(),
        .sleep => sleep(args[0]),
        .read => read(args[0], args[1]),
        .fork => fork(),
        .exec => exec(args[0], args[1]),
        .wait => wait(args[0], args[1], args[2]),
        .kill => kill(args[0]),
        .getppid => if (proc.current.?.parent) |p| p.pid else 0,
        .setfg => setfg(args[0]),
        .procinfo => procinfo(args[0], args[1]),
        .meminfo => meminfo(args[0]),
        .listprog => listprog(args[0], args[1], args[2]),
        .shutdown => shutdown(),
        _ => abi.fail(.nosys),
    };
}

fn space() *vm.PageTable {
    return proc.current.?.space;
}

fn yield() usize {
    proc.yield();
    return 0;
}

/// 睡至少 ms 毫秒，按 tick 向上取整（乘法和加法都是饱和的，ms 再大也不溢出）。
/// 和 xv6 的 sys_sleep 一样：睡在 &timer.ticks 上，每个时钟中断叫醒一次，醒来自己数够了没有。
/// 被 kill 了就提前返回，回到陷阱处理程序后结束。
fn sleep(ms: usize) usize {
    const n = (ms *| timer.tick_hz +| 999) / 1000;
    const start = timer.ticks;
    while (timer.ticks - start < n and proc.current.?.killed == null) proc.sleep(&timer.ticks);
    return 0;
}

/// 用户内存先分块复制到内核缓冲区再输出，每块都经过 vm.copyFromUser 检查。
/// 中途遇到坏地址就停下，返回已经写出的字节数；一个字节都没写出才返回错误。
fn write(ptr: usize, len: usize) usize {
    var buf: [128]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        // 每块都不跨页：一块失败就说明这一页整个不能读，前面的字节都已经写出去了
        const va = ptr + done;
        const chunk = buf[0..@min(buf.len, len - done, page.size - va % page.size)];
        vm.copyFromUser(space(), chunk, va) catch {
            return if (done == 0) abi.fail(.fault) else done;
        };
        uart.write(chunk);
        done += chunk.len;
    }
    return done;
}

/// 从键盘缓冲区读最多 len 个字节。缓冲区为空时睡在 uart.rx_chan 上，串口中断叫醒它。
/// 先检查整个目标范围可写：字符从缓冲区取出来就放不回去了，不能取出来之后才发现写不进去。
fn read(ptr: usize, len: usize) usize {
    if (len == 0) return 0;
    vm.checkUser(space(), ptr, len, true) catch return abi.fail(.fault);
    while (!uart.hasInput()) {
        if (proc.current.?.killed != null) return 0; // 回到陷阱处理程序后结束，返回值没人看
        proc.sleep(uart.rx_chan);
    }
    var buf: [64]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        var n: usize = 0;
        while (n < @min(buf.len, len - done)) : (n += 1) buf[n] = uart.read() orelse break;
        if (n == 0) break;
        vm.copyToUser(space(), ptr + done, buf[0..n]) catch unreachable; // 上面检查过了
        done += n;
    }
    return done;
}

fn fork() usize {
    return proc.fork() catch |err| abi.fail(switch (err) {
        error.TooManyProcesses => .again,
        error.OutOfMemory => .nomem,
    });
}

/// 程序名最长多少字节。嵌在内核里的程序名都很短，更长的一定找不到。
const max_name = 32;

fn exec(name_ptr: usize, name_len: usize) usize {
    if (name_len > max_name) return abi.fail(.noent);
    var buf: [max_name]u8 = undefined;
    const name = buf[0..name_len];
    vm.copyFromUser(space(), name, name_ptr) catch return abi.fail(.fault);
    proc.exec(name) catch |err| return abi.fail(switch (err) {
        error.NoSuchProgram => .noent,
        error.OutOfMemory => .nomem,
        error.BadElf => .noexec,
    });
    return 0; // 写进新程序的 a0，和它其他寄存器一样是 0
}

/// 等子进程结束（见 proc.waitChild），把结束状态写进 status_ptr（不为 0 时），回收它，返回它的 pid。
/// 写状态失败时不回收，返回 -EFAULT：子进程还在，可以再 wait 一次。
fn wait(pid: usize, status_ptr: usize, options: usize) usize {
    if (options & ~abi.wait_nohang != 0) return abi.fail(.inval);
    const found = proc.waitChild(pid, options & abi.wait_nohang != 0) catch return abi.fail(.child);
    const child = found orelse return 0;
    if (status_ptr != 0) {
        vm.copyToUser(space(), status_ptr, std.mem.asBytes(&child.xstatus)) catch return abi.fail(.fault);
    }
    const child_pid = child.pid;
    proc.reap(child);
    return child_pid;
}

fn kill(pid: usize) usize {
    proc.kill(pid, "kill()") catch |err| return abi.fail(switch (err) {
        error.NoSuchProcess => .srch,
        error.PermissionDenied => .perm,
    });
    return 0;
}

fn setfg(pid: usize) usize {
    if (pid != 0 and proc.findPid(pid) == null) return abi.fail(.srch);
    proc.foreground = pid;
    return 0;
}

/// 把进程表里每个在用的槽位写成一个 ProcInfo，最多写 n 个，返回进程总数（可能比 n 大）。
fn procinfo(ptr: usize, n: usize) usize {
    var count: usize = 0;
    for (&proc.table) |*p| {
        if (p.state == .unused) continue;
        if (count < n) {
            var info: abi.ProcInfo = .{
                .pid = p.pid,
                .ppid = if (p.parent) |q| q.pid else 0,
                .ticks = p.ticks,
                .state = p.state,
                .name_len = @intCast(@min(p.name.len, 16)),
                .name = @splat(0),
            };
            @memcpy(info.name[0..info.name_len], p.name[0..info.name_len]);
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
