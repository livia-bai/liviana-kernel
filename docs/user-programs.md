# 用户程序

涉及文件：`user/start.zig`、`user/sys.zig`、`user/linker.ld`、`user/init.zig`、`user/sh.zig`、`user/hello.zig`、`user/fault.zig`、`user/spin.zig`、`user/ticker.zig`、`user/echo.zig`、`user/cat.zig`、`user/wc.zig`

用户程序运行在 U 模式，只能访问自己地址空间里的页，要输出文字、读键盘、用管道、创建进程、退出都要通过系统调用（[syscalls.md](syscalls.md)）。它们在构建时编译成独立的 ELF 并嵌进内核（[build.md](build.md#用户程序)）。内核启动时只加载 `init`，其他程序都是由已有的进程 `fork` 再 `exec` 出来的（[process.md](process.md#创建进程)）：init 启动 shell（`sh`），shell 的 `run` 命令再启动别的程序。

## 目录结构

| 文件 | 角色 |
| --- | --- |
| `user/start.zig` | 每个程序的**根文件**，相当于 C 的 crt0：导出入口 `_start`，定义 panic 处理，调用程序的 `main` |
| `user/sys.zig` | `sys` 模块：系统调用封装和 `print`，程序用 `@import("sys")` 使用 |
| `user/linker.ld` | 所有程序共用的链接脚本 |
| `user/<名字>.zig` | 程序本身，作为 `program` 模块被 `start.zig` 导入，提供 `pub fn main() u8` |
| `src/abi.zig` | 系统调用号和错误码，内核和 `sys` 模块共用（构建时作为 `abi` 模块） |

## start.zig

```zig
const std = @import("std");
const sys = @import("sys");
const program = @import("program");

export fn _start(argc: usize, argv: [*]const sys.abi.Arg) callconv(.c) noreturn {
    sys.argv = argv[0..argc];
    sys.exit(program.main());
}

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    sys.print("panic: {s}\n", .{msg});
    sys.exit(255);
}
```

- **入口**：内核跳到 `_start` 时，`a0` = 参数个数，`a1` = `sp` = 栈顶的 `Arg` 数组的地址（16 字节对齐，参数的字节在它上面，[process.md](process.md#命令行参数)），其他寄存器全为 0。按 C 调用约定，`a0`、`a1` 正好是 `_start` 的前两个参数；`_start` 把它们变成切片存进 `sys.argv`，程序用 `sys.argv` 或 `sys.arg(i)` 读。参数在栈的最顶上，`_start` 的栈帧在它们下面，程序运行期间一直有效。`main` 的返回值就是退出码。没有环境变量。
- **打开的文件**：0、1、2 号 fd 是从父进程继承的（[files.md](files.md)），一般是串口；在 shell 的管道里运行时，0 或 1 是管道的一端。程序不用自己打开什么。
- **为什么 `_start` 在这里而不在 `sys.zig` 里**：Zig 按需分析代码，只有根文件里的 `export` 一定会被处理；写在 `sys.zig` 里的 `comptime { @export(...) }` 只有在 `sys.zig` 被引用到时才会执行。最初就是那么写的，结果 release 模式下 `_start` 没有导出，产出的 ELF 是空的（入口地址 0），运行时在地址 0 取指出错。
- **panic**：用户程序里的 `@panic`，以及 Debug/safe 模式下的安全检查失败（整数溢出、数组越界等），都会打印 `panic: <原因>` 并以退出码 255 结束。fast/small 模式没有安全检查，同样的代码不会 panic（比如整数溢出直接回绕）。没有栈回溯（没有调试信息和 unwind 表）。

## sys.zig

```zig
pub const abi = @import("abi");          // 系统调用号、错误码、ProcInfo 等，和内核共用
pub fn syscall(n: abi.Syscall, arg0: usize, arg1: usize, arg2: usize) usize
pub fn syscall4(n: abi.Syscall, arg0: usize, arg1: usize, arg2: usize, arg3: usize) usize

pub var argv: []const abi.Arg            // 命令行参数，argv[i].slice() 是第 i 个
pub fn arg(i: usize) ?[]const u8         // 第 i 个参数，没有就是 null

pub const Fd = usize;                    // stdin = 0，stdout = 1，stderr = 2
pub fn exit(code: u8) noreturn
pub fn write(fd: Fd, bytes: []const u8) WriteError!usize
pub fn writeAll(fd: Fd, bytes: []const u8) WriteError!void
pub fn read(fd: Fd, buf: []u8) ReadError!usize   // 没有数据时阻塞；0 表示读到结尾
pub fn close(fd: Fd) error{ BadFd, Unexpected }!void
pub fn dup(fd: Fd) error{ BadFd, TooManyOpenFiles, Unexpected }!Fd
pub fn pipe() PipeError![2]Fd            // { 读端, 写端 }
pub fn sbrk(increment: isize) SbrkError!usize    // 返回原来的堆末尾
pub fn getpid() usize
pub fn getppid() usize
pub fn uptime() u64                      // 开机以来的毫秒数
pub fn yield() void                      // 让出 CPU
pub fn sleep(ms: u64) void               // 睡至少 ms 毫秒，精度 10 ms
pub fn fork() ForkError!usize            // 父进程得到子进程的 pid，子进程得到 0
pub fn exec(name: []const u8, args: []const []const u8) ExecError!noreturn
pub fn execRaw(name: []const u8, args: []const abi.Arg) ExecError!noreturn
pub fn wait(pid: ?usize, nohang: bool) WaitError!?WaitResult
pub fn kill(pid: usize) KillError!void
pub fn setfg(pid: ?usize) error{ NoSuchProcess, Unexpected }!void
pub fn procinfo(buf: []abi.ProcInfo) usize
pub fn meminfo() abi.MemInfo
pub fn listprog(index: usize, buf: []u8) ?[]u8
pub fn shutdown() noreturn
pub fn print(comptime fmt: []const u8, args: anytype) void              // 输出到 stdout
pub fn fprint(fd: Fd, comptime fmt: []const u8, args: anytype) void
```

每个函数的语义和错误见 [syscalls.md](syscalls.md#用户态封装)。所有调用都通过 `syscall4`（`syscall` 是第四个参数为 0 的简写）：

```zig
pub fn syscall4(n: abi.Syscall, arg0: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [n] "{a7}" (@backingInt(n)),
          [arg0] "{a0}" (arg0),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
          [arg3] "{a3}" (arg3),
        : .{ .memory = true });
}
```

- 调用号放 `a7`，参数放 `a0`..`a3`，返回值在 `a0`。内核会保存并恢复其他所有寄存器，所以不需要声明更多 clobber。memory clobber 是因为 `write` 要读用户内存、`read` 等要写用户内存，编译器必须在 `ecall` 之前把缓冲区真正写好，之后重新读。
- `syscall` 是 `pub` 的：回归测试用它传各种坏参数，直接看原始的返回值。
- 封装函数把内核返回的错误码（`abi.errnoOf`）转换成 Zig 的错误，比如 `write` 的 `EFAULT` → `error.BadAddress`、`EBADF` → `error.BadFd`、`EPIPE` → `error.BrokenPipe`，其他 → `error.Unexpected`。`write` 的返回值可能小于 `bytes.len`（遇到坏地址时只写出了前一部分）。
- `exit` 之后写的是 `unreachable`：内核保证 `exit` 不返回。
- `print` 和内核的 `uart.print` 一样接入 `std.Io.Writer`，输出到 1 号 fd（stdout），带一个 256 字节的缓冲区：格式化的各段先攒在缓冲区里，`print` 最后 `flush`，用**一次** `write` 系统调用写出去（超过 256 字节时，`drain` 先写出攒着的部分，再直接写剩下的，会多写几次）。`write` 在内核里关着中断整段输出，所以一次 `print` 的输出不会被别的进程的输出从中间打断。最初没有缓冲区，每一段都是一次 `write`（`print("pid {d}\n", .{pid})` 是三次），时钟中断可能落在两次 `write` 之间：后台进程刚启动时，它打印的一行插进了 shell 的 `[proc] pid 9 (spin) started in the background` 中间，fast 模式下的 QEMU 测试因此失败过。`drain` 里 `write` 失败（比如 stdout 是读端已经关了的管道）就返回 `error.WriteFailed`，`print` 吞掉错误、丢掉没写出去的部分。要知道写没写成功的程序（`echo`、`cat`）直接用 `writeAll`。
- `Writer` 包在 `FdWriter` 里，`FdWriter` 记着写到哪个 fd，`drain` 用 `@fieldParentPtr` 从 `Writer` 找回它。stdout 的 `FdWriter` 是全局变量，放在程序的 `.data` 段里（实测 Debug 版 `hello` 的 `.data` 是 56 字节：它占 40 字节，`sys.argv` 占 16 字节），缓冲区在 `.bss` 里（256 字节）。`fprint` 写别的 fd 时在栈上临时建一个。`fork` 出来的子进程有自己的一份；`print` 每次都清空缓冲区，所以 `fork` 时缓冲区总是空的。

## 链接脚本

`user/linker.ld`：从 `0x4000_0000`（`vm.user_base`）开始，用 `PHDRS` 声明 text（R+X）、rodata（R）、data（R+W，含 `.bss`）三个段，每个段从新的一页开始。内核的 ELF 加载器要求每个段页对齐、可读、在用户区内（[process.md](process.md#elf-加载器)）。详细的段布局见 [build.md](build.md#用户程序的链接脚本)。

## init 和 sh

这两个程序必须有（`build.zig` 的 `user_programs` 里排在最前面），整个系统靠它们运转，结构和 xv6 的 `user/init.c`、`user/sh.c` 一样。

**init**（`user/init.zig`）是内核启动时创建的第一个进程，pid 1（`proc.userinit`）：

```zig
pub fn main() u8 {
    while (true) {
        const sh = startShell();          // fork，子进程 exec("sh", &.{"sh"})
        while (true) {
            const child = (sys.wait(null, false) catch break) orelse continue;
            if (child.pid == sh) break;
        }
        sys.print("init: sh exited, restarting it\n", .{});
    }
}
```

- 启动 shell，然后一直 `wait` 任意一个子进程。父进程先结束的进程会被内核交给 init（[process.md](process.md#exit变成-zombie)），它们结束后变成 zombie，靠 init 的 `wait` 回收。
- 等到的是 shell 的话（shell 被 `kill` 了），打印一行，再启动一个新的。
- init 不能结束：它一结束内核就 panic（`init exited`），`kill` 也不允许杀它。`fork` 失败时打印原因，睡一秒再试。

**sh**（`user/sh.zig`）是 shell，详见 [shell.md](shell.md)。它的父进程是 init，`run` 启动的程序都是它的子进程。

## 示例程序

### hello

```zig
pub fn main() u8 {
    sys.print("Hello from U-mode! I am pid {d}, the kernel has been up for {d} ms.\n", .{
        sys.getpid(), sys.uptime(),
    });
    const kernel_text: [*]const u8 = @ptrFromInt(0x8020_0000);
    if (sys.write(sys.stdout, kernel_text[0..16])) |_| {
        sys.print("the kernel leaked its own memory!\n", .{});
    } else |err| {
        sys.print("write() refused a kernel pointer: {s}\n", .{@errorName(err)});
    }
    return 0;
}
```

演示 `getpid`、`uptime`、`write`，并且故意把内核代码的地址交给 `write`：内核检查后发现这一页不属于用户空间，返回 `EFAULT`。

```
> run hello
Hello from U-mode! I am pid 3, the kernel has been up for 30 ms.
write() refused a kernel pointer: BadAddress
[proc] pid 3 (hello) exited with code 0
```

### fault

```zig
pub fn main() u8 {
    const kernel_text: *const volatile u32 = @ptrFromInt(0x8020_0000);
    sys.print("reading kernel memory at 0x{x} from U-mode...\n", .{@intFromPtr(kernel_text)});
    const value = kernel_text.*;
    sys.print("read 0x{x}, memory protection is broken!\n", .{value});
    return 1;
}
```

在 U 模式直接读内核内存。内核页表项没有 U 位，读操作触发 `load_page_fault`，内核结束这个进程，shell 照常运行。`volatile` 保证这次读不会被优化掉。

```
> run fault
reading kernel memory at 0x80200000 from U-mode...
[proc] pid 6 (fault) killed: load_page_fault at 0x40011462, stval=0x80200000
```

（`at` 后面是出错指令的地址，随优化模式变化；`stval` 是被访问的地址。）

### spin

```zig
pub fn main() u8 {
    sys.print("pid {d} spinning in U-mode without making syscalls\n", .{sys.getpid()});
    while (true) {}
}
```

进入死循环，不再做任何系统调用。时钟中断每 10 ms 打断它一次，让它让出 CPU，别的进程和 shell 照样运行。证明用户程序没法霸占 CPU。前台运行时按 Ctrl-C 结束它；后台运行时用 `kill` 结束它，`ps` 能看到它的 `TICKS` 一直在涨。

```
> run spin
pid 4 spinning in U-mode without making syscalls
^C
[proc] pid 4 (spin) killed: interrupted by Ctrl-C
```

### ticker

```zig
pub fn main() u8 {
    const pid = sys.getpid();
    for (1..6) |i| {
        sys.sleep(1000);
        sys.print("[ticker pid {d}] tick {d} at {d} ms\n", .{ pid, i, sys.uptime() });
    }
    return 0;
}
```

每秒打印一行，共 5 行，然后退出。睡眠期间不被调度，`ps` 里是 `sleeping`、`TICKS` 几乎不涨。适合放到后台（`run ticker &`），和别的程序、shell 一起跑，看输出交错；多开几个，它们的输出间隔仍然是 1 秒：

```
> run ticker &
[proc] pid 4 (ticker) started in the background
> [ticker pid 4] tick 1 at 2330 ms
[ticker pid 4] tick 2 at 3330 ms
```

### echo、cat、wc

演示命令行参数和管道的三个小程序，和 Unix 的同名命令一样：

- `echo`（`user/echo.zig`）：把参数用空格连起来，加换行，写到 stdout。写失败（读端关了）以 1 结束。
- `cat`（`user/cat.zig`）：把 stdin 原样复制到 stdout，读到结尾结束。没有文件系统，不接受文件名。直接从键盘读时输入不回显（串口不回显，回显是 shell 做的），按 Ctrl-D 结束。
- `wc`（`user/wc.zig`）：数 stdin 的行数、单词数、字节数，读到结尾后打印 `行 词 字节`。

```
> run echo hello world | wc
[proc] pid 60 (echo) exited with code 0
1 2 12
[proc] pid 61 (wc) exited with code 0
[proc] pid 59 (sh) exited with code 0
> run echo a b c | cat | cat | wc
[proc] pid 63 (echo) exited with code 0
[proc] pid 64 (cat) exited with code 0
[proc] pid 65 (cat) exited with code 0
1 3 6
[proc] pid 66 (wc) exited with code 0
[proc] pid 62 (sh) exited with code 0
```

（QEMU 测试跑到一半时的输出，所以 pid 比较大。）

最后一行 `(sh)` 是 shell 为管道 fork 出来的“组长”（[shell.md](shell.md#管道)）。

## 写一个新程序

1. 新建 `user/<名字>.zig`：

   ```zig
   const sys = @import("sys");

   pub fn main() u8 {
       sys.print("...\n", .{});
       return 0;
   }
   ```

   必须写 `@import("sys")`，不能写 `@import("sys.zig")`（同一个文件不能属于两个模块，见 [build.md](build.md#用户程序)）。
2. 在 `build.zig` 的 `user_programs` 数组里加一项 `.{ .name = "<名字>" }`。（回归测试程序放在 `user/tests/`，加到 `test_programs` 里，见 [testing.md](testing.md#加一个回归测试)。）
3. `zig build run`，在 shell 里 `run <名字> [参数...]`（加 ` &` 在后台运行，用 `|` 接成管道）。不带参数的 `run` 会列出所有程序。参数用 `sys.argv`、`sys.arg(i)` 读，`sys.arg(0)` 是程序名。

可以用的：`std.mem`、`std.fmt`、`std.math` 等纯计算的标准库；全局变量；最多约 16 KiB 的栈。

不能用或要注意的：

- 堆要自己用 `sbrk` 要：`std.heap.page_allocator` 等依赖操作系统的分配器不可用，`sys.zig` 也还没有提供分配器。可以用 `sbrk` 要一块内存，再用 `std.heap.FixedBufferAllocator` 包起来；小的也可以直接用全局数组或者栈。
- 系统调用见 [syscalls.md](syscalls.md#调用列表)：可以读写 fd（串口、管道）、`fork`/`exec`/`wait`、读命令行参数，但没有文件系统、线程。`exec` 只能运行嵌在内核里的程序。
- 不能用浮点指令：浮点运算由 compiler_rt 软件实现，慢而且让程序变大。浮点单元被内核关掉了（`sstatus.FS = Off`），手写的浮点指令会触发 `illegal_instruction` 被结束（回归测试 `t_fp`）。
- 栈只有 16 KiB，下面是不映射的保护页：栈溢出时触发 `store_page_fault`（`stval` 落在 `0x7fffb000..0x7fffc000`），进程被结束。
- 不能执行特权指令、不能访问 S 模式的 CSR（比如 `csrr sstatus`），否则触发 `illegal_instruction` 被结束。例外是 `cycle`、`time`、`instret` 三个计数器：OpenSBI 启动时把 `scounteren` 设成了 7（内核进入时实测，内核没有改它），所以用户程序可以直接用 `rdtime` 等指令读，实测 `rdtime` 在 U 模式下正常返回。
- 代码段只读：往自己的代码里写会触发 `store_page_fault`。
- 程序的各段加上栈不能超出 `0x4000_0000..0x7fff_b000`，堆也只能长到 `0x7fff_b000` 为止（实际上先碰到的是 128 MiB 的物理内存）。
- 读到 0 就是结尾，要结束循环：从管道读时写端都关了，从键盘读时按了 Ctrl-D。
