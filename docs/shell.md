# shell

涉及文件：`src/shell.zig`（调用方：`src/main.zig` 创建它，`src/trap.zig` 在串口中断里调用 `interrupt`）

一个极简的命令行：逐字符接收键盘输入并回显，回车后执行一条命令。它运行在 S 模式，是内核的一部分，不是用户程序。

shell 是一个**内核线程**：`kmain` 用 `proc.spawnKernel("shell", &shell.main)` 把它放进进程表（槽位 0、pid 1），和用户进程一样由调度器调度（[process.md](process.md#创建进程)）。它没有自己的地址空间，用内核页表，**全程关着中断运行**，要等待时调用 `proc.sleep` 让出 CPU。

## 输入处理

```zig
var line: [64]u8 = undefined;
var len: usize = 0;

pub fn main() callconv(.c) noreturn   // 内核线程的入口
fn feed(c: u8) void                   // 处理一个字符
```

```zig
pub fn main() callconv(.c) noreturn {
    prompt();
    while (true) {
        const c = uart.read() orelse {
            proc.sleep(uart.rx_chan);
            continue;
        };
        feed(c);
    }
}
```

缓冲区里有字符就一个一个交给 `feed`；空了就睡在 `uart.rx_chan` 上，串口中断收到字符后 `proc.wakeup(uart.rx_chan)` 叫醒它（[process.md](process.md#sleepwakeup)）。检查缓冲区和睡下之间不会丢字符：shell 关着中断，这期间到的字符只会让中断挂起，等调度器开中断时才处理、叫醒 shell。`uart.read()` 要求调用时中断是关着的（它和中断处理程序共用缓冲区的索引），这里满足。

`feed` 按字符分类：

| 字符 | 处理 |
| --- | --- |
| `\r` 或 `\n` | 换行，执行 `line[0..len]`，清空，打印新的提示符 |
| `0x08`（Backspace）或 `0x7f`（Delete） | 行不为空时删掉最后一个字符，并输出 `\x08 \x08`（光标左移、用空格盖掉、再左移） |
| 可打印字符 `' '..'~'` | 行没满（64 字节）时追加并回显；满了就忽略 |
| 其他（包括方向键产生的转义序列、Tab） | 忽略 |

终端（QEMU `-nographic` 下就是你的终端）处于原始模式，按回车发送的是 `\r`。Ctrl-C 不会作为字符到达 `feed`：串口中断处理程序把它截下来了（[devices.md](devices.md#ctrl-c)），在中断里直接调用 `shell.interrupt()`。

执行命令是关着中断的，命令都很短。执行期间输入的字符进入串口的环形缓冲区，命令结束后接着读。

## 前台和后台

```zig
var foreground: ?usize = null;   // 前台进程的 pid

pub fn interrupt() void          // 串口中断处理程序发现 Ctrl-C 时调用
fn waitFor(pid: usize) void      // 睡着等进程 pid 结束
```

```zig
fn waitFor(pid: usize) void {
    while (proc.findPid(pid)) |p| proc.sleep(p);
}
```

- `run NAME` 启动的进程是**前台进程**：`run` 把它的 pid 记进 `foreground`，然后 `waitFor(pid)`：睡在这个进程上，它结束时 `proc.finish` 叫醒 shell（[process.md](process.md#结束进程)）；醒来时调度器已经回收了它，`findPid` 找不到，循环结束，清掉 `foreground`，`run` 返回，`feed` 打印提示符。所以输出顺序是：程序的输出、`[proc] ... exited ...`，然后才是 `> `。前台进程运行期间 shell 在睡，敲的字符留在串口缓冲区里，它结束后才回显、执行。
- `interrupt()`：有前台进程就打印 `^C`，调用 `proc.kill(pid, "interrupted by Ctrl-C")`；没有就什么也不做。它在中断处理程序里运行，`proc.kill` 只做标记，前台进程自己结束后照常叫醒 shell。
- `run NAME &` 启动的是**后台进程**：打印 `[proc] pid N (NAME) started in the background` 后马上回到提示符。它的输出和 shell 的输出会交错在一起，没有作业控制，只能用 `kill` 结束它。

pid 从不复用，所以 `foreground` 里的 pid 不会被别的进程误认。`waitFor` 睡的通道是进程表的槽位地址，槽位会复用，但醒来后按 pid 重新查，不会认错。

## 命令解析

```zig
const trimmed = std.mem.trim(u8, input, " ");
if (trimmed.len == 0) return;
const name, const arg = std.mem.cutScalar(u8, trimmed, ' ') orelse .{ trimmed, "" };
const cmd = std.meta.stringToEnum(Command, name) orelse { ... "unknown command" ... };
```

- 去掉首尾空格；空行什么也不做。
- 第一个空格之前是命令名，之后是参数（`std.mem.cutScalar` 是 0.17 新增的，返回分割点前后两段）。参数只有 `run` 和 `kill` 用，它们会再去掉首尾空格。
- 命令名用 `std.meta.stringToEnum` 转成 `Command` 枚举，不认识就打印 `unknown command: NAME (try 'help')`。

## 命令

| 命令 | 作用 | 输出示例 |
| --- | --- | --- |
| `help` | 列出命令 | |
| `uptime` | 开机时长，由时钟中断计数得出 | `up 3.26s (326 timer interrupts)` |
| `mem` | 物理页的使用情况（[page-allocator.md](page-allocator.md)） | `32052 of 32057 pages free (128208 KiB), 4 KiB each` |
| `run` | 列出所有用户程序 | `programs: hello fault spin ticker` |
| `run NAME` | 在前台运行用户程序 `NAME`，等它结束；Ctrl-C 结束它（[process.md](process.md)） | 程序自己的输出 + `[proc] pid 2 (hello) exited with code 0` |
| `run NAME &` | 在后台运行，马上回到提示符 | `[proc] pid 3 (spin) started in the background` |
| `ps` | 列出进程：pid、状态、用掉的时钟 tick 数、名字 | 见下文 |
| `kill PID` | 结束进程，等它结束再回到提示符 | `[proc] pid 3 (spin) killed: kill command` |
| `ebreak` | 执行一条 `ebreak`，触发断点异常，处理后继续 | `[trap] breakpoint at 0x80216562, skipping it` |
| `crash` | 读地址 0。地址 0 没有映射，触发缺页异常，内核 panic 停机 | `!!! KERNEL PANIC: unhandled exception: load_page_fault (scause=13), sepc=0x..., stval=0x0` |
| `shutdown` | 通过 SBI 关机，QEMU 退出，退出码 0 | `bye!` |

说明：

- `uptime` 的小数部分是 `ticks % tick_hz`，格式 `{d:0>2}`（补零到两位），所以 `up 3.05s` 不会显示成 `3.5s`。
- `run NAME` 找不到程序时打印 `no such program: NAME`，接着列出所有程序。进程表满了（shell 占一个槽位，所以是 7 个用户进程）打印 `run: too many processes (at most 8)`，ELF 加载失败打印 `run: cannot load NAME: BadElf`（或 `OutOfMemory`）。
- `run` 的参数以 `&` 结尾就是后台运行，`&` 前面有没有空格都行（`run spin&` 也可以）。
- `ps` 的输出（一个后台的 `spin` 在死循环，一个后台的 `ticker` 在睡眠）：

  ```
    PID STATE     TICKS NAME
      1 running       0 shell
      2 runnable    122 spin
      3 sleeping      0 ticker
  ```

  `ps` 是 shell 执行的，所以 `running` 的总是 shell 自己。`TICKS` 是进程在 U 模式运行期间来过的时钟中断数，大致等于它用掉的 CPU 时间（单位 10 ms），shell 不进 U 模式，总是 0。按槽位顺序列出，不一定按 pid 排序。
- `kill PID`：`PID` 不是数字时打印 `usage: kill PID`，没有这个进程时打印 `kill: no such process: PID`，是 shell 自己时打印 `kill: pid 1 is a kernel thread`。`proc.kill` 只做标记（[process.md](process.md#结束进程)），shell 接着用 `waitFor` 等它真的结束，所以 `killed: kill command` 那一行在下一个提示符之前。
- `crash` 是故意的：演示内核自己出错时的样子。它用 `*allowzero volatile u64`：`allowzero` 让 Zig 允许地址 0 的指针，`volatile` 保证这次读不会被优化掉。
- `ebreak` 演示可恢复的异常：陷阱处理程序把 `sepc` 加上指令长度跳过它。开着 C 扩展时汇编器会把 `ebreak` 压缩成 2 字节的 `c.ebreak`（编码 `0x9002`，`llvm-objdump -d` 里仍显示为 `ebreak`），所以这里跳过的是 2 字节；`instructionLength` 两种长度都能处理（[trap.md](trap.md#分发)）。

## 添加命令

1. 在 `Command` 枚举里加一个名字（就是用户要输入的命令名）。
2. 在 `help` 的文本里加一行。
3. 在 `execute` 的 `switch` 里加分支；需要参数就用 `arg`。
4. 更新本文和根目录 README 的命令表。

`help` 的文本按 12 列对齐。

命令在 S 模式、开着中断运行，可以调用内核的任何函数，但注意：`page.alloc` 等不加锁的函数在这里调用是安全的，因为中断处理程序不会调用它们（[page-allocator.md](page-allocator.md#并发)）。
