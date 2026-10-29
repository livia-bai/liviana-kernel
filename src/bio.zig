//! 缓冲区缓存（buffer cache），照 xv6 的 bio.c 写：在内存里缓存磁盘上最近用过的块，
//! 同一个块读第二次不用再等磁盘；同时保证同一个块在内存里只有一份，几个进程要改它时排队（睡眠锁）。
//!
//! - nbuf 个缓冲区，每个装一个 4 KiB 的块（abi.block_size，正好一页），按最近使用的顺序串成链表（LRU）。
//!   要一个不在缓存里的块时，从最久没用的一端找一个没人在用的（refcnt 为 0）换掉。
//! - read 返回拿着睡眠锁的缓冲区，内容就是磁盘上的；改完调用 write 写回磁盘（同步：写完才返回）；
//!   用完调用 release。拿着缓冲区的期间，别的进程要同一个块会睡着等。
//! - 磁盘读写交给 Device（内核里是 virtio_disk，单元测试里是一块内存）。
//!
//! 锁：lock（自旋锁）保护链表、每个缓冲区的 refcnt 和 blockno；每个缓冲区的睡眠锁保护 valid 和 data。
//! 拿到睡眠锁之后才读写磁盘，读写时睡着等，不占 CPU。

const std = @import("std");
const abi = @import("abi.zig");
const proc = @import("proc.zig");
const Spinlock = @import("spinlock.zig").Spinlock;
const Sleeplock = @import("sleeplock.zig").Sleeplock;

pub const block_size = abi.block_size;
/// 缓冲区的个数
pub const nbuf = 32;

/// 磁盘：有多少块，怎么读写一块（同步，做完才返回，可以睡）。
pub const Device = struct {
    blocks: u64,
    transfer: *const fn (block: u64, data: *[block_size]u8, write: bool) void,
};

pub const Buf = struct {
    /// 保护 valid 和 data，拿着它才能读写磁盘
    lock: Sleeplock = .init("buf"),
    /// lock（bio.lock）。有几个人拿着（或者在等）这个缓冲区；为 0 时可以换成别的块
    refcnt: u32 = 0,
    /// bio.lock。装的是哪个块
    blockno: u64 = 0,
    /// data 是不是这个块在磁盘上的内容（换成别的块之后为 false，第一次 read 时才去读）
    valid: bool = false,
    /// LRU 链表的节点，表头是最近用过的
    node: std.DoublyLinkedList.Node = .{},
    data: *align(4096) [block_size]u8,
};

var lock: Spinlock = .init("bcache");
var bufs: [nbuf]Buf = undefined;
var datas: [nbuf][block_size]u8 align(4096) = undefined;
var lru: std.DoublyLinkedList = .{};
/// 在等空闲缓冲区的进程个数（release 时有人等才 wakeup）
var waiting: usize = 0;
var device: ?Device = null;

pub const Error = error{ NoDevice, OutOfRange };

/// 清空缓存，换上磁盘 dev（null 表示没有磁盘）。kmain 调用一次；单元测试每次换一块内存当磁盘。
pub fn init(dev: ?Device) void {
    device = dev;
    lru = .{};
    for (&bufs, &datas) |*b, *d| {
        b.* = .{ .data = d };
        lru.append(&b.node);
    }
}

/// 磁盘有多少块，没有磁盘时是 0。
pub fn blockCount() u64 {
    return if (device) |d| d.blocks else 0;
}

fn check(blockno: u64) Error!Device {
    const dev = device orelse return error.NoDevice;
    if (blockno >= dev.blocks) return error.OutOfRange;
    return dev;
}

/// 块 blockno 的缓冲区，拿着睡眠锁返回，不读磁盘：valid 为 false 时内容是别的块留下的。
/// 要整块覆盖的调用方用它，省掉一次读；覆盖完把 valid 设成 true，再 write。
/// 所有缓冲区都有人在用时睡着等。只能由进程调用。
pub fn get(blockno: u64) Error!*Buf {
    _ = try check(blockno);
    lock.acquire();
    const b = while (true) {
        if (find(blockno)) |b| break b;
        waiting += 1;
        proc.sleep(&lru, &lock);
        waiting -= 1;
    };
    b.refcnt += 1;
    lock.release();
    b.lock.acquire();
    return b;
}

/// 已经缓存着的块，或者换掉一个最久没用、没人在用的缓冲区；都没有返回 null。调用方拿着 lock。
fn find(blockno: u64) ?*Buf {
    var it = lru.first;
    while (it) |n| : (it = n.next) {
        const b: *Buf = @fieldParentPtr("node", n);
        if (b.blockno == blockno and (b.refcnt > 0 or b.valid)) return b;
    }
    it = lru.last;
    while (it) |n| : (it = n.prev) {
        const b: *Buf = @fieldParentPtr("node", n);
        if (b.refcnt == 0) {
            b.blockno = blockno;
            b.valid = false;
            return b;
        }
    }
    return null;
}

