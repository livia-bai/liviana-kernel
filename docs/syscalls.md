# 系统调用

涉及文件：`src/abi.zig`（内核和用户程序共用）、`src/syscall.zig`（内核实现）、`user/sys.zig`（用户态封装）、`src/vm.zig` 的 `copyFromUser`

## 调用约定

和 Linux 在 RISC-V 上的约定一样：

| 寄存器 | 用途 |
| --- | --- |
| `a7` | 调用号（`abi.Syscall`） |
| `a0..a5` | 参数（目前最多用两个） |
| `a0`（返回） | 返回值 |
| 其他寄存器 | 内核原样恢复 |

用户程序执行 `ecall` → CPU 产生“来自 U 模式的 ecall”异常（`scause = 8`，委托给了 S 模式）→ `trapEntry` 通过 `sscratch` 换到进程内核栈、保存全部寄存器 → `handleTrap` 把 `sepc` 加 4（跳过 `ecall`，它没有压缩形式，固定 4 字节）→ `syscall.dispatch(frame)` 的返回值写进 `frame.regs[10]`（`a0`）→ `trapExit` 恢复寄存器、`sret` 回到 `ecall` 的下一条指令。

**返回值按有符号数理解**：`>= 0` 表示成功；`-4095..-1` 表示失败，取反就是错误码（和 Linux 一样，错误码的编号也沿用 Linux）。

## abi.zig

```zig
pub const Syscall = enum(usize) {
    exit = 0,
    write = 1,
    getpid = 2,
    uptime = 3,
    _,
};

pub const Errno = enum(usize) {
    fault = 14,   // EFAULT：指针指向的内存不属于用户空间，或者没有映射
    nosys = 38,   // ENOSYS：没有这个系统调用
    _,
};

pub fn fail(e: Errno) usize            // 把错误码编码成返回值：0 -% e
pub fn errnoOf(ret: usize) ?Errno      // 返回值在 [-4095, -1] 内时取出错误码
```

两个枚举都是非穷尽的（`_`），所以用户程序传来任意数字都能安全地转换成 `Syscall`（`@fromBackingInt`），不认识的落到 `_` 分支。

这个文件被**两次编译**使用：内核里按路径 `@import("abi.zig")`，用户程序里作为构建系统创建的 `abi` 模块（[build.md](build.md#用户程序)）。改它就同时改了两边的约定。

## 调用列表

| 号 | 调用 | 参数 | 返回 | 说明 |
| --- | --- | --- | --- | --- |
| 0 | `exit` | `a0` = 退出码 | 不返回 | 只取低 8 位（`@truncate` 成 `u8`）。打印 `[proc] pid N (NAME) exited with code C`，回到 shell |
| 1 | `write` | `a0` = 用户缓冲区地址，`a1` = 长度 | 写出的字节数，或 `-14` | 把用户内存里的字节输出到串口，详见下文 |
| 2 | `getpid` | 无 | 进程号 | 从 1 开始，每次 `run` 加 1 |
| 3 | `uptime` | 无 | 开机以来的毫秒数 | `timer.uptimeMs()`，精度 10 ms（一个时钟 tick） |
| 其他 | | | `-38`（ENOSYS） | |

### 分发

```zig
pub fn dispatch(frame: *TrapFrame) usize {
    const args = frame.regs[10..16]; // a0..a5
    const number: abi.Syscall = @fromBackingInt(frame.regs[17]); // a7
    return switch (number) {
        .exit => proc.exit(@truncate(args[0])),
        .write => write(args[0], args[1]),
        .getpid => proc.current.?.pid,
        .uptime => timer.uptimeMs(),
        _ => abi.fail(.nosys),
    };
}
```

`proc.exit` 是 `noreturn`，可以直接放在 `switch` 表达式里。

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

## 访问用户内存

```zig
pub fn copyFromUser(root: *PageTable, dst: []u8, src: usize) error{BadAddress}!void
```

系统调用拿到的指针完全由用户程序控制，可能是：没有映射的地址、内核的地址（比如 `hello` 故意传的 `0x8020_0000`）、跨越地址空间末尾的范围、或者让 `src + len` 溢出的长度。`copyFromUser` 对每一页：

1. `src + done` 用 `std.math.add` 计算，溢出就是 `BadAddress`。
2. `translateUser`：地址必须在 `[user_base, user_end)` 里；用**软件**走一遍进程的页表，叶子必须有效、带 U 位、可读。任何一条不满足就是 `BadAddress`。
3. 用翻译得到的物理地址，通过内核的恒等映射读出这一页里需要的部分。

为什么不直接让内核去读用户地址（打开 `sstatus.SUM`，让 S 模式可以访问 U 页）：

- 那样用户传进来一个**内核地址**，内核会照读不误（内核页在 S 模式下本来就可读），用户程序就能借 `write` 把内核内存打印出来。软件查页表时要求 U 位，内核地址自然被拒绝。
- 用户地址没有映射时，内核会在 S 模式下触发缺页，而现在内核里的缺页一律 panic。

所以 `sstatus.SUM` 始终为 0，这也意味着内核里任何地方不小心解引用了用户指针都会立刻缺页 panic，而不是悄悄成功。

目前只有从用户读（`copyFromUser`）。以后实现需要往用户内存写的系统调用（比如 `read`）时，应该加一个对应的 `copyToUser`，检查条件里再加上“叶子可写”。

## 用户态封装

`user/sys.zig` 为每个调用提供一个函数（[user-programs.md](user-programs.md#syszig)）：

```zig
pub fn exit(code: u8) noreturn
pub fn write(bytes: []const u8) error{ BadAddress, Unexpected }!usize
pub fn getpid() usize
pub fn uptime() u64
pub fn print(comptime fmt: []const u8, args: anytype) void   // 通过 write 做格式化输出
```

## 执行环境

- 系统调用在陷阱处理程序里执行，**全程关着中断**，所以每个调用都要短。一个很长的 `write` 会在输出期间挡住时钟中断（计时会少几个 tick），但不会丢失中断：挂起的中断在 `sret` 回到 U 模式后立刻被处理。
- 运行在进程内核栈上（16 KiB），系统调用里不要放大的局部数组。
- `exit` 不返回；其他调用返回后，用户程序从 `ecall` 的下一条指令继续执行，除 `a0` 以外的寄存器都不变。

## 新增一个系统调用

1. `src/abi.zig`：在 `Syscall` 里加一个编号（需要新错误码就在 `Errno` 里加，沿用 Linux 的编号）。
2. `src/syscall.zig`：在 `dispatch` 的 `switch` 里加分支。参数是 `args[0..6]`，返回 `usize`；失败时返回 `abi.fail(...)`。
3. 涉及用户指针的，一律通过 `vm.copyFromUser`（或新写的 `copyToUser`）访问，不要打开 `SUM`。
4. 要阻塞等待的（比如等键盘输入），要在里面打开中断再 `wfi`。这时会出现嵌套的陷阱（来自 S 模式，压在当前的进程内核栈上），先读 [trap.md](trap.md#中断开关不变量) 再动手。
5. `user/sys.zig`：加一个封装函数。
6. 更新本文的调用列表，在 [changes.md](changes.md) 里加一行。
