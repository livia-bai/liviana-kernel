# 用户程序

涉及文件：`user/start.zig`、`user/sys.zig`、`user/linker.ld`、`user/hello.zig`、`user/fault.zig`、`user/spin.zig`、`user/ticker.zig`

用户程序运行在 U 模式，只能访问自己地址空间里的页，要输出文字、查询时间、退出都要通过系统调用（[syscalls.md](syscalls.md)）。它们在构建时编译成独立的 ELF 并嵌进内核（[build.md](build.md#用户程序)），运行时由 shell 的 `run` 命令加载（[process.md](process.md)）。

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

export fn _start() noreturn {
    sys.exit(program.main());
}

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    sys.print("panic: {s}\n", .{msg});
    sys.exit(255);
}
```

- **入口**：内核跳到 `_start` 时，`sp` = 用户栈顶 `0x8000_0000`（16 字节对齐），其他寄存器全为 0。`export fn` 默认是 C 调用约定，它的序言会正常使用 `sp`。`main` 的返回值就是退出码。没有命令行参数、没有环境变量。
- **为什么 `_start` 在这里而不在 `sys.zig` 里**：Zig 按需分析代码，只有根文件里的 `export` 一定会被处理；写在 `sys.zig` 里的 `comptime { @export(...) }` 只有在 `sys.zig` 被引用到时才会执行。最初就是那么写的，结果 release 模式下 `_start` 没有导出，产出的 ELF 是空的（入口地址 0），运行时在地址 0 取指出错。
- **panic**：用户程序里的 `@panic`，以及 Debug/safe 模式下的安全检查失败（整数溢出、数组越界等），都会打印 `panic: <原因>` 并以退出码 255 结束。fast/small 模式没有安全检查，同样的代码不会 panic（比如整数溢出直接回绕）。没有栈回溯（没有调试信息和 unwind 表）。

## sys.zig

```zig
pub fn exit(code: u8) noreturn
pub const WriteError = error{ BadAddress, Unexpected };
pub fn write(bytes: []const u8) WriteError!usize
pub fn getpid() usize
pub fn uptime() u64                      // 开机以来的毫秒数
pub fn yield() void                      // 让出 CPU
pub fn sleep(ms: u64) void               // 睡至少 ms 毫秒，精度 10 ms
pub fn print(comptime fmt: []const u8, args: anytype) void
```

所有调用都通过一个内部函数：

```zig
fn syscall(n: abi.Syscall, arg0: usize, arg1: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [n] "{a7}" (@backingInt(n)),
          [arg0] "{a0}" (arg0),
          [arg1] "{a1}" (arg1),
        : .{ .memory = true });
}
```

- 调用号放 `a7`，参数放 `a0`、`a1`，返回值在 `a0`。内核会保存并恢复其他所有寄存器，所以不需要声明更多 clobber。memory clobber 是因为 `write` 要读用户内存，编译器必须在 `ecall` 之前把缓冲区真正写好。
- `write` 把内核返回的错误码（`abi.errnoOf`）转换成 Zig 的错误：`EFAULT` → `error.BadAddress`，其他 → `error.Unexpected`。返回值可能小于 `bytes.len`（遇到坏地址时只写出了前一部分）。
- `exit` 之后写的是 `unreachable`：内核保证 `exit` 不返回。
- `print` 和内核的 `uart.print` 一样接入 `std.Io.Writer`，`buffer` 为空，所以格式化输出的**每一段**都是一次 `write` 系统调用（例如 `print("pid {d}\n", .{pid})` 是三次：`"pid "`、数字、`"\n"`）。用 QEMU 的 `-d int` 数过：`hello` 一共执行 12 次 `ecall`（两个 `print` 共 8 次 `write`，加上 `getpid`、`uptime`、故意失败的那次 `write` 和 `exit`）。简单，但系统调用次数多；需要时可以给 Writer 一个缓冲区，在 `print` 结束时 flush。`drain` 里 `write` 失败就返回 `error.WriteFailed`，`print` 吞掉错误。
- `writer` 是全局变量，放在程序的 `.data` 段里（各程序数据段里唯一的 32 字节就是它）。

## 链接脚本

`user/linker.ld`：从 `0x4000_0000`（`vm.user_base`）开始，用 `PHDRS` 声明 text（R+X）、rodata（R）、data（R+W，含 `.bss`）三个段，每个段从新的一页开始。内核的 ELF 加载器要求每个段页对齐、可读、在用户区内（[process.md](process.md#elf-加载器)）。详细的段布局见 [build.md](build.md#用户程序的链接脚本)。

## 示例程序

### hello

```zig
pub fn main() u8 {
    sys.print("Hello from U-mode! I am pid {d}, the kernel has been up for {d} ms.\n", .{
        sys.getpid(), sys.uptime(),
    });
    const kernel_text: [*]const u8 = @ptrFromInt(0x8020_0000);
    if (sys.write(kernel_text[0..16])) |_| {
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
Hello from U-mode! I am pid 1, the kernel has been up for 5120 ms.
write() refused a kernel pointer: BadAddress
[proc] pid 1 (hello) exited with code 0
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
[proc] pid 2 (fault) killed: load_page_fault at 0x40011454, stval=0x80200000
```

（`at` 后面是出错指令的地址，随优化模式变化；`stval` 是被访问的地址。）

### spin

```zig
pub fn main() u8 {
    sys.print("pid {d} spinning in U-mode without making syscalls\n", .{sys.getpid()});
    while (true) {}
}
```

进入死循环，不再做任何系统调用。时钟中断每 10 ms 打断它一次，串口中断在收到字符时打断它，每次打断它都要让出 CPU，别的进程和 shell 照样运行。证明用户程序没法霸占 CPU。前台运行时按 Ctrl-C 结束它；后台运行时用 `kill` 结束它，`ps` 能看到它的 `TICKS` 一直在涨。

```
> run spin
pid 3 spinning in U-mode without making syscalls
^C
[proc] pid 3 (spin) killed: interrupted by Ctrl-C
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
[proc] pid 3 (ticker) started in the background
> [ticker pid 3] tick 1 at 2580 ms
[ticker pid 3] tick 2 at 3590 ms
```

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
3. `zig build run`，在 shell 里 `run <名字>`（加 ` &` 在后台运行）。不带参数的 `run` 会列出所有程序。

可以用的：`std.mem`、`std.fmt`、`std.math` 等纯计算的标准库；全局变量；最多约 16 KiB 的栈。

不能用或要注意的：

- 没有堆：没有分配内存的系统调用，`std.heap.page_allocator` 等依赖操作系统的分配器不可用。需要内存就用全局数组或者栈（可以用 `std.heap.FixedBufferAllocator` 包一个全局数组）。
- 系统调用只有 `exit`、`write`、`getpid`、`uptime`、`yield`、`sleep` 六个：没有读键盘、文件、线程，也没有命令行参数。
- 不能用浮点指令：浮点运算由 compiler_rt 软件实现，慢而且让程序变大。浮点单元被内核关掉了（`sstatus.FS = Off`），手写的浮点指令会触发 `illegal_instruction` 被结束（回归测试 `t_fp`）。
- 栈只有 16 KiB，下面是不映射的保护页：栈溢出时触发 `store_page_fault`（`stval` 落在 `0x7fffb000..0x7fffc000`），进程被结束。
- 不能执行特权指令、不能访问 S 模式的 CSR（比如 `csrr sstatus`），否则触发 `illegal_instruction` 被结束。例外是 `cycle`、`time`、`instret` 三个计数器：OpenSBI 启动时把 `scounteren` 设成了 7（内核进入时实测，内核没有改它），所以用户程序可以直接用 `rdtime` 等指令读，实测 `rdtime` 在 U 模式下正常返回。
- 代码段只读：往自己的代码里写会触发 `store_page_fault`。
- 程序的各段加上栈不能超出 `0x4000_0000..0x7fff_b000`。
