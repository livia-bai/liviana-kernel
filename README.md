# liviana-kernel

用 Zig 0.17 写的最小 RISC-V 64 位内核，运行在 QEMU `virt` 机器上，由 OpenSBI 引导。

功能：串口输出、陷阱（异常 + 中断）处理、解析设备树、物理页分配、Sv39 分页、时钟中断、键盘（串口）中断输入，外加一个能执行几条命令的小 shell。

```
Hello from a Zig kernel on RISC-V!
SBI: OpenSBI, spec v1.0 | hart 0 | device tree at 0x87e00000
[ok] trap vector installed
[trap] breakpoint at 0x80215d34, skipping it
[ok] device tree: 128 MiB RAM at 0x80000000, timebase 10000000 Hz
[ok] page allocator: 32138 free pages (128552 KiB)
[ok] Sv39 paging enabled: kernel mapped 1:1, text r-x, rodata r--, data rw-
[ok] interrupts enabled: timer at 100 Hz, keyboard via UART + PLIC
Type 'help' for commands.
> uptime
up 3.26s (326 timer interrupts)
> mem
32133 of 32138 pages free (128532 KiB), 4 KiB each
> crash

!!! KERNEL PANIC: unhandled exception: load_page_fault (scause=13), sepc=0x80216472, stval=0x0
system halted.
```

## 运行

需要 Zig **0.17.0** 和 `qemu-system-riscv64`（Debian/Ubuntu 包名 `qemu-system-misc`，自带 OpenSBI 固件）。

```sh
zig build run                     # 编译并在 QEMU 中启动（Debug 模式）
zig build run -Doptimize=small    # 体积优化，代码段约 9.3 KB
```

退出 QEMU：先按 `Ctrl-A`，再按 `X`；或者在 shell 里输入 `shutdown`。

shell 命令：

| 命令 | 作用 |
| --- | --- |
| `help` | 列出命令 |
| `uptime` | 开机时长，由时钟中断计数得出 |
| `mem` | 物理页的使用情况 |
| `ebreak` | 触发断点异常，处理后恢复执行 |
| `crash` | 读地址 0（没有映射），触发无法处理的缺页异常，进入 panic |
| `shutdown` | 通过 SBI 关机，QEMU 随之退出 |

## 启动流程

1. QEMU 上电，执行 OpenSBI（M 模式，最高特权级）。OpenSBI 初始化硬件后切到 S 模式，跳到 `0x80200000`。
2. `_start`（`src/main.zig`）：设置栈指针、清零 `.bss`，然后跳到 `kmain`。此时 `a0` = hart 编号，`a1` = 设备树地址。
3. `kmain`：初始化串口 → 安装陷阱向量 `stvec` → 用 `ebreak` 自检 → 解析设备树 → 初始化页分配器 → 建内核页表、打开 Sv39 分页 → 配置 PLIC 和定时器 → 打开中断 → 进入主循环。
4. 主循环大部分时间停在 `wfi` 休眠；时钟或键盘中断把它唤醒。

## 文件结构

| 文件 | 内容 |
| --- | --- |
| `build.zig` | 目标平台（riscv64-freestanding，rv64imac）、链接脚本、`run` 步骤 |
| `linker.ld` | 内存布局：代码从 `0x80200000` 开始，各段按 4 KiB 对齐，`.bss` 后面是 64 KiB 内核栈 |
| `src/main.zig` | `_start` 入口、`kmain`、panic 处理 |
| `src/riscv.zig` | CSR 读写、开关中断、`wfi`、`sfence.vma` |
| `src/sbi.zig` | SBI 调用：版本查询、设置定时器、关机 |
| `src/dtb.zig` | 设备树解析：内存范围、时钟频率、保留内存 |
| `src/page.zig` | 物理页分配器：空闲页串成单链表 |
| `src/vm.zig` | Sv39 页表：建立映射、内核恒等映射、打开分页 |
| `src/uart.zig` | NS16550A 串口驱动 + 接收环形缓冲区 + `std.Io.Writer` 适配 |
| `src/trap.zig` | 陷阱入口汇编（保存/恢复寄存器）和分发 |
| `src/plic.zig` | 外部中断控制器，把串口中断送给 CPU |
| `src/timer.zig` | 每 10 ms 一次的时钟中断，`time` 的频率来自设备树 |
| `src/shell.zig` | 逐字符读输入、回显、执行命令 |

## 设备树

OpenSBI 把设备树（DTB）的物理地址放在 `a1` 里交给内核。`dtb.zig` 按 Devicetree 规范第 5 章的格式遍历它，取出：

- `memory` 节点（`device_type = "memory"`）的 `reg`：物理内存的起点和大小。`reg` 的格式由父节点的 `#address-cells` / `#size-cells` 决定，QEMU virt 上都是 2，也就是 64 位地址 + 64 位长度。
- `/cpus` 的 `timebase-frequency`：`time` CSR 每秒增加多少，定时器按它换算 10 ms 是多少个计数。
- 不能用的内存：设备树自己占的空间、内存保留块里的条目、`/reserved-memory` 的子节点（OpenSBI 在这里登记了自己占用的 `0x80000000..0x80060000`）。

