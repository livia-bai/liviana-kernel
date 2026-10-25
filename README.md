# liviana-kernel

用 Zig 0.17 写的最小 RISC-V 64 位内核，运行在 QEMU `virt` 机器上，由 OpenSBI 引导。

功能：串口输出、陷阱（异常 + 中断）处理、解析设备树、物理页分配、Sv39 分页、时钟中断、键盘（串口）中断输入、U 模式用户程序和系统调用，外加一个能执行几条命令的小 shell。

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
> uptime
up 3.26s (326 timer interrupts)
> mem
32052 of 32057 pages free (128208 KiB), 4 KiB each
> run
programs: hello fault spin
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
> crash

!!! KERNEL PANIC: unhandled exception: load_page_fault (scause=13), sepc=0x8021656c, stval=0x0
system halted.
```

## 运行

需要 Zig **0.17.0** 和 `qemu-system-riscv64`（Debian/Ubuntu 包名 `qemu-system-misc`，自带 OpenSBI 固件）。

```sh
zig build run                     # 编译并在 QEMU 中启动（Debug 模式）
zig build run -Doptimize=small    # 体积优化，内核代码段约 12.8 KB
```

退出 QEMU：先按 `Ctrl-A`，再按 `X`；或者在 shell 里输入 `shutdown`。

shell 命令：

| 命令 | 作用 |
| --- | --- |
| `help` | 列出命令 |
| `uptime` | 开机时长，由时钟中断计数得出 |
| `mem` | 物理页的使用情况 |
| `run NAME` | 在 U 模式运行用户程序 `NAME`，等它结束；不带参数时列出所有程序 |
| `ebreak` | 触发断点异常，处理后恢复执行 |
| `crash` | 读地址 0（没有映射），触发无法处理的缺页异常，进入 panic |
| `shutdown` | 通过 SBI 关机，QEMU 随之退出 |

## 启动流程

1. QEMU 上电，执行 OpenSBI（M 模式，最高特权级）。OpenSBI 初始化硬件后切到 S 模式，跳到 `0x80200000`。
2. `_start`（`src/main.zig`）：设置栈指针、清零 `.bss`，然后跳到 `kmain`。此时 `a0` = hart 编号，`a1` = 设备树地址。
3. `kmain`：初始化串口 → 安装陷阱向量 `stvec` → 用 `ebreak` 自检 → 解析设备树 → 初始化页分配器 → 建内核页表、打开 Sv39 分页 → 配置 PLIC 和定时器 → 打开中断 → 进入主循环。
4. 主循环大部分时间停在 `wfi` 休眠；时钟或键盘中断把它唤醒。shell 执行 `run` 时，主循环一直停在这条命令里，直到用户程序结束。

## 文件结构

| 文件 | 内容 |
| --- | --- |
| `build.zig` | 目标平台（riscv64-freestanding，rv64imac）、链接脚本、编译并嵌入用户程序、`run` 步骤 |
| `linker.ld` | 内存布局：代码从 `0x80200000` 开始，各段按 4 KiB 对齐，`.bss` 后面是 64 KiB 内核栈 |
| `src/main.zig` | `_start` 入口、`kmain`、panic 处理 |
| `src/riscv.zig` | CSR 读写、开关中断、`wfi`、`sfence.vma` |
| `src/sbi.zig` | SBI 调用：版本查询、设置定时器、关机 |
| `src/dtb.zig` | 设备树解析：内存范围、时钟频率、保留内存 |
| `src/page.zig` | 物理页分配器：空闲页串成单链表 |
| `src/vm.zig` | Sv39 页表：建立映射、内核恒等映射、打开分页 |
| `src/uart.zig` | NS16550A 串口驱动 + 接收环形缓冲区 + `std.Io.Writer` 适配 |
| `src/trap.zig` | 陷阱入口/出口汇编（切换内核栈、保存/恢复寄存器）和分发 |
| `src/abi.zig` | 系统调用号和错误码，内核和用户程序共用 |
| `src/proc.zig` | 用户进程：加载 ELF、建用户地址空间、进出 U 模式、exit/kill |
| `src/syscall.zig` | 系统调用分发和实现 |
| `src/plic.zig` | 外部中断控制器，把串口中断送给 CPU |
| `src/timer.zig` | 每 10 ms 一次的时钟中断，`time` 的频率来自设备树 |
| `src/shell.zig` | 逐字符读输入、回显、执行命令 |
| `user/linker.ld` | 用户程序的内存布局：从 `0x40000000` 开始，代码、只读数据、数据各占一个按页对齐的段 |
| `user/start.zig` | 每个用户程序的根文件（相当于 crt0）：`_start` 入口、panic 处理 |
| `user/sys.zig` | 用户态的系统调用封装和 `print` |
| `user/hello.zig` 等 | 用户程序本身，见下面的“用户程序和系统调用” |

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

这些内核映射都不带 U 位，U 模式碰不到。用户程序的地址空间见下一节。

## 用户程序和系统调用

**编译和嵌入**：`user/` 下的每个程序（`hello`、`fault`、`spin`）都以 `user/start.zig` 为根文件、程序本身作为 `program` 模块，单独编译成一个 ELF，链接到 `0x40000000`。`build.zig` 再把这些 ELF 作为匿名模块交给内核，内核里用 `@embedFile` 拿到它们的字节，相当于一个编译进内核的小文件系统。新增程序时，在 `build.zig` 的 `user_programs` 列表里加上名字即可。

**地址空间**：Sv39 根页表的第 1 项（`0x4000_0000..0x8000_0000`，1 GiB）专门留给用户程序，内核的映射都不落在这一项里（外设在第 0 项，内存从第 2 项开始）。所以 `run` 新建地址空间时只要复制一份内核的根页表，下面的页表全部共用；陷入内核时也不用切换页表，内核代码照样能执行，只是 U 模式访问不到它们。

| 用户地址 | 内容 | 权限 |
| --- | --- | --- |
| `0x40000000` 起 | ELF 的代码段 / 只读数据段 / 数据段（含 `.bss`） | `R-X` / `R--` / `RW-`，按 ELF 程序头 |
| `0x7fffb000` | 保护页，不映射：栈溢出时触发缺页异常 | — |
| `0x7fffc000..0x80000000` | 16 KiB 用户栈 | `RW-` |

加载器检查 ELF 头和每个程序头（段要页对齐、在用户区内、在保护页之下、必须可读、文件内容不越界），按页分配物理内存、复制文件内容，剩下的部分（`.bss`）保持清零。

**进出 U 模式**：`proc.run` 在一块进程专用的内核栈顶上构造一个 `TrapFrame`（`sepc` = 入口地址，`sp` = 用户栈顶，`sstatus.SPP` = 0 表示 U 模式），保存 shell 的上下文（`ra`、`sp`、`s0..s11`），然后走和陷阱返回同一段代码 `trap.trapExit`，`sret` 进入用户程序。用户程序结束（`exit`、出异常、被 Ctrl-C 打断）时，内核恢复保存的上下文，`run` 就像普通函数一样返回到 shell。

从 U 模式陷入时 `sp` 还是用户栈，不能用。约定：在 U 模式运行时 `sscratch` 存着内核栈顶，在内核里时为 0。`trapEntry` 第一条指令交换 `sp` 和 `sscratch`，交换后 `sp` 不为 0 就说明来自 U 模式、已经换到内核栈；为 0 说明来自内核，再把原来的 `sp` 取回来。`trapExit` 发现要回到 U 模式时，再把内核栈顶写回 `sscratch`。

**系统调用**：用户程序把调用号放进 `a7`、参数放进 `a0..a5`，执行 `ecall`；内核把返回值写回 `a0`，`sepc` 加 4 跳过 `ecall`。负的返回值是错误码的相反数（编号沿用 Linux）。

| 号 | 调用 | 作用 |
| --- | --- | --- |
| 0 | `exit(code)` | 结束进程，`code` 是退出码 |
| 1 | `write(ptr, len)` | 把用户内存里的字节输出到串口，返回写出的字节数；指针无效返回 `-14`（EFAULT） |
| 2 | `getpid()` | 进程号，每次 `run` 加 1 |
| 3 | `uptime()` | 开机以来的毫秒数 |

其他调用号返回 `-38`（ENOSYS）。内核从不直接解引用用户给的指针（`sstatus.SUM` 始终为 0）：`write` 逐页查用户页表，确认这一页属于用户空间、带 U 位、可读，再通过恒等映射从物理地址读，所以传内核地址进来只会得到 EFAULT。

**保护**：用户程序出了任何异常（缺页、非法指令、在 U 模式读写 CSR 等），内核打印原因并结束这个进程，然后照常回到 shell。用户程序就算死循环，时钟和串口中断照样会打断它；串口中断处理程序看到 Ctrl-C 就记下来，陷阱处理程序在返回 U 模式前检查，结束进程。

演示程序：

- `hello`：打招呼，调用 `getpid`、`uptime`，再故意把内核地址传给 `write`，看它被拒绝。
- `fault`：直接读内核内存 `0x80200000`，触发缺页异常被杀掉。
- `spin`：不做系统调用的死循环，按 Ctrl-C 结束。

一次只运行一个进程，没有调度：`run` 会一直等到程序结束。运行用户程序期间，内核代码（陷阱处理、系统调用）都是关着中断执行的，中断只会打断 U 模式。

## 中断是怎么走的

- **时钟**：`sbi.setTimer(deadline)` 请 OpenSBI 预约一次中断，到点后 CPU 收到 S 模式时钟中断（`scause` = 中断 5）。处理程序把 `ticks` 加 1，再预约下一次。
- **键盘**：串口收到字符 → 拉高 10 号中断线 → PLIC 转成 S 模式外部中断（`scause` = 中断 9）→ 处理程序向 PLIC `claim` 领取中断号，把字符搬进环形缓冲区，再 `complete`。主循环从缓冲区取字符交给 shell。
- **异常**：`ebreak` 之类的指令会直接产生陷阱（`scause` 最高位为 0）。断点异常处理完把 `sepc` 加上指令长度跳过去；其他异常无法恢复，直接 panic。

所有陷阱都先进入 `trap.trapEntry`：必要时换到内核栈（见上一节），在栈上压一个 `TrapFrame`（31 个通用寄存器 + `sepc` + `sstatus`），调用 Zig 写的 `handleTrap`，返回后由 `trap.trapExit` 恢复寄存器并执行 `sret`。保存/恢复寄存器的 60 条指令是用 `comptime` 在编译期生成的。

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
- 裸函数（`callconv(.naked)`）不能直接调用。`proc.zig` 里是在内联汇编中 `call` 它，并把调用者保存的寄存器都声明为 clobber，编译器不会对它做任何假设。如果转成函数指针来调，签名必须如实：调用之后还会回来的裸函数被声明成 `noreturn`，release 模式下调用之后的代码会被整个删掉。
- 0.17.0 有一个 x86 软浮点下 compiler-rt 编译失败的回归（#37006），只影响 x86 目标，这里的 RISC-V 目标不受影响。

## 可以继续做的方向

- 多进程：每个进程一块内核栈，在时钟中断里切换，实现抢占式调度
- 更多系统调用：阻塞读键盘的 `read`、`sleep`，以及用户程序自己申请内存
- 多核：用 SBI HSM 扩展启动其他 hart
