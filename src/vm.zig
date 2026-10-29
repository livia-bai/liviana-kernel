//! Sv39 分页。虚拟地址 39 位，拆成 VPN[2] | VPN[1] | VPN[0] | 页内偏移（9 + 9 + 9 + 12 位）。
//! 页表有三级，每级 512 项、每项 8 字节，一张页表正好一页。CPU 从 satp 指向的根页表开始，
//! 用 VPN[2]、VPN[1]、VPN[0] 依次索引：某一项的 R/W/X 有一位为 1 就是叶子，映射到此为止；
//! 全为 0 则指向下一级页表。在第 2、1 级就停下的叶子是 1 GiB、2 MiB 的大页。
//!
//! 内核的映射：物理内存和外设都按“虚拟地址 = 物理地址”恒等映射，所以开分页前后地址不变，
//! 页分配器给出的物理地址也能直接当指针用。代码 R-X、只读数据 R--、其余 RW-，都不带 U 位，
//! U 模式访问不到。
//!
//! 用户地址空间：根页表的第 1 项（0x4000_0000..0x8000_0000，1 GiB）专门留给用户程序。
//! 内核的映射都不落在这一项里（外设在第 0 项，内存从第 2 项开始），所以每个进程的根页表
//! 直接复制内核根页表的其他项、共用下面的页表即可，陷入内核时不用切换页表。

const std = @import("std");
const riscv = @import("riscv.zig");
const page = @import("page.zig");
const dtb = @import("dtb.zig");
const uart = @import("uart.zig");
const plic = @import("plic.zig");

pub const user_base: usize = 0x4000_0000;
pub const user_end: usize = 0x8000_0000;

/// 页表项。A（访问过）和 D（写过）位直接置 1：规范允许硬件在它们为 0 时触发缺页异常，
/// 而不是自动置位，这个内核不需要靠它们统计页面使用情况。
pub const Pte = packed struct(u64) {
    v: bool = false,
    r: bool = false,
    w: bool = false,
    x: bool = false,
    u: bool = false,
    /// 全局映射：所有地址空间都有，切换地址空间时 TLB 里的这些项不用作废
    g: bool = false,
    a: bool = false,
    d: bool = false,
    rsw: u2 = 0,
    ppn: u44 = 0,
    reserved: u10 = 0,

    fn isLeaf(pte: Pte) bool {
        return pte.r or pte.w or pte.x;
    }

    fn addr(pte: Pte) usize {
        return @as(usize, pte.ppn) << 12;
    }
};

pub const PageTable = [512]Pte;

pub const Perm = struct {
    r: bool = false,
    w: bool = false,
    x: bool = false,
    u: bool = false,
};

pub const MapError = error{ OutOfMemory, AlreadyMapped };

// 链接脚本（linker.ld）里定义的符号，标出内核镜像各段的边界，都按页对齐
extern const __text_start: u8;
extern const __rodata_start: u8;
extern const __data_start: u8;
extern const __kernel_end: u8;

pub fn kernelEnd() usize {
    return @intFromPtr(&__kernel_end);
}

pub var kernel_root: *PageTable = undefined;

/// 建立内核页表并打开分页。
pub fn init(memory: dtb.Region) MapError!void {
    const text = @intFromPtr(&__text_start);
    const rodata = @intFromPtr(&__rodata_start);
    const data = @intFromPtr(&__data_start);
    const end = kernelEnd();
    const mem_end = std.mem.alignBackward(usize, memory.end(), page.size);
    if (text < memory.base or end > mem_end) @panic("kernel image is outside of RAM");

    kernel_root = @ptrCast(try page.alloc());
    try map(kernel_root, text, text, rodata - text, .{ .r = true, .x = true });
    try map(kernel_root, rodata, rodata, data - rodata, .{ .r = true });
    try map(kernel_root, data, data, end - data, .{ .r = true, .w = true });
    // 内核之后的内存：页分配器管理的页、页表、设备树都在这里。
    // 内核之前是 OpenSBI，S 模式本来就无权访问（被 PMP 挡住），不映射。
    try map(kernel_root, end, end, mem_end - end, .{ .r = true, .w = true });
    try mapMmio(uart.base, uart.mmio_size);
    try mapMmio(plic.base, plic.mmio_size);

    activate(kernel_root);
}