设备树是固件给的数据，解析时每次读取都检查边界，格式不对就返回错误、内核 panic，不会读到范围外面去。外设地址（串口、PLIC）和中断号目前仍按 QEMU virt 写死。

## 内存管理

**物理页分配器**（`page.zig`）：内核镜像结束（`__kernel_end`）到内存末尾之间、不在保留区里的每一页（4 KiB）都串进一个单链表，链表节点就存在空闲页自己的开头，不占额外内存。分配从表头取一页并清零，释放插回表头，都是 O(1)。只能一页一页地分配，没有连续多页的分配。

**Sv39 分页**（`vm.zig`）：39 位虚拟地址分成三段 9 位的页号加 12 位页内偏移，对应三级页表；每张页表 512 项、正好一页。查表时遇到 R/W/X 任一位为 1 的项就是叶子：在最后一级是 4 KiB 的页，在中间两级就是 2 MiB 或 1 GiB 的大页。

内核页表把内存和外设都按“虚拟地址 = 物理地址”恒等映射，所以写 `satp` 打开分页的那一刻，正在执行的代码地址不变，页分配器给出的物理地址也能继续直接当指针用。内核镜像按段设置权限（这就是 `linker.ld` 里各段按 4 KiB 对齐的原因）：

| 范围 | 权限 |
| --- | --- |
| `.text` | 读 + 执行 |
| `.rodata`（含 `.eh_frame`） | 只读 |
| `.data`、`.bss`、内核栈 | 读 + 写 |
| 内核之后的所有内存 | 读 + 写 |
| 串口、PLIC | 读 + 写 |

所以往代码段写数据、跳到数据段执行，都会触发缺页异常。内核之前的 `0x80000000..0x80200000` 是 OpenSBI，本来就被 PMP 挡住，不映射；地址 0 附近也没有映射，空指针解引用会变成缺页异常。映射时只要对齐条件允许就用大页，128 MiB 内存和 6 MiB 的 PLIC 区域主要是 2 MiB 大页，整个内核页表只用了 5 页。

## 中断是怎么走的

- **时钟**：`sbi.setTimer(deadline)` 请 OpenSBI 预约一次中断，到点后 CPU 收到 S 模式时钟中断（`scause` = 中断 5）。处理程序把 `ticks` 加 1，再预约下一次。
- **键盘**：串口收到字符 → 拉高 10 号中断线 → PLIC 转成 S 模式外部中断（`scause` = 中断 9）→ 处理程序向 PLIC `claim` 领取中断号，把字符搬进环形缓冲区，再 `complete`。主循环从缓冲区取字符交给 shell。
- **异常**：`ebreak` 之类的指令会直接产生陷阱（`scause` 最高位为 0）。断点异常处理完把 `sepc` 加上指令长度跳过去；其他异常无法恢复，直接 panic。

所有陷阱都先进入 `trap.trapEntry`：它在栈上压一个 `TrapFrame`（31 个通用寄存器 + `sepc` + `sstatus`），调用 Zig 写的 `handleTrap`，返回后恢复寄存器并执行 `sret`。保存/恢复寄存器的 62 条指令是用 `comptime` 在编译期生成的。

如果熟悉 x86：`stvec` 相当于 IDT，PLIC 相当于 PIC/APIC，SBI 定时器相当于 PIT。RISC-V 没有 GDT 这类分段机制，不需要设置。

## Zig 0.17 需要注意的地方

写这个项目时对照了 0.17.0 的语言参考和 0.16/0.17 的 release notes，以下几点和旧教程不同：

- `std.builtin` 改名为 `std.lang`（旧名称已弃用）。
- `@intFromEnum` / `@enumFromInt` 已弃用，改用 `@backingInt` / `@fromBackingInt`（`uart.zig`、`sbi.zig`、`trap.zig` 里有用到）。
- 优化模式改成小写：`-Doptimize=debug|safe|fast|small`（以前是 `Debug/ReleaseSafe/...`）。
- 构建脚本：`addArtifactArg` → `addArtifactArg2`，`if (b.args) |args| run.addArgs(args)` → `run.addPassthruArgs()`。
- 内联汇编的 clobber 写成结构体：`.{ .memory = true }`。
- 自定义 panic：在根文件写 `pub const panic = std.debug.FullPanic(fn)`。必须是 `pub`，因为 0.17 起 `@hasDecl` 只认公开声明。0.17.0 里 `std.debug.simple_panic` 有已知回归（#36986），不要用。
- `std.Io.Writer` 是新的输出接口，自己实现一个 `drain` 函数就能直接用标准库的格式化输出。
- 0.17.0 有一个 x86 软浮点下 compiler-rt 编译失败的回归（#37006），只影响 x86 目标，这里的 RISC-V 目标不受影响。

## 可以继续做的方向

- U 模式用户程序 + 系统调用（`ecall` 从 U 模式陷入）
- 多核：用 SBI HSM 扩展启动其他 hart
