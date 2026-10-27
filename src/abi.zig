//! 系统调用约定，内核和用户程序共用这个文件（build.zig 把它作为 abi 模块交给用户程序）。
//!
//! 用户程序把调用号放进 a7、参数放进 a0..a5，执行 ecall 陷入内核；内核把返回值写回 a0，
//! 其他寄存器原样恢复。返回值按有符号数理解：>= 0 表示成功，-4095..-1 是错误码的相反数
//! （和 Linux 一样，错误码也沿用 Linux 的编号）。

pub const Syscall = enum(usize) {
    /// exit(code: u8) 结束当前进程，不返回
    exit = 0,
    /// write(ptr, len) 把用户内存里的 len 个字节输出到串口，返回写出的字节数
    write = 1,
    /// getpid() 返回当前进程号
    getpid = 2,
    /// uptime() 返回开机以来的毫秒数
    uptime = 3,
    /// yield() 让出 CPU，让别的就绪进程先运行，返回 0
    yield = 4,
    /// sleep(ms) 睡至少 ms 毫秒（按 10 ms 的 tick 向上取整），期间不占 CPU，返回 0
    sleep = 5,
    /// read(ptr, len) 从键盘读最多 len 个字节到用户内存，返回读到的字节数。
    /// 一个字节都没有时阻塞，直到有输入；不回显，不做行编辑（shell 自己做）
    read = 6,
    /// fork() 复制当前进程。父进程得到子进程的 pid，子进程得到 0
    fork = 7,
    /// exec(name_ptr, name_len) 用嵌在内核里的程序 name 替换当前进程的地址空间，从它的入口开始执行。
    /// 成功时不返回到原来的程序（新程序看到的寄存器除了 sp 都是 0）
    exec = 8,
    /// wait(pid, status_ptr, options) 等子进程结束并回收它，返回它的 pid。
    /// pid 为 wait_any 时等任意一个子进程；status_ptr 不为 0 时写入一个 u32 的结束状态（见 killed_status）；
    /// options 含 wait_nohang 时不阻塞，没有已结束的子进程就返回 0
    wait = 9,
    /// kill(pid) 结束进程 pid，返回 0。只做标记，进程回到 U 模式之前才结束
    kill = 10,
    /// getppid() 返回父进程的 pid（init 返回 0）
    getppid = 11,
    /// setfg(pid) 设置前台进程：按 Ctrl-C 时内核结束它。pid 为 0 表示没有前台进程
    setfg = 12,
    /// procinfo(ptr, n) 把最多 n 个进程的 ProcInfo 写进用户内存，返回进程总数
    procinfo = 13,
    /// meminfo(ptr) 把 MemInfo 写进用户内存，返回 0
    meminfo = 14,
    /// listprog(index, ptr, len) 把第 index 个嵌在内核里的程序名写进用户内存（最多 len 字节），
    /// 返回名字的完整长度；index 超出范围时返回 -ENOENT
    listprog = 15,
    /// shutdown() 关机，不返回
    shutdown = 16,
    _,
};

pub const Errno = enum(usize) {
    /// 没有权限（kill init）
    perm = 1,
    /// 没有这个程序（exec、listprog）
    noent = 2,
    /// 没有这个进程（kill、setfg）
    srch = 3,
    /// 程序不是合法的 ELF（exec）
    noexec = 8,
    /// 没有可以等的子进程（wait）
    child = 10,
    /// 进程表满了（fork）
    again = 11,
    /// 物理内存不够（fork、exec）
    nomem = 12,
    /// 指针指向的内存不属于用户空间，或者没有映射
    fault = 14,
    /// 参数不对
    inval = 22,
    /// 没有这个系统调用
    nosys = 38,
    _,
};

/// 进程表的大小：最多同时有这么多个进程（包括 init、shell 和还没被回收的 zombie）。
pub const max_procs = 8;

/// wait 的 pid 参数：等任意一个子进程。
pub const wait_any: usize = 0 -% @as(usize, 1);
/// wait 的 options：没有已结束的子进程时不阻塞，返回 0。
pub const wait_nohang: usize = 1;
/// wait 写回的结束状态：正常退出时是退出码（0..255），被杀时是 killed_status。
pub const killed_status: u32 = 0x100;

/// 进程的状态。内核的进程表直接用这个类型（proc.State），procinfo 原样交给用户程序。
pub const ProcState = enum(u8) {
    unused,
    /// 可以运行，等调度器挑到它
    runnable,
    /// 正在 CPU 上运行
    running,
    /// 在 sleep(chan) 里等某件事：sleep 系统调用、read 等键盘、wait 等子进程
    sleeping,
    /// 已经结束，等父进程 wait 回收
    zombie,
};

/// procinfo 返回的一个进程的信息。
pub const ProcInfo = extern struct {
    pid: u64,
    ppid: u64,
    /// 在 U 模式运行期间来过的时钟中断数
    ticks: u64,
    state: ProcState,
    /// name 里有效的字节数（名字超过 16 字节时截断）
    name_len: u8,
    name: [16]u8,
};

/// meminfo 返回的物理内存使用情况。
pub const MemInfo = extern struct {
    free_pages: u64,
    total_pages: u64,
    page_size: u64,
};

const max_errno = 4095;

/// 把错误码编码成返回值。
pub fn fail(e: Errno) usize {
    return 0 -% @backingInt(e);
}

/// 返回值表示错误时取出错误码，否则返回 null。
pub fn errnoOf(ret: usize) ?Errno {
    if (ret < 0 -% @as(usize, max_errno)) return null;
    return @fromBackingInt(0 -% ret);
}

test "错误码编码成返回值，再取回来" {
    const expectEqual = @import("std").testing.expectEqual;
    try expectEqual(@as(?Errno, .fault), errnoOf(fail(.fault)));
    try expectEqual(@as(?Errno, .nosys), errnoOf(0 -% @as(usize, 38)));
    // 普通返回值不是错误；-4096 超出了错误码的范围，也当成普通返回值
    try expectEqual(@as(?Errno, null), errnoOf(42));
    try expectEqual(@as(?Errno, null), errnoOf(0 -% @as(usize, 4096)));
}