fn mapMmio(base: usize, size: usize) MapError!void {
    try map(kernel_root, base, base, std.mem.alignForward(usize, size, page.size), .{ .r = true, .w = true });
}

/// 切换到 root 描述的地址空间。
pub fn activate(root: *PageTable) void {
    riscv.sfenceVma();
    riscv.write(.satp, riscv.satp_sv39 | (@intFromPtr(root) >> 12));
    riscv.sfenceVma();
}

/// 第 level 级（0、1、2）一个叶子映射的大小：4 KiB、2 MiB、1 GiB。
fn levelSize(level: u2) usize {
    return @as(usize, 1) << (12 + 9 * @as(u6, level));
}

fn vpn(va: usize, level: u2) usize {
    return (va >> (12 + 9 * @as(u6, level))) & 0x1ff;
}

/// 把虚拟地址 [va, va+size) 映射到物理地址 [pa, pa+size)，地址和长度都要按页对齐。
/// 对齐条件和剩余长度允许时就用大页，这样 128 MiB 内存只需要几张页表。
pub fn map(root: *PageTable, va: usize, pa: usize, size: usize, perm: Perm) MapError!void {
    std.debug.assert(va % page.size == 0 and pa % page.size == 0 and size % page.size == 0);
    // 叶子必须至少可读或可执行（R/W/X 全为 0 表示指向下一级页表），可写必须可读（W 无 R 是保留组合）
    std.debug.assert((perm.r or perm.x) and (perm.r or !perm.w));
    // 用户映射只能落在用户区里，内核映射不能落进用户区，否则进程之间会共用页表（见文件开头）
    const in_user = va >= user_base and va + size <= user_end;
    const overlaps_user = va < user_end and va + size > user_base;
    std.debug.assert(if (perm.u) in_user else !overlaps_user);

    var offset: usize = 0;
    while (offset < size) {
        const level: u2 = for ([_]u2{ 2, 1 }) |l| {
            const s = levelSize(l);
            if ((va + offset) % s == 0 and (pa + offset) % s == 0 and size - offset >= s) break l;
        } else 0;
        const pte = try walk(root, va + offset, level);
        if (pte.v) return error.AlreadyMapped;
        pte.* = .{
            .v = true,
            .r = perm.r,
            .w = perm.w,
            .x = perm.x,
            .u = perm.u,
            .g = !perm.u,
            .a = true,
            .d = true,
            .ppn = @intCast((pa + offset) >> 12),
        };
        offset += levelSize(level);
    }
}

/// 找到 va 在第 level 级页表里的那一项，途中缺的页表现场分配。
fn walk(root: *PageTable, va: usize, level: u2) MapError!*Pte {
    var table = root;
    var l: u2 = 2;
    while (l > level) : (l -= 1) {
        const pte = &table[vpn(va, l)];
        if (!pte.v) {
            const next = try page.alloc();
            pte.* = .{ .v = true, .ppn = @intCast(@intFromPtr(next) >> 12) };
        } else if (pte.isLeaf()) {
            return error.AlreadyMapped; // 已经被一个大页覆盖了
        }
        table = @ptrFromInt(pte.addr());
    }
    return &table[vpn(va, level)];
}

/// 新建一个用户地址空间：复制内核的根页表（第 1 项在内核页表里是空的，留给用户程序）。
pub fn createUserSpace() error{OutOfMemory}!*PageTable {
    const root: *PageTable = @ptrCast(try page.alloc());
    root.* = kernel_root.*;
    return root;
}

/// 释放用户地址空间：用户区里的页、装这些页的页表，最后是根页表本身。
/// 调用前要先切回别的地址空间。
pub fn destroyUserSpace(root: *PageTable) void {
    for (vpn(user_base, 2)..vpn(user_end - 1, 2) + 1) |i| freeTree(root[i], 2);
    page.free(@ptrCast(@alignCast(root)));
}

fn freeTree(pte: Pte, level: u2) void {
    if (!pte.v) return;
    if (!pte.isLeaf() and level > 0) {
        const table: *PageTable = @ptrFromInt(pte.addr());
        for (table) |child| freeTree(child, level - 1);
    }
    // 叶子是 allocUserPage 分配的页（用户映射只用 4 KiB 的页），非叶子是页表，都还给页分配器
    page.free(@ptrFromInt(pte.addr()));
}

