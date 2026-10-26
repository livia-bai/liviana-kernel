# 启动流程

涉及文件：`linker.ld`、`src/main.zig`

## 从上电到内核

1. QEMU 把 OpenSBI 放在 `0x8000_0000`，把内核 ELF 的各段按程序头放到 `0x8020_0000` 起的物理地址，把设备树放在内存靠顶端的位置（128 MiB 时是 `0x87e0_0000`），然后从 OpenSBI 开始执行（M 模式）。
2. OpenSBI 初始化串口、定时器、PMP（物理内存保护，把自己所在的 `0x8000_0000..0x8006_0000` 设成 S/U 模式不可访问）和中断/异常委托，在设备树里加上 `/reserved-memory` 节点登记自己占用的内存，打印启动横幅。
3. OpenSBI 以 S 模式跳到 `0x8020_0000`（启动横幅里的 `Domain0 Next Address`），寄存器状态：
   - `a0` = 当前 hart 的编号（单核时是 0）
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
             __bss_start    .bss       .sbss、.bss、COMMON（NOLOAD：ELF 里不占空间）
             __bss_end
                            64 KiB 启动栈
             __stack_top
             （4 KiB 对齐）
             __kernel_end              之后的内存交给页分配器
```

- `ENTRY(_start)` 设置 ELF 入口；更重要的是 `.text.boot` 排在 `.text` 最前面，保证 `_start` 正好在 `0x8020_0000`，因为 OpenSBI 跳到的是这个固定地址，而不是 ELF 的入口字段。
- `.rodata`、`.data` 和 `__kernel_end` 都按 4 KiB 对齐，这样每一页只属于一个段，开分页时可以分别设置权限（代码 R-X、只读数据 R--、其余 RW-，见 [paging.md](paging.md#内核页表)）。`vm.zig` 通过 `__text_start`、`__rodata_start`、`__data_start`、`__kernel_end` 这四个符号确定边界，改链接脚本时要保持它们的含义和对齐。
- 没在脚本里列出的段（如 `.eh_frame_hdr`、`.eh_frame`）是“孤儿段”，LLD 会把它们放在属性最接近的段后面。它们是只读的，落在 `.rodata` 之后、`__data_start` 之前，所以也被映射成只读。可以用 `llvm-readelf -S zig-out/bin/kernel` 确认。
- `.bss` 标成 `NOLOAD`，ELF 文件里没有它的内容，`_start` 要自己清零。启动栈放在 `.bss` 后面同一个输出段里，也不占文件空间。

Debug 模式下实测的符号值（代码改动后会变）：

| 符号 | 地址 |
| --- | --- |
| `__text_start` | `0x80200000` |
| `__rodata_start` | `0x8024c000` |
| `__data_start` | `0x802af000` |
| `__bss_start` / `__bss_end` | `0x802af040` / `0x802b4280` |
| `__stack_top` | `0x802c4280` |
| `__kernel_end` | `0x802c5000` |

查看方法：`llvm-nm zig-out/bin/kernel | grep __`（release 模式的 ELF 不带符号表，要在 Debug 下看）。

## `_start`

```zig
export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\la sp, __stack_top
        \\la t0, __bss_start
        \\la t1, __bss_end
        \\1:
        \\bgeu t0, t1, 2f
        \\sd zero, 0(t0)
        \\addi t0, t0, 8
        \\j 1b
        \\2:
        \\tail %[kmain]
        :
        : [kmain] "X" (&kmain),
    );
}
```

- 必须是裸函数（`callconv(.naked)`）：普通函数的序言会用 `sp` 压栈，而此时还没有栈。
- `linksection(".text.boot")` 配合链接脚本把它放在 `0x8020_0000`。
- 设好 `sp` 后，以 8 字节为单位清零 `[__bss_start, __bss_end)`（链接脚本保证 `__bss_end` 8 字节对齐）。所有初值为 0 的全局变量（例如 `timer.ticks`、页分配器的链表头）都在 `.bss` 里，不清零就是 QEMU 留下的随机内容。
- 全程没碰 `a0`、`a1`，`tail` 跳到 `kmain` 时它们原样成为 `kmain(hartid, dtb_addr)` 的两个参数。`tail` 不保存返回地址，`kmain` 也是 `noreturn`。

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
| 8 | `plic.init(hartid)`、`timer.init(info.timebase_hz)` | — | 配置外部中断和第一次时钟中断，并在 `sie` 里打开对应的使能位 |
| 9 | `riscv.enableInterrupts()` | `[ok] interrupts enabled: timer at 100 Hz, keyboard via UART + PLIC` | 最后才置 `sstatus.SIE`，之前的初始化都不会被中断打断 |
| 10 | `shell.prompt()` + 主循环 | `Type 'help' for commands.`、`> ` | |

任何一步失败（设备树格式不对、建页表时内存不够）都会 `std.debug.panic`，打印原因后停机。

## 主循环

```zig
while (true) {
    riscv.disableInterrupts();
    const c = uart.read();
    if (c == null) riscv.wfi();
    riscv.enableInterrupts(); // 挂起的中断在这里立刻被处理
    if (c) |ch| shell.feed(ch);
}
```

顺序不能改，原因是一个经典的竞争：如果开着中断检查缓冲区，可能出现“检查时缓冲区为空 → 正要执行 `wfi` 时字符到了，中断处理程序把它放进缓冲区 → `wfi` 睡下去”，这个字符要等到下一个中断（最长 10 ms 后的时钟中断）才会被处理。

关中断后再检查就没有这个问题：字符在检查之后到达时，中断只是挂起（`sip.SEIP` 置位）而不会被处理；`wfi` 只看 `sie` 和 `sip`、不看 `sstatus.SIE`，有挂起的中断就立即返回；接着 `enableInterrupts()` 让挂起的中断马上被处理。

`uart.read()` 要求调用时中断是关着的（它和中断处理程序共用环形缓冲区的索引），这个循环正好满足。`shell.feed` 在开着中断时调用，shell 执行 `run` 时会在里面停留到用户程序结束。

## panic 处理

```zig
pub const panic = std.debug.FullPanic(kernelPanic);

