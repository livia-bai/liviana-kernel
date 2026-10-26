# 总体结构

这一篇从整体上介绍内核：谁运行在哪个特权级、物理内存和虚拟地址怎么分布、各模块之间的关系，以及几条主要的控制流。各部分的细节见对应的文档（[目录](README.md)）。

## 特权级

RISC-V 有三个特权级，这个项目三个都用到了：

| 特权级 | 运行的代码 | 负责的事 |
| --- | --- | --- |
| M（Machine，最高） | OpenSBI 固件（QEMU 自带，`-bios default`） | 上电初始化，把中断和部分异常委托给 S 模式，替 S 模式做它无权做的事：设置定时器、关机（通过 SBI 调用，见 [riscv-sbi.md](riscv-sbi.md)） |
| S（Supervisor） | 本内核（`src/`） | 陷阱处理、设备驱动、页表、加载和运行用户程序、系统调用 |
| U（User，最低） | 用户程序（`user/`） | 只能访问自己地址空间里带 U 位的页，要做任何别的事都得通过 `ecall` 请内核代办 |

内核从头到尾只在 S 模式运行，没有切到 M 模式的路径；需要 M 模式权限的操作都通过 `ecall` 交给 OpenSBI。

## 物理内存布局

QEMU `virt` 机器、`-m 128M` 时，和这个内核有关的物理地址如下（完整的设备列表可以用 `-machine virt,dumpdtb=virt.dtb` 导出设备树查看，见 [devicetree.md](devicetree.md)）：

| 物理地址 | 内容 | 内核怎么用 |
| --- | --- | --- |
| `0x0000_0000` 附近 | 没有设备 | 不映射，空指针解引用会触发缺页异常 |
| `0x0010_0000` | `sifive,test` 设备 | OpenSBI 用它关机/重启，内核不直接碰 |
| `0x0200_0000` | CLINT（核间中断、`mtime`） | 只有 M 模式能访问，内核不碰 |
| `0x0c00_0000..0x0c60_0000` | PLIC，6 MiB | 映射为 RW，见 [devices.md](devices.md) |
| `0x1000_0000..0x1000_0100` | NS16550A 串口 | 映射一页 RW |
| `0x8000_0000..0x8006_0000` | OpenSBI 自己的代码和数据 | 被 PMP 保护，S 模式无权访问；设备树里登记为保留内存 |
| `0x8020_0000` 起 | 内核镜像：`.text`、`.rodata`、`.data`、`.bss`、64 KiB 启动栈 | 按段设置权限，见 [paging.md](paging.md) |
| `__kernel_end..0x8800_0000` | 其余内存 | 交给页分配器（[page-allocator.md](page-allocator.md)）：页表、用户程序的页都从这里来 |
| `0x87e0_0000` 起约 5.3 KiB | OpenSBI 传给内核的设备树 | 页分配器跳过这些页，不会分配出去 |

内存的起点和大小、设备树的位置都是运行时从设备树里读出来的，上表是 QEMU 默认配置下的实测值。串口和 PLIC 的地址目前写死在代码里。

## 虚拟地址空间

内核开启 Sv39 分页后，有两种地址空间：

```
内核地址空间（vm.kernel_root）            用户进程的地址空间（每次 run 新建）
                                          
0x0c00_0000  PLIC        RW- (G)          0x0c00_0000  PLIC        RW- (G)  ┐
0x1000_0000  串口        RW- (G)          0x1000_0000  串口        RW- (G)  │ 和内核共用
                                          0x4000_0000  程序各段    U + R/W/X│ ← 根页表第 1 项，
                                          0x7fff_b000  保护页（不映射）    │   每个进程独有
                                          0x7fff_c000  用户栈 16K  U + RW-  │
0x8020_0000  内核镜像    R-X/R--/RW- (G)  0x8020_0000  内核镜像    同左     │ 和内核共用
内核之后     其余内存    RW- (G)          内核之后     其余内存    同左     ┘
```

- 内核的映射都是恒等映射（虚拟地址 = 物理地址），都不带 U 位、都带 G（全局）位。
- 用户空间固定是 Sv39 根页表第 1 项覆盖的 `0x4000_0000..0x8000_0000`（1 GiB）。内核的映射都不在这一项里，所以新建进程地址空间时只复制一份内核根页表，下面的页表全部共用。陷入内核时不用切换页表：内核代码在用户地址空间里照样能执行，U 模式只是访问不到它们。