/// 分配一页清零的物理内存，映射到用户地址 va，返回这一页（内核通过恒等映射访问它）。
pub fn allocUserPage(root: *PageTable, va: usize, perm: Perm) MapError!*align(page.size) page.Page {
    const p = try page.alloc();
    errdefer page.free(p);
    var user_perm = perm;
    user_perm.u = true;
    try map(root, va, @intFromPtr(p), page.size, user_perm);
    return p;
}

/// 把用户区 [alignForward(old_end), alignForward(new_end)) 的页都映射上（清零，权限 perm），
/// 用来把一段内存（堆）从 old_end 长到 new_end（old_end < new_end，都按字节算）。
/// 内存不够时把这次映射上的页都释放掉，地址空间保持原样。
pub fn growUser(root: *PageTable, old_end: usize, new_end: usize, perm: Perm) error{OutOfMemory}!void {
    std.debug.assert(old_end <= new_end and new_end <= user_end);
    const start = std.mem.alignForward(usize, old_end, page.size);
    var va = start;
    errdefer shrinkUser(root, va, start);
    while (va < new_end) : (va += page.size) {
        _ = allocUserPage(root, va, perm) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AlreadyMapped => unreachable, // 调用方保证 old_end 之后没有映射
        };
    }
}

/// growUser 反过来：把用户区 [alignForward(new_end), alignForward(old_end)) 的页取消映射并释放
/// （new_end <= old_end）。因此空出来的第 0 级页表也释放掉：不然堆长到很大再缩回来，
/// 每 2 MiB 会留下一张空页表，直到进程结束。
/// 改的可能是正在用的页表，调用方要刷新 TLB。
pub fn shrinkUser(root: *PageTable, old_end: usize, new_end: usize) void {
    std.debug.assert(new_end <= old_end);
    const start = std.mem.alignForward(usize, new_end, page.size);
    var va = start;
    while (va < old_end) : (va += page.size) {
        const pte = leafOf(root, va) orelse unreachable; // growUser 映射过的页
        page.free(@ptrFromInt(pte.addr()));
        pte.* = .{};
    }
    // 第 1 级页表（整个用户区只有一张）里还有栈的映射，不会空，不用管
    var region = std.mem.alignBackward(usize, start, levelSize(1));
    while (region < old_end) : (region += levelSize(1)) {
        const l2 = root[vpn(region, 2)];
        if (!l2.v or l2.isLeaf()) continue;
        const l1: *Pte = &@as(*PageTable, @ptrFromInt(l2.addr()))[vpn(region, 1)];
        if (!l1.v or l1.isLeaf()) continue;
        const table: *PageTable = @ptrFromInt(l1.addr());
        for (table) |pte| {
            if (pte.v) break;
        } else {
            page.free(@ptrCast(@alignCast(table)));
            l1.* = .{};
        }
    }
}

/// 找到用户地址 va 的第 0 级页表项（已经映射了的 4 KiB 页），没有就返回 null。不分配页表。
fn leafOf(root: *PageTable, va: usize) ?*Pte {
    var table = root;
    var l: u2 = 2;
    while (l > 0) : (l -= 1) {
        const pte = table[vpn(va, l)];
        if (!pte.v or pte.isLeaf()) return null;
        table = @ptrFromInt(pte.addr());
    }
    const pte = &table[vpn(va, 0)];
    return if (pte.v) pte else null;
}

/// 复制一个用户地址空间（fork 用）：新建一个地址空间，用户区里每一页都分配一页新的物理内存，
/// 复制内容，按原来的权限映射到同一个地址。之后两边各改各的，互不影响。
pub fn cloneUserSpace(src: *PageTable) error{OutOfMemory}!*PageTable {
    const dst = try createUserSpace();
    errdefer destroyUserSpace(dst);
    for (vpn(user_base, 2)..vpn(user_end - 1, 2) + 1) |i| try cloneTree(dst, src[i], 2, i * levelSize(2));
    return dst;
}

