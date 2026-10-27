# shell

涉及文件：`user/sh.zig`（由 `user/init.zig` 启动，[user-programs.md](user-programs.md#init-和-sh)）

一个极简的命令行：读一行，执行一条命令，再读下一行。它是一个**普通的用户程序**，运行在 U 模式，和 xv6 的 `user/sh.c` 一样，内核的功能都通过系统调用使用（[syscalls.md](syscalls.md)）：

| shell 做的事 | 用到的系统调用 |
| --- | --- |
| 读键盘、回显 | `read`、`write` |
| 运行程序 | `fork`、`exec`、`wait` |
| 前台程序和 Ctrl-C | `setfg` |
| `ps`、`mem`、`uptime`、`run` 列出程序 | `procinfo`、`meminfo`、`uptime`、`listprog` |
| `kill`、`shutdown` | `kill`、`shutdown` |

主循环：

```zig
pub fn main() u8 {
    sys.print("Type 'help' for commands.\n", .{});
    while (true) {
        reapBackground();
        sys.print("> ", .{});
        execute(readLine());
    }
}
```

## 输入处理

`read` 系统调用不回显、不做行编辑（[syscalls.md](syscalls.md#read)），这些都由 shell 自己做。`readLine` 每次 `read` 一个字节：

| 字符 | 处理 |
| --- | --- |
| `\r` 或 `\n` | 换行，返回这一行 |
| `0x08`（Backspace）或 `0x7f`（Delete） | 行不为空时删掉最后一个字符，并输出 `\x08 \x08`（光标左移、用空格盖掉、再左移） |
| 可打印字符 `' '..'~'` | 行没满（64 字节）时追加并回显；满了就忽略 |
| 其他（包括方向键产生的转义序列、Tab） | 忽略 |

- 终端（QEMU `-nographic` 下就是你的终端）处于原始模式，按回车发送的是 `\r`。
- Ctrl-C 不会被读到：内核在串口中断里就把它截下了（[process.md](process.md#ctrl-c)）。
- 缓冲区为空时 `read` 在内核里睡着，不占 CPU，串口中断叫醒它。
- 前台程序运行期间 shell 在 `wait` 里睡着，不读键盘，这期间敲的字符留在内核的输入缓冲区里，程序结束后 shell 才读到、回显、执行。（如果前台程序自己调用 `read`，字符就被它读走了。）

## 前台和后台

```zig
fn run(arg: []const u8) void {
    ...
    const pid = sys.fork() catch |err| { ... return; };
    if (pid == 0) {
        sys.exec(name) catch |err| sys.print("run: cannot load {s}: {s}\n", .{ name, @errorName(err) });
        sys.exit(127);
    }
    if (background) {
        sys.print("[proc] pid {d} ({s}) started in the background\n", .{ pid, name });
        return;
    }
    sys.setfg(pid) catch {};
    _ = sys.wait(pid, false) catch {};
    sys.setfg(null) catch {};
}
```

- 先用 `listprog` 确认有这个程序，没有就打印 `no such program: NAME` 和程序列表，不 `fork`。
- `fork` 出子进程，子进程 `exec` 成要运行的程序。`exec` 失败（比如 ELF 不合法）时，子进程打印原因并以 127 结束；这时它还是 shell 的副本，内核打印的名字是 `sh`。
- **前台**（`run NAME`）：`setfg(pid)` 告诉内核按 Ctrl-C 时杀掉它，然后 `wait(pid)` 睡着等它结束、回收它，再 `setfg(null)`。所以输出顺序是：程序的输出、`[proc] ... exited ...`，然后才是 `> `。
- **后台**（`run NAME &`）：打印 `[proc] pid N (NAME) started in the background` 后马上回到提示符。它的输出和 shell 的输出会交错在一起，没有作业控制，只能用 `kill` 结束它。后台进程和 shell 谁先运行取决于调度，所以程序的第一行输出可能出现在 `started in the background` 前面。
- **回收后台进程**：每次打印提示符之前，`reapBackground` 用 `wait(null, nohang)` 把已经结束的子进程都回收掉。它们的结束信息内核已经打印过了；不回收的话会一直是 zombie，占着进程表的槽位。

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
| `uptime` | 开机时长（`uptime` 系统调用，精度一个 tick） | `up 3.26s` |
| `mem` | 物理页的使用情况（`meminfo`，[page-allocator.md](page-allocator.md)） | `31600 of 31676 pages free (126400 KiB), 4 KiB each` |
| `run` | 列出所有用户程序（`listprog`） | `programs: init sh hello fault spin ticker` |
| `run NAME` | 在前台运行用户程序 `NAME`，等它结束；Ctrl-C 结束它 | 程序自己的输出 + `[proc] pid 3 (hello) exited with code 0` |
| `run NAME &` | 在后台运行，马上回到提示符 | `[proc] pid 4 (spin) started in the background` |
| `ps` | 列出进程（`procinfo`）：pid、父进程、状态、用掉的时钟 tick 数、名字 | 见下文 |
| `kill PID` | 结束进程 | `[proc] pid 4 (spin) killed: kill()` |
| `shutdown` | 打印 `bye!`，通过 SBI 关机，QEMU 退出，退出码 0 | `bye!` |

说明：

- `uptime` 显示 `ms / 1000` 秒和 `ms % 1000 / 10` 百分之一秒（补零到两位），所以 `up 3.05s` 不会显示成 `3.5s`。内核按 tick 计时，百分之一秒正好是 tick 数。
- 进程表满了打印 `run: too many processes (at most 8)`（`fork` 返回 `TooManyProcesses`；8 是 `abi.max_procs`，其中 init 和 shell 占两个），ELF 加载失败打印 `run: cannot load NAME: BadElf`（或 `OutOfMemory`）。
- `run` 的参数以 `&` 结尾就是后台运行，`&` 前面有没有空格都行（`run spin&` 也可以）。
- `ps` 的输出（一个后台的 `spin` 在死循环）：

  ```
    PID  PPID STATE     TICKS NAME
      1     0 sleeping      0 init
      2     1 running       3 sh
     17     2 runnable      2 spin
  ```

  `ps` 是 shell 执行的，所以 `running` 的总是 shell 自己；init 总在 `wait` 里睡着。`TICKS` 是进程在 U 模式运行期间来过的时钟中断数，大致等于它用掉的 CPU 时间（单位 10 ms）。按槽位顺序列出，不一定按 pid 排序。结束了还没被回收的进程显示为 `zombie`。
- `kill PID`：`PID` 不是数字时打印 `usage: kill PID`，没有这个进程时打印 `kill: no such process: PID`，杀 init 打印 `kill: cannot kill pid 1: permission denied`。`kill` 系统调用只做标记（[process.md](process.md#kill只做标记)），所以 shell 接着 `wait(pid)`：是自己的子进程的话，等它真的结束、回收它，`killed: kill()` 那一行就在下一个提示符之前；不是自己的子进程时 `wait` 立刻返回 `NoChildren`。
- `kill` shell 自己（它的 pid）也可以：shell 结束，init 打印 `init: sh exited, restarting it` 并启动一个新的 shell。

## 添加命令

1. 在 `Command` 枚举里加一个名字（就是用户要输入的命令名）。
2. 在 `help` 的文本里加一行。
3. 在 `execute` 的 `switch` 里加分支；需要参数就用 `arg`。需要内核做的事，先加系统调用（[syscalls.md](syscalls.md#新增一个系统调用)）。
4. 更新本文和根目录 README 的命令表。

`help` 的文本按 12 列对齐。
