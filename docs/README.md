# 文档目录

liviana-kernel 的详细文档，按功能组织，讲这个用 Zig 写的 RISC-V 内核每一部分是怎么做的、为什么这样做。仓库根目录的 [README.md](../README.md) 只有简介和上手步骤。

## 按功能

建议按这个顺序读：

| 文档 | 内容 |
| --- | --- |
| [architecture.md](architecture.md) | 总体结构：特权级、多核、物理内存布局、虚拟地址空间、模块关系、主要控制流、全局不变量 |
| [build.md](build.md) | 构建系统：目标平台、优化模式、用户程序的编译和嵌入、QEMU 运行步骤 |
| [boot.md](boot.md) | 启动流程：OpenSBI 交接、链接脚本、`_start`、每个 hart 的启动栈、`kmain` 的初始化顺序、启动其他 hart、交给调度器、panic 时让所有 hart 停下 |
| [riscv-sbi.md](riscv-sbi.md) | CSR 访问和 SBI 调用 |
| [trap.md](trap.md) | 陷阱处理：异常委托、`TrapFrame`、`sscratch` 和 `tp` 约定、入口/出口汇编、分发 |
| [devices.md](devices.md) | 串口（含输入缓冲区和 Ctrl-C）、PLIC、定时器 |
| [devicetree.md](devicetree.md) | 设备树：格式、解析器、QEMU 给的内容、错误和限制 |
| [page-allocator.md](page-allocator.md) | 物理页分配器、每一页的引用数 |
| [paging.md](paging.md) | Sv39 分页：页表格式、建立映射、内核页表、用户地址空间、`fork` 的写时复制 |
| [user-programs.md](user-programs.md) | 用户程序：运行时（`start.zig`、`sys.zig`）、示例程序、怎么写新程序 |
| [process.md](process.md) | 进程：进程表、ELF 加载器、`userinit`/`fork`/`exec`、命令行参数、`sbrk`、xv6 式调度（每个 hart 的 `scheduler`、`sched`/`sleep`/`wakeup`）、核间中断、切换上下文、`exit`/`wait`/`kill`、Ctrl-C、锁和加锁顺序 |
| [disk.md](disk.md) | 磁盘：virtio 块设备驱动、睡眠锁、缓冲区缓存、读写块的系统调用 |
| [btree.md](btree.md) | 写时复制 B 树（以后文件系统的基础，类似 btrfs）：节点格式、写时复制、事务和提交、空闲空间、掉电测试 |
| [files.md](files.md) | 文件：fd 表、文件表、串口和管道的读写 |
| [syscalls.md](syscalls.md) | 系统调用：调用约定、调用列表、访问用户内存、怎么加新调用 |
| [shell.md](shell.md) | shell（用户程序）：输入处理、前台和后台进程、命令 |
| [testing.md](testing.md) | 测试与调试：单元测试、QEMU 测试（`tools/qemu_test.py`）、回归测试程序、QEMU 日志、GDB、症状速查 |
| [zig-0.17.md](zig-0.17.md) | Zig 0.17 和旧版本的差别，以及这个项目里踩过的坑 |

## 按源码文件

| 文件 | 主要文档 | 也涉及 |
| --- | --- | --- |
| `build.zig` | [build.md](build.md) | [user-programs.md](user-programs.md) |
| `linker.ld` | [boot.md](boot.md#链接脚本) | [paging.md](paging.md#内核页表) |
| `src/main.zig` | [boot.md](boot.md) | [process.md](process.md#调度器) |
| `src/hart.zig` | [boot.md](boot.md#panic) | [trap.md](trap.md#tp-约定)、[process.md](process.md#锁) |
| `src/riscv.zig` | [riscv-sbi.md](riscv-sbi.md) | |
| `src/sbi.zig` | [riscv-sbi.md](riscv-sbi.md#sbi-调用sbizig) | [devices.md](devices.md#定时器timerzig) |
| `src/trap.zig` | [trap.md](trap.md) | [process.md](process.md)、[syscalls.md](syscalls.md) |
| `src/uart.zig` | [devices.md](devices.md#串口uartzig) | [files.md](files.md#串口) |
| `src/plic.zig` | [devices.md](devices.md#plicpliczig) | |
| `src/timer.zig` | [devices.md](devices.md#定时器timerzig) | |
| `src/virtio_disk.zig` | [disk.md](disk.md#virtio-块设备驱动virtio_diskzig) | [devices.md](devices.md#中断路径汇总) |
| `src/sleeplock.zig` | [disk.md](disk.md#睡眠锁sleeplockzig) | [process.md](process.md#锁) |
| `src/bio.zig` | [disk.md](disk.md#缓冲区缓存biozig) | [syscalls.md](syscalls.md#调用列表) |
| `src/btree.zig` | [btree.md](btree.md#节点格式btreezig) | |
| `src/ctree.zig` | [btree.md](btree.md) | [disk.md](disk.md#缓冲区缓存biozig) |
| `src/ipi.zig` | [process.md](process.md#核间中断) | [riscv-sbi.md](riscv-sbi.md#用到的扩展)、[trap.md](trap.md#分发) |
| `src/dtb.zig` | [devicetree.md](devicetree.md) | |
| `src/page.zig` | [page-allocator.md](page-allocator.md) | |
| `src/vm.zig` | [paging.md](paging.md) | [syscalls.md](syscalls.md#访问用户内存) |
| `src/proc.zig` | [process.md](process.md) | |
| `src/spinlock.zig` | [process.md](process.md#锁) | [boot.md](boot.md#panic) |
| `src/file.zig` | [files.md](files.md) | [syscalls.md](syscalls.md#closeduppipe) |
| `src/pipe.zig` | [files.md](files.md#管道) | |
| `src/syscall.zig` | [syscalls.md](syscalls.md) | [process.md](process.md) |
| `src/abi.zig` | [syscalls.md](syscalls.md#abizig) | [build.md](build.md#用户程序) |
| `user/start.zig` | [user-programs.md](user-programs.md#startzig) | |
| `user/sys.zig` | [user-programs.md](user-programs.md#syszig) | [syscalls.md](syscalls.md#用户态封装) |
| `user/linker.ld` | [build.md](build.md#用户程序的链接脚本) | [process.md](process.md#elf-加载器) |
| `user/init.zig` | [user-programs.md](user-programs.md#init-和-sh) | [process.md](process.md#结束进程) |
| `user/sh.zig` | [shell.md](shell.md) | [user-programs.md](user-programs.md#init-和-sh) |
| `user/hello.zig`、`user/fault.zig`、`user/spin.zig`、`user/ticker.zig` | [user-programs.md](user-programs.md#示例程序) | |
| `user/echo.zig`、`user/cat.zig`、`user/wc.zig` | [user-programs.md](user-programs.md#echocatwc) | [shell.md](shell.md#管道) |
| `user/tests/*.zig`、`user/tests/noperm.ld` | [testing.md](testing.md#回归测试程序) | [build.md](build.md#用户程序) |
| `src/tests.zig` | [testing.md](testing.md#单元测试zig-build-test) | [build.md](build.md#单元测试) |
| `tools/qemu_test.py` | [testing.md](testing.md#qemu-测试toolsqemu_testpy) | |

## 修改记录

[changes.md](changes.md)：每次改动新增了什么功能、修了什么 bug。
