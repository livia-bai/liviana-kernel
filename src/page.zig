//! 物理页分配器：把空闲内存切成 4 KiB 的页，用单链表串起来，分配和释放都是 O(1)。
//! 链表节点就放在空闲页自己的开头，所以记账不需要额外的内存。
//!
//! 内核对所有物理内存做了恒等映射（见 vm.zig），开分页前后都可以直接用物理地址访问页，
//! 所以这里的接口直接返回指针。只在 shell 和系统调用里使用，不能在中断处理程序里调用。

const std = @import("std");
const dtb = @import("dtb.zig");

pub const size = 4096;
pub const Page = [size]u8;

var free_list: std.SinglyLinkedList = .{};
/// 归分配器管的地址范围，用来检查 free 收到的地址
var range: dtb.Region = .{ .base = 0, .size = 0 };
pub var total_pages: usize = 0;
pub var free_pages: usize = 0;

/// 把 [start, end) 中不和 reserved 重叠的整页都放进空闲链表。
pub fn init(start: usize, end: usize, reserved: []const dtb.Region) void {
    const lo = std.mem.alignForward(usize, start, size);
    const hi = std.mem.alignBackward(usize, end, size);
    range = .{ .base = lo, .size = hi - lo };
    // 从高地址往低地址插到表头，这样先分配出去的是低地址的页，调试时更好认
    var addr = hi;
    while (addr > lo) {
        addr -= size;
        if (isReserved(addr, reserved)) continue;
        free_list.prepend(@ptrFromInt(addr));
        total_pages += 1;
    }
    free_pages = total_pages;
}

fn isReserved(addr: usize, reserved: []const dtb.Region) bool {
    for (reserved) |r| {
        if (addr + size > r.base and addr < r.end()) return true;
    }
    return false;
}

/// 分配一页并清零。
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
