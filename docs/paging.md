# Sv39 分页

涉及文件：`src/vm.zig`（以及 `linker.ld` 里的段边界符号；调用方：`src/main.zig`、`src/proc.zig`、`src/syscall.zig`）

## Sv39 基础

Sv39 是 RV64 上最常用的分页模式：虚拟地址有效位 39 位（512 GiB），物理地址最多 56 位。

### 地址拆分

```
 38        30 29        21 20        12 11            0
+------------+------------+------------+---------------+
|   VPN[2]   |   VPN[1]   |   VPN[0]   |   页内偏移     |
|   9 位     |   9 位     |   9 位     |   12 位        |
+------------+------------+------------+---------------+
```

第 39..63 位必须等于第 38 位（符号扩展），否则访问会触发缺页异常。这个内核只用低半部分（第 38 位为 0），所以虚拟地址都小于 `0x40_0000_0000`。

### 三级页表

每张页表 512 项、每项 8 字节，正好一页（4 KiB）。翻译过程：

1. 从 `satp` 里取根页表的物理页号，用 VPN[2] 索引得到一项。
2. 这一项无效（V = 0）→ 缺页异常。
3. R/W/X 中有一位为 1 → 这是**叶子**，翻译到此为止。
4. R/W/X 全为 0 → 这一项指向下一级页表，用 VPN[1]（再下一级用 VPN[0]）继续。第 0 级的项必须是叶子。

在不同级停下的叶子映射的大小不同：

| 叶子所在级 | 映射大小 | 对齐要求 |
| --- | --- | --- |
| 第 2 级（根） | 1 GiB | 虚拟地址和物理地址都 1 GiB 对齐 |
| 第 1 级 | 2 MiB | 都 2 MiB 对齐 |
| 第 0 级 | 4 KiB | 都 4 KiB 对齐 |

### 页表项

```
 63  54 53                        10 9  8 7 6 5 4 3 2 1 0
+------+----------------------------+----+-+-+-+-+-+-+-+-+
| 保留 |            PPN             |RSW |D|A|G|U|X|W|R|V|
+------+----------------------------+----+-+-+-+-+-+-+-+-+
```

| 位 | 含义 |
| --- | --- |
| V | 有效 |
| R / W / X | 可读 / 可写 / 可执行；全 0 表示指向下一级页表。W = 1 且 R = 0 是保留组合，不能用 |
| U | U 模式可以访问。S 模式默认**不能**访问 U 页（除非 `sstatus.SUM = 1`），也永远不能执行 U 页里的代码 |
| G | 全局映射：在所有地址空间里都存在，切换地址空间时不需要作废 TLB 里的这一项 |
| A / D | 访问过 / 写过。规范允许硬件在它们为 0 时直接产生缺页异常，而不是自动置位 |
| RSW | 留给软件用，这里没用 |
| PPN | 物理页号 = 物理地址 >> 12，44 位 |

## 数据类型

```zig
pub const Pte = packed struct(u64) {
    v: bool = false, r: bool = false, w: bool = false, x: bool = false,
    u: bool = false, g: bool = false, a: bool = false, d: bool = false,
    rsw: u2 = 0,
    ppn: u44 = 0,
    reserved: u10 = 0,
};
pub const PageTable = [512]Pte;
pub const Perm = struct { r: bool = false, w: bool = false, x: bool = false, u: bool = false };
pub const MapError = error{ OutOfMemory, AlreadyMapped };
```

`packed struct(u64)` 的字段从最低位开始排，和硬件格式一一对应，编译器保证总共正好 64 位。

**A 和 D 总是直接置 1。** 这个内核不靠它们统计页面访问情况，预先置位可以避免“硬件不自动置位、要靠缺页异常让软件来置位”这种实现带来的额外缺页。

## 建立映射

```zig
pub fn map(root: *PageTable, va: usize, pa: usize, size: usize, perm: Perm) MapError!void
```

把虚拟地址 `[va, va+size)` 映射到物理地址 `[pa, pa+size)`。

**前提**（用 `std.debug.assert` 检查，Debug/safe 模式下违反会 panic）：

