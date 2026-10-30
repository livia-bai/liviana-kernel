# liviana-kernel

用 Zig 0.17 写的最小 RISC-V 64 位内核，运行在 QEMU `virt` 机器上，由 OpenSBI 引导，内核运行在 S 模式。

功能：

- 串口输出和键盘（串口中断）输入
- 陷阱处理：异常和中断，时钟中断
- 解析设备树，得到内存范围和时钟频率
- 物理页分配器，Sv39 分页，内核按段设置权限（代码只读可执行，数据不可执行）
- U 模式用户程序：独立编译的 ELF 装在文件系统的 `/bin` 里，`exec` 时由内核从磁盘加载（只有 init 嵌在内核里）；用户程序出错或按 Ctrl-C 只结束进程，内核照常运行
- 多核：启动 hart 用 SBI 的 HSM 扩展启动设备树里的其他 hart（QEMU 默认 4 个，最多用 8 个），每个 hart 跑自己的调度器；核间中断叫醒空闲的 hart、打断运行着被杀进程的 hart
- 多进程，照 xv6 的结构：时间片轮转调度（每个 hart 一个调度器循环、`sleep`/`wakeup`、`kill` 只做标记）；`fork`/`exec`/`wait`、父子进程、zombie 和孤儿回收；最多 16 个进程
- 写时复制的 `fork`：父子进程共用物理页（页分配器记引用数），谁先写哪一页谁在缺页异常里复制一份
- 磁盘：virtio 块设备驱动（DMA + 中断，等磁盘时进程睡着），睡眠锁，照 xv6 的缓冲区缓存（LRU）
- 文件系统，类似 btrfs：所有东西（inode、目录项、文件内容）都是一棵写时复制 B 树里的条目，每个操作一个事务，掉电后总是某个操作做完的样子；小文件内联在树里，数据块带校验和；构建时由主机上的 `mkfs` 生成磁盘镜像，用户程序装在 `/bin`
- 30 个系统调用：文件描述符（`read`/`write`/`close`/`dup`）和管道（`pipe`），文件系统（`open`/`mkdir`/`unlink`/`chdir`/`fstat`/`readdir`，检查整个文件系统的 `scrub`），命令行参数（`exec` 带 `argv`），堆（`sbrk`），读写磁盘的原始区域（`readblock`/`writeblock`）
- 用户态的 init 和 shell：init 启动 shell，shell 用 `fork` + `exec` 运行程序，可以带参数、在后台运行、用 `|` 接成管道、用 `<`、`>` 重定向到文件，`cd` 换当前目录
- 照 xv6 加锁：每个进程一把锁、`wait_lock`、tickslock，页分配器、文件表、管道、串口的输入和输出、磁盘队列、缓冲区缓存都有自旋锁，缓冲区和文件系统还有睡眠锁

```
Hello from a Zig kernel on RISC-V!
SBI: OpenSBI, spec v1.0 | hart 0 | device tree at 0x87e00000
[ok] trap vector installed
[trap] breakpoint at 0x80216878, skipping it
[ok] device tree: 128 MiB RAM at 0x80000000, timebase 10000000 Hz
[ok] page allocator: 31901 free pages (127604 KiB)
[ok] Sv39 paging enabled: kernel mapped 1:1, text r-x, rodata r--, data rw-
[ok] virtio disk: 8192 blocks of 4 KiB (32 MiB), irq 1
[ok] interrupt sources enabled: timer at 100 Hz, keyboard via UART + PLIC, IPIs, disk
[ok] 4 harts running, booted on hart 0
[ok] file system: 6840 of 7168 blocks free, generation 27
Type 'help' for commands.
> run
programs: cat echo fault hello init ls mkdir rm scrub sh spin ticker wc
> run hello
Hello from U-mode! I am pid 3, the kernel has been up for 280 ms.
write() refused a kernel pointer: BadAddress
[proc] pid 3 (hello) exited with code 0
> run echo hello, world > /hello.txt
[proc] pid 4 (echo) exited with code 0
> run cat /hello.txt
hello, world
[proc] pid 5 (cat) exited with code 0
> run echo one two three | wc
[proc] pid 7 (echo) exited with code 0
1 3 14
[proc] pid 8 (wc) exited with code 0
[proc] pid 6 (sh) exited with code 0
> run mkdir /docs
[proc] pid 9 (mkdir) exited with code 0
> cd /docs
> run wc < /hello.txt > count.txt
[proc] pid 10 (wc) exited with code 0
> run ls /docs /
/docs:
file        7 count.txt
/:
file       13 hello.txt
dir         0 bin
dir         0 docs
[proc] pid 11 (ls) exited with code 0
> cd
> run spin &
[proc] pid 12 (spin) started in the background
> pid 12 spinning in U-mode without making syscalls
ps
  PID  PPID STATE     TICKS NAME
    1     0 sleeping      1 init
    2     1 running       3 sh
   12     2 running      48 spin
> run spin
pid 13 spinning in U-mode without making syscalls
^C
[proc] pid 13 (spin) killed: interrupted by Ctrl-C
```