fn cloneTree(dst: *PageTable, pte: Pte, level: u2, va: usize) error{OutOfMemory}!void {
    if (!pte.v) return;
    if (pte.isLeaf()) {
        std.debug.assert(level == 0); // 用户映射只用 4 KiB 的页（allocUserPage）
        const p = allocUserPage(dst, va, .{ .r = pte.r, .w = pte.w, .x = pte.x }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AlreadyMapped => unreachable, // dst 是新的，按 src 的结构逐页映射，不会重复
        };
        @memcpy(p, @as(*const page.Page, @ptrFromInt(pte.addr())));
        return;
    }
    const table: *PageTable = @ptrFromInt(pte.addr());
    for (table, 0..) |child, i| try cloneTree(dst, child, level - 1, va + i * levelSize(level - 1));
}

/// 按页表把用户地址 va 翻译成物理地址。要求这一页是 U 模式可读的（write 为 true 时还要可写），
/// 否则返回 null。
fn translateUser(root: *PageTable, va: usize, write: bool) ?usize {
    if (va < user_base or va >= user_end) return null;
    var table = root;
    var l: u2 = 2;
    while (true) : (l -= 1) {
        const pte = table[vpn(va, l)];
        if (!pte.v) return null;
        if (pte.isLeaf()) {
            if (!pte.u or !pte.r or (write and !pte.w)) return null;
            return pte.addr() + va % levelSize(l);
        }
        if (l == 0) return null; // 第 0 级必须是叶子
        table = @ptrFromInt(pte.addr());
    }
}

/// 从用户地址 src 复制 dst.len 个字节到内核缓冲区 dst。
/// 系统调用收到的指针都要经过这里：每一页都检查是否属于用户空间、是否允许 U 模式读，
/// 用户程序就没法借系统调用读到内核的内存。sstatus.SUM 始终为 0，内核不会直接解引用用户指针。
pub fn copyFromUser(root: *PageTable, dst: []u8, src: usize) error{BadAddress}!void {
    var done: usize = 0;
    while (done < dst.len) {
        const va = std.math.add(usize, src, done) catch return error.BadAddress;
        const pa = translateUser(root, va, false) orelse return error.BadAddress;
        const n = @min(dst.len - done, page.size - va % page.size);
        @memcpy(dst[done..][0..n], @as([*]const u8, @ptrFromInt(pa))[0..n]);
        done += n;
    }
}

/// 把内核缓冲区 src 复制到用户地址 dst。每一页都要求 U 模式可读可写：
/// 用户程序不能借系统调用改写内核的内存，也不能改写自己的只读页（比如代码段）。
/// 中途失败时，前面的页已经写进去了；需要“要么全写、要么不写”的调用方先用 checkUser 检查。
pub fn copyToUser(root: *PageTable, dst: usize, src: []const u8) error{BadAddress}!void {
    var done: usize = 0;
    while (done < src.len) {
        const va = std.math.add(usize, dst, done) catch return error.BadAddress;
        const pa = translateUser(root, va, true) orelse return error.BadAddress;
        const n = @min(src.len - done, page.size - va % page.size);
        @memcpy(@as([*]u8, @ptrFromInt(pa))[0..n], src[done..][0..n]);
        done += n;
    }
}

/// 检查用户地址 [va, va+len) 是否都是 U 模式可读的（write 为 true 时还要可写）。
pub fn checkUser(root: *PageTable, va: usize, len: usize, write: bool) error{BadAddress}!void {
    if (len == 0) return;
    const last = std.math.add(usize, va, len - 1) catch return error.BadAddress;
    var addr = va;
    while (true) {
        _ = translateUser(root, addr, write) orelse return error.BadAddress;
        const next = std.mem.alignBackward(usize, addr, page.size) + page.size;
        if (next > last) return;
        addr = next;
    }
}

/// 测试用的“物理内存”：页分配器管理这块数组，页表就建在里面。
var test_memory: [600 * page.size]u8 align(page.size) = undefined;

fn testInit() void {
    const base = @intFromPtr(&test_memory);
    page.init(base, base + test_memory.len, &.{});
}

