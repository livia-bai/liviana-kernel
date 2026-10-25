# shell

涉及文件：`src/shell.zig`（调用方：`src/main.zig` 的主循环）

一个极简的命令行：逐字符接收键盘输入并回显，回车后执行一条命令。它运行在 S 模式，是内核的一部分，不是用户程序。

## 输入处理

```zig
var line: [64]u8 = undefined;
var len: usize = 0;

pub fn prompt() void        // 打印 "> "
pub fn feed(c: u8) void     // 主循环每收到一个字符调用一次
```

`feed` 按字符分类：

| 字符 | 处理 |
| --- | --- |
| `\r` 或 `\n` | 换行，执行 `line[0..len]`，清空，打印新的提示符 |
| `0x08`（Backspace）或 `0x7f`（Delete） | 行不为空时删掉最后一个字符，并输出 `\x08 \x08`（光标左移、用空格盖掉、再左移） |
| 可打印字符 `' '..'~'` | 行没满（64 字节）时追加并回显；满了就忽略 |
| 其他（包括方向键产生的转义序列、Tab） | 忽略 |

终端（QEMU `-nographic` 下就是你的终端）处于原始模式，按回车发送的是 `\r`。Ctrl-C 根本到不了 shell：串口中断处理程序把它截下来了（[devices.md](devices.md#ctrl-c)）。

`feed` 是在开着中断时被调用的，执行命令期间时钟和键盘中断照常发生；命令执行期间输入的字符会进入串口的环形缓冲区，命令结束后由主循环交给 shell。

## 命令解析

```zig
const trimmed = std.mem.trim(u8, input, " ");
if (trimmed.len == 0) return;
const name, const arg = std.mem.cutScalar(u8, trimmed, ' ') orelse .{ trimmed, "" };
const cmd = std.meta.stringToEnum(Command, name) orelse { ... "unknown command" ... };
```

- 去掉首尾空格；空行什么也不做。
- 第一个空格之前是命令名，之后是参数（`std.mem.cutScalar` 是 0.17 新增的，返回分割点前后两段）。参数只有 `run` 用，会再去掉首尾空格。
- 命令名用 `std.meta.stringToEnum` 转成 `Command` 枚举，不认识就打印 `unknown command: NAME (try 'help')`。

## 命令

| 命令 | 作用 | 输出示例 |
| --- | --- | --- |
| `help` | 列出命令 | |
| `uptime` | 开机时长，由时钟中断计数得出 | `up 3.26s (326 timer interrupts)` |
| `mem` | 物理页的使用情况（[page-allocator.md](page-allocator.md)） | `32052 of 32057 pages free (128208 KiB), 4 KiB each` |
| `run` | 列出所有用户程序 | `programs: hello fault spin` |
| `run NAME` | 在 U 模式运行用户程序 `NAME`，等它结束（[process.md](process.md)） | 程序自己的输出 + `[proc] pid 1 (hello) exited with code 0` |
| `ebreak` | 执行一条 `ebreak`，触发断点异常，处理后继续 | `[trap] breakpoint at 0x80216562, skipping it` |
| `crash` | 读地址 0。地址 0 没有映射，触发缺页异常，内核 panic 停机 | `!!! KERNEL PANIC: unhandled exception: load_page_fault (scause=13), sepc=0x..., stval=0x0` |
| `shutdown` | 通过 SBI 关机，QEMU 退出，退出码 0 | `bye!` |

说明：

- `uptime` 的小数部分是 `ticks % tick_hz`，格式 `{d:0>2}`（补零到两位），所以 `up 3.05s` 不会显示成 `3.5s`。
- `run NAME` 找不到程序时打印 `no such program: NAME`，接着列出所有程序。
- `crash` 是故意的：演示内核自己出错时的样子。它用 `*allowzero volatile u64`：`allowzero` 让 Zig 允许地址 0 的指针，`volatile` 保证这次读不会被优化掉。
- `ebreak` 演示可恢复的异常：陷阱处理程序把 `sepc` 加上指令长度跳过它。开着 C 扩展时汇编器会把 `ebreak` 压缩成 2 字节的 `c.ebreak`（编码 `0x9002`，`llvm-objdump -d` 里仍显示为 `ebreak`），所以这里跳过的是 2 字节；`instructionLength` 两种长度都能处理（[trap.md](trap.md#分发)）。

## 添加命令

1. 在 `Command` 枚举里加一个名字（就是用户要输入的命令名）。
2. 在 `help` 的文本里加一行。
3. 在 `execute` 的 `switch` 里加分支；需要参数就用 `arg`。
4. 更新本文和根目录 README 的命令表。

命令在 S 模式、开着中断运行，可以调用内核的任何函数，但注意：`page.alloc` 等不加锁的函数在这里调用是安全的，因为中断处理程序不会调用它们（[page-allocator.md](page-allocator.md#并发)）。
