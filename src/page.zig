//! 物理页分配器：把空闲内存切成 4 KiB 的页，用单链表串起来，分配和释放都是 O(1)。
//! 链表节点就放在空闲页自己的开头，所以记账不需要额外的内存。
//!
//! 内核对所有物理内存做了恒等映射（见 vm.zig），开分页前后都可以直接用物理地址访问页，
//! 所以这里的接口直接返回指针。只在启动时、系统调用和缺页异常里使用，不能在中断处理程序里调用。
//!
//! 每一页有一个引用数：fork 之后父子进程共用同一页（写时复制，见 vm.cloneUserSpace），
//! 每多一个地址空间映射它就加 1（share），free 减 1，减到 0 才真正放回空闲链表。
//! 引用数数组放在管理范围最开头的几页里（128 MiB 内存是 8 页）。

const std = @import("std");
const dtb = @import("dtb.zig");
const Spinlock = @import("spinlock.zig").Spinlock;

pub const size = 4096;
pub const Page = [size]u8;

/// 保护 free_list、free_pages 和 refs（多核时几个 hart 会同时分配、释放、共用页）
var lock: Spinlock = .init("page");
var free_list: std.SinglyLinkedList = .{};
/// 归分配器管的地址范围（不含引用数数组本身），用来检查 free 收到的地址
var range: dtb.Region = .{ .base = 0, .size = 0 };
/// 每一页的引用数，按 (地址 - range.base) / size 下标。空闲页是 0。
/// 一页最多被 abi.max_procs 个进程共用，u8 足够；溢出说明引用数记错了，直接 panic
var refs: []u8 = &.{};
pub var total_pages: usize = 0;
pub var free_pages: usize = 0;

/// 把 [start, end) 中不和 reserved 重叠的整页都放进空闲链表。最开头的几页留给引用数数组。
pub fn init(start: usize, end: usize, reserved: []const dtb.Region) void {
    const first = std.mem.alignForward(usize, start, size);
    const hi = std.mem.alignBackward(usize, end, size);
    // 数组按整个范围的页数分配（略多于真正要管的页数，多出来的几项不用）
    const n = (hi - first) / size;
    const lo = first + std.mem.alignForward(usize, n, size); // 每页一个字节，占满整页
    if (isReserved(first, lo - first, reserved)) @panic("page.init: no room for the reference counts");
    refs = @as([*]u8, @ptrFromInt(first))[0..n];
    @memset(refs, 0);
    range = .{ .base = lo, .size = hi - lo };
    free_list = .{};
    total_pages = 0;
    // 从高地址往低地址插到表头，这样先分配出去的是低地址的页，调试时更好认
    var addr = hi;
    while (addr > lo) {
        addr -= size;
        if (isReserved(addr, size, reserved)) continue;
        free_list.prepend(@ptrFromInt(addr));
        total_pages += 1;
    }
    free_pages = total_pages;
}

/// [addr, addr+len) 是否和某个保留区重叠（哪怕只重叠一个字节）。
fn isReserved(addr: usize, len: usize, reserved: []const dtb.Region) bool {
    for (reserved) |r| {
        if (addr + len > r.base and addr < r.end()) return true;
    }
    return false;
}

/// 页 page 的引用数。不是分配器管的地址就 panic（who 是调用方的名字，打印在 panic 信息里）。调用方拿着 lock。
fn refOf(comptime who: []const u8, page: *align(size) Page) *u8 {
    const addr = @intFromPtr(page);
    if (addr < range.base or addr >= range.end()) {
        std.debug.panic(who ++ ": 0x{x} was not handed out by the page allocator", .{addr});
    }
    return &refs[(addr - range.base) / size];
}

/// 分配一页并清零，引用数为 1。
pub fn alloc() error{OutOfMemory}!*align(size) Page {
    lock.acquire();
    const node = free_list.popFirst();
    if (node) |n| {
        free_pages -= 1;
        refOf("page.alloc", @ptrCast(@alignCast(n))).* = 1;
    }
    lock.release();
    // 清零放在锁外面：这一页已经是自己的了
    const page: *align(size) Page = @ptrCast(@alignCast(node orelse return error.OutOfMemory));
    @memset(page, 0);
    return page;
}

/// 放掉一个引用。最后一个引用放掉时，这一页回到空闲链表。
pub fn free(page: *align(size) Page) void {
    lock.acquire();
    defer lock.release();
    const r = refOf("page.free", page);
    if (r.* == 0) std.debug.panic("page.free: 0x{x} is already free", .{@intFromPtr(page)});
    r.* -= 1;
    if (r.* > 0) return;
    free_list.prepend(@ptrCast(page));
    free_pages += 1;
}

/// 多一个引用：又有一个地址空间映射了这一页（fork 时父子共用，见 vm.cloneUserSpace）。
pub fn share(page: *align(size) Page) void {
    lock.acquire();
    defer lock.release();
    const r = refOf("page.share", page);
    if (r.* == 0) std.debug.panic("page.share: 0x{x} is free", .{@intFromPtr(page)});
    r.* = std.math.add(u8, r.*, 1) catch std.debug.panic("page.share: 0x{x} has too many references", .{@intFromPtr(page)});
}

/// 这一页是不是只有一个引用。是的话别人不会再拿到它（只有映射着它的进程自己 fork 才会加引用），
/// 写时复制时就不用复制，直接归自己（见 vm.breakCow）。
pub fn isExclusive(page: *align(size) Page) bool {
    lock.acquire();
    defer lock.release();
    return refOf("page.isExclusive", page).* == 1;
}

test "先分配低地址、分配时清零、跳过保留区、释放后能再用" {
    var mem: [9 * size]u8 align(size) = undefined;
    @memset(&mem, 0xaa);
    const base = @intFromPtr(&mem);
    // 第 0 页放引用数；第 3 页被保留（哪怕只保留了 1 个字节，整页都不能用）
    init(base, base + mem.len, &.{.{ .base = base + 3 * size, .size = 1 }});
    try std.testing.expectEqual(7, total_pages);

    const a = try alloc();
    const b = try alloc();
    const c = try alloc();
    try std.testing.expectEqual(base + size, @intFromPtr(a));
    try std.testing.expectEqual(base + 2 * size, @intFromPtr(b));
    try std.testing.expectEqual(base + 4 * size, @intFromPtr(c));
    try std.testing.expect(std.mem.allEqual(u8, c, 0));
    try std.testing.expectEqual(4, free_pages);

    free(b);
    try std.testing.expectEqual(@intFromPtr(b), @intFromPtr(try alloc())); // 刚释放的页最先被拿走
    for (0..4) |_| _ = try alloc();
    try std.testing.expectError(error.OutOfMemory, alloc());
}

test "共用的页：最后一个引用放掉才回到空闲链表" {
    var mem: [4 * size]u8 align(size) = undefined;
    const base = @intFromPtr(&mem);
    init(base, base + mem.len, &.{});
    const before = free_pages;
    const p = try alloc();
    try std.testing.expect(isExclusive(p));
    share(p);
    share(p);
    try std.testing.expect(!isExclusive(p));
    free(p);
    free(p);
    try std.testing.expect(isExclusive(p));
    try std.testing.expectEqual(before - 1, free_pages);
    free(p);
    try std.testing.expectEqual(before, free_pages);
    // 释放之后再分配，引用数重新从 1 开始
    try std.testing.expectEqual(p, try alloc());
    try std.testing.expect(isExclusive(p));
}
