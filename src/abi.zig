//! 系统调用约定，内核和用户程序共用这个文件（build.zig 把它作为 abi 模块交给用户程序）。
//!
//! 用户程序把调用号放进 a7、参数放进 a0..a5，执行 ecall 陷入内核；内核把返回值写回 a0，
//! 其他寄存器原样恢复。返回值按有符号数理解：>= 0 表示成功，-4095..-1 是错误码的相反数
//! （和 Linux 一样，错误码也沿用 Linux 的编号）。

pub const Syscall = enum(usize) {
    /// exit(code: u8) 结束当前进程，不返回
    exit = 0,
    /// write(fd, ptr, len) 把用户内存里的 len 个字节写进文件 fd（串口或管道），返回写出的字节数
    write = 1,
    /// getpid() 返回当前进程号
    getpid = 2,
    /// uptime() 返回开机以来的毫秒数
    uptime = 3,
    /// yield() 让出 CPU，让别的就绪进程先运行，返回 0
    yield = 4,
    /// sleep(ms) 睡至少 ms 毫秒（按 10 ms 的 tick 向上取整），期间不占 CPU，返回 0
    sleep = 5,
    /// read(fd, ptr, len) 从文件 fd（串口或管道）读最多 len 个字节到用户内存，返回读到的字节数。
    /// 一个字节都没有时阻塞；返回 0 表示读到了结尾（管道的写端都关了，或者在串口上按了 Ctrl-D）
    read = 6,
    /// fork() 复制当前进程。父进程得到子进程的 pid，子进程得到 0
    fork = 7,
    /// exec(name_ptr, name_len, argv_ptr, argc) 用嵌在内核里的程序 name 替换当前进程的地址空间，
    /// 从它的入口开始执行。argv_ptr 指向 argc 个 Arg（命令行参数，按惯例第一个是程序名），
    /// 内核把它们复制到新程序的栈顶。成功时不返回到原来的程序：新程序看到 a0 = argc、
    /// a1 = 栈上 Arg 数组的地址、sp 在这个数组下面，其他寄存器都是 0。打开的文件保持不变
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
    /// close(fd) 关闭文件 fd，返回 0
    close = 17,
    /// dup(fd) 让编号最小的空闲 fd 指向和 fd 同一个文件，返回新的 fd
    dup = 18,
    /// pipe(fds_ptr) 创建一个管道，把读端、写端的 fd（两个 u32）写进用户内存，返回 0
    pipe = 19,
    /// sbrk(increment) 把堆的末尾（program break）移动 increment 字节（按有符号数理解，可以为负），
    /// 返回原来的末尾。新增的内存清零；缩小时释放整页
    sbrk = 20,
    _,
};

pub const Errno = enum(usize) {
    /// 没有权限（kill init）
    perm = 1,
    /// 没有这个程序（exec、listprog）
    noent = 2,
    /// 没有这个进程（kill、setfg）
    srch = 3,
    /// 命令行参数太多或太长（exec）
    toobig = 7,
    /// 程序不是合法的 ELF（exec）
    noexec = 8,
    /// fd 不是打开的文件，或者文件不能这样用（往读端写、从写端读）
    badf = 9,
    /// 没有可以等的子进程（wait）
    child = 10,
    /// 进程表满了（fork）
    again = 11,
    /// 物理内存不够（fork、exec、pipe），或者堆不能再长了（sbrk）
    nomem = 12,
    /// 指针指向的内存不属于用户空间，或者没有映射
    fault = 14,
    /// 参数不对
    inval = 22,
    /// 系统的文件表满了（pipe、fork）
    nfile = 23,
    /// 进程的 fd 表满了（dup、pipe）
    mfile = 24,
    /// 管道的读端都关了，写进去没人读（write）
    pipe = 32,
    /// 没有这个系统调用
    nosys = 38,
    _,
};

/// 进程表的大小：最多同时有这么多个进程（包括 init、shell 和还没被回收的 zombie）。
pub const max_procs = 8;

/// 每个进程最多同时打开多少个文件（fd 的范围是 0..max_fds）。
pub const max_fds = 16;
/// 约定的三个 fd：init 把它们都指向串口，之后由 fork 继承下去。
pub const stdin = 0;
pub const stdout = 1;
pub const stderr = 2;

/// exec 最多传多少个命令行参数，参数加起来最多多少字节。
pub const max_args = 16;
pub const max_arg_bytes = 1024;

/// 一个命令行参数：用户地址空间里的一段字节（不以 0 结尾）。
pub const Arg = extern struct {
    ptr: usize,
    len: usize,

    pub fn of(s: []const u8) Arg {
        return .{ .ptr = @intFromPtr(s.ptr), .len = s.len };
    }

    /// 用户程序用：参数在自己的地址空间里，直接当成切片。
    pub fn slice(a: Arg) []const u8 {
        if (a.len == 0) return ""; // ptr 可能是 0，不能转成普通指针
        return @as([*]const u8, @ptrFromInt(a.ptr))[0..a.len];
    }
};

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
