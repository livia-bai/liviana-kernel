# liviana-kernel

用 Zig 0.17 写的最小 RISC-V 64 位内核，运行在 QEMU `virt` 机器上，由 OpenSBI 引导，内核运行在 S 模式。

功能：

- 串口输出和键盘（串口中断）输入，一个能执行几条命令的小 shell
- 陷阱处理：异常和中断，时钟中断
- 解析设备树，得到内存范围和时钟频率
- 物理页分配器，Sv39 分页，内核按段设置权限（代码只读可执行，数据不可执行）
- U 模式用户程序：独立编译的 ELF 嵌进内核，由内核加载；四个系统调用；用户程序出错或按 Ctrl-C 只结束进程，内核照常运行

```
Hello from a Zig kernel on RISC-V!
SBI: OpenSBI, spec v1.0 | hart 0 | device tree at 0x87e00000
[ok] trap vector installed
[trap] breakpoint at 0x80215d34, skipping it
[ok] device tree: 128 MiB RAM at 0x80000000, timebase 10000000 Hz
[ok] page allocator: 32057 free pages (128228 KiB)
[ok] Sv39 paging enabled: kernel mapped 1:1, text r-x, rodata r--, data rw-
[ok] interrupts enabled: timer at 100 Hz, keyboard via UART + PLIC
Type 'help' for commands.
> run hello
Hello from U-mode! I am pid 1, the kernel has been up for 5120 ms.
write() refused a kernel pointer: BadAddress
[proc] pid 1 (hello) exited with code 0
> run fault
reading kernel memory at 0x80200000 from U-mode...
[proc] pid 2 (fault) killed: load_page_fault at 0x40011454, stval=0x80200000
> run spin
spinning in U-mode without making syscalls, press Ctrl-C to stop
^C
[proc] pid 3 (spin) killed: interrupted by Ctrl-C
```

## 运行

需要 Zig **0.17.0** 和 `qemu-system-riscv64`（Debian/Ubuntu 包名 `qemu-system-misc`，自带 OpenSBI 固件）。

```sh
zig build run                     # 编译并在 QEMU 中启动（Debug 模式）
zig build run -Doptimize=small    # 体积优化，内核代码段约 12.8 KB
```

退出 QEMU：先按 `Ctrl-A`，再按 `X`；或者在 shell 里输入 `shutdown`。

## shell 命令

| 命令 | 作用 |
| --- | --- |
| `help` | 列出命令 |
| `uptime` | 开机时长，由时钟中断计数得出 |
| `mem` | 物理页的使用情况 |
| `run NAME` | 在 U 模式运行用户程序 `NAME`（`hello`、`fault`、`spin`），等它结束；不带参数时列出所有程序 |
| `ebreak` | 触发断点异常，处理后恢复执行 |
| `crash` | 读地址 0（没有映射），触发缺页异常，内核 panic |
| `shutdown` | 通过 SBI 关机，QEMU 随之退出 |

## 文档

详细文档在 [docs/](docs/README.md)，按功能组织，每一篇都对应若干源码文件：

- 整体：[总体结构](docs/architecture.md)、[构建系统](docs/build.md)、[启动流程](docs/boot.md)
- 内核：[陷阱处理](docs/trap.md)、[串口 / PLIC / 定时器](docs/devices.md)、[CSR 和 SBI](docs/riscv-sbi.md)、[设备树](docs/devicetree.md)、[页分配器](docs/page-allocator.md)、[Sv39 分页](docs/paging.md)、[shell](docs/shell.md)
- 用户态：[用户程序](docs/user-programs.md)、[进程](docs/process.md)、[系统调用](docs/syscalls.md)
- 开发：[测试与调试](docs/testing.md)、[Zig 0.17 笔记](docs/zig-0.17.md)
- [修改与验错记录](docs/changes/README.md)：每次改动做了什么、怎么验证的、发现并修复了哪些问题

改代码之前先读 [AGENTS.md](AGENTS.md)。

## 目录

```
build.zig       构建脚本：内核 + 用户程序
linker.ld       内核的链接脚本
src/            内核（S 模式）
user/           用户程序和它们的运行时（U 模式）
docs/           文档
docs/changes/   修改与验错记录
```

## 可以继续做的方向

- 多进程：每个进程一块内核栈，在时钟中断里切换，实现抢占式调度
- 更多系统调用：阻塞读键盘的 `read`、`sleep`，以及用户程序自己申请内存
- 从设备树读串口、PLIC 的地址和中断号
- 多核：用 SBI HSM 扩展启动其他 hart
