# 0004 物理页分配器和 Sv39 分页

- 日期：2026-10-25
- 提交：`f1041ab` Add a physical page allocator and Sv39 paging
- 涉及文件：`src/page.zig`（新）、`src/vm.zig`（新）、`linker.ld`、`src/main.zig`、`src/riscv.zig`、`src/uart.zig`、`src/plic.zig`、`src/shell.zig`、`README.md`、`AGENTS.md`

## 目标

维护者要求的第二部分：物理页分配 + Sv39 分页。

## 改动

- `src/page.zig`：物理页分配器。`[__kernel_end, 内存末尾)` 里不和保留区重叠的页串成侵入式单链表（`std.SinglyLinkedList`），`alloc` 取表头并清零，`free` 检查地址范围后插回表头。
- `src/vm.zig`：Sv39 页表。`Pte`（`packed struct(u64)`）、`map`（自动选用 1 GiB / 2 MiB / 4 KiB 页）、`walk`、`init`（建内核页表并打开分页）、`activate`（写 `satp` 前后各一次 `sfence.vma`）。
- `linker.ld`：`.rodata`、`.data`、`__kernel_end` 按 4 KiB 对齐，新增 `__text_start`、`__rodata_start`、`__data_start`、`__kernel_end` 符号。
- `src/riscv.zig`：`Csr` 加 `satp`；新增 `satp_sv39`、`sfenceVma()`。
- `src/uart.zig`、`src/plic.zig`：基地址改成 `pub`，新增 `mmio_size`，供 `vm.init` 映射。
- `src/main.zig`：设备树解析之后初始化页分配器、建页表开分页，各打印一行 `[ok]`。
- `src/shell.zig`：新增 `mem` 命令。
- README：新增“内存管理”一节，`crash` 的说明改为缺页异常；AGENTS.md：新增链接脚本对齐的约定。

细节见 [page-allocator.md](../page-allocator.md)、[paging.md](../paging.md)。

## 设计决策

- **恒等映射**：写 `satp` 的那一刻正在执行的代码地址不变，页分配器给出的物理地址也能继续当指针用。代价是内核和用户空间要分享低半部分的地址，这在 [0005](0005-user-mode-and-syscalls.md) 里通过“用户只用根页表第 1 项”解决。没有做高半部分内核（需要重定位、跳板代码，复杂得多）。
- **按段设置权限（W^X）**：代码 R-X、只读数据 R--、其余 RW-。为此链接脚本里的段按页对齐。
- **能用大页就用大页**：128 MiB 内存如果全用 4 KiB 页需要 64 张第 0 级页表（256 KiB）；用 2 MiB 页后整个内核页表只要 5 页。内核镜像所在的 2 MiB 里因为权限不同必须用 4 KiB 页。
- **A、D 位预先置 1**：不依赖硬件自动置位。
- **内核映射带 G 位**，为以后的多地址空间做准备。
- **页分配器的接口直接用指针**，返回类型 `*align(4096) [4096]u8` 把对齐写进类型。
- 用户空间相关的函数（`createUserSpace` 等）当时已经写好，但为了让提交保持单一主题，挪到了 0005。

## 验证

### 环境

Zig 0.17.0、QEMU 8.2.2、OpenSBI v1.3（同 [0003](0003-device-tree.md)）。

### 步骤和结果

**四种优化模式**：启动、`mem`、`uptime`、`ebreak`、`crash` 都按预期，以 Debug 为例：

```
[ok] device tree: 128 MiB RAM at 0x80000000, timebase 10000000 Hz
[ok] page allocator: 32138 free pages (128552 KiB)
[ok] Sv39 paging enabled: kernel mapped 1:1, text r-x, rodata r--, data rw-
[ok] interrupts enabled: timer at 100 Hz, keyboard via UART + PLIC
> mem
32133 of 32138 pages free (128532 KiB), 4 KiB each
> crash
!!! KERNEL PANIC: unhandled exception: load_page_fault (scause=13), sepc=0x80216472, stval=0x0
```

- 开分页后串口、PLIC、时钟中断都正常（shell 能用、`uptime` 在走）。
- `mem` 比启动时少 5 页，正是内核页表的页数（根 + 两张第 1 级 + 两张第 0 级）。
- `crash` 读地址 0 从原来的 `load_access_fault`（物理地址 0 处没有任何设备，访问出错）变成了 `load_page_fault`（虚拟地址 0 没有映射，在翻译这一步就失败了），符合预期。

**空闲页数核对**：当时 `__kernel_end = 0x80275000`，`(0x88000000 - 0x80275000) / 4096 = 32139` 页，减去设备树的 2 页 = 32137，和带着插桩代码（内核大了一页）时打印的 `32137 free pages` 一致。

**W^X**：临时在 `kmain` 末尾往自己的代码页写一个字：

```zig
const code: *volatile u32 = @ptrFromInt(@intFromPtr(&kmain) & ~@as(usize, 3));
uart.print("  text word 0x{x}, now writing it...\n", .{code.*});
code.* = 0;
```

结果：

```
  text word 0x95010113, now writing it...
!!! KERNEL PANIC: unhandled exception: store_page_fault (scause=15), sepc=0x8021608c, stval=0x80215c44
```

读可以、写触发缺页，代码段确实是只读的。测完删掉。（第一次写成 `@ptrCast(@constCast(&kmain))`，编译报 `@ptrCast increases pointer alignment`：函数指针只有 2 字节对齐，改成先转整数再对齐。）

**段布局**：`llvm-readelf -lS zig-out/bin/kernel` 确认 `.rodata`、`.data` 从页边界开始，链接脚本没提到的 `.eh_frame_hdr`、`.eh_frame` 落在 `.rodata` 之后、`__data_start` 之前，被映射成只读。

**拆分提交**：和 0003 一样，先把 U 模式需要的部分（`sscratch`、`SPP`/`SPIE` 常量、Ctrl-C、用户空间函数）临时拿掉，单独验证了这个提交的状态。

**体积**：small 模式 `.text` 从 0x1fba 增加到 0x2566 字节（约 9.3 KB），README 里的数字同步更新。

## 发现的问题

测试中没有发现问题。

## 遗留问题

- 页分配器只能单页分配，不检测重复释放，不是中断安全的（[page-allocator.md](../page-allocator.md#限制和以后可以做的)）。
- 内核栈下面没有保护页：栈溢出时陷阱处理程序也在同一个栈上，会连锁出错，需要单独的异常栈才有意义。