- `va`、`pa`、`size` 都按 4 KiB 对齐。
- 叶子权限合法：`r` 或 `x` 至少有一个，有 `w` 就必须有 `r`。R/W/X 全为 0 的“叶子”会被 CPU 当成指向下一级页表的指针，后果很严重（见 [process.md](process.md#elf-加载器) 里“为什么一定要拒绝不可读的段”）。
- 用户映射（`perm.u`）必须完全落在 `[user_base, user_end)` 里；内核映射不能和这个范围有任何重叠（原因见下文“用户地址空间”）。

**算法**：从 `offset = 0` 开始，每一步选一个尽量大的页：

```zig
const level: u2 = for ([_]u2{ 2, 1 }) |l| {
    const s = levelSize(l);
    if ((va + offset) % s == 0 and (pa + offset) % s == 0 and size - offset >= s) break l;
} else 0;
```

也就是：当前的虚拟地址和物理地址都按 1 GiB 对齐、剩余长度也够 1 GiB，就用 1 GiB 的页；否则试 2 MiB；都不行就用 4 KiB。然后用 `walk` 找到那一级的页表项，已经有效就返回 `AlreadyMapped`，否则写入叶子：`v = 1`、权限来自 `perm`、`g = !perm.u`、`a = d = 1`、`ppn = (pa + offset) >> 12`。

```zig
fn walk(root: *PageTable, va: usize, level: u2) MapError!*Pte
```

从根页表往下走到第 `level` 级，途中遇到无效的项就用 `page.alloc()` 分配一张清零的新页表、填一个指向它的非叶子项（只有 V = 1）。途中遇到叶子说明这段地址已经被一个大页覆盖，返回 `AlreadyMapped`。

`map` 失败时已经建好的那部分映射和页表不会回滚。内核页表失败了直接 panic；用户地址空间失败了，整个地址空间会被 `destroyUserSpace` 一起释放，所以都没有问题。

## 内核页表

```zig
pub fn init(memory: dtb.Region) MapError!void
```

`kmain` 在页分配器初始化之后调用它。所有内核映射都是**恒等映射**（虚拟地址 = 物理地址），不带 U 位，带 G 位：

| 范围 | 来自 | 权限 | Debug 模式实测 | 页大小 |
| --- | --- | --- | --- | --- |
| `[__text_start, __rodata_start)` | 代码 | R-X | `0x80200000..0x8024c000` | 4 KiB |
| `[__rodata_start, __data_start)` | 只读数据（含 `.eh_frame`、嵌入的用户程序 ELF） | R-- | `0x8024c000..0x802af000` | 4 KiB |
| `[__data_start, __kernel_end)` | `.data`、`.bss`、启动栈、进程内核栈 | RW- | `0x802af000..0x802c5000` | 4 KiB |
| `[__kernel_end, 内存末尾)` | 页分配器管理的内存、设备树 | RW- | `0x802c5000..0x88000000` | 到 `0x80400000` 为止用 4 KiB，之后 62 个 2 MiB |
| 串口 | `uart.base`、`uart.mmio_size` 向上取整到页 | RW- | `0x10000000..0x10001000` | 4 KiB |
| PLIC | `plic.base`、`plic.mmio_size` | RW- | `0x0c000000..0x0c600000` | 3 个 2 MiB |

整张内核页表一共 5 页：

```
根页表
├─ [0] → 第 1 级页表 A
│        ├─ [0x60..0x62]  PLIC 的 3 个 2 MiB 叶子
│        └─ [0x80] → 第 0 级页表（只有串口这 1 项）
└─ [2] → 第 1 级页表 B
         ├─ [1] → 第 0 级页表（0x8020_0000..0x8040_0000：内核镜像按段的 4 KiB 叶子 + 之后的空闲内存）
         └─ [2..63]  0x8040_0000..0x8800_0000 的 62 个 2 MiB 叶子
```

`mem` 命令在启动后显示的空闲页比启动日志里少 5，就是这 5 页。

几点说明：

- **为什么是恒等映射**：写 `satp` 的那一刻 CPU 就开始翻译地址，正在执行的代码地址必须在新页表里映射到同一个物理地址，否则下一条指令就会取错。恒等映射一次性解决这个问题，也让页分配器给出的物理地址可以继续直接当指针用（分配页表、往用户页里复制数据都靠这一点）。
- **按段设权限**带来的保护：往代码或只读数据里写会触发写缺页（`store_page_fault`），跳到数据或空闲内存里执行会触发取指缺页。这要求各段按页对齐，见 [boot.md](boot.md#链接脚本)。开发时用一段临时代码验证过：往 `kmain` 所在的代码页写一个字，得到 `store_page_fault`。
- **不映射的地方**：内核之前的 `0x8000_0000..0x8020_0000`（其中 `0x8000_0000..0x8006_0000` 是 OpenSBI，PMP 本来就不让 S 模式访问；后面是空着的，内核用不到）；地址 0 附近（空指针解引用变成 `load_page_fault`，shell 的 `crash` 命令演示的就是这个）；设备树里的其他外设（virtio、RTC 等，内核不用）。
- 开始映射前检查内核镜像是否完全在设备树报告的内存范围里，不在就 panic（`kernel image is outside of RAM`）。

## 切换地址空间

```zig
pub fn activate(root: *PageTable) void {
    riscv.sfenceVma();
    riscv.write(.satp, riscv.satp_sv39 | (@intFromPtr(root) >> 12));
    riscv.sfenceVma();
}
```

- `satp` = MODE（最高 4 位，8 = Sv39）| ASID（第 44..59 位，这里一直是 0）| 根页表的物理页号。
- 规范规定写 `satp` 本身不保证之前对页表的修改已经生效，也不会作废 TLB。所以写之前和之后各执行一次 `sfence.vma`：之前的那次保证页表的写入对页表遍历可见，之后的那次作废旧地址空间留在 TLB 里的翻译。
- 没有使用 ASID，所有地址空间都是 ASID 0，所以每次切换都要作废整个 TLB。内核映射带 G 位，规范允许实现保留它们，但不带参数的 `sfence.vma` 会连全局项一起作废，这里也没有依赖这个优化。
- `vm.init` 最后调用 `activate(kernel_root)` 打开分页；`proc.schedule` 每次切到进程前切到它的地址空间，进程让出 CPU 后切回 `kernel_root`（回收进程的页表之前必须先切走）。

## 用户地址空间

```zig
pub const user_base: usize = 0x4000_0000;
pub const user_end: usize = 0x8000_0000;
```

用户程序只能使用根页表的**第 1 项**覆盖的这 1 GiB。内核的映射都不在这一项里：外设在第 0 项（`0x0..0x4000_0000`），内存从第 2 项开始（`0x8000_0000..`）。这样：

- 新建地址空间只需要复制内核的根页表（512 项，一页）。复制出来的第 0、2 项指向内核的第 1 级页表，**下面的页表全部共用**，不用复制；第 1 项在内核页表里是空的，留给这个进程自己填。
- 进程的映射全部在第 1 项下面，释放时只需要遍历这一项，不会碰到共用的内核页表。
- 陷入内核时不需要切换页表：内核的代码、数据、栈在进程的地址空间里照样映射着，只是没有 U 位，U 模式访问不到。

这就是 `map` 断言“内核映射不能进入用户区”的原因：如果内核往第 1 项里加了映射，它就会出现在之后复制出来的每个进程的根页表里，而且会被进程的映射覆盖或者在释放时被当成进程的页释放掉。

QEMU `virt` 上 `0x4000_0000..0x8000_0000` 其实是 PCIe 的 32 位 MMIO 窗口（设备树 `pci@30000000` 的 `ranges`），但内核不用 PCIe，从不映射它，所以没有冲突。

### 函数

```zig
pub fn createUserSpace() error{OutOfMemory}!*PageTable
```

分配一页作为根页表，内容复制 `kernel_root.*`。

```zig
pub fn allocUserPage(root: *PageTable, va: usize, perm: Perm) MapError!*align(page.size) page.Page
```

分配一页清零的物理内存，以 `perm` + U 位映射到用户地址 `va`，返回这一页的指针（内核通过恒等映射直接往里写，比如复制 ELF 的内容）。映射失败时把刚分配的页还回去（`errdefer`）。用户映射**只用 4 KiB 的页**，每一页单独分配，所以物理上不连续也没关系。

```zig
pub fn destroyUserSpace(root: *PageTable) void
```

释放用户区（根页表第 1 项）下面的所有东西：`freeTree` 递归地释放每个有效的叶子指向的物理页、每一张中间级页表，最后释放根页表本身。**调用前必须已经切换到别的地址空间**，否则正在使用的页表会被释放。`freeTree` 把叶子都当作 4 KiB 的页释放，这依赖于“用户映射只用 4 KiB 的页”。

```zig
fn translateUser(root: *PageTable, va: usize) ?usize
pub fn copyFromUser(root: *PageTable, dst: []u8, src: usize) error{BadAddress}!void
```

`translateUser` 用软件走一遍页表，把用户虚拟地址翻译成物理地址；要求地址在用户区里，叶子有效、带 U 位、可读，否则返回 null。`copyFromUser` 在此基础上逐页翻译、逐页复制，是系统调用读取用户内存的唯一途径，详见 [syscalls.md](syscalls.md#访问用户内存)。

## 调试技巧

- 想确认映射，可以在 GDB 里用 `monitor info mem`（QEMU 监视器命令，打印当前 `satp` 下的所有映射，相邻且权限相同的会合并成一行）。开分页之后在 `plic.init` 处停下，Debug 模式下的实际输出：

  ```
  vaddr            paddr            size             attr
  ---------------- ---------------- ---------------- -------
  000000000c000000 000000000c000000 0000000000600000 rw--gad     PLIC
  0000000010000000 0000000010000000 0000000000001000 rw--gad     串口
  0000000080200000 0000000080200000 000000000004c000 r-x-gad     .text
  000000008024c000 000000008024c000 0000000000063000 r---gad     .rodata
  00000000802af000 00000000802af000 0000000000151000 rw--gad     .data 到 0x8040_0000（4 KiB 页）
  0000000080400000 0000000080400000 0000000007c00000 rw--gad     其余内存（2 MiB 页）
  ```

  `attr` 依次是 r、w、x、u、g、a、d；内核映射都没有 `u`，都有 `g`。在用户程序运行时停下（比如断在 `syscall.dispatch`），还能看到 `0x4000_0000` 起带 `u` 的用户映射。GDB 的用法见 [testing.md](testing.md#gdb)。
- 想看缺页发生在哪：内核态的缺页会 panic 并打印 `sepc`（出错指令）和 `stval`（出错地址）；QEMU 的 `-d int` 会记录每一次陷阱（[testing.md](testing.md#qemu-的陷阱日志)）。
- 改了内核映射以后，四种优化模式都要跑（`qemu_test.py --all-modes`）：映射错一页往往只在某些模式下才会被访问到（各模式下内核镜像的大小、段边界都不一样）。
