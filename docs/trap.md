# 陷阱处理

涉及文件：`src/trap.zig`（以及它调用的 `src/proc.zig`、`src/syscall.zig`、`src/timer.zig`；`tp` 的用法见 `src/hart.zig`）

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
    kernel_tp: usize = 0,  // 回到 U 模式时内核的 tp（hart 编号），见“tp 约定”
    _pad: usize = 0,       // 补齐到 16 字节
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
| 272 | `kernel_tp` |
| 280 | 填充，不用 |

总大小 288 字节，是 16 的倍数（编译期断言），压栈后 `sp` 仍满足 RISC-V 调用约定要求的 16 字节对齐。没有最后那个填充字段的话是 280 字节，`TrapFrame` 放在内核栈顶，`handleTrap` 拿到的 `sp` 就只有 8 字节对齐了。

**布局和汇编绑在一起**：`trapEntry`、`trapExit` 按偏移读写这个结构。汇编里用到的偏移通过 `@sizeOf`/`@offsetOf` 在编译期算出（`asm_offsets`），寄存器的保存/恢复指令由 `regsAsm` 在编译期生成（`x1`、`x3..x31` 各一条，共 30 条存 + 30 条取），所以改字段顺序不会悄悄错位，但增删字段时仍要检查两段汇编的逻辑（比如 `sp` 的特殊处理）。系统调用处理程序通过 `regs[10]`（`a0`）..`regs[17]`（`a7`）读参数、写返回值。

## sscratch 约定

陷阱可能来自 S 模式（内核自己被中断打断、或内核代码出了异常），也可能来自 U 模式（用户程序）。来自 U 模式时 `sp` 是用户栈：既不可信（用户可以把它设成任何值），内核也不应该往用户内存里写东西。所以要先换到内核栈，而换栈之前不能动任何通用寄存器（它们都还没保存）。

办法是用 `sscratch` 暂存：

