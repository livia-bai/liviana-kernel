# 物理页分配器

涉及文件：`src/page.zig`（调用方：`src/main.zig`、`src/vm.zig`、`src/shell.zig`）

把内核镜像之后的空闲内存切成 4 KiB 的页，一页一页地分配和释放。页表、用户程序的代码/数据/栈都从这里来。

## 接口

```zig
pub const size = 4096;
pub const Page = [size]u8;

pub var total_pages: usize;   // init 时放进空闲链表的页数
pub var free_pages: usize;    // 当前空闲的页数

pub fn init(start: usize, end: usize, reserved: []const dtb.Region) void
pub fn alloc() error{OutOfMemory}!*align(size) Page   // 返回清零的一页
pub fn free(page: *align(size) Page) void
```

接口直接用指针：内核对所有物理内存做了恒等映射（[paging.md](paging.md#内核页表)），物理地址就是能直接解引用的虚拟地址，开分页前后都一样。返回类型 `*align(4096) [4096]u8` 把“按页对齐”写进了类型，`@ptrCast` 成 `*PageTable` 时不需要再做对齐检查。

## 数据结构：侵入式空闲链表

```zig
var free_list: std.SinglyLinkedList = .{};
```

0.17 的 `std.SinglyLinkedList` 是侵入式的：链表只管 `Node { next: ?*Node }`，节点放在哪由使用者决定。这里每个空闲页的**开头 8 字节**就是它的 `Node`，指向下一个空闲页。所以：

- 记账不占额外内存，也不需要预先知道有多少页。
- 分配：`popFirst()` 取表头，O(1)。
- 释放：`prepend()` 插回表头，O(1)。
- 空闲页的内容除了开头 8 字节都是无意义的；`alloc` 返回前整页清零，所以拿到的页里不会残留上一个使用者的数据（包括链表指针）。这对页表尤其重要：新页表必须全是无效项。对用户程序来说，这也保证了它读不到之前别的进程留下的内容。

## 初始化

```zig
page.init(vm.kernelEnd(), info.memory.end(), info.reserved());
```

1. 范围 = `[alignForward(start, 4096), alignBackward(end, 4096))`，也就是从 `__kernel_end` 到内存末尾。内核之前的 `0x8000_0000..0x8020_0000` 是 OpenSBI 和空隙，不归分配器管。
2. **从高地址往低地址**遍历每一页，跳过和任一保留区重叠的页（`isReserved`：`addr + 4096 > r.base and addr < r.end()`，只要有一个字节重叠就跳过），其余的插到表头。因为是倒着插的，最后表头是最低地址的页：先分配出去的是低地址，调试时地址更好认（新建的页表、用户页都在 `0x802c_xxxx` 附近）。
3. `total_pages = free_pages = 放进去的页数`。

保留区来自设备树（[devicetree.md](devicetree.md#结果)）：设备树自身、内存保留块、`/reserved-memory`。OpenSBI 的两段在内核之前，本来就不在范围里；真正起作用的是设备树自身那 2 页。

实测（Debug 模式，128 MiB）：

```
范围 [0x802c5000, 0x88000000)  = 32059 页
减去设备树占的 2 页            = 32057 页   ← 启动日志 [ok] page allocator: 32057 free pages
建内核页表用掉 5 页            = 32052 页   ← 进 shell 后 mem 命令显示的空闲页数
```

不同优化模式下内核镜像大小不同，`__kernel_end` 不同，页数也会不同。

初始化的开销是“页数 × 保留区数”次比较，32K 页 × 3 段在 QEMU 上可以忽略。初始化时要往每个空闲页写一个指针，这发生在开分页之前，用的是物理地址。

## 分配和释放

```zig
pub fn alloc() error{OutOfMemory}!*align(size) Page {
    const node = free_list.popFirst() orelse return error.OutOfMemory;
    free_pages -= 1;
    const page: *align(size) Page = @ptrCast(@alignCast(node));
    @memset(page, 0);
    return page;
}

pub fn free(page: *align(size) Page) void {
    const addr = @intFromPtr(page);
    if (addr < range.base or addr >= range.end()) {
        std.debug.panic("page.free: 0x{x} was not handed out by the page allocator", .{addr});
    }
    free_list.prepend(@ptrCast(page));
    free_pages += 1;
}
```

- `free` 检查地址是否在分配器管理的范围内，不在就 panic。这能抓住“把一个不是页分配器给的指针拿来释放”这类错误；它在开发 U 模式时确实抓到过一次（进程退出后内核状态被破坏，拿着垃圾值去释放，见 [changes/0005](changes/0005-user-mode-and-syscalls.md)）。
- **不检测重复释放**：同一页释放两次会让它在链表里出现两次，之后被分配给两个使用者。调用方要自己保证。
- 释放时不清零（分配时清）。

## 谁在用

| 调用方 | 用途 | 何时释放 |
| --- | --- | --- |
| `vm.init` | 内核根页表、中间级页表（共 5 页） | 从不 |
| `vm.walk` | 建映射时缺的中间级页表 | 用户区的页表在 `vm.destroyUserSpace` 时释放 |
| `vm.createUserSpace` | 进程的根页表 | `vm.destroyUserSpace` |
| `vm.allocUserPage` | 用户程序的代码、数据、栈 | `vm.destroyUserSpace` |
| `shell` 的 `mem` 命令 | 只读 `free_pages`、`total_pages` | — |

一个用户程序运行时用多少页：根页表 1 + 第 1 级页表 1 + 第 0 级页表 2（各段所在的 `0x4000_0000..0x4020_0000` 一张，栈所在的 `0x7fe0_0000..0x8000_0000` 一张）+ 各段占的页 + 栈 4 页。以 Debug 版 `hello` 为例：代码 19 页 + 只读数据 4 页 + 数据 1 页，合计 4 + 24 + 4 = 32 页。用 GDB 在 `proc.switchToUser` 处停下读 `page.free_pages`，实测正好从 32052 降到 32020。

程序结束后这些页全部还回来，`mem` 前后的数字应该一致；测试时就用这一点检查有没有漏页（[testing.md](testing.md)）。

## 并发

分配器没有锁，也不关中断。安全的前提是：它只在启动阶段和普通内核代码里调用（`kmain`、shell 的 `run` 命令），从不在中断处理程序里调用，而且只有一个 hart。以后如果中断处理程序需要分配内存，或者支持多核，就要加锁或者在分配时关中断。

## 限制和以后可以做的

- 只能一页一页地分配，没有连续多页的分配（需要的话可以改成伙伴系统或位图）。
- 只管理设备树里第一段内存。
- 没有统计谁占用了哪些页；排查泄漏只能看 `free_pages` 的前后差。
