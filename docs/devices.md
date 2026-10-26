# 设备：串口、PLIC、定时器

涉及文件：`src/uart.zig`、`src/plic.zig`、`src/timer.zig`

这三个模块的地址、中断号都按 QEMU `virt` 写死（时钟频率除外，它来自设备树）。分页打开后，串口和 PLIC 的寄存器区域在内核页表里按恒等映射为 RW（[paging.md](paging.md#内核页表)），所以开分页前后访问方式不变。

## 串口（`uart.zig`）

QEMU `virt` 上的 NS16550A 兼容串口，基地址 `0x1000_0000`，寄存器区 `0x100` 字节（分页时映射一整页）。它同时充当“屏幕”和“键盘”：输出用轮询，输入用中断。

### 寄存器

每个寄存器 1 字节，偏移相对基地址：

| 偏移 | 名字 | 用法 |
| --- | --- | --- |
| 0 | RBR（读）/ THR（写） | 读：取出收到的一个字节；写：发送一个字节 |
| 1 | IER | 中断使能，bit 0 = 收到数据时产生中断 |
| 2 | FCR（写） | FIFO 控制 |
| 3 | LCR | 线路控制：数据位、校验、停止位 |
| 5 | LSR | 线路状态：bit 0 = 有数据可读，bit 5 = 发送保持寄存器空 |

寄存器指针都是 `*volatile u8`：每次读写都必须真的发生，而且不能合并、不能重排。比如轮询 LSR 的循环，如果不是 `volatile`，优化模式下编译器可以只读一次。

### 初始化

```zig
reg(.ier).* = 0x00; // 配置期间先关掉串口中断
reg(.lcr).* = 0x03; // 8 位数据、无校验、1 位停止位
reg(.fcr).* = 0x07; // 启用并清空收发 FIFO
reg(.ier).* = 0x01; // 收到数据时产生中断
```

QEMU 的模拟串口不在乎波特率，所以没有设置分频（DLAB）。IER 打开接收中断后，串口在收到字符时拉高中断线，但 CPU 要等 PLIC 和 `sie.SEIE` 都配好、`sstatus.SIE` 打开之后才会真的收到。

### 输出

```zig
fn putRaw(c: u8) void {
    while (reg(.lsr).* & lsr_thr_empty == 0) {}
    reg(.rbr_thr).* = c;
}
pub fn putc(c: u8) void { if (c == '\n') putRaw('\r'); putRaw(c); }
pub fn write(bytes: []const u8) void
pub fn print(comptime fmt: []const u8, args: anytype) void
```

- 轮询 LSR 的“发送保持寄存器空”位，空了才写下一个字节。
- `\n` 前补一个 `\r`：终端需要回车才会回到行首。
- `print` 通过 `std.Io.Writer` 使用标准库的格式化（`{d}`、`{x}`、`{s}` 等）。Writer 的 `buffer` 为空，所以每次写入都直接调用 `drain`：

  ```zig
  fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize
  ```

  `data` 是若干段字节，最后一段要重复输出 `splat` 次（格式化填充对齐时会用到），返回实际写出的字节数。这里全部写完，返回总长度。
- `print` 吞掉格式化错误（串口写不会失败）。
- 输出不加锁，因为不会有两个执行流同时打印。时钟和串口的中断处理程序本身不打印（只有“意外的外部中断”和 panic 这种出错路径会打印）；陷阱处理程序里的其他打印（断点、进程退出或被杀）都是同步发生的，打印时 shell 正停在 `ebreak` 或 `run` 命令里。

### 输入：环形缓冲区

```zig
var rx_buf: [256]u8 = undefined;
var rx_head: u8 = 0;  // 中断处理程序写入的位置
var rx_tail: u8 = 0;  // 主循环读出的位置
```

- 索引是 `u8`，`+%` 回绕正好对应 256 字节的缓冲区，不需要取模。
- `head == tail` 表示空；`head + 1 == tail` 表示满（留一个空位区分空和满，实际容量 255）。满了之后新来的字符被丢弃。
- **单生产者单消费者**：只有中断处理程序（`onInterrupt`）改 `head`，只有主循环（`read`）改 `tail`。`read` 要求调用时中断是关着的，这样它执行期间不会有 `onInterrupt` 插进来。

```zig
pub fn onInterrupt() void {
    while (getc()) |c| {
        if (c == ctrl_c) { ctrl_c_pressed = true; continue; }
        if (rx_head +% 1 == rx_tail) continue;   // 满了，丢弃
        rx_buf[rx_head] = c;
        rx_head +%= 1;
    }
}
```

一次中断里把硬件 FIFO 里所有字符都读走（循环直到 LSR 说没有数据）。只读一个也能工作：串口的接收中断是电平信号，FIFO 里还有数据时，`complete` 之后 PLIC 会再次投递。但那样每个字符都要完整走一遍陷阱。实测（临时改成每次只读一个字符，一次性发出 30 个字符）：字符一个不丢，外部中断 30 次；现在的循环读法同样的输入只有 2 次。

### Ctrl-C

Ctrl-C（ASCII `0x03`）不进缓冲区，只把 `ctrl_c_pressed` 置为 `true`：

```zig
pub fn takeCtrlC() bool   // 返回上次调用以来是否按过 Ctrl-C，并清除标志
```

- 陷阱处理程序在处理完一次**来自 U 模式**的中断后调用 `takeCtrlC()`，按过就结束当前用户程序（[trap.md](trap.md#分发)、[process.md](process.md#ctrl-c)）。用户程序就算在 U 模式死循环、从不做系统调用，串口中断也照样会打断它。
- `proc.run` 进入 U 模式前先调用一次 `takeCtrlC()` 丢掉之前按下的 Ctrl-C，免得在 shell 里随手按的 Ctrl-C 把下一个程序一启动就杀掉。
- 在 shell 里按 Ctrl-C 没有任何效果（不进缓冲区，shell 看不到）。
- 管道测试里用 `printf '\003'` 发送 Ctrl-C。QEMU `-nographic` 会把 Ctrl-C 原样交给客户机串口，不会结束 QEMU 自己（结束 QEMU 是 Ctrl-A X）。

## PLIC（`plic.zig`）

PLIC（Platform-Level Interrupt Controller）把外设的中断线汇总起来，按优先级送给各个 hart 的各个特权级。QEMU `virt` 上它的基地址是 `0x0c00_0000`，寄存器区域 6 MiB（`mmio_size = 0x60_0000`，设备树里 plic 节点的 `reg`），分页时整块映射。串口是 10 号中断源（`uart0_irq = 10`，设备树里串口节点的 `interrupts = <0x0a>`）。

### 上下文

PLIC 把“某个 hart 的某个特权级”叫一个上下文（context）。QEMU `virt` 上每个 hart 有两个：`2 * hart` 是 M 模式，`2 * hart + 1` 是 S 模式。内核用 S 模式上下文，hart 0 就是上下文 1。

### 寄存器

| 地址 | 寄存器 | 用法 |
| --- | --- | --- |
| `base + 4 * irq` | 中断源 `irq` 的优先级 | 0 表示永不触发，所以至少设成 1 |
| `base + 0x2000 + 0x80 * ctx` | 上下文 `ctx` 的使能位图（第一个字对应中断源 0..31） | 第 `irq` 位置 1 |
| `base + 0x20_0000 + 0x1000 * ctx` | 上下文 `ctx` 的优先级阈值 | 只有优先级 > 阈值的中断才会送达；设 0 接收所有 |
| `base + 0x20_0004 + 0x1000 * ctx` | 上下文 `ctx` 的 claim/complete | 读 = 领取（claim），写 = 完成（complete） |

都是 32 位寄存器，用 `*volatile u32` 访问。

### 初始化

```zig
pub fn init(hartid: usize) void {
    context = 2 * hartid + 1;
    priority(uart0_irq).* = 1;
    enable().* = 1 << uart0_irq;
    threshold().* = 0;
    riscv.set(.sie, riscv.sie_seie);
}
```

最后一步打开 `sie.SEIE`：S 模式外部中断使能。之后只要 PLIC 有中断送给这个上下文，`sip.SEIP` 就会置位。

### claim / complete

外部中断处理（`trap.handleExternal`）：

1. `plic.claim()` 读 claim 寄存器，得到当前优先级最高的待处理中断号；PLIC 同时把它标记为“处理中”。读到 0 表示没有（可能被别的上下文抢先领取了），直接返回。
2. 按中断号分发：10 号交给 `uart.onInterrupt()`；其他号打印一条 `[trap] unexpected external interrupt N`。
3. `plic.complete(irq)` 把中断号写回同一个寄存器，告诉 PLIC 处理完了。在此之前 PLIC 不会再投递同一个中断源。

## 定时器（`timer.zig`）

```zig
pub const tick_hz = 100;          // 每秒 100 次，也就是每 10 ms 一次
var timebase_hz: u64 = undefined; // time CSR 每秒增加多少，来自设备树
var deadline: u64 = undefined;    // 下一次中断预约在 time CSR 的哪个值
pub var ticks: u64 = 0;
```

- **时钟频率**：`time` CSR 以 timebase 频率递增，QEMU `virt` 上是 10 MHz。这个值来自设备树 `/cpus` 节点的 `timebase-frequency`（[devicetree.md](devicetree.md)），`kmain` 把它传给 `timer.init`。
- **预约**：`arm()` 把 `deadline` 加上一个周期 `timebase_hz / tick_hz`（10 MHz 下是 100000 个计数），通过 `sbi.setTimer(deadline)` 让 OpenSBI 在那时产生 S 模式时钟中断。下一次的预约时刻以**上一次的预约时刻**为基准，而不是以“现在”为基准，原因见下面的“为什么”。
- **初始化**：`init(hz)` 记下频率，把 `deadline` 设成当前的 `time`，预约第一次（一个周期之后），再打开 `sie.STIE`。
- **中断处理**：`onInterrupt()` 让 `ticks` 加 1，再预约下一次。`setTimer` 同时清除了当前挂起的时钟中断，不预约的话处理程序返回后会立刻再次进来。
- **计时**：`ticks` 从打开时钟中断开始计数，shell 的 `uptime` 命令显示 `ticks / tick_hz` 秒；`uptimeMs()` 返回 `ticks * 1000 / tick_hz` 毫秒，是 `uptime` 系统调用的返回值。误差在一个 tick（10 ms）以内，不随时间累积。
- **为什么以上一次的预约时刻为基准**：中断从到期到被处理总有一段延迟。以前 `arm()` 按“处理中断时读到的 `time` + 一个周期”预约，每个 tick 都把这段延迟丢掉，误差越积越多。实测 `uptime` 比 `time` 慢 2%～3%，shell 空闲 20 秒就慢了 543 ms。现在每个周期的边界是固定的，延迟不累积，同样空闲 20 秒只差 4 ms。
- **处理晚了超过一个周期时**：新的预约时刻已经过去。按 SBI 规范，这时中断会立刻挂起，连续来几次之后 `ticks` 就追上了。这种情况没有实测过。

时钟中断在 U 模式下同样会发生（`sret` 进入 U 模式时 `SPIE = 1`），这是内核能从死循环的用户程序手里拿回 CPU 的原因。

## 中断路径汇总

| 中断 | `scause` | 来源 | 处理 |
| --- | --- | --- | --- |
| S 模式时钟中断 | 中断 5 | OpenSBI 按 `setTimer` 的预约触发 | `timer.onInterrupt()` |
| S 模式外部中断 | 中断 9 | PLIC，目前只有串口（10 号源） | `plic.claim()` → `uart.onInterrupt()` → `plic.complete()` |
| S 模式软件中断 | 中断 1 | 核间中断，单核下不会出现 | `sie.SSIE` 没有打开，不会被接收；万一收到就 panic（`unexpected interrupt 1`） |

这三类都在 `mideleg` 里委托给了 S 模式（OpenSBI 设置的 `MIDELEG = 0x1666`）。陷阱分发的细节见 [trap.md](trap.md)。
