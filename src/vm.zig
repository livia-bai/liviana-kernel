//! Sv39 分页。虚拟地址 39 位，拆成 VPN[2] | VPN[1] | VPN[0] | 页内偏移（9 + 9 + 9 + 12 位）。
//! 页表有三级，每级 512 项、每项 8 字节，一张页表正好一页。CPU 从 satp 指向的根页表开始，
//! 用 VPN[2]、VPN[1]、VPN[0] 依次索引：某一项的 R/W/X 有一位为 1 就是叶子，映射到此为止；
//! 全为 0 则指向下一级页表。在第 2、1 级就停下的叶子是 1 GiB、2 MiB 的大页。
//!
//! 内核的映射：物理内存和外设都按“虚拟地址 = 物理地址”恒等映射，所以开分页前后地址不变，
//! 页分配器给出的物理地址也能直接当指针用。代码 R-X、只读数据 R--、其余 RW-。

const std = @import("std");
const riscv = @import("riscv.zig");
const page = @import("page.zig");
const dtb = @import("dtb.zig");
const uart = @import("uart.zig");
const plic = @import("plic.zig");

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