为什么选根页表第 1 项、为什么用户映射不能用大页等细节见 [paging.md](paging.md) 和 [process.md](process.md)。

## 模块和依赖

```
main.zig ─┬─ uart.zig ──────────── 串口输出、键盘输入缓冲、Ctrl-C
          ├─ sbi.zig ───────────── ecall 到 OpenSBI
          ├─ trap.zig ─┬─ timer.zig、plic.zig、uart.zig（中断）
          │            ├─ syscall.zig ─── abi.zig、vm.zig、proc.zig
          │            └─ proc.zig（杀进程）
          ├─ dtb.zig ───────────── 设备树
          ├─ page.zig ──────────── 物理页
          ├─ vm.zig ────────────── 页表（用 page.zig 分配页表）
          ├─ plic.zig、timer.zig
          └─ shell.zig ─┬─ page.zig（mem 命令）
                        └─ proc.zig ─── vm.zig、trap.zig（进出 U 模式）、build_options + 嵌入的用户程序

user/start.zig ─┬─ user/sys.zig ─── src/abi.zig（与内核共用的系统调用约定）
                └─ user/<程序>.zig ─── user/sys.zig
```

`riscv.zig`（CSR 读写）几乎被所有内核模块用到，图里省略了。

## 主要控制流

**启动**（[boot.md](boot.md)）：OpenSBI → `_start`（设栈、清 `.bss`）→ `kmain`：关浮点单元 → 串口 → 陷阱向量 → 设备树 → 页分配器 → 内核页表、开分页 → PLIC 和定时器 → 开中断 → shell 主循环。

**主循环**：关中断 → 从串口缓冲区取一个字符 → 没有就 `wfi` 休眠 → 开中断（挂起的中断在这一刻被处理）→ 有字符就交给 shell。

**中断**（[trap.md](trap.md)、[devices.md](devices.md)）：硬件跳到 `trap.trapEntry` → 压 `TrapFrame` → `handleTrap` 按 `scause` 分发：时钟中断让 `ticks` 加 1 并预约下一次；外部中断向 PLIC 领取中断号，串口中断把字符搬进环形缓冲区 → `trapExit` 恢复寄存器、`sret`。

**运行用户程序**（[process.md](process.md)）：shell 的 `run NAME` → `proc.run`：新建地址空间、加载 ELF、映射栈 → 在进程内核栈顶构造 `TrapFrame` → 保存 shell 的上下文 → 走 `trapExit` 进入 U 模式。

**系统调用**（[syscalls.md](syscalls.md)）：用户程序 `ecall` → `trapEntry` 通过 `sscratch` 换到内核栈 → `handleTrap` → `syscall.dispatch` → 返回值写进 `TrapFrame` 的 `a0` → `trapExit` 回到 U 模式。

**进程结束**：`exit` 系统调用、U 模式下的任何其他异常、或者运行期间按 Ctrl-C → `proc.exit` / `proc.kill` 打印原因 → `switchBack` 恢复 shell 的上下文 → `proc.run` 像普通函数一样返回：切回内核页表，释放进程的全部内存 → 回到 shell。

## 全局不变量

改代码时要守住的几条约定，详细原因见各篇文档：

- 内核在 S 模式时 `sscratch` 为 0；在 U 模式运行时 `sscratch` 存着进程内核栈顶（[trap.md](trap.md)）。
- 陷阱处理和系统调用全程关着中断（`sstatus.SIE = 0`），所以中断只会打断 shell 或 U 模式，不会嵌套（[trap.md](trap.md)）。
- 用户程序只能用根页表第 1 项；内核的映射不能放进 `0x4000_0000..0x8000_0000`（[paging.md](paging.md)）。
- 内核从不直接解引用用户给的指针，`sstatus.SUM` 始终为 0，访问用户内存一律走 `vm.copyFromUser`（[syscalls.md](syscalls.md)）。
- `TrapFrame` 的布局和 `trapEntry`/`trapExit` 的汇编绑在一起；`proc.Context` 和 `proc.contextAsm` 绑在一起。
- 内核和用户程序都不用浮点（目标是 rv64imac），陷阱处理不保存浮点寄存器；`sstatus.FS` 在启动时清成 Off，手写的浮点指令也会触发非法指令异常（[build.md](build.md)）。