test "对齐和长度允许时用大页" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    const before = page.free_pages;
    // 2 MiB + 4 KiB：一个 2 MiB 的大页（第 1 级叶子）加一个 4 KiB 的页（第 0 级叶子），需要第 1、0 级各一张页表
    try map(kernel_root, 0x8000_0000, 0x8000_0000, (2 << 20) + page.size, .{ .r = true, .w = true });
    try std.testing.expectEqual(before - 2, page.free_pages);
    // 1 GiB 对齐的 1 GiB：根页表里的一项就够了，不需要新的页表
    try map(kernel_root, 0xc000_0000, 0xc000_0000, 1 << 30, .{ .r = true, .w = true });
    try std.testing.expectEqual(before - 2, page.free_pages);
    // 已经被大页覆盖的地址不能再映射
    try std.testing.expectError(error.AlreadyMapped, map(kernel_root, 0x8010_0000, 0x8010_0000, page.size, .{ .r = true }));
}

test "copyFromUser 只读得到 U 模式可读的用户页，用户空间释放后不漏页" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    try map(kernel_root, 0x8020_0000, 0x8020_0000, page.size, .{ .r = true, .x = true });
    const before = page.free_pages;

    const space = try createUserSpace();
    const p0 = try allocUserPage(space, user_base, .{ .r = true, .w = true });
    const p1 = try allocUserPage(space, user_base + page.size, .{ .r = true });
    _ = try allocUserPage(space, user_base + 2 * page.size, .{ .x = true }); // 只能执行，不可读
    @memcpy(p0[page.size - 3 ..], "abc");
    @memcpy(p1[0..3], "def");

    var buf: [6]u8 = undefined;
    try copyFromUser(space, &buf, user_base + page.size - 3); // 跨页
    try std.testing.expectEqualStrings("abcdef", &buf);
    const bad = [_]usize{
        user_base + 2 * page.size, // 不可读
        user_base + 3 * page.size, // 没有映射
        0x8020_0000, // 内核的页：这个地址空间里有映射，但不在用户区、没有 U 位
        std.math.maxInt(usize) - 2, // 地址加长度溢出
    };
    for (bad) |va| try std.testing.expectError(error.BadAddress, copyFromUser(space, &buf, va));

    // 释放的只是用户区的页和页表，和内核共用的页表不动
    destroyUserSpace(space);
    try std.testing.expectEqual(before, page.free_pages);
}

test "copyToUser 只写得进 U 模式可写的用户页，checkUser 检查整个范围" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    const before = page.free_pages;
    const space = try createUserSpace();
    defer {
        destroyUserSpace(space);
        std.testing.expectEqual(before, page.free_pages) catch @panic("leaked pages");
    }
    const p0 = try allocUserPage(space, user_base, .{ .r = true, .w = true });
    const p1 = try allocUserPage(space, user_base + page.size, .{ .r = true, .w = true });
    _ = try allocUserPage(space, user_base + 2 * page.size, .{ .r = true }); // 只读

    try copyToUser(space, user_base + page.size - 2, "wxyz"); // 跨页
    try std.testing.expectEqualStrings("wx", p0[page.size - 2 ..]);
    try std.testing.expectEqualStrings("yz", p1[0..2]);
    try std.testing.expectError(error.BadAddress, copyToUser(space, user_base + 2 * page.size, "a")); // 只读
    try std.testing.expectError(error.BadAddress, copyToUser(space, user_base + 3 * page.size, "a")); // 没有映射

    try checkUser(space, user_base, 2 * page.size, true);
    try checkUser(space, user_base, 3 * page.size, false);
    try checkUser(space, 0, 0, true); // 长度为 0：不检查地址
    try std.testing.expectError(error.BadAddress, checkUser(space, user_base, 2 * page.size + 1, true));
    try std.testing.expectError(error.BadAddress, checkUser(space, user_base + 1, 3 * page.size, false));
    try std.testing.expectError(error.BadAddress, checkUser(space, user_base, std.math.maxInt(usize), false));
}

