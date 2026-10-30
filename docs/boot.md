# 启动流程

涉及文件：`linker.ld`、`src/main.zig`（以及 `src/hart.zig`、`src/sbi.zig` 的 `hartStart`）

## 从上电到内核

1. QEMU 把 OpenSBI 放在 `0x8000_0000`，把内核 ELF 的各段按程序头放到 `0x8020_0000` 起的物理地址，把设备树放在内存靠顶端的位置（128 MiB 时是 `0x87e0_0000`），然后从 OpenSBI 开始执行（M 模式）。
2. OpenSBI 初始化串口、定时器、PMP（物理内存保护，把自己所在的 `0x8000_0000..0x8006_0000` 设成 S/U 模式不可访问）和中断/异常委托，在设备树里加上 `/reserved-memory` 节点登记自己占用的内存，打印启动横幅。
3. OpenSBI 以 S 模式跳到 `0x8020_0000`（启动横幅里的 `Domain0 Next Address`）。**只有一个 hart 会来**：多个 hart 时 OpenSBI 让最先到的那个当启动 hart（横幅里的 `Boot HART ID`，多数时候是 0，实测也见过 2），其他 hart 停在 OpenSBI 里（HSM 扩展的 STOPPED 状态），等内核用 SBI 调用启动它们（[启动其他 hart](#启动其他-hart)）。寄存器状态：
   - `a0` = 启动 hart 的编号
   - `a1` = 设备树的物理地址（横幅里的 `Domain0 Next Arg1`）
   - `satp` = 0：分页关闭，地址就是物理地址
   - `sstatus.SIE` = 0：中断关闭
   - `sp` 没有约定：内核要自己设栈

OpenSBI 横幅里和内核相关的几行（QEMU 8.2 自带的 OpenSBI v1.3）：

```
Domain0 Region00          : 0x0000000002000000-0x000000000200ffff M: (I,R,W) S/U: ()    ← CLINT，S 模式不可访问
Domain0 Region01          : 0x0000000080040000-0x000000008005ffff M: (R,W) S/U: ()      ← OpenSBI 数据
Domain0 Region02          : 0x0000000080000000-0x000000008003ffff M: (R,X) S/U: ()      ← OpenSBI 代码
Domain0 Region03          : 0x0000000000000000-0xffffffffffffffff M: (R,W,X) S/U: (R,W,X)
Domain0 Next Address      : 0x0000000080200000
Domain0 Next Arg1         : 0x0000000087e00000
Domain0 Next Mode         : S-mode
Boot HART ISA Extensions  : time,sstc
Boot HART MIDELEG         : 0x0000000000001666
Boot HART MEDELEG         : 0x0000000000f0b509
```

`MIDELEG`/`MEDELEG` 是委托给 S 模式的中断和异常，含义见 [trap.md](trap.md#异常委托)。

## 链接脚本

`linker.ld` 决定内核镜像在内存里的样子：

```
0x8020_0000  __text_start   .text      KEEP(*(.text.boot)) 在最前面，然后是 *(.text .text.*)
             （4 KiB 对齐）
             __rodata_start .rodata    .srodata、.rodata；链接器把 .eh_frame_hdr、.eh_frame 也放在后面
             （4 KiB 对齐）
             __data_start   .data      .sdata、.data
             （16 字节对齐）
             __bss_start    .bss       .sbss、.bss、COMMON（NOLOAD：ELF 里不占空间），每个 hart 的启动栈也在这里
             __bss_end
             （4 KiB 对齐）
             __kernel_end              之后的内存交给页分配器
```

- `ENTRY(_start)` 设置 ELF 入口；更重要的是 `.text.boot` 排在 `.text` 最前面，保证 `_start` 正好在 `0x8020_0000`，因为 OpenSBI 跳到的是这个固定地址，而不是 ELF 的入口字段。
- `.rodata`、`.data` 和 `__kernel_end` 都按 4 KiB 对齐，这样每一页只属于一个段，开分页时可以分别设置权限（代码 R-X、只读数据 R--、其余 RW-，见 [paging.md](paging.md#内核页表)）。`vm.zig` 通过 `__text_start`、`__rodata_start`、`__data_start`、`__kernel_end` 这四个符号确定边界，改链接脚本时要保持它们的含义和对齐。
- 没在脚本里列出的段（如 `.eh_frame_hdr`、`.eh_frame`）是“孤儿段”，LLD 会把它们放在属性最接近的段后面。它们是只读的，落在 `.rodata` 之后、`__data_start` 之前，所以也被映射成只读。可以用 `llvm-readelf -S zig-out/bin/kernel` 确认。
- `.bss` 标成 `NOLOAD`，ELF 文件里没有它的内容，`_start` 要自己清零。启动栈是 `main.zig` 里的全局数组 `boot_stacks`，也在 `.bss` 里，不占文件空间。

Debug 模式下实测的符号值（代码改动后会变）：

| 符号 | 地址 |
| --- | --- |
| `__text_start` | `0x80200000` |
| `__rodata_start` | `0x8026e000` |
| `__data_start` | `0x802ac000` |
| `__bss_start` / `__bss_end` | `0x802ae000` / `0x80358100` |
| `boot_stacks`（8 × 32 KiB） | `0x803170e0` |
| `__kernel_end` | `0x80359000` |

查看方法：`llvm-nm zig-out/bin/kernel | grep -E ' (__(text|rodata|data|bss|kernel)_|boot_stacks$)'`（release 模式的 ELF 不带符号表，要在 Debug 下看）。

## `_start`

```zig
const enter_asm =                      // _start 和 secondaryEntry 共用
    \\mv tp, a0
    \\la sp, boot_stacks
    \\addi t0, a0, 1
    \\slli t0, t0, %[shift]
    \\add sp, sp, t0
;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\li t0, %[max]
        \\bgeu a0, t0, 3f
        \\la t0, __bss_start
        \\la t1, __bss_end
        \\1:
        \\bgeu t0, t1, 2f
        \\sd zero, 0(t0)
        \\addi t0, t0, 8
        \\j 1b
        \\2:
    ++ enter_asm ++
        \\tail %[kmain]
        \\3:
        \\wfi
        \\j 3b
        : ...
    );
}
```

- 必须是裸函数（`callconv(.naked)`）：普通函数的序言会用 `sp` 压栈，而此时还没有栈。
- `linksection(".text.boot")` 配合链接脚本把它放在 `0x8020_0000`。
- 启动 hart 的编号不小于 `hart.max`（8）的话没有启动栈可用，停在最后的 `wfi` 循环里。QEMU `virt` 的 hart 从 0 开始编号，不会走到这里。
- 先以 8 字节为单位清零 `[__bss_start, __bss_end)`（链接脚本保证 `__bss_end` 8 字节对齐）。所有初值为 0 的全局变量（例如 `timer.ticks`、页分配器的链表头）都在 `.bss` 里，不清零就是 QEMU 留下的随机内容。清零只用 `t0`、`t1`，不需要栈；启动栈也在 `.bss` 里，所以先清零、再用栈。
- `enter_asm` 把 hart 编号放进 `tp`、让 `sp` 指向这个 hart 的启动栈顶，见下一节。
- 全程没碰 `a0`、`a1`，`tail` 跳到 `kmain` 时它们原样成为 `kmain(hartid, dtb_addr)` 的两个参数。`tail` 不保存返回地址，`kmain` 也是 `noreturn`。

## 每个 hart 的启动栈

```zig
const boot_stack_shift = 15;   // 32 KiB
export var boot_stacks: [hart.max][1 << boot_stack_shift]u8 align(16) = undefined;
```

- 每个 hart 一块，按 hart 编号下标：hart `i` 的栈顶是 `boot_stacks + (i + 1) * 32 KiB`（`enter_asm` 用移位算乘法）。`kmain`、`kmainSecondary` 在上面运行，之后归这个 hart 的调度器用（[process.md](process.md#栈的变化)）。
- **大小是实测出来的**：Debug 模式下跑完全部 QEMU 测试，启动 hart 最深用了 17432 字节（`kmain` 那一串初始化，Debug 模式下栈帧很大），其他 hart 约 2.2 KiB；safe 模式下分别是 3616 和 800 字节（加了磁盘之后重新量的）。测法和进程内核栈一样（`.bss` 清零，`shutdown` 时从栈底找第一个不为 0 的字节，临时代码）。最早给的是 16 KiB，Debug 模式下启动 hart 的栈溢出了 1 KiB 左右，踩进了紧挨着的 `proc.cpus`，所以改成 32 KiB。栈两侧没有保护页，溢出不会触发缺页。
- **栈底的金丝雀**（`src/canary.zig`，和进程内核栈的一样，[process.md](process.md#进程表)）：`kmain`、`kmainSecondary` 第一件事是在自己启动栈最底下的 256 字节写上固定的图案，调度器（`proc.scheduler` 收到这块栈）每一轮检查一次，被改了就 panic：`kernel stack overflow: boot stack of hart N`。打断调度器的中断也在这块栈上处理，下一轮就能查到。临时在 hart 2 的 `kmainSecondary` 里放一个将近 32 KiB 的数组实测过。
- `boot_stacks` 用 `export` 导出成符号，汇编里直接 `la sp, boot_stacks`。用 `"X"` 约束把 `&boot_stacks` 传进去不行：编译器会先把这个地址算进一个寄存器再代入，实测它挑了 `a0`，把 hart 编号覆盖了（函数指针 `&kmain` 用 `"X"` 就没问题，代入的是符号名）。
- `tp` 从这里开始就是 hart 编号，内核里 `hart.id()` 直接读它（[trap.md](trap.md#tp-约定)）。之后第一次拿锁（`uart.init` 之后的打印）就要用到它。

## `kmain` 的初始化顺序

| 步骤 | 代码 | 启动日志 | 为什么在这个位置 |
| --- | --- | --- | --- |
| 1 | `riscv.clear(.sstatus, riscv.sstatus_fs)` | — | 关掉 OpenSBI 留着的浮点单元（`FS`：Dirty → Off，见 [riscv-sbi.md](riscv-sbi.md#位定义)）。内核不会生成浮点指令，放在哪里都行；放在最前面，保证进入 U 模式之前一定已经关了 |
| 2 | `uart.init()` | `Hello from a Zig kernel on RISC-V!` | 最先初始化，之后的每一步都能打印信息 |
| 3 | `sbi.specVersion()`、`sbi.implName()` | `SBI: OpenSBI, spec v1.0 \| hart 0 \| device tree at 0x87e00000` | 确认 SBI 能用；顺便打印 hart 号和设备树地址 |
| 4 | `trap.init()` + `ebreak` | `[ok] trap vector installed`、`[trap] breakpoint at ..., skipping it` | 尽早装好陷阱向量：后面解析设备树、建页表时如果出错（访问了坏地址），能得到一条带 `sepc`/`stval` 的 panic 信息，而不是跳到未初始化的 `stvec` 上不知所终。`ebreak` 自检确认陷阱能进能出 |
| 5 | `dtb.parse(dtb_addr)` | `[ok] device tree: 128 MiB RAM at 0x80000000, timebase 10000000 Hz` | 页分配器要知道内存范围和保留区，定时器要知道时钟频率 |
| 6 | `page.init(vm.kernelEnd(), info.memory.end(), info.reserved())` | `[ok] page allocator: N free pages (... KiB)` | 建页表需要分配页 |
| 7 | `vm.init(info.memory)` | `[ok] Sv39 paging enabled: ...` | 写 `satp` 打开分页。恒等映射保证这一刻前后地址不变 |
| 8 | `virtio_disk.init()`、`bio.init(...)`、`plic.init(virtio_disk.irq)`、`plic.initHart()`、`timer.init(info.timebase_hz)`、`timer.initHart()`、`ipi.initHart()` | `[ok] virtio disk: 8192 blocks of 4 KiB (32 MiB), irq 1`、`[ok] interrupt sources enabled: timer at 100 Hz, keyboard via UART + PLIC, IPIs, disk` | 先找磁盘（要访问 MMIO，所以在开分页之后；只是协商、配置队列，不读写：`kmain` 不是进程，不能睡着等磁盘，[disk.md](disk.md)），PLIC 要知道它的中断号。然后是全局的设置（串口中断的优先级、时钟频率、由哪个 hart 计时）和这个 hart 自己的（PLIC 上下文、第一次时钟中断、`sie` 里时钟、外部、软件中断的使能位）。全局开关 `sstatus.SIE` 不在这里开，见下文 |
| 9 | `startHarts(hartid, info.harts(), info.timebase_hz)` | `[ok] 4 harts running, booted on hart 0` | 启动设备树里列出的其他 hart，等它们都进了调度器（[启动其他 hart](#启动其他-hart)）。要在全局的初始化都做完之后：它们直接用页表、页分配器 |
| 10 | `proc.userinit()` + `proc.scheduler()` | `Type 'help' for commands.`、`> ` | 和 xv6 的 `main` 一样：建好第一个进程 init，启动栈交给调度器，`kmain` 不再返回。之后的两行是 shell（init 启动的）打印的，init 和 shell 可能在任何一个 hart 上运行 |

**`kmain` 不打开 `sstatus.SIE`**：OpenSBI 交过来时它是 0，之后一直保持 0，直到调度器第一轮开头开一下。以前 `kmain` 在创建 init 之前就打开了，`userinit` 是开着中断运行的；加了自旋锁之后，`userinit` 里分配页（`page.alloc`）要拿锁，`Spinlock.acquire` 检查到中断开着，直接 panic（`acquire: interrupts are enabled`）。现在内核代码从头到尾都关着中断，只有调度器开头那一下例外。时钟中断在第 8 步就预约了，到调度器开中断时已经挂起，马上被处理，计时不受影响。

任何一步失败（设备树格式不对、建页表时内存不够）都会 `std.debug.panic`，打印原因后停机。

## 启动其他 hart

```zig
fn startHarts(self: usize, ids: []const u32, timebase_hz: u64) void
fn secondaryEntry() callconv(.naked) noreturn   // 其他 hart 的入口
fn kmainSecondary() callconv(.c) noreturn
```

照 xv6 的思路（启动 hart 做完全局的初始化，其他 hart 只做自己那一份），只是 xv6 的所有 hart 是同时从入口进来的，这里其他 hart 要由内核叫醒：

1. 设备树 `/cpus` 下每个 `device_type = "cpu"`、没被禁用的节点是一个 hart，`reg` 是它的编号（[devicetree.md](devicetree.md#cpu-节点)）。`startHarts` 跳过自己、跳过编号不小于 `hart.max` 的（打印 `[warn] hart N not started`），对其余的逐个调用 SBI HSM 扩展的 `hart_start(hartid, start_addr, arg)`（[riscv-sbi.md](riscv-sbi.md#sbi-调用sbizig)）：让那个 hart 在 S 模式从 `secondaryEntry` 的物理地址开始执行，`a0` = 它的编号，分页和中断都是关的。
2. **一个一个来**：每启动一个，就等它把 `harts_online` 加 1（原子变量，最多等一秒，等不到就 panic），再启动下一个。所以启动日志的顺序是固定的，也不会出现几个 hart 同时初始化的情况。
3. 调用 `hart_start` 之前先 `fence rw, rw`：新的 hart 要看到启动 hart 之前写的所有东西（页表、页分配器、各个模块的初始化）。SBI 规范没说 `hart_start` 本身保证这一点，所以自己做。`harts_online` 的加 1 和读取用 release / acquire，反方向也一样。
4. `secondaryEntry` 是裸函数：`enter_asm` 设好 `tp` 和启动栈，`tail` 到 `kmainSecondary`。它不清零 `.bss`（启动 hart 早就清过，现在里面全是有用的数据）。
5. `kmainSecondary` 做每个 hart 一份的初始化：关掉 `sstatus.FS`（OpenSBI 给每个 hart 都留着），`trap.init()`（每个 hart 有自己的 `stvec`、`sscratch`），`vm.initHart()`（打开分页：内核页表所有 hart 共用，启动后不再改），`plic.initHart()`、`timer.initHart()`、`ipi.initHart()`（自己的 PLIC 上下文、自己的定时器、接收核间中断），然后把 `harts_online` 加 1，进入自己的调度器。它不打印东西。
6. 全部启动完，启动 hart 打印 `[ok] N harts running, booted on hart M`，然后才创建 init。这时其他 hart 已经在调度器里空转（没有可运行的进程就 `wfi`，每 10 ms 被自己的时钟中断叫醒一次；有进程变成 runnable 时被核间中断叫醒）。

`hart_start` 失败（返回错误码）只打印 `[warn] cannot start hart N: SBI error E`，跳过它，内核照样用剩下的 hart 运行。QEMU `-smp 1` 时设备树里只有一个 hart，`startHarts` 什么都不启动，打印 `[ok] 1 hart running, booted on hart 0`。

## 调度器

`kmain` 的最后两行：

```zig
proc.userinit() catch |err| std.debug.panic("cannot start init: {s}", .{@errorName(err)});
proc.scheduler();
```

之后每个 hart 的启动栈上都永远运行着这个 hart 的调度器：扫描（共用的）进程表、切到 `runnable` 的进程、等它切回来，一个都没有就 `wfi`。它只管调度，别的什么都不做。init 被调度后启动 shell（[user-programs.md](user-programs.md#init-和-sh)），之后的一切都由用户程序通过系统调用驱动。调度器的代码和“为什么要先关中断再 `wfi`”见 [process.md](process.md#调度器)。

内核里只有调度器每一轮开头开一下中断再关上。其余时间（初始化、调度器扫描、陷阱处理、系统调用）都关着中断；用户程序在 U 模式运行时中断是开着的。

## panic

```zig
pub const panic = std.debug.FullPanic(kernelPanic);

fn kernelPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    riscv.disableInterrupts();
    hart.beginPanic();
    uart.print("\n!!! KERNEL PANIC on hart {d}: {s}\n", .{ hart.id(), msg });
    uart.write("system halted.\n");
    hart.halt();
}

pub fn halt() noreturn {           // hart.zig
    riscv.disableInterrupts();
    riscv.write(.sie, 0);
    while (true) riscv.wfi();
}
```

- 根文件里的 `pub const panic` 替换标准库默认的 panic 处理（freestanding 下默认是直接 `@trap()`）。`@panic`、`std.debug.panic`，以及 Debug/safe 模式下的安全检查失败（整数溢出、越界、`.?` 取到 null 等）都会走到这里。必须写成 `pub`，0.17 起 `@hasDecl` 只认公开声明。
- `FullPanic` 会把各种安全检查失败格式化成可读的消息再交给 `kernelPanic`。0.17.0 的 `std.debug.simple_panic` 有回归（#36986），编译不过，不要用。
- **别的 hart 也要停下**：`hart.beginPanic()` 用原子变量记下“hart N 在 panic”（已经有别的 hart 在 panic 的话，自己直接停下，两份 panic 信息交错在一起谁也看不清）。别的 hart 在下一次输出一个字符（`uart` 的 `putc`）、等锁时每转一圈（`Spinlock.acquire`）、调度器每一轮开头都会调用 `hart.checkPanic()`，看到了就自己 `halt()`。这三个地方覆盖了所有会一直跑下去的路径：在 U 模式里死循环的进程每 10 ms 就会因为时钟中断回到调度器。没有核间中断，所以不是立刻停下，最多晚一个时钟周期。xv6 的做法类似（`panicked` 标志，别的 hart 在 `printf` 里卡住）。
- panic 的 hart 输出不拿 `uart.tx_lock`：锁可能就在它自己手里（比如在 `print` 里出错），也可能在已经停下的 hart 手里（[devices.md](devices.md#串口uartzig)）。
- 先关中断再打印，然后（`halt`）把 `sie` 清零，停在 `wfi` 循环里。清零 `sie` 是因为 `wfi` 看的是 `sie & sip`，不看 `sstatus.SIE`：panic 之后没人再预约时钟中断，它会一直挂着；`sie.STIE` 还开着的话，`wfi` 每次都立刻返回，停机就成了忙等，QEMU 占满一个 CPU 核（实测 97%～99%，清零 `sie` 之后是 0%）。规范允许 `wfi` 无故返回，所以仍然放在循环里。
- 内核 panic 后 QEMU 不会退出，管道测试会超时（`timeout` 返回 124），见 [testing.md](testing.md)。

用户程序出错不会走到这里：U 模式的异常只结束那个进程（[process.md](process.md#结束进程)）。
