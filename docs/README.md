# 文档目录

liviana-kernel 的详细文档，按功能组织，讲这个用 Zig 写的 RISC-V 内核每一部分是怎么做的、为什么这样做。仓库根目录的 [README.md](../README.md) 只有简介和上手步骤。

## 按功能

建议按这个顺序读：

| 文档 | 内容 |
| --- | --- |
| [architecture.md](architecture.md) | 总体结构：特权级、物理内存布局、虚拟地址空间、模块关系、主要控制流、全局不变量 |
| [build.md](build.md) | 构建系统：目标平台、优化模式、用户程序的编译和嵌入、QEMU 运行步骤 |
| [boot.md](boot.md) | 启动流程：OpenSBI 交接、链接脚本、`_start`、`kmain` 的初始化顺序、交给调度器、panic 处理 |
| [riscv-sbi.md](riscv-sbi.md) | CSR 访问和 SBI 调用 |
| [trap.md](trap.md) | 陷阱处理：异常委托、`TrapFrame`、`sscratch` 约定、入口/出口汇编、分发 |
| [devices.md](devices.md) | 串口（含输入缓冲区和 Ctrl-C）、PLIC、定时器 |
| [devicetree.md](devicetree.md) | 设备树：格式、解析器、QEMU 给的内容、错误和限制 |
| [page-allocator.md](page-allocator.md) | 物理页分配器 |
| [paging.md](paging.md) | Sv39 分页：页表格式、建立映射、内核页表、用户地址空间 |
| [user-programs.md](user-programs.md) | 用户程序：运行时（`start.zig`、`sys.zig`）、示例程序、怎么写新程序 |
| [process.md](process.md) | 进程：进程表、ELF 加载器、xv6 式调度（`scheduler`/`sched`/`sleep`/`wakeup`）、切换上下文、结束进程和 `kill`、Ctrl-C |
| [syscalls.md](syscalls.md) | 系统调用：调用约定、调用列表、访问用户内存、怎么加新调用 |
| [shell.md](shell.md) | shell：输入处理、前台和后台进程、命令 |
| [testing.md](testing.md) | 测试与调试：单元测试、QEMU 测试（`tools/qemu_test.py`）、回归测试程序、QEMU 日志、GDB、症状速查 |
| [zig-0.17.md](zig-0.17.md) | Zig 0.17 和旧版本的差别，以及这个项目里踩过的坑 |

## 按源码文件

| 文件 | 主要文档 | 也涉及 |
| --- | --- | --- |
| `build.zig` | [build.md](build.md) | [user-programs.md](user-programs.md) |
| `linker.ld` | [boot.md](boot.md#链接脚本) | [paging.md](paging.md#内核页表) |
| `src/main.zig` | [boot.md](boot.md) | [process.md](process.md#调度器) |
| `src/riscv.zig` | [riscv-sbi.md](riscv-sbi.md) | |
| `src/sbi.zig` | [riscv-sbi.md](riscv-sbi.md#sbi-调用sbizig) | [devices.md](devices.md#定时器timerzig) |
| `src/trap.zig` | [trap.md](trap.md) | [process.md](process.md)、[syscalls.md](syscalls.md) |
| `src/uart.zig` | [devices.md](devices.md#串口uartzig) | [process.md](process.md#sleepwakeup) |
| `src/plic.zig` | [devices.md](devices.md#plicpliczig) | |
| `src/timer.zig` | [devices.md](devices.md#定时器timerzig) | |
| `src/dtb.zig` | [devicetree.md](devicetree.md) | |
| `src/page.zig` | [page-allocator.md](page-allocator.md) | |
| `src/vm.zig` | [paging.md](paging.md) | [syscalls.md](syscalls.md#访问用户内存) |
| `src/proc.zig` | [process.md](process.md) | |
| `src/syscall.zig` | [syscalls.md](syscalls.md) | |
| `src/abi.zig` | [syscalls.md](syscalls.md#abizig) | [build.md](build.md#用户程序) |
| `src/shell.zig` | [shell.md](shell.md) | [process.md](process.md#创建进程) |
| `user/start.zig` | [user-programs.md](user-programs.md#startzig) | |
| `user/sys.zig` | [user-programs.md](user-programs.md#syszig) | [syscalls.md](syscalls.md#用户态封装) |
| `user/linker.ld` | [build.md](build.md#用户程序的链接脚本) | [process.md](process.md#elf-加载器) |
| `user/hello.zig`、`user/fault.zig`、`user/spin.zig`、`user/ticker.zig` | [user-programs.md](user-programs.md#示例程序) | |
| `user/tests/*.zig`、`user/tests/noperm.ld` | [testing.md](testing.md#回归测试程序) | [build.md](build.md#用户程序) |
| `src/tests.zig` | [testing.md](testing.md#单元测试zig-build-test) | [build.md](build.md#单元测试) |
| `tools/qemu_test.py` | [testing.md](testing.md#qemu-测试toolsqemu_testpy) | |

## 修改记录

[changes.md](changes.md)：每次改动新增了什么功能、修了什么 bug。
