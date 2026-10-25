# 陷阱处理

涉及文件：`src/trap.zig`（以及调用它的 `src/proc.zig`、`src/syscall.zig`）

RISC-V 把同步的**异常**（非法指令、缺页、`ebreak`、`ecall` 等）和异步的**中断**（时钟、外设）统称为陷阱（trap）。陷阱发生时 CPU 跳到 `stvec` 指向的地址，相当于 x86 上 IDT 的角色，但只有一个入口，由软件读 `scause` 自己分发。

## 硬件做了什么

S 模式陷阱发生时，硬件自动：

1. `sepc` ← 被打断的指令地址（异常时是出错的那条指令；中断时是下一条将要执行的指令）
2. `scause` ← 原因：最高位 1 = 中断、0 = 异常，低位是编号
3. `stval` ← 附加信息：缺页/访问错误时是出错的地址，非法指令时是指令编码，其他情况一般是 0
4. `sstatus.SPP` ← 陷入前的特权级（0 = U，1 = S）；`sstatus.SPIE` ← `sstatus.SIE`；`sstatus.SIE` ← 0（关中断）
5. 切到 S 模式，PC ← `stvec`（Direct 模式下所有陷阱都是同一个地址）

除此之外**什么都不保存**：所有通用寄存器（包括 `sp`）都还是被打断时的值，保存和切栈全靠软件。

`sret` 做相反的事：特权级 ← `SPP`，`SIE` ← `SPIE`，`SPIE` ← 1，`SPP` ← 0，PC ← `sepc`。

## 异常委托

默认所有陷阱都进 M 模式。OpenSBI 通过 `medeleg`/`mideleg` 把一部分直接交给 S 模式，启动横幅里打印了它们的值：

**`MIDELEG = 0x1666`**：S 模式软件中断（1）、时钟中断（5）、外部中断（9），以及虚拟化相关的 2、6、10、12 位。内核用到的三类中断都直接进 S 模式。

**`MEDELEG = 0xf0b509`**：

