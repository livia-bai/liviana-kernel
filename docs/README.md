# 文档目录

liviana-kernel 的详细文档，按功能组织。仓库根目录的 [README.md](../README.md) 只有简介和上手步骤，[AGENTS.md](../AGENTS.md) 是给代码代理（以及任何改代码的人）的工作规则。

## 按功能

建议按这个顺序读：

| 文档 | 内容 |
| --- | --- |
| [architecture.md](architecture.md) | 总体结构：特权级、物理内存布局、虚拟地址空间、模块关系、主要控制流、全局不变量 |
| [build.md](build.md) | 构建系统：目标平台、优化模式、用户程序的编译和嵌入、QEMU 运行步骤 |
| [boot.md](boot.md) | 启动流程：OpenSBI 交接、链接脚本、`_start`、`kmain` 的初始化顺序、主循环、panic 处理 |
| [riscv-sbi.md](riscv-sbi.md) | CSR 访问和 SBI 调用 |
| [trap.md](trap.md) | 陷阱处理：异常委托、`TrapFrame`、`sscratch` 约定、入口/出口汇编、分发 |
| [devices.md](devices.md) | 串口（含输入缓冲区和 Ctrl-C）、PLIC、定时器 |
| [devicetree.md](devicetree.md) | 设备树：格式、解析器、QEMU 给的内容、错误和限制 |
| [page-allocator.md](page-allocator.md) | 物理页分配器 |
| [paging.md](paging.md) | Sv39 分页：页表格式、建立映射、内核页表、用户地址空间 |
| [user-programs.md](user-programs.md) | 用户程序：运行时（`start.zig`、`sys.zig`）、示例程序、怎么写新程序 |
| [process.md](process.md) | 进程：ELF 加载器、进出 U 模式、结束进程、Ctrl-C |
| [syscalls.md](syscalls.md) | 系统调用：调用约定、调用列表、访问用户内存、怎么加新调用 |
| [shell.md](shell.md) | shell：输入处理、命令 |
| [testing.md](testing.md) | 测试与调试：必做检查、标准测试脚本、边界情况、QEMU 日志、GDB、症状速查 |
| [zig-0.17.md](zig-0.17.md) | Zig 0.17 和旧版本的差别，以及这个项目里踩过的坑 |

## 按源码文件

| 文件 | 主要文档 | 也涉及 |
| --- | --- | --- |
| `build.zig` | [build.md](build.md) | [user-programs.md](user-programs.md) |
| `linker.ld` | [boot.md](boot.md#链接脚本) | [paging.md](paging.md#内核页表) |
| `src/main.zig` | [boot.md](boot.md) | |
| `src/riscv.zig` | [riscv-sbi.md](riscv-sbi.md) | |
| `src/sbi.zig` | [riscv-sbi.md](riscv-sbi.md#sbi-调用sbizig) | [devices.md](devices.md#定时器timerzig) |
| `src/trap.zig` | [trap.md](trap.md) | [process.md](process.md)、[syscalls.md](syscalls.md) |
| `src/uart.zig` | [devices.md](devices.md#串口uartzig) | |
| `src/plic.zig` | [devices.md](devices.md#plicpliczig) | |
| `src/timer.zig` | [devices.md](devices.md#定时器timerzig) | |
| `src/dtb.zig` | [devicetree.md](devicetree.md) | |
| `src/page.zig` | [page-allocator.md](page-allocator.md) | |
| `src/vm.zig` | [paging.md](paging.md) | [syscalls.md](syscalls.md#访问用户内存) |
| `src/proc.zig` | [process.md](process.md) | |
| `src/syscall.zig` | [syscalls.md](syscalls.md) | |
| `src/abi.zig` | [syscalls.md](syscalls.md#abizig) | [build.md](build.md#用户程序) |
| `src/shell.zig` | [shell.md](shell.md) | |
| `user/start.zig` | [user-programs.md](user-programs.md#startzig) | |
| `user/sys.zig` | [user-programs.md](user-programs.md#syszig) | [syscalls.md](syscalls.md#用户态封装) |
| `user/linker.ld` | [build.md](build.md#用户程序的链接脚本) | [process.md](process.md#elf-加载器) |
| `user/hello.zig`、`user/fault.zig`、`user/spin.zig` | [user-programs.md](user-programs.md#示例程序) | |
| `tools/check_links.py` | [testing.md](testing.md#必做的检查) | |

## 修改与验错记录

[changes/](changes/README.md)：每一次改动一篇记录，写明改了什么、为什么这样设计、怎么验证的、测试中发现了哪些问题以及如何修复。想知道某段代码为什么写成现在这样，先去那里找。写记录的规则见 [AGENTS.md](../AGENTS.md#修改与验错记录)。

## 维护文档

- 改了代码就同步改对应的文档（上表）。文档里的实测数字（地址、页数、体积）会随代码变化，大的变化要更新，小的漂移可以不管，但不要留下错误的说法。
- 文档里写的命令、输出、结论都应该是实际验证过的；没验证的推测要明确标出来。
- 文档用中文，代码、命令、内核输出保持原样（英文）。
- 改完运行 `python3 tools/check_links.py` 检查链接和锚点。