- 在内核里（S 模式）运行时，`sscratch` = 0。
- 在 U 模式运行时，`sscratch` = 当前进程内核栈的栈顶。每个进程有自己的内核栈（[process.md](process.md#进程表)），`trapExit` 每次回到 U 模式时都按这次要回去的进程重新写 `sscratch`，所以切换进程不需要另外维护它。

`trap.init` 把 `sscratch` 清零（固件不保证它的初值），每个 hart 启动时各调用一次（`sscratch`、`stvec` 都是每个 hart 自己的）；之后由 `trapEntry`/`trapExit` 维护这个约定。

## tp 约定

内核用 `tp` 存当前 hart 的编号（`hart.id()` 直接读 `tp`，[boot.md](boot.md#每个-hart-的启动栈)）：S 模式读不到自己的编号（`mhartid` 只有 M 模式能读），xv6 也是这样做的。可 `tp` 是普通的通用寄存器，用户程序可以随便改它，所以：

- **从 U 模式陷入**：`tp` 是用户程序的值，和别的寄存器一起存进 `TrapFrame`，然后从 `kernel_tp` 换回内核的值，之后才调用 `handleTrap`。
- **回到 U 模式**：`trapExit` 先把当前的 `tp`（内核的）存进 `kernel_tp`，再从 `regs[4]` 恢复用户的 `tp`。
- **来自、回到 S 模式**：`tp` 本来就是内核的，存进去、原样恢复，不用换。

`kernel_tp` 每次回到 U 模式都重新存，而不是在创建进程时存一次：进程可能在 hart 0 上陷入、让出 CPU，再在 hart 2 上被调度、回到 U 模式，下次陷入时就该换成 2。进程切换（`switchContext`）不保存 `tp`，`tp` 一直是当前 hart 的。`gp` 不换：内核不使用它（链接时不做 gp 相对寻址的优化），用户程序留在里面的值不会影响内核。

## trapEntry

```asm
csrrw sp, sscratch, sp      # 交换 sp 和 sscratch
bnez  sp, 1f                # 交换后 sp != 0：来自 U 模式，sp 已经是内核栈顶
csrr  sp, sscratch          # sp == 0：来自内核，原来的 sp 在 sscratch 里，取回来
1:
addi  sp, sp, -288          # 压一个 TrapFrame
sd    x1, 8(sp)             # 保存 x1、x3..x31（30 条），包括被打断时的 tp
...
sd    x31, 248(sp)
csrrw t0, sscratch, zero    # t0 = 被打断时的 sp；同时 sscratch 清零：现在在内核里
sd    t0, 16(sp)
csrr  t0, sepc
sd    t0, 256(sp)
csrr  t0, sstatus
sd    t0, 264(sp)
andi  t0, t0, 0x100         # SPP 位
bnez  t0, 2f                # 来自 S 模式：tp 本来就是内核的
ld    tp, 272(sp)           # 来自 U 模式：换回内核的 tp（kernel_tp）
2:
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
- 来自 U 模式时换掉 `tp`，见 [tp 约定](#tp-约定)。

## trapExit

```asm
ld    t0, 264(sp)
csrw  sstatus, t0           # 先写回 sstatus：SIE 仍是 0，之后不会再被中断
andi  t0, t0, 0x100         # SPP 位
bnez  t0, 1f                # SPP = 1：回到 S 模式，sscratch 保持 0
addi  t0, sp, 288           # SPP = 0：要回 U 模式，把 TrapFrame 的上沿（内核栈顶）
csrw  sscratch, t0          #   存进 sscratch，下次从 U 模式陷入时从这里开始用
sd    tp, 272(sp)           #   内核的 tp 存进 kernel_tp，下次陷入时换回来
1:
ld    t0, 256(sp)
csrw  sepc, t0
ld    x1, 8(sp)             # 恢复 x1、x3..x31（30 条），回 U 模式时 tp 变成用户的
...
ld    x31, 248(sp)
ld    sp, 16(sp)            # 最后恢复 sp
sret
```

- `trapExit` 是 `pub` 的，因为除了陷阱返回，新进程也从这里**第一次**进入 U 模式：`proc.userinit`、`fork`、`exec` 在进程内核栈顶准备好 `TrapFrame`（`startFrame` 或复制父进程的），再构造一个 `ra` = `proc.forkret`、`sp` = 这个 `TrapFrame` 的上下文；第一次被调度时 `switchContext` 恢复这个上下文、`ret` 进 `forkret`，它放开进程锁、检查完 `killed` 再跳进 `trapExit`（[process.md](process.md#创建进程)）。
- SPP 的掩码 `0x100` 通过 `"i"`（立即数）约束传入：`%[spp]`（两段汇编都这样传）。偏移量放在 `comptimePrint` 的参数结构体 `asm_offsets` 里，两段汇编都要用到其中的每一个字段，否则 `comptimePrint` 会报“unused argument”（[zig-0.17.md](zig-0.17.md#stdfmtcomptimeprint-不允许多余的参数)）。
- “`addi t0, sp, 288` 就是内核栈顶”成立的前提是：来自 U 模式的陷阱，`TrapFrame` 总是压在进程内核栈的最顶端。`trapEntry` 从 `sscratch`（= 栈顶）减去 288 压栈，`proc.frameOf` 也把初始的 `TrapFrame` 放在栈顶下方 288 字节处，所以一直成立。
- 用户程序被打断时 `sstatus` 的值原样写回，包括 `SPIE = 1`，所以 `sret` 回到 U 模式后中断是开着的。写回的值里 `SIE` 必须是 0（陷阱入口保存的值天然如此，`proc.startFrame` 构造初始值时专门清掉了），否则恢复寄存器的途中就会被中断打断。
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
| 中断 5（时钟） | `timer.onInterrupt()`：预约这个 hart 的下一次时钟中断；在启动 hart 上还给 `timer.ticks` 加 1、叫醒 `sleep` 系统调用里的进程（[devices.md](devices.md#定时器timerzig)）。`from_user` 时 `proc.yieldTimeslice()`：当前进程的 `ticks` 加 1，时间片用完，让出 CPU，下次轮到这个进程时（可能在别的 hart 上）返回（[process.md](process.md#schedyield)） |
| 中断 9（外部） | `handleExternal()`：PLIC claim → 串口（收字符；按过 Ctrl-C 就 `proc.interruptForeground()`；`proc.wakeup(uart.rx_chan)` 叫醒在 `read` 里等输入的进程）→ complete（[devices.md](devices.md#claim--complete)）。串口中断发给所有 hart，claim 到 0 的 hart 什么也不做 |
| 其他中断 | `std.debug.panic("unexpected interrupt N")` |
| 来自 U 模式的异常 8（`ecall`） | `frame.sepc += 4`，`frame.regs[10] = syscall.dispatch(frame)`（[syscalls.md](syscalls.md)） |
| 来自 U 模式的其他异常 | `proc.killCurrent("<异常名> at <sepc>, stval=<stval>")`：结束进程，内核照常运行 |
| 来自 S 模式的异常 3（`ebreak`） | 打印 `[trap] breakpoint at ...`，`frame.sepc += instructionLength(frame.sepc)` 跳过它 |
| 来自 S 模式的其他异常 | `std.debug.panic("unhandled exception: ...")`：内核自己的错，停机 |
| 最后，`from_user` 时 | `proc.checkKilled()`：被 kill 了就在这里结束，不再回到 U 模式（[process.md](process.md#结束进程)）；`spinlock.assertNoneHeld()` |

和 xv6 的 `usertrap` 末尾一样：先处理陷阱，只在时钟中断时 `yield`，回到用户态之前检查 `killed`。

几个细节：

- **`sepc` 要手动前进。** 异常时 `sepc` 指向出错的指令本身，原样返回会再执行一遍。`ecall` 固定 4 字节（没有压缩形式），直接加 4；`ebreak` 有 4 字节的标准形式和 2 字节的压缩形式 `c.ebreak`，由 `instructionLength` 判断：指令的低 2 位为 `0b11` 是 4 字节，否则是 2 字节。中断不需要调整 `sepc`。
- **`syscall.dispatch` 在 `sepc += 4` 之后调用**，这样即使系统调用是 `exit`（不返回），状态也是一致的。
- **`proc.killCurrent`、`proc.exit` 和结束了进程的 `checkKilled` 不返回**：它们切回调度器，当前的 `TrapFrame` 和进程内核栈上的其他内容一起被丢弃（[process.md](process.md#结束进程)）。
- **`proc.yieldTimeslice` 可能很久以后才返回**，而且可能是在另一个 hart 上返回：别的进程会先运行。时钟中断不经过 PLIC，`timer.onInterrupt` 已经预约了下一次中断，所以在这里让出没问题。`syscall.dispatch` 里的 `yield`、`sleep` 也一样，返回之后照常把返回值写进 `a0`：`frame` 在这个进程自己的内核栈上，切走期间没人动它。
- 中断来自 S 模式时打断的一定是这个 hart 的调度器（它开中断的那一下，或者 `wfi` 之后），这时 `proc.current()` 为 `null`，只处理中断，不让出 CPU。
- 异常名来自 `Exception` 枚举的标签名（`std.enums.tagName`），不认识的编号显示为 `unknown`/`unknown exception`。

## 中断开关不变量

陷阱处理全程 `sstatus.SIE = 0`（硬件进陷阱时清零，`handleTrap` 里没有任何地方打开它），所以：

- 不会有嵌套的陷阱，除非处理程序自己出了异常（那是内核 bug，会 panic）。
- 系统调用都是关着中断执行的。会阻塞的系统调用（`sleep`、`read`、管道的 `write`、`wait`）不在里面开中断等，而是 `proc.sleep(chan, lock)` 切回调度器，由中断处理程序或别的进程 `wakeup` 它。以后再加阻塞的调用也照这个办法做。
- 自旋锁要求拿锁时中断关着（[process.md](process.md#锁)），陷阱处理程序里随时可以拿锁。中断处理程序（`timer.onInterrupt`、`interruptForeground`、`wakeup`）也拿锁，它们不会在同一个 hart 上和被打断的代码抢同一把锁：中断只打断 U 模式和调度器开中断的那一下，那时这个 hart 什么锁都没拿；别的 hart 拿着锁的话，等它放开就是了。`handleTrap` 回到 U 模式之前检查没有拿着任何锁（`spinlock.assertNoneHeld()`），漏放的锁在这里就会被发现。
- 进程切换（`proc.switchContext`）都发生在关中断时：调度器关着中断扫描进程表，进程这边是在陷阱处理程序里调用 `proc.sched`。
- 中断只可能打断 U 模式，或者调度器每一轮开头开中断的那一下。每个 hart 的 `sstatus.SIE` 是它自己的，这些规矩对每个 hart 分别成立。

## 扩展

- **处理新的中断源**：在 PLIC 里使能它（`plic.init`），在 `handleExternal` 的 `switch` 里加一个分支。
- **处理新的异常**：来自 U 模式的，加到 `from_user` 分支的 `switch` 里（比如以后实现按需分页，可以在这里处理缺页，而不是直接杀进程）；来自内核的，加到最后一个分支里。
- **改 `TrapFrame`**：同时检查 `trapEntry`、`trapExit`、`proc.startFrame`（构造初始 `TrapFrame`，`a0`/`a1`/`sp` 传命令行参数）和 `syscall.dispatch` 读参数的下标。