| 编号 | 异常 | 委托？ |
| --- | --- | --- |
| 0 | 指令地址不对齐 | 是 |
| 1 | 取指访问错误 | 否 |
| 2 | 非法指令 | 否 |
| 3 | 断点（`ebreak`） | 是 |
| 4 / 6 | 读 / 写地址不对齐 | 否（OpenSBI 用软件模拟不对齐访问） |
| 5 / 7 | 读 / 写访问错误 | 否 |
| 8 | 来自 U 模式的 `ecall` | 是 |
| 9 | 来自 S 模式的 `ecall` | 否（这就是 SBI 调用，见 [riscv-sbi.md](riscv-sbi.md#sbi-调用sbizig)） |
| 12 / 13 / 15 | 取指 / 读 / 写缺页 | 是 |

没有委托的异常先进 M 模式，OpenSBI 能处理的自己处理（例如模拟不对齐访问），处理不了的原样转交给 S 模式，所以内核照样能看到它们。实测：用户程序在 U 模式执行 `csrr sstatus` 产生的非法指令异常，内核收到的 `scause = 2`、`stval` 是那条指令的编码。

## TrapFrame

```zig
pub const TrapFrame = extern struct {
    regs: [32]usize,   // regs[i] 就是 xi；x0 恒为 0，它的槽位不用
    sepc: usize,
    sstatus: usize,
};
```

| 偏移（字节） | 内容 |
| --- | --- |
| 0 | x0 的槽位（不保存，内容无意义） |
| 8 | x1 = `ra` |
| 16 | x2 = `sp`（被打断时的值，单独保存） |
| 24..248 | x3..x31（`gp`、`tp`、`t0..t6`、`s0..s11`、`a0..a7`），`regs[i]` 在 `8 * i` |
| 256 | `sepc` |
| 264 | `sstatus` |

总大小 272 字节，是 16 的倍数，压栈后 `sp` 仍满足 RISC-V 调用约定要求的 16 字节对齐。

**布局和汇编绑在一起**：`trapEntry`、`trapExit` 按偏移读写这个结构。汇编里用到的偏移通过 `@sizeOf`/`@offsetOf` 在编译期算出（`asm_offsets`），寄存器的保存/恢复指令由 `regsAsm` 在编译期生成（`x1`、`x3..x31` 各一条，共 30 条存 + 30 条取），所以改字段顺序不会悄悄错位，但增删字段时仍要检查两段汇编的逻辑（比如 `sp` 的特殊处理）。系统调用处理程序通过 `regs[10]`（`a0`）..`regs[17]`（`a7`）读参数、写返回值。

## sscratch 约定

陷阱可能来自 S 模式（内核自己被中断打断、或内核代码出了异常），也可能来自 U 模式（用户程序）。来自 U 模式时 `sp` 是用户栈：既不可信（用户可以把它设成任何值），内核也不应该往用户内存里写东西。所以要先换到内核栈，而换栈之前不能动任何通用寄存器（它们都还没保存）。

办法是用 `sscratch` 暂存：

- 在内核里（S 模式）运行时，`sscratch` = 0。
- 在 U 模式运行时，`sscratch` = 当前进程内核栈的栈顶。

`trap.init` 把 `sscratch` 清零（固件不保证它的初值）；之后由 `trapEntry`/`trapExit` 维护这个约定。

## trapEntry

```asm
csrrw sp, sscratch, sp      # 交换 sp 和 sscratch
bnez  sp, 1f                # 交换后 sp != 0：来自 U 模式，sp 已经是内核栈顶
csrr  sp, sscratch          # sp == 0：来自内核，原来的 sp 在 sscratch 里，取回来
1:
addi  sp, sp, -272          # 压一个 TrapFrame
sd    x1, 8(sp)             # 保存 x1、x3..x31（30 条）
...
sd    x31, 248(sp)
csrrw t0, sscratch, zero    # t0 = 被打断时的 sp；同时 sscratch 清零：现在在内核里
sd    t0, 16(sp)
csrr  t0, sepc
sd    t0, 256(sp)
csrr  t0, sstatus
sd    t0, 264(sp)
mv    a0, sp
call  handleTrap            # handleTrap(frame: *TrapFrame)
tail  trapExit
```

逐步看两种情况：

| | 来自 U 模式 | 来自 S 模式 |
| --- | --- | --- |
| 进入前 | `sp` = 用户栈，`sscratch` = 内核栈顶 | `sp` = 内核栈，`sscratch` = 0 |
| `csrrw sp, sscratch, sp` 之后 | `sp` = 内核栈顶，`sscratch` = 用户 `sp` | `sp` = 0，`sscratch` = 内核 `sp` |
| `bnez` / `csrr` 之后 | 不变 | `sp` = 内核 `sp`，`sscratch` = 内核 `sp` |
| 结论 | 两种情况下 `sp` 都是可用的内核栈，`sscratch` 都是被打断时的 `sp` | |

保存完寄存器后，`csrrw t0, sscratch, zero` 一步取出被打断时的 `sp` 并把 `sscratch` 清零，此后处于“内核里”的状态。

- 函数按 4 字节对齐（`align(4)`）：`stvec` 的低 2 位是模式字段，地址必须 4 字节对齐，低 2 位为 0 就是 Direct 模式。
- 它是裸函数，没有序言/尾声，全部逻辑在汇编里。`handleTrap`、`trapExit` 通过 `"X"` 约束以符号的形式传进汇编。
- **`gp`、`tp` 不换**：内核不使用它们（没有线程局部变量，链接时也不做 gp 相对寻址的优化），所以用户程序留在里面的值不会影响内核。如果以后要用 `tp` 存每个 hart 的数据，从 U 模式陷入时就必须先换掉它。

## trapExit

```asm
ld    t0, 264(sp)
csrw  sstatus, t0           # 先写回 sstatus：SIE 仍是 0，之后不会再被中断
andi  t0, t0, 0x100         # SPP 位
bnez  t0, 1f                # SPP = 1：回到 S 模式，sscratch 保持 0
addi  t0, sp, 272           # SPP = 0：要回 U 模式，把 TrapFrame 的上沿（内核栈顶）
csrw  sscratch, t0          #   存进 sscratch，下次从 U 模式陷入时从这里开始用
1:
ld    t0, 256(sp)
csrw  sepc, t0
ld    x1, 8(sp)             # 恢复 x1、x3..x31（30 条）
...
ld    x31, 248(sp)
ld    sp, 16(sp)            # 最后恢复 sp
sret
```

- `trapExit` 是 `pub` 的，因为除了陷阱返回，`proc.switchToUser` 也从这里**第一次**进入 U 模式：它在进程内核栈顶构造一个 `TrapFrame`，把 `sp` 指向它，然后跳进 `trapExit`（[process.md](process.md#进出-u-模式)）。
- SPP 的掩码 `0x100` 通过 `"i"`（立即数）约束传入：`%[spp]`。如果放进 `comptimePrint` 的参数结构体里，`trapEntry` 那边用不到这个字段，`comptimePrint` 会报“unused argument”。
- “`addi t0, sp, 272` 就是内核栈顶”成立的前提是：来自 U 模式的陷阱，`TrapFrame` 总是压在进程内核栈的最顶端。`trapEntry` 从 `sscratch`（= 栈顶）减去 272 压栈，`proc.run` 也把初始的 `TrapFrame` 放在栈顶下方 272 字节处，所以一直成立。
- 用户程序被打断时 `sstatus` 的值原样写回，包括 `SPIE = 1`，所以 `sret` 回到 U 模式后中断是开着的。
- 写 `sscratch` 发生在写回 `sstatus`（`SIE = 0`）之后、`sret` 之前，这段时间不会有中断进来，不会出现“人在内核里、`sscratch` 却不为 0”的窗口。

## 分发

```zig
fn handleTrap(frame: *TrapFrame) callconv(.c) void
```

先解出三个量：

```zig
const scause = riscv.read(.scause);
const is_interrupt = scause >> 63 != 0;
const code = scause & ~(@as(usize, 1) << 63);
const from_user = frame.sstatus & riscv.sstatus_spp == 0;
```

`from_user` 看的是保存在 `TrapFrame` 里的 `sstatus.SPP`，也就是陷入前的特权级。

| 条件 | 处理 |
| --- | --- |
| 中断 5（时钟） | `timer.onInterrupt()` |
| 中断 9（外部） | `handleExternal()`：PLIC claim → 串口 → complete（[devices.md](devices.md#claim--complete)） |
| 其他中断 | `std.debug.panic("unexpected interrupt N")` |
| 中断处理完，且 `from_user`，且 `uart.takeCtrlC()` 为真 | 打印 `^C`，`proc.kill("interrupted by Ctrl-C")` |
| 来自 U 模式的异常 8（`ecall`） | `frame.sepc += 4`，`frame.regs[10] = syscall.dispatch(frame)`（[syscalls.md](syscalls.md)） |
| 来自 U 模式的其他异常 | `proc.kill("<异常名> at <sepc>, stval=<stval>")`：结束进程，内核照常运行 |
| 来自 S 模式的异常 3（`ebreak`） | 打印 `[trap] breakpoint at ...`，`frame.sepc += instructionLength(frame.sepc)` 跳过它 |
| 来自 S 模式的其他异常 | `std.debug.panic("unhandled exception: ...")`：内核自己的错，停机 |

几个细节：

- **`sepc` 要手动前进。** 异常时 `sepc` 指向出错的指令本身，原样返回会再执行一遍。`ecall` 固定 4 字节（没有压缩形式），直接加 4；`ebreak` 有 4 字节的标准形式和 2 字节的压缩形式 `c.ebreak`，由 `instructionLength` 判断：指令的低 2 位为 `0b11` 是 4 字节，否则是 2 字节。中断不需要调整 `sepc`。
- **`syscall.dispatch` 在 `sepc += 4` 之后调用**，这样即使系统调用是 `exit`（不返回），状态也是一致的。
- **`proc.kill` 和 `proc.exit` 不返回**：它们直接恢复 shell 的上下文，当前的 `TrapFrame` 和进程内核栈上的其他内容一起被丢弃（[process.md](process.md#结束进程)）。所以 Ctrl-C 检查放在中断处理（包括 PLIC 的 complete）全部完成之后。
- 异常名来自 `Exception` 枚举的标签名（`std.enums.tagName`），不认识的编号显示为 `unknown`/`unknown exception`。

## 中断开关不变量

陷阱处理全程 `sstatus.SIE = 0`（硬件进陷阱时清零，`handleTrap` 里没有任何地方打开它），所以：

- 不会有嵌套的陷阱，除非处理程序自己出了异常（那是内核 bug，会 panic）。
- 系统调用都是关着中断执行的。将来如果要实现会阻塞的系统调用（比如等键盘输入），在里面打开中断时要想清楚嵌套陷阱的处理：嵌套的陷阱来自 S 模式，会压在当前内核栈上，这本身没问题，但要保证 `sscratch` 此时为 0（现在的代码满足）。
- 用户程序运行期间，中断只可能打断 U 模式；shell 运行期间，中断只可能打断 shell 或 `wfi`。

## 扩展

- **处理新的中断源**：在 PLIC 里使能它（`plic.init`），在 `handleExternal` 的 `switch` 里加一个分支。
- **处理新的异常**：来自 U 模式的，加到 `from_user` 分支的 `switch` 里（比如以后实现按需分页，可以在这里处理缺页，而不是直接杀进程）；来自内核的，加到最后一个分支里。
- **改 `TrapFrame`**：同时检查 `trapEntry`、`trapExit`、`proc.run` 里构造初始 `TrapFrame` 的代码和 `syscall.dispatch` 读参数的下标。
