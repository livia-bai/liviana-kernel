# 系统调用

涉及文件：`src/abi.zig`（内核和用户程序共用）、`src/syscall.zig`（内核实现）、`user/sys.zig`（用户态封装）、`src/vm.zig` 的 `copyFromUser`、`copyToUser`、`checkUser`

## 调用约定

和 Linux 在 RISC-V 上的约定一样：

| 寄存器 | 用途 |
| --- | --- |
| `a7` | 调用号（`abi.Syscall`） |
| `a0..a5` | 参数（目前最多用三个） |
| `a0`（返回） | 返回值 |
| 其他寄存器 | 内核原样恢复 |

用户程序执行 `ecall` → CPU 产生“来自 U 模式的 ecall”异常（`scause = 8`，委托给了 S 模式）→ `trapEntry` 通过 `sscratch` 换到进程内核栈、保存全部寄存器 → `handleTrap` 把 `sepc` 加 4（跳过 `ecall`，它没有压缩形式，固定 4 字节）→ `syscall.dispatch(frame)` 的返回值写进 `frame.regs[10]`（`a0`）→ `trapExit` 恢复寄存器、`sret` 回到 `ecall` 的下一条指令。

**返回值按有符号数理解**：`>= 0` 表示成功；`-4095..-1` 表示失败，取反就是错误码（和 Linux 一样，错误码的编号也沿用 Linux）。

## abi.zig

```zig
pub const Syscall = enum(usize) {
    exit = 0, write = 1, getpid = 2, uptime = 3, yield = 4, sleep = 5,
    read = 6, fork = 7, exec = 8, wait = 9, kill = 10, getppid = 11,
    setfg = 12, procinfo = 13, meminfo = 14, listprog = 15, shutdown = 16,
    _,
};

pub const Errno = enum(usize) {
    perm = 1,     // EPERM：杀 init
    noent = 2,    // ENOENT：没有这个程序（exec、listprog）
    srch = 3,     // ESRCH：没有这个进程（kill、setfg）
    noexec = 8,   // ENOEXEC：程序不是合法的 ELF（exec）
    child = 10,   // ECHILD：没有可以等的子进程（wait）
    again = 11,   // EAGAIN：进程表满了（fork）
    nomem = 12,   // ENOMEM：物理内存不够（fork、exec）
    fault = 14,   // EFAULT：指针指向的内存不属于用户空间、没有映射，或者要写的页不可写
    inval = 22,   // EINVAL：参数不对（wait 的 options）
    nosys = 38,   // ENOSYS：没有这个系统调用
    _,
};

pub const max_procs = 8;
pub const wait_any: usize = 0 -% 1;   // wait 的 pid：任意一个子进程
pub const wait_nohang: usize = 1;     // wait 的 options：不阻塞
pub const killed_status: u32 = 0x100; // wait 拿到的“被杀”状态（正常退出是 0..255）

pub const ProcState = enum(u8) { unused, runnable, running, sleeping, zombie };
pub const ProcInfo = extern struct { pid: u64, ppid: u64, ticks: u64, state: ProcState, name_len: u8, name: [16]u8 };
pub const MemInfo = extern struct { free_pages: u64, total_pages: u64, page_size: u64 };

pub fn fail(e: Errno) usize            // 把错误码编码成返回值：0 -% e
pub fn errnoOf(ret: usize) ?Errno      // 返回值在 [-4095, -1] 内时取出错误码
```

`Syscall` 和 `Errno` 都是非穷尽的（`_`），所以用户程序传来任意数字都能安全地转换成 `Syscall`（`@fromBackingInt`），不认识的落到 `_` 分支。

`ProcInfo`、`MemInfo` 是 `extern struct`，内核把它们的字节原样复制进用户内存，两边的布局由 C ABI 保证一致。`ProcState` 同时是内核进程表的状态类型（`proc.State = abi.ProcState`），不用转换。

