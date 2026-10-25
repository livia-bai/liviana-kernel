# CSR 和 SBI 调用

涉及文件：`src/riscv.zig`、`src/sbi.zig`

## CSR 访问（`riscv.zig`）

控制和状态寄存器（CSR）只能用专门的指令访问，地址在指令里编码，所以必须在编译期确定。内核里所有 CSR 操作都通过 `riscv.zig`，不在别处手写 `csrr`/`csrw`（陷阱入口出口等必须用汇编写的地方除外）。

### 用到的 CSR

`Csr` 枚举的名字就是汇编里的寄存器名，`@tagName(csr)` 直接拼进指令：

| CSR | 用途 | 用在哪里 |
| --- | --- | --- |
| `sstatus` | S 模式状态：全局中断使能 SIE、陷入前的特权级 SPP、陷入前的 SIE（SPIE）等 | 开关中断；陷阱时保存/恢复；构造进入 U 模式的状态 |
| `sie` | 各类 S 模式中断的使能位 | PLIC、定时器初始化时打开 SEIE、STIE |
| `sip` | 各类中断的挂起位 | 目前只在注释里提到（`wfi` 的唤醒条件） |
| `stvec` | 陷阱入口地址 + 模式 | `trap.init` |
| `sscratch` | 给陷阱处理程序用的暂存寄存器 | 进出 U 模式时存内核栈顶，见 [trap.md](trap.md#sscratch-约定) |
| `sepc` | 陷阱发生时的 PC | 陷阱入口保存、出口恢复；跳过 `ebreak`/`ecall` |
| `scause` | 陷阱原因：最高位区分中断/异常，低位是编号 | `handleTrap` 分发 |
| `stval` | 和陷阱相关的值：出错的地址，或非法指令的编码 | 打印异常信息 |
| `satp` | 分页模式 + 根页表的物理页号 | `vm.activate` |
| `time` | 只读计数器，按 timebase 频率递增 | 定时器预约下一次中断 |

新用到的 CSR 要加进这个枚举。

### 位定义

```zig
pub const sstatus_sie: usize = 1 << 1;  // S 模式全局中断使能
pub const sstatus_spie: usize = 1 << 5; // 陷入前的 SIE，sret 时恢复到 SIE
pub const sstatus_spp: usize = 1 << 8;  // 陷入前的特权级：0 = U，1 = S

pub const sie_ssie: usize = 1 << 1;     // 软件中断
pub const sie_stie: usize = 1 << 5;     // 时钟中断
pub const sie_seie: usize = 1 << 9;     // 外部中断（PLIC）

pub const satp_sv39: usize = 8 << 60;   // satp.MODE = 8 表示 Sv39
```

陷阱发生时硬件自动做的事：`SPIE ← SIE`、`SIE ← 0`、`SPP ← 陷入前的特权级`。`sret` 反过来：`SIE ← SPIE`、`SPIE ← 1`、特权级 ← `SPP`、`SPP ← 0`，然后跳到 `sepc`。内核正是利用这一点进入 U 模式：把 `SPP` 设成 0、`SPIE` 设成 1，`sret` 之后就在 U 模式运行并且开着中断（见 [process.md](process.md#run-的步骤)）。

`sstatus` 里还有几个这个内核刻意保持为 0 的位：`SUM`（为 1 时 S 模式可以访问 U 页，见 [syscalls.md](syscalls.md#访问用户内存)）、`MXR`、`FS`（浮点单元状态，没有浮点所以一直是 Off）。

### 函数

```zig
pub inline fn read(comptime csr: Csr) usize      // csrr
pub inline fn write(comptime csr: Csr, value: usize) void   // csrw
pub inline fn set(comptime csr: Csr, mask: usize) void      // csrs：mask 中为 1 的位置 1
pub inline fn clear(comptime csr: Csr, mask: usize) void    // csrc：mask 中为 1 的位清 0
pub inline fn enableInterrupts() void            // set(.sstatus, sstatus_sie)
pub inline fn disableInterrupts() void           // clear(.sstatus, sstatus_sie)
pub inline fn wfi() void
pub inline fn sfenceVma() void                   // sfence.vma zero, zero
```

- 全部是 `inline` 加 `comptime` CSR 参数：每次调用都直接展开成一条指令。
- 所有内联汇编都是 `asm volatile`，写操作都带 `.{ .memory = true }` clobber。`volatile` 防止编译器把“结果没被使用”的汇编删掉或合并；memory clobber 防止编译器把内存访问挪到 CSR 操作的另一边。例如关中断之后读环形缓冲区，读操作不能被提前到关中断之前。
- `read` 没有 memory clobber，但有 `volatile`，不会被删除或合并（`time` 每次读的值都不一样）。
- `wfi`：让 CPU 休眠直到有**使能的**中断挂起（看 `sie & sip`，不看 `sstatus.SIE`）。规范允许它随时返回，所以总是放在循环里使用。
- `sfenceVma`：不带参数的 `sfence.vma` 作废所有地址空间的所有 TLB 项。改了当前正在用的页表、或者写了 `satp` 之后都要执行（见 [paging.md](paging.md#切换地址空间)）。

## SBI 调用（`sbi.zig`）

SBI（Supervisor Binary Interface）是 S 模式软件请求 M 模式固件服务的接口，相当于“内核的系统调用”。调用约定：

| 寄存器 | 含义 |
| --- | --- |
| `a7` | 扩展号 EID |
| `a6` | 功能号 FID |
| `a0..a5` | 参数 |
| 返回 `a0` | 错误码（0 = 成功，负数为错误） |
| 返回 `a1` | 返回值 |

```zig
fn call(ext: Extension, fid: usize, arg0: usize, arg1: usize) Ret {
    var err: isize = undefined;
    var value: usize = undefined;
    asm volatile ("ecall"
        : [err] "={a0}" (err),
          [value] "={a1}" (value),
        : [eid] "{a7}" (@backingInt(ext)),
          [fid] "{a6}" (fid),
          [arg0] "{a0}" (arg0),
          [arg1] "{a1}" (arg1),
        : .{ .memory = true });
    return .{ .err = err, .value = value };
}
```

从 S 模式执行 `ecall` 产生的是“来自 S 模式的 ecall”（异常 9），这个异常没有委托给 S 模式，所以直接进入 M 模式由 OpenSBI 处理，不会经过内核的陷阱处理程序。用户程序的 `ecall`（异常 8）则委托给了 S 模式，进的是内核（见 [syscalls.md](syscalls.md)）。两者用的是同一条指令，靠当前特权级区分。

### 用到的扩展

| 扩展 | EID | 函数 | FID | 用途 |
| --- | --- | --- | --- | --- |
| Base | `0x10` | `get_spec_version` | 0 | `specVersion()`：返回值的 bit 24..30 是主版本号，低 24 位是次版本号 |
| Base | `0x10` | `get_impl_id` | 1 | `implName()`：0 BBL、1 OpenSBI、2 Xvisor、3 KVM、4 RustSBI、5 Diosix |
| TIME | `0x54494D45`（"TIME"） | `set_timer` | 0 | `setTimer(deadline)`：`time` 达到 `deadline` 时产生 S 模式时钟中断，同时清除当前挂起的时钟中断 |
| SRST | `0x53525354`（"SRST"） | `system_reset` | 0 | `shutdown()`：参数 type 0 = 关机，reason 0 = 无原因 |

- `setTimer` 是唯一能清除 S 模式时钟中断挂起位的办法（`sip.STIP` 对 S 模式只读），所以时钟中断处理程序每次都要调用它预约下一次，否则中断会一直挂着、处理程序返回后马上又进来。
- `shutdown` 成功时不返回，QEMU 退出且退出码为 0。如果固件不支持 SRST 扩展调用会返回，这时只能在 `wfi` 循环里停机。
- QEMU 的 CPU 支持 Sstc 扩展（横幅里的 `Boot HART ISA Extensions: time,sstc`），S 模式本可以直接写 `stimecmp` 设置定时器，这个内核为了简单和可移植仍然走 SBI。
