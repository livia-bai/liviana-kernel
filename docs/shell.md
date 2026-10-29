# shell

涉及文件：`user/sh.zig`（由 `user/init.zig` 启动，[user-programs.md](user-programs.md#init-和-sh)）

一个极简的命令行：读一行，执行一条命令，再读下一行。它是一个**普通的用户程序**，运行在 U 模式，和 xv6 的 `user/sh.c` 一样，内核的功能都通过系统调用使用（[syscalls.md](syscalls.md)）：

| shell 做的事 | 用到的系统调用 |
| --- | --- |
| 读键盘、回显 | `read`、`write`（0、1 号 fd，都是串口） |
| 运行程序（带参数） | `fork`、`exec`、`wait` |
| 管道 | `pipe`、`close`、`dup` |
| 重定向 `<`、`>`、`cd` | `open`、`close`、`dup`、`chdir` |
| 前台程序和 Ctrl-C | `setfg` |
| `ps`、`mem`、`uptime` | `procinfo`、`meminfo`、`uptime` |
| `run` 检查程序在不在、列出 `/bin` | `open`、`fstat`、`readdir` |
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
| 可打印字符 `' '..'~'` | 行没满（128 字节）时追加并回显；满了就忽略 |
| 其他（包括方向键产生的转义序列、Tab、Ctrl-D） | 忽略。Ctrl-D 单独按时 `read` 返回 0，也忽略 |

- 终端（QEMU `-nographic` 下就是你的终端）处于原始模式，按回车发送的是 `\r`。
- Ctrl-C 不会被读到：内核在串口中断里就把它截下了（[process.md](process.md#ctrl-c)）。
- 缓冲区为空时 `read` 在内核里睡着，不占 CPU，串口中断叫醒它。
- 前台程序运行期间 shell 在 `wait` 里睡着，不读键盘，这期间敲的字符留在内核的输入缓冲区里，程序结束后 shell 才读到、回显、执行。（如果前台程序自己调用 `read`，字符就被它读走了。）

## 前台和后台

```zig
fn run(input: []const u8) void {
    // 去掉末尾的 &，按 | 和空格拆开（parse），检查每个程序都存在
    ...
    const pid = sys.fork() catch |err| return forkFailed(err);
    if (pid == 0) {
        if (!background) sys.setfg(sys.getpid()) catch {};
        if (stages.len == 1) execStage(&stages[0]);   // 一个程序：直接 exec 成它
        sys.exit(runPipeline(stages));                // 管道：这个子进程当“组长”
    }
    if (background) {
        sys.print("[proc] pid {d} ({s}) started in the background\n", .{ pid, what });
        return;
    }
    sys.setfg(pid) catch {};
    _ = sys.wait(pid, false) catch {};
    sys.setfg(null) catch {};
}
```

- 先确认每个程序都有（`programExists`：和内核的 `exec` 一样，名字里没有 `/` 的看 `/bin/名字`，有的按路径看，要能打开、是文件），没有就打印 `no such program: NAME` 和程序列表，不 `fork`。
- `fork` 出子进程，子进程 `exec` 成要运行的程序，命令行参数就是拆出来的那些词（第一个是程序名，[命令解析](#命令解析)）。`exec` 失败（比如 ELF 不合法）时，子进程打印原因并以 127 结束；这时它还是 shell 的副本，内核打印的名字是 `sh`。
- **前台**（`run NAME`）：`setfg(pid)` 告诉内核按 Ctrl-C 时杀掉它（和它的子孙），然后 `wait(pid)` 睡着等它结束、回收它，再 `setfg(null)`。子进程在 `exec` 之前也先 `setfg(自己的 pid)`：`fork` 之后先运行父进程还是子进程不一定，只靠父进程登记的话，子进程可能已经开始运行、等着输入了，父进程还没来得及 `setfg`，这时按的 Ctrl-C 没人管。QEMU 测试在 Debug 模式下碰到过一次：`t_read` 打印了 `reading`，测试马上按 Ctrl-C，结果没有任何反应。所以输出顺序是：程序的输出、`[proc] ... exited ...`，然后才是 `> `。
- **后台**（`run NAME &`）：打印 `[proc] pid N (NAME) started in the background`（管道是 `(pipeline)`）后马上回到提示符。它的输出和 shell 的输出会交错在一起，没有作业控制，只能用 `kill` 结束它。后台进程和 shell 谁先运行取决于调度（多核时它们同时运行），所以程序的第一行输出可能出现在 `started in the background` 前面；紧接着 `ps` 的话，还可能看到它还没 `exec`，名字仍然是 `sh`。每次 `print` 是一次 `write`，内核整段输出，所以两边的输出只会按行交错，不会插进一行的中间。
- **回收后台进程**：每次打印提示符之前，`reapBackground` 用 `wait(null, nohang)` 把已经结束的子进程都回收掉。它们的结束信息内核已经打印过了；不回收的话会一直是 zombie，占着进程表的槽位。

## 管道

`run A | B | C`：A 的标准输出接到 B 的标准输入，B 的接到 C 的，最多 4 个程序（`max_stages`：init、shell、组长占三个槽位，进程表原来只有 8 个槽位时定下的，现在有 16 个，没有改）。和 xv6 的 `sh` 一样，shell 自己不建管道，而是 fork 一个子进程当**组长**（`runPipeline`），由它来建：

```zig
for (stages, 0..) |*st, i| {
    if (!is_last) p = sys.pipe() ...;
    const pid = sys.fork() ...;
    if (pid == 0) {
        if (prev) |fd| { close(stdin); dup(fd); close(fd); }          // 标准输入换成上一个管道的读端
        if (!is_last) { close(stdout); dup(p[1]); close(p[0]); close(p[1]); }  // 标准输出换成这个管道的写端
        execStage(st);
    }
    if (prev) |fd| close(fd);       // 组长自己不用的那一端都关掉
    if (!is_last) { close(p[1]); prev = p[0]; }
}
// 等所有程序结束，以最后一个程序的退出码结束
```

- **换标准输入输出靠 `close` 再 `dup`**：`dup` 返回编号最小的空闲 fd，刚关掉 0 号，`dup` 出来的就是 0 号（[syscalls.md](syscalls.md#closeduppipe)）。子进程 `exec` 之后打开的文件不变，新程序直接从 0 号读、往 1 号写，不知道自己在管道里。
- **用不着的一端都要关掉**，包括组长自己手里的：管道的写端只要还有一个开着，读的一方就读不到结尾。比如组长忘了关 `p[1]`，`run echo hi | wc` 里 echo 结束了，wc 也永远等不到结尾。
- **为什么要组长**：Ctrl-C 只认一个前台进程（`setfg`），内核杀的是前台进程和它的子孙（[process.md](process.md#ctrl-c)）。所有程序都是组长的子进程，把组长设成前台进程，按一次 Ctrl-C 整条管道都结束了。组长是 shell `fork` 出来的，内核打印的名字是 `sh`：

  ```
  > run echo hello world | wc
  [proc] pid 60 (echo) exited with code 0
  1 2 12
  [proc] pid 61 (wc) exited with code 0
  [proc] pid 59 (sh) exited with code 0
  ```

  对 `run cat | wc` 按 Ctrl-C（cat 在等键盘，wc 在等 cat）：

  ```
  ^C
  [proc] pid 73 (sh) killed: interrupted by Ctrl-C
  [proc] pid 74 (cat) killed: interrupted by Ctrl-C
  [proc] pid 75 (wc) killed: interrupted by Ctrl-C
  ```

  组长被杀时 cat、wc 还没结束，它们被交给 init，由 init 回收。
- 组长 `pipe` 或 `fork` 失败时打印原因，关掉已经建好的管道，等已经启动的程序结束，以 1 结束。
- 前一个程序先结束：后一个程序读完管道里剩下的，读到结尾。后一个程序先结束：前一个程序再写就得到 `BrokenPipe`（`echo` 以 1 结束）。

## 重定向

`run 程序 > 文件` 把标准输出换成文件（没有就建，有就截成 0 字节），`run 程序 < 文件` 把标准输入换成文件；`<`、`>` 和文件名之间可以有空格也可以没有，在管道的哪一段都行（`run echo a b c | cat >/p.txt`）。和管道一样是在子进程里、`exec` 之前换（`redirect`）：

```zig
fn replaceFd(target: sys.Fd, path: []const u8, flags: sys.OpenFlags) void {
    const fd = sys.open(path, flags) catch |err| { print("run: {s}: {s}\n", ...); sys.exit(1); };
    sys.close(target) catch {};
    _ = sys.dup(fd) catch {};     // 编号最小的空闲 fd，就是刚关掉的 target
    sys.close(fd) catch {};
}
```

- `>` 用 `open(.{ .read = false, .write = true, .create = true, .truncate = true })`，`<` 用只读的 `open`。
- 管道里的一段同时有管道和重定向时，重定向在后面做，所以它优先（和 Unix 的 sh 一样）。
- 打不开（`run cat < /nope`、`run echo x > /bin`）时子进程打印 `run: /nope: NotFound`、`run: /bin: IsDir`，以 1 结束，不运行程序。`>` 或 `<` 后面没有文件名打印 `run: missing file name after < or >`，不 `fork`。
- 例子：

  ```
  > run echo hello file system > /hello.txt
  [proc] pid 4 (echo) exited with code 0
  > run wc < /hello.txt
  1 3 18
  [proc] pid 5 (wc) exited with code 0
  ```

## 命令解析

```zig
const trimmed = std.mem.trim(u8, input, " ");
if (trimmed.len == 0) return;
const name, const arg = std.mem.cutScalar(u8, trimmed, ' ') orelse .{ trimmed, "" };
const cmd = std.meta.stringToEnum(Command, name) orelse { ... "unknown command" ... };
```

- 去掉首尾空格；空行什么也不做。
- 第一个空格之前是命令名，之后是参数（`std.mem.cutScalar` 是 0.17 新增的，返回分割点前后两段）。参数只有 `run`、`kill`、`cd` 用。
- 命令名用 `std.meta.stringToEnum` 转成 `Command` 枚举，不认识就打印 `unknown command: NAME (try 'help')`。

`run` 的参数再拆一次（`parse`）：

- 末尾的 `&` 表示后台运行，`&` 前面有没有空格都行（`run spin&` 也可以）。
- 剩下的按 `|` 拆成几段（`std.mem.splitScalar`），每段按空格拆成词（`std.mem.tokenizeScalar`，连续的空格算一个）。以 `<`、`>` 开头的词是重定向（[重定向](#重定向)），其余的第一个词是程序名，所有词（包括程序名）就是它的命令行参数。词是 `line` 里的切片，不复制。
- 没有引号、没有转义：参数里不能有空格、`|`，也不能以 `<`、`>` 开头。
- 某一段是空的（`run echo a |`）打印 `run: empty command in the pipeline`；一段超过 16 个词（`abi.max_args`）打印 `run: too many arguments (at most 16)`；超过 4 段打印 `run: too many programs in the pipeline (at most 4)`。

## 命令

| 命令 | 作用 | 输出示例 |
| --- | --- | --- |
| `help` | 列出命令 | |
| `uptime` | 开机时长（`uptime` 系统调用，精度一个 tick） | `up 3.26s` |
| `mem` | 物理页的使用情况（`meminfo`，[page-allocator.md](page-allocator.md)） | `31600 of 31676 pages free (126400 KiB), 4 KiB each` |
| `disk` | 磁盘的原始区域（文件系统之后的块）有多大（`blockcount`，[disk.md](disk.md#系统调用)）；没有磁盘时打印 `no disk` | `1024 blocks of 4 KiB (4 MiB)` |
| `cd [DIR]` | 换 shell 的当前目录（`chdir`），之后启动的程序继承它；不给 `DIR` 时回到 `/`。出错时打印 `cd: DIR: NotFound`（或 `NotDir`） | |
| `run` | 列出 `/bin` 里的程序（`readdir`），按名字排序 | `programs: cat echo fault hello init ls mkdir rm sh spin ticker wc` |
| `run NAME [ARGS...]` | 在前台运行用户程序 `NAME`（`/bin/NAME`；带 `/` 的按路径找，比如 `run /h`），带上参数，等它结束；Ctrl-C 结束它 | 程序自己的输出 + `[proc] pid 3 (hello) exited with code 0` |
| `run A \| B \| ...` | 管道（[管道](#管道)） | `run echo one two three \| wc` 打印 `1 3 14` |
| `run ... > F`、`run ... < F` | 标准输出写进文件 `F`、标准输入从 `F` 读（[重定向](#重定向)） | |
| `run ... &` | 在后台运行，马上回到提示符 | `[proc] pid 4 (spin) started in the background` |
| `ps` | 列出进程（`procinfo`）：pid、父进程、状态、用掉的时钟 tick 数、名字 | 见下文 |
| `kill PID` | 结束进程 | `[proc] pid 4 (spin) killed: kill()` |
| `shutdown` | 打印 `bye!`，通过 SBI 关机，QEMU 退出，退出码 0 | `bye!` |

说明：

- `uptime` 显示 `ms / 1000` 秒和 `ms % 1000 / 10` 百分之一秒（补零到两位），所以 `up 3.05s` 不会显示成 `3.5s`。内核按 tick 计时，百分之一秒正好是 tick 数。
- 进程表满了打印 `run: too many processes (at most 16)`（`fork` 返回 `TooManyProcesses`；16 是 `abi.max_procs`，其中 init 和 shell 占两个），ELF 加载失败打印 `run: cannot load NAME: BadElf`（或 `OutOfMemory`）。
- `ps` 的输出（单核，一个后台的 `spin` 在死循环）：

  ```
    PID  PPID STATE     TICKS NAME
      1     0 sleeping      0 init
      2     1 running       3 sh
     17     2 runnable      2 spin
  ```

  `ps` 是 shell 执行的，所以 shell 自己总是 `running`；init 总在 `wait` 里睡着。单核时 shell 占着唯一的 hart，`spin` 只能是 `runnable`；多核时它在别的 hart 上跑，显示 `running`。`TICKS` 是进程在 U 模式运行期间来过的时钟中断数，大致等于它用掉的 CPU 时间（单位 10 ms）。按槽位顺序列出，不一定按 pid 排序。结束了还没被回收的进程显示为 `zombie`。
- `kill PID`：`PID` 不是数字时打印 `usage: kill PID`，没有这个进程时打印 `kill: no such process: PID`，杀 init 打印 `kill: cannot kill pid 1: permission denied`。`kill` 系统调用只做标记（[process.md](process.md#kill只做标记)），所以 shell 接着 `wait(pid)`：是自己的子进程的话，等它真的结束、回收它，`killed: kill()` 那一行就在下一个提示符之前；不是自己的子进程时 `wait` 立刻返回 `NoChildren`。
- **列程序**（`listPrograms`）：`readdir` 给的是名字的散列的顺序，shell 把名字收进全局的数组再排序。用的是插入排序：`std.mem.sort` 是块排序，栈上有一个 512 项的缓存（512 个切片，8 KiB），Debug 模式下把 shell 16 KiB 的用户栈撑爆过（`store_page_fault`，`stval` 在保护页里，init 重启了 shell）。
- 文件操作是普通的用户程序：`run ls [PATH...]`、`run cat [FILE...]`、`run mkdir DIR...`、`run rm PATH...`（[user-programs.md](user-programs.md)）。`cd` 必须是 shell 自己的命令：子进程 `chdir` 改不了父进程的当前目录。
- `kill` shell 自己（它的 pid）也可以：shell 结束，init 打印 `init: sh exited, restarting it` 并启动一个新的 shell。

## 添加命令

1. 在 `Command` 枚举里加一个名字（就是用户要输入的命令名）。
2. 在 `help` 的文本里加一行。
3. 在 `execute` 的 `switch` 里加分支；需要参数就用 `arg`。需要内核做的事，先加系统调用（[syscalls.md](syscalls.md#新增一个系统调用)）。
4. 更新本文和根目录 README 的命令表。

`help` 的文本按 12 列对齐。