fn kernelPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    riscv.disableInterrupts();
    uart.print("\n!!! KERNEL PANIC: {s}\n", .{msg});
    uart.write("system halted.\n");
    riscv.write(.sie, 0);
    while (true) riscv.wfi();
}
```

- 根文件里的 `pub const panic` 替换标准库默认的 panic 处理（freestanding 下默认是直接 `@trap()`）。`@panic`、`std.debug.panic`，以及 Debug/safe 模式下的安全检查失败（整数溢出、越界、`.?` 取到 null 等）都会走到这里。必须写成 `pub`，0.17 起 `@hasDecl` 只认公开声明。
- `FullPanic` 会把各种安全检查失败格式化成可读的消息再交给 `kernelPanic`。0.17.0 的 `std.debug.simple_panic` 有回归（#36986），编译不过，不要用。
- 先关中断再打印，然后把 `sie` 清零，停在 `wfi` 循环里。清零 `sie` 是因为 `wfi` 看的是 `sie & sip`，不看 `sstatus.SIE`：panic 之后没人再预约时钟中断，它会一直挂着；`sie.STIE` 还开着的话，`wfi` 每次都立刻返回，停机就成了忙等，QEMU 占满一个 CPU 核（实测 97%～99%，清零 `sie` 之后是 0%）。规范允许 `wfi` 无故返回，所以仍然放在循环里。
- 内核 panic 后 QEMU 不会退出，管道测试会超时（`timeout` 返回 124），见 [testing.md](testing.md)。

用户程序出错不会走到这里：U 模式的异常只结束那个进程（[process.md](process.md#结束进程)）。