这个文件被**两次编译**使用：内核里按路径 `@import("abi.zig")`，用户程序里作为构建系统创建的 `abi` 模块（[build.md](build.md#用户程序)），用户程序通过 `sys.abi` 访问它。改它就同时改了两边的约定。

## 调用列表

| 号 | 调用 | 参数 | 返回 | 说明 |
| --- | --- | --- | --- | --- |
| 0 | `exit` | `a0` = 退出码 | 不返回 | 只取低 8 位（`@truncate` 成 `u8`）。打印 `[proc] pid N (NAME) exited with code C`，变成 zombie 等父进程回收（[process.md](process.md#结束进程)） |
| 1 | `write` | `a0` = 用户缓冲区地址，`a1` = 长度 | 写出的字节数，或 `-EFAULT` | 把用户内存里的字节输出到串口，详见下文 |
| 2 | `getpid` | 无 | 进程号 | 每创建一个进程加 1，不复用。init 是 1，shell 是 2 |
| 3 | `uptime` | 无 | 开机以来的毫秒数 | `timer.uptimeMs()`，精度 10 ms（一个时钟 tick） |
| 4 | `yield` | 无 | 0 | 让出 CPU：回到调度器，别的 runnable 进程先运行，轮到它时返回。没有别的 runnable 进程时很快就会返回 |
| 5 | `sleep` | `a0` = 毫秒数 | 0 | 睡至少 `a0` 毫秒（按 10 ms 的 tick 向上取整），期间不被调度、不占 CPU。`0` 立刻返回 |
| 6 | `read` | `a0` = 缓冲区地址，`a1` = 长度 | 读到的字节数（至少 1），或 `-EFAULT` | 从键盘读，详见下文 |
| 7 | `fork` | 无 | 父进程得到子进程的 pid，子进程得到 0；或 `-EAGAIN`、`-ENOMEM` | 复制当前进程（[process.md](process.md#fork)） |
| 8 | `exec` | `a0` = 程序名地址，`a1` = 名字长度 | 成功时不返回；`-ENOENT`、`-ENOEXEC`、`-ENOMEM`、`-EFAULT` | 换成嵌在内核里的程序 `name` 运行（[process.md](process.md#exec)）。名字超过 32 字节一定找不到，返回 `-ENOENT` |
| 9 | `wait` | `a0` = pid（`wait_any` 表示任意一个），`a1` = 状态的地址（0 表示不要），`a2` = options | 回收的子进程的 pid；`nohang` 时没有已结束的子进程返回 0；`-ECHILD`、`-EFAULT`、`-EINVAL` | 详见下文 |
| 10 | `kill` | `a0` = pid | 0；`-ESRCH`、`-EPERM`（init） | 只做标记，目标进程回到 U 模式之前结束（[process.md](process.md#kill只做标记)） |
| 11 | `getppid` | 无 | 父进程的 pid；init 是 0 | |
| 12 | `setfg` | `a0` = pid，0 表示没有 | 0；`-ESRCH` | 设置前台进程：按 Ctrl-C 时内核杀掉它（[process.md](process.md#ctrl-c)） |
| 13 | `procinfo` | `a0` = `ProcInfo` 数组的地址，`a1` = 数组长度 n | 进程总数（可能大于 n）；`-EFAULT` | 按槽位顺序写最多 n 个进程的信息。n = 0 时只返回总数。名字超过 16 字节时截断 |
| 14 | `meminfo` | `a0` = `MemInfo` 的地址 | 0；`-EFAULT` | 空闲页数、总页数、页大小 |
| 15 | `listprog` | `a0` = 下标，`a1` = 缓冲区地址，`a2` = 长度 | 名字的完整长度；`-ENOENT`（下标超出范围）、`-EFAULT` | 把第 `a0` 个嵌在内核里的程序名写进缓冲区，最多写 `a2` 字节 |
| 16 | `shutdown` | 无 | 不返回 | 通过 SBI 关机 |
| 其他 | | | `-ENOSYS` | |

### 分发

```zig
pub fn dispatch(frame: *TrapFrame) usize {
    const args = frame.regs[10..16]; // a0..a5
    const number: abi.Syscall = @fromBackingInt(frame.regs[17]); // a7
    return switch (number) {
        .exit => proc.exit(@truncate(args[0])),
        .write => write(args[0], args[1]),
        .getpid => proc.current.?.pid,
        ...
        .getppid => if (proc.current.?.parent) |p| p.pid else 0,
        ...
        .shutdown => shutdown(),
        _ => abi.fail(.nosys),
    };
}
```

`proc.exit` 和 `shutdown` 是 `noreturn`，可以直接放在 `switch` 表达式里。其余的大多是一个小函数：把参数交给 `proc` 或 `vm` 里的函数，把 Zig 的错误换成 `abi.fail(错误码)`。

会等待的调用（`yield`、`sleep`、`read`、`wait`）在里面切回调度器，等这个进程再被调度时才返回，然后 `handleTrap` 照常把返回值写进 `a0`、检查 `killed`、回到 U 模式。`sleep` 和 xv6 的 `sys_sleep` 一样，在循环里 `proc.sleep(&timer.ticks)`，每个时钟中断醒来一次，数够了 tick（或者被 kill 了）才返回（[process.md](process.md#sleepwakeup)）。

## write

```zig
fn write(ptr: usize, len: usize) usize {
    var buf: [128]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        const va = ptr + done;
        const chunk = buf[0..@min(buf.len, len - done, page.size - va % page.size)];
        vm.copyFromUser(proc.current.?.space, chunk, va) catch {
            return if (done == 0) abi.fail(.fault) else done;
        };
        uart.write(chunk);
        done += chunk.len;
    }
    return done;
}
```

- 用户内存先**复制**到内核栈上 128 字节的缓冲区，再从缓冲区输出。内核从不直接解引用用户给的指针。
- 每一块都不跨页（块大小取 128、剩余长度、到页尾的距离三者的最小值）。所以一块复制失败，就说明这一页整个不能读，而之前的块都已经完整输出了。这保证了返回值的含义是精确的：
  - 一个字节都没写出就遇到坏地址 → 返回 `-14`（EFAULT）。
  - 写出了一部分之后遇到坏地址 → 返回已经写出的字节数（小于 `len`），和 POSIX 的部分写语义一致。
  - `len = 0` → 返回 0，不检查指针。
- `ptr + done` 不会溢出：`done > 0` 说明 `[ptr, ptr + done)` 已经全部通过了检查，都在用户区内。
- 最初的实现不按页分块，一个 128 字节的块可能跨过有效页和无效页的边界，导致“前 4 个字节有效，后面无效”的写入整体失败、返回 EFAULT，而不是写出 4 个字节。测试时发现并修正了。

## read

```zig
fn read(ptr: usize, len: usize) usize {
    if (len == 0) return 0;
    vm.checkUser(space(), ptr, len, true) catch return abi.fail(.fault);
    while (!uart.hasInput()) {
        if (proc.current.?.killed != null) return 0;
        proc.sleep(uart.rx_chan);
    }
    // 从 uart 的缓冲区取出最多 len 个字节，每次最多 64 个放进内核缓冲区，copyToUser 写进用户内存
    ...
}
```

- 读的是串口中断处理程序填的输入缓冲区（[devices.md](devices.md#输入环形缓冲区)）。**不回显、不做行编辑**：原样返回收到的字节（回车是 `\r`），shell 自己回显。Ctrl-C 不会被读到。
- 缓冲区为空就睡在 `uart.rx_chan` 上，串口中断收到字符后叫醒它。至少读到一个字节才返回；缓冲区里有多少就读多少（最多 `len`），不等凑满。
- **先检查整个目标范围可写，再取字符**（`vm.checkUser`）：字符从缓冲区取出来就放不回去了，要是取出来才发现用户给的地址写不进去，这些字符就丢了。所以坏地址立刻返回 `-EFAULT`，不阻塞、不消耗输入。
- `len = 0` 直接返回 0，不检查指针、不阻塞。
- 被 kill 了就提前返回，回到陷阱处理程序后结束。
- 好几个进程同时 `read` 时，都被叫醒，先运行的那个拿走字符，其他的发现缓冲区又空了，接着睡。

## wait

```zig
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
```

- 怎么找、怎么等子进程见 [process.md](process.md#wait回收子进程)。
- 结束状态是一个 `u32`：正常退出时是退出码（0..255），被杀（异常、`kill`、Ctrl-C）时是 `abi.killed_status`（`0x100`）。
- **写状态失败时不回收**，返回 `-EFAULT`：子进程还是 zombie，可以换个地址再 `wait`。
- 不认识的 options 位返回 `-EINVAL`。

## 访问用户内存

```zig
pub fn copyFromUser(root: *PageTable, dst: []u8, src: usize) error{BadAddress}!void
pub fn copyToUser(root: *PageTable, dst: usize, src: []const u8) error{BadAddress}!void
pub fn checkUser(root: *PageTable, va: usize, len: usize, write: bool) error{BadAddress}!void
```

系统调用拿到的指针完全由用户程序控制，可能是：没有映射的地址、内核的地址（比如 `hello` 故意传的 `0x8020_0000`）、跨越地址空间末尾的范围、或者让 `src + len` 溢出的长度。`copyFromUser` 对每一页：

1. `src + done` 用 `std.math.add` 计算，溢出就是 `BadAddress`。
2. `translateUser`：地址必须在 `[user_base, user_end)` 里；用**软件**走一遍进程的页表，叶子必须有效、带 U 位、可读。任何一条不满足就是 `BadAddress`。
3. 用翻译得到的物理地址，通过内核的恒等映射读出这一页里需要的部分。

为什么不直接让内核去读用户地址（打开 `sstatus.SUM`，让 S 模式可以访问 U 页）：

- 那样用户传进来一个**内核地址**，内核会照读不误（内核页在 S 模式下本来就可读），用户程序就能借 `write` 把内核内存打印出来。软件查页表时要求 U 位，内核地址自然被拒绝。
- 用户地址没有映射时，内核会在 S 模式下触发缺页，而现在内核里的缺页一律 panic。

所以 `sstatus.SUM` 始终为 0，这也意味着内核里任何地方不小心解引用了用户指针都会立刻缺页 panic，而不是悄悄成功。

**往用户内存写**用 `copyToUser`，检查和 `copyFromUser` 一样，`translateUser` 再多要求叶子**可写**：

- 不能借系统调用改写内核内存（内核页没有 U 位）；
- 也不能改写自己的只读页：硬件不会替内核检查这一点（内核的映射可写，S 模式写的是物理地址的恒等映射），不检查的话，用户程序可以让 `read` 把输入写进自己的代码段。

`copyToUser` 逐页写，中途遇到坏页时前面的页已经写进去了。需要“要么全写、要么不写”的调用方先用 `checkUser` 检查整个范围（`read` 就是这样）。`checkUser` 逐页查页表，`len = 0` 时不检查，`va + len - 1` 溢出是 `BadAddress`。这三个函数在 `vm.zig` 里有单元测试（跨页、只读页、没有映射、溢出）。

## 用户态封装

`user/sys.zig` 为每个调用提供一个函数，把错误码换成 Zig 的错误（[user-programs.md](user-programs.md#syszig)）：

```zig
pub const abi = @import("abi");
pub fn syscall(n: abi.Syscall, arg0: usize, arg1: usize, arg2: usize) usize   // 原始调用，测试用

pub fn exit(code: u8) noreturn
pub fn write(bytes: []const u8) error{ BadAddress, Unexpected }!usize
pub fn getpid() usize
pub fn getppid() usize
pub fn uptime() u64
pub fn yield() void
pub fn sleep(ms: u64) void
pub fn read(buf: []u8) error{ BadAddress, Unexpected }!usize
pub fn fork() error{ TooManyProcesses, OutOfMemory, Unexpected }!usize
pub fn exec(name: []const u8) error{ NoSuchProgram, OutOfMemory, BadElf, BadAddress, Unexpected }!noreturn
pub fn wait(pid: ?usize, nohang: bool) error{ NoChildren, Unexpected }!?WaitResult   // WaitResult{ pid, status }
pub fn kill(pid: usize) error{ NoSuchProcess, PermissionDenied, Unexpected }!void
pub fn setfg(pid: ?usize) error{ NoSuchProcess, Unexpected }!void
pub fn procinfo(buf: []abi.ProcInfo) usize
pub fn meminfo() abi.MemInfo
pub fn listprog(index: usize, buf: []u8) ?[]u8
pub fn shutdown() noreturn
pub fn print(comptime fmt: []const u8, args: anytype) void   // 通过 write 做格式化输出
```

- `exec` 的返回类型是 `ExecError!noreturn`：成功时不返回，所以只可能拿到错误。
- `wait` 的 `pid` 为 `null` 时等任意一个子进程；`nohang` 时没有已结束的子进程返回 `null`。状态写进 `wait` 自己栈上的变量，再放进 `WaitResult`。

## 执行环境

- 系统调用在陷阱处理程序里执行，**全程关着中断**，所以每个调用都要短。一个很长的 `write` 会在输出期间挡住时钟中断，但不会丢失中断：挂起的中断在 `sret` 回到 U 模式后立刻被处理（这时进程马上让出 CPU），计时也不会少，`timer` 按预约时刻补上错过的 tick（[devices.md](devices.md#定时器timerzig)）。
- 会等待的调用（`yield`、`sleep`、`read`、`wait`）不在里面开中断等待，而是切回调度器，由调度器开着中断去处理别的事。
- `exec` 一次加载整个程序（分配页、复制内容），`fork` 一次复制整个地址空间，期间都关着中断。现在的程序都只有几十 KiB，没有问题。
- 运行在当前进程自己的内核栈上（16 KiB），系统调用里不要放大的局部数组。
- `exit`、`shutdown` 和成功的 `exec` 不返回；其他调用返回后，用户程序从 `ecall` 的下一条指令继续执行，除 `a0` 以外的寄存器都不变。

## 新增一个系统调用

1. `src/abi.zig`：在 `Syscall` 里加一个编号（需要新错误码就在 `Errno` 里加，沿用 Linux 的编号）。
2. `src/syscall.zig`：在 `dispatch` 的 `switch` 里加分支。参数是 `args[0..6]`，返回 `usize`；失败时返回 `abi.fail(...)`。
3. 涉及用户指针的，一律通过 `vm.copyFromUser` / `vm.copyToUser` 访问，不要打开 `SUM`。会消耗内核状态（比如取走输入）的，先用 `vm.checkUser` 检查整个范围。
4. 要阻塞等待的（比如等键盘输入），照 `sleep` 的办法：挑一个代表“在等什么”的地址作通道，`while (!条件 and current.killed == null) proc.sleep(chan);`，在条件可能变化的地方（通常是中断处理程序）`proc.wakeup(chan)`。`read` 用的是 `uart.rx_chan`，`wait` 用的是进程自己。不要在系统调用里开中断 `wfi`（[trap.md](trap.md#中断开关不变量)）。
5. `user/sys.zig`：加一个封装函数。
6. 更新本文的调用列表，在 [changes.md](changes.md) 里加一行。
