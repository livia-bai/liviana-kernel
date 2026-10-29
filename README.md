# liviana-kernel

用 Zig 0.17 写的最小 RISC-V 64 位内核，运行在 QEMU `virt` 机器上，由 OpenSBI 引导，内核运行在 S 模式。

功能：

- 串口输出和键盘（串口中断）输入
- 陷阱处理：异常和中断，时钟中断
- 解析设备树，得到内存范围和时钟频率
- 物理页分配器，Sv39 分页，内核按段设置权限（代码只读可执行，数据不可执行）
- U 模式用户程序：独立编译的 ELF 嵌进内核，由内核加载；用户程序出错或按 Ctrl-C 只结束进程，内核照常运行
- 多核：启动 hart 用 SBI 的 HSM 扩展启动设备树里的其他 hart（QEMU 默认 4 个，最多用 8 个），每个 hart 跑自己的调度器
- 多进程，照 xv6 的结构：时间片轮转调度（每个 hart 一个调度器循环、`sleep`/`wakeup`、`kill` 只做标记）；`fork`/`exec`/`wait`、父子进程、zombie 和孤儿回收；最多 16 个进程
- 21 个系统调用：文件描述符（`read`/`write`/`close`/`dup`）和管道（`pipe`），命令行参数（`exec` 带 `argv`），堆（`sbrk`）
- 用户态的 init 和 shell：init 启动 shell，shell 用 `fork` + `exec` 运行程序，可以带参数、在后台运行、用 `|` 接成管道
- 照 xv6 加锁：每个进程一把锁、`wait_lock`、tickslock，页分配器、文件表、管道、串口的输入和输出都有自旋锁

```
Hello from a Zig kernel on RISC-V!
SBI: OpenSBI, spec v1.0 | hart 0 | device tree at 0x87e00000
[ok] trap vector installed
[trap] breakpoint at 0x8021687c, skipping it
[ok] device tree: 128 MiB RAM at 0x80000000, timebase 10000000 Hz
[ok] page allocator: 31783 free pages (127132 KiB)
[ok] Sv39 paging enabled: kernel mapped 1:1, text r-x, rodata r--, data rw-
[ok] interrupt sources enabled: timer at 100 Hz, keyboard via UART + PLIC
[ok] 4 harts running, booted on hart 0
Type 'help' for commands.
> run hello
Hello from U-mode! I am pid 3, the kernel has been up for 2170 ms.
write() refused a kernel pointer: BadAddress
[proc] pid 3 (hello) exited with code 0
> run echo hello, world
hello, world
[proc] pid 4 (echo) exited with code 0
> run echo one two three | wc
[proc] pid 6 (echo) exited with code 0
1 3 14
[proc] pid 7 (wc) exited with code 0
[proc] pid 5 (sh) exited with code 0
> run spin &
[proc] pid 8 (spin) started in the background
> pid 8 spinning in U-mode without making syscalls
run spin &
[proc] pid 9 (spin) started in the background
> pid 9 spinning in U-mode without making syscalls
run ticker &
[proc] pid 10 (ticker) started in the background
> [ticker pid 10] tick 1 at 8170 ms
[ticker pid 10] tick 2 at 9170 ms
ps
  PID  PPID STATE     TICKS NAME
    1     0 sleeping      0 init
    2     1 running       2 sh
    8     2 running     400 spin
    9     2 running     301 spin
   10     2 sleeping      0 ticker
> [ticker pid 10] tick 3 at 10170 ms
run spin
pid 11 spinning in U-mode without making syscalls
[ticker pid 10] tick 4 at 11170 ms
^C
[proc] pid 11 (spin) killed: interrupted by Ctrl-C
```

## 运行

需要 Zig **0.17.0** 和 `qemu-system-riscv64`（Debian/Ubuntu 包名 `qemu-system-misc`，自带 OpenSBI 固件）。

```sh
zig build run                     # 编译并在 QEMU 中启动（Debug 模式，4 个 hart）
zig build run -Doptimize=small    # 体积优化，内核代码段约 22 KB
zig build run -- -smp 1           # 只用一个 hart
```

退出 QEMU：先按 `Ctrl-A`，再按 `X`；或者在 shell 里输入 `shutdown`。

测试（详见 [测试与调试](docs/testing.md)）：

```sh
zig build test                        # 单元测试：在主机上测设备树解析、页分配器、页表、ELF 加载器
python3 tools/qemu_test.py --changed  # QEMU 测试：只跑和改动有关的用例
python3 tools/qemu_test.py            # QEMU 测试：全部用例
```

## shell 命令

shell 是用户程序（`user/sh.zig`），由 init 启动。

| 命令 | 作用 |
| --- | --- |
| `help` | 列出命令 |
| `uptime` | 开机时长，精度 10 ms |
| `mem` | 物理页的使用情况 |
| `run NAME [ARGS...]` | 用 `fork` + `exec` 运行用户程序 `NAME`（`hello`、`fault`、`spin`、`ticker`、`echo`、`cat`、`wc`），带上参数，等它结束，Ctrl-C 结束它；不带参数时列出所有程序 |
| `run A \| B \| ...` | 管道：A 的输出接到 B 的输入，最多 4 个程序；Ctrl-C 结束整条管道 |
| `run ... &` | 在后台运行，马上回到提示符 |
| `ps` | 列出进程：pid、父进程、状态、用掉的时钟 tick 数 |
| `kill PID` | 结束进程（init 不能杀；杀掉 shell 的话 init 会重新启动一个） |
| `shutdown` | 通过 SBI 关机，QEMU 随之退出 |

## 文档

详细文档在 [docs/](docs/README.md)，按功能组织，每一篇都对应若干源码文件：

- 整体：[总体结构](docs/architecture.md)、[构建系统](docs/build.md)、[启动流程](docs/boot.md)
- 内核：[陷阱处理](docs/trap.md)、[串口 / PLIC / 定时器](docs/devices.md)、[CSR 和 SBI](docs/riscv-sbi.md)、[设备树](docs/devicetree.md)、[页分配器](docs/page-allocator.md)、[Sv39 分页](docs/paging.md)
- 进程和用户态：[进程](docs/process.md)、[文件和管道](docs/files.md)、[系统调用](docs/syscalls.md)、[用户程序](docs/user-programs.md)、[shell](docs/shell.md)
- 开发：[测试与调试](docs/testing.md)、[Zig 0.17 笔记](docs/zig-0.17.md)
- [修改记录](docs/changes.md)：每次改动新增了什么功能、修了什么 bug

改代码之前先读 [AGENTS.md](AGENTS.md)。

## 目录

```
build.zig       构建脚本：内核 + 用户程序
linker.ld       内核的链接脚本
src/            内核（S 模式）
user/           用户程序和它们的运行时（U 模式）
user/tests/     回归测试程序（zig build -Dtest-programs=true 时才编进内核）
docs/           文档
tools/          QEMU 测试脚本
```

## 许可证

[MIT](LICENSE)。

## 可以继续做的方向

- 更多系统调用：阻塞读键盘的 `read`、`fork`/`exec`/`wait`，以及用户程序自己申请内存
- 从设备树读串口、PLIC 的地址和中断号
- 多核：核间中断（叫醒的进程、被杀的进程现在要等那个 hart 的下一个时钟中断）