/// 块 blockno 的缓冲区，拿着睡眠锁返回，内容是磁盘上的（不在缓存里就读进来）。
pub fn read(blockno: u64) Error!*Buf {
    const b = try get(blockno);
    _ = load(b);
    return b;
}

/// get 拿到的缓冲区内容无效的话从磁盘读进来。返回这次是不是真的读了磁盘：
/// 文件系统只在读盘时验校验和，缓存里的内容验过了就不用每次都算（ctree.zig）。
/// 发现内容不对的调用方把 valid 设回 false，下次再读盘。
pub fn load(b: *Buf) bool {
    std.debug.assert(b.lock.holding());
    if (b.valid) return false;
    device.?.transfer(b.blockno, b.data, false);
    b.valid = true;
    return true;
}

/// 把缓冲区写回磁盘，写完才返回。调用方拿着它的睡眠锁。
pub fn write(b: *Buf) void {
    std.debug.assert(b.lock.holding() and b.valid);
    device.?.transfer(b.blockno, b.data, true);
}

/// 用完了：放开睡眠锁。没人用了就挪到 LRU 链表的表头（最近用过），叫醒在等空闲缓冲区的进程。
pub fn release(b: *Buf) void {
    b.lock.release();
    lock.acquire();
    defer lock.release();
    b.refcnt -= 1;
    if (b.refcnt == 0) {
        lru.remove(&b.node);
        lru.prepend(&b.node);
        if (waiting > 0) proc.wakeup(&lru);
    }
}

// ---- 单元测试：一块内存当磁盘，记下读写了几次 ----

const test_blocks = 64;
var test_disk: [test_blocks][block_size]u8 = undefined;
var test_reads: usize = 0;
var test_writes: usize = 0;

fn testTransfer(block: u64, data: *[block_size]u8, write_: bool) void {
    if (write_) {
        test_writes += 1;
        test_disk[block] = data.*;
    } else {
        test_reads += 1;
        data.* = test_disk[block];
    }
}

fn testInit() void {
    for (&test_disk, 0..) |*blk, i| @memset(blk, @truncate(i));
    test_reads = 0;
    test_writes = 0;
    init(.{ .blocks = test_blocks, .transfer = testTransfer });
}

test "缓存命中不读磁盘；超出 nbuf 时换掉最久没用的块" {
    const expectEqual = std.testing.expectEqual;
    testInit();
    var b = try read(5);
    try expectEqual(5, b.data[0]);
    release(b);
    b = try read(5);
    release(b);
    try expectEqual(1, test_reads);

    // 再读 nbuf - 1 个别的块：块 5 还在缓存里（缓存正好装满）
    for (10..10 + nbuf - 1) |i| release(try read(i));
    try expectEqual(nbuf, test_reads);
    release(try read(5));
    try expectEqual(nbuf, test_reads);
    // 再读一个新块：换掉的是最久没用的块 10，不是刚用过的块 5
    release(try read(50));
    release(try read(5));
    try expectEqual(nbuf + 1, test_reads);
    release(try read(10));
    try expectEqual(nbuf + 2, test_reads);
}

test "write 写回磁盘；get 不读磁盘；拿着的缓冲区不会被换掉；超出范围、没有磁盘" {
    const expectEqual = std.testing.expectEqual;
    testInit();
    const b = try get(3);
    @memset(b.data, 0xab);
    b.valid = true;
    write(b);
    try expectEqual(0, test_reads);
    try expectEqual(1, test_writes);
    try expectEqual(0xab, test_disk[3][block_size - 1]);
    // 一直拿着块 3，把别的块读两遍、塞满整个缓存也换不掉它（再读块 3 的话是自己等自己，会 panic）
    for (0..2 * nbuf) |i| release(try read(4 + i % (test_blocks - 4)));
    try expectEqual(3, b.blockno);
    release(b);
    const reads = test_reads;
    release(try read(3));
    try expectEqual(reads, test_reads); // 还在缓存里，内容是写进去的
    try std.testing.expectError(error.OutOfRange, read(test_blocks));
    try std.testing.expectError(error.OutOfRange, get(std.math.maxInt(u64)));
    try expectEqual(test_blocks, blockCount());
    init(null);
    try std.testing.expectError(error.NoDevice, read(0));
    try expectEqual(0, blockCount());
}