## 运行

需要 Zig **0.17.0** 和 `qemu-system-riscv64`（Debian/Ubuntu 包名 `qemu-system-misc`，自带 OpenSBI 固件）。

```sh
zig build run                     # 编译并在 QEMU 中启动（Debug 模式，4 个 hart）
zig build run -Doptimize=small    # 体积优化，内核代码段约 45 KB
zig build run -- -smp 1           # 只用一个 hart

# zig build run 接上一块 32 MiB 的 virtio 磁盘（zig-out/disk.img，构建时生成，装着文件系统；写的内容在 QEMU 退出时丢掉）
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
| `disk` | 磁盘的原始区域（文件系统之后的块）有多大 |
| `cd [DIR]` | 换当前目录，不给时回到 `/` |
| `run NAME [ARGS...]` | 用 `fork` + `exec` 运行用户程序 `NAME`（`hello`、`fault`、`spin`、`ticker`、`echo`、`cat`、`wc`、`ls`、`mkdir`、`rm`、`scrub`），带上参数，等它结束，Ctrl-C 结束它；不带参数时列出所有程序 |
| `run A \| B \| ...` | 管道：A 的输出接到 B 的输入，最多 4 个程序；Ctrl-C 结束整条管道 |
| `run ... > F`、`run ... < F` | 标准输出写进文件 `F`（没有就建，有就清空）、标准输入从 `F` 读 |
| `run ... &` | 在后台运行，马上回到提示符 |
| `ps` | 列出进程：pid、父进程、状态、用掉的时钟 tick 数 |
| `kill PID` | 结束进程（init 不能杀；杀掉 shell 的话 init 会重新启动一个） |
| `shutdown` | 通过 SBI 关机，QEMU 随之退出 |

## 文档

详细文档在 [docs/](docs/README.md)，按功能组织，每一篇都对应若干源码文件：

- 整体：[总体结构](docs/architecture.md)、[构建系统](docs/build.md)、[启动流程](docs/boot.md)
- 内核：[陷阱处理](docs/trap.md)、[串口 / PLIC / 定时器](docs/devices.md)、[CSR 和 SBI](docs/riscv-sbi.md)、[设备树](docs/devicetree.md)、[页分配器](docs/page-allocator.md)、[Sv39 分页](docs/paging.md)、[磁盘](docs/disk.md)、[写时复制 B 树](docs/btree.md)、[文件系统](docs/fs.md)
- 进程和用户态：[进程](docs/process.md)、[文件和管道](docs/files.md)、[系统调用](docs/syscalls.md)、[用户程序](docs/user-programs.md)、[shell](docs/shell.md)
- 开发：[测试与调试](docs/testing.md)、[Zig 0.17 笔记](docs/zig-0.17.md)
- [修改记录](docs/changes.md)：每次改动新增了什么功能、修了什么 bug

改代码之前先读 [AGENTS.md](AGENTS.md)。

## 目录

```
build.zig       构建脚本：内核 + 用户程序 + 磁盘镜像（src/mkfs.zig 在主机上生成）
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

- 从设备树读串口、PLIC 的地址和中断号
- 按需分页（`sbrk` 先不分配，第一次访问时再分配）；内核栈两侧的保护页
- 文件系统：`rename`、`lseek`、把几个操作攒进一个事务、按文件分锁