test "cloneUserSpace 复制每一页的内容和权限，两边互不影响，释放后不漏页" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    const before = page.free_pages;
    const src = try createUserSpace();
    const data = try allocUserPage(src, user_base, .{ .r = true, .w = true });
    _ = try allocUserPage(src, user_base + page.size, .{ .r = true, .x = true });
    _ = try allocUserPage(src, user_end - page.size, .{ .r = true, .w = true }); // 栈：另一张第 0 级页表
    @memcpy(data[0..5], "hello");

    const dst = try cloneUserSpace(src);
    var buf: [5]u8 = undefined;
    try copyFromUser(dst, &buf, user_base);
    try std.testing.expectEqualStrings("hello", &buf);
    // 改子进程的那一份，父进程的不变
    try copyToUser(dst, user_base, "HELLO");
    try copyFromUser(src, &buf, user_base);
    try std.testing.expectEqualStrings("hello", &buf);
    // 权限照搬：代码页可读不可写，栈页可写，没映射的还是没映射
    try copyFromUser(dst, &buf, user_base + page.size);
    try std.testing.expectError(error.BadAddress, copyToUser(dst, user_base + page.size, "a"));
    try copyToUser(dst, user_end - 5, "stack");
    try std.testing.expectError(error.BadAddress, copyFromUser(dst, &buf, user_base + 2 * page.size));

    destroyUserSpace(dst);
    destroyUserSpace(src);
    try std.testing.expectEqual(before, page.free_pages);
}

test "growUser、shrinkUser 按页映射和释放，内存不够时不留下半截" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    const space = try createUserSpace();
    _ = try allocUserPage(space, user_base, .{ .r = true, .x = true }); // 程序的段
    const heap = user_base + page.size;

    // 长 1 字节也要映射一整页；再长到页中间，不用新的页
    try growUser(space, heap, heap + 1, .{ .r = true, .w = true });
    try copyToUser(space, heap, "x");
    const one = page.free_pages;
    try growUser(space, heap + 1, heap + 100, .{ .r = true, .w = true });
    try std.testing.expectEqual(one, page.free_pages);
    // 跨过两页的边界
    try growUser(space, heap + 100, heap + 2 * page.size + 1, .{ .r = true, .w = true });
    try copyToUser(space, heap + 3 * page.size - 1, "y");
    try std.testing.expectError(error.BadAddress, copyToUser(space, heap + 3 * page.size, "z"));

    // 缩到页中间：这一页还在，后面两页释放
    shrinkUser(space, heap + 2 * page.size + 1, heap + 10);
    try std.testing.expectEqual(one, page.free_pages);
    try std.testing.expectError(error.BadAddress, copyToUser(space, heap + page.size, "z"));
    try copyToUser(space, heap + page.size - 1, "z");
    shrinkUser(space, heap + 10, heap);
    try std.testing.expectError(error.BadAddress, copyToUser(space, heap, "z"));

    // 跨过 2 MiB 的边界，要一张新的第 0 级页表；缩回来时它也被释放
    const before = page.free_pages;
    try growUser(space, heap, heap + (2 << 20), .{ .r = true, .w = true });
    try copyToUser(space, heap + (2 << 20) - 1, "z");
    shrinkUser(space, heap + (2 << 20), heap);
    try std.testing.expectEqual(before, page.free_pages);
    try std.testing.expectError(error.BadAddress, copyToUser(space, heap + (2 << 20) - 1, "z"));

    // 内存不够：一页都不留，页表也不留
    var hoard: std.SinglyLinkedList = .{};
    while (page.free_pages > 3) hoard.prepend(@ptrCast(try page.alloc()));
    const left = page.free_pages;
    try std.testing.expectError(error.OutOfMemory, growUser(space, heap, heap + 10 * page.size, .{ .r = true, .w = true }));
    try std.testing.expectEqual(left, page.free_pages);
    try std.testing.expectError(error.BadAddress, copyToUser(space, heap, "z"));
    destroyUserSpace(space);
}

test "cloneUserSpace 内存不够时不漏页" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    const src = try createUserSpace();
    for (0..8) |i| _ = try allocUserPage(src, user_base + i * page.size, .{ .r = true, .w = true });
    // 把剩下的页拿到只剩几页，复制到一半就会失败
    var hoard: std.SinglyLinkedList = .{};
    while (page.free_pages > 5) hoard.prepend(@ptrCast(try page.alloc()));
    const before = page.free_pages;
    try std.testing.expectError(error.OutOfMemory, cloneUserSpace(src));
    try std.testing.expectEqual(before, page.free_pages);
    destroyUserSpace(src);
}
