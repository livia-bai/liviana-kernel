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

/// 按页表把用户地址 va 翻译成物理地址。要求这一页是 U 模式可读的，否则返回 null。
fn translateUser(root: *PageTable, va: usize) ?usize {
    if (va < user_base or va >= user_end) return null;
    var table = root;
    var l: u2 = 2;
    while (true) : (l -= 1) {
        const pte = table[vpn(va, l)];
        if (!pte.v) return null;
        if (pte.isLeaf()) {
            if (!pte.u or !pte.r) return null;
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
        const pa = translateUser(root, va) orelse return error.BadAddress;
        const n = @min(dst.len - done, page.size - va % page.size);
        @memcpy(dst[done..][0..n], @as([*]const u8, @ptrFromInt(pa))[0..n]);
        done += n;
    }
}
