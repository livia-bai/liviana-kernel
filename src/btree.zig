//! 写时复制 B 树的节点格式和节点内的操作（纯逻辑，不读写磁盘），照 btrfs 的 ctree.h 简化。
//! 读写磁盘、写时复制、事务提交在 ctree.zig。
//!
//! 每个节点正好是一个磁盘块（4 KiB），开头是 Header：
//!
//!   叶子（level 0）：  Header | Item 0 | Item 1 | ... →    空闲    ← ... | 数据 1 | 数据 0
//!   内部节点：         Header | Ptr 0 | Ptr 1 | ... | Ptr n-1 |  空闲
//!
//! - 叶子里的 Item 是 { 键, 数据的位置, 数据的长度 }，按键从小到大排在前面；数据从块的末尾往前放，
//!   第 0 个条目的数据在最后面，第 i 个紧挨在第 i-1 个的前面（和 btrfs 一样），中间是空闲空间。
//! - 内部节点的 Ptr 是 { 键, 子节点的块号, 子节点的 generation }。第 i 个子节点里的键都 >= ptrs[i].key、
//!   < ptrs[i+1].key。ptrs[0].key 不参与查找（当作负无穷），所以往最左边插入更小的键时不用回头改父节点；
//!   它也就可能过时（比 ptrs[1].key 还大，第 0 个子节点里插进了更小的键又分裂过），什么地方都不看它。
//! - 所有整数都是小端（RISC-V 和 x86 都是），结构体都是 extern struct，内核和主机上的单元测试、
//!   以后的 mkfs 看到的布局一样。

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");

pub const block_size = abi.block_size;
pub const Block = [block_size]u8;

/// 键：先比 objectid，再比 type，最后比 offset（和 btrfs 一样）。文件系统用 objectid 表示 inode 号，
/// type 表示条目的种类，offset 的意思由种类决定（ctree.zig 只把它们当成三个数比较）。
pub const Key = extern struct {
    objectid: u64,
    offset: u64,
    type: u8,
    _pad: [7]u8 = @splat(0),

    pub const min: Key = .{ .objectid = 0, .type = 0, .offset = 0 };
    pub const max: Key = .{ .objectid = std.math.maxInt(u64), .type = std.math.maxInt(u8), .offset = std.math.maxInt(u64) };

    pub fn init(objectid: u64, @"type": u8, offset: u64) Key {
        return .{ .objectid = objectid, .type = @"type", .offset = offset };
    }

    pub fn order(a: Key, b: Key) std.math.Order {
        if (a.objectid != b.objectid) return std.math.order(a.objectid, b.objectid);
        if (a.type != b.type) return std.math.order(a.type, b.type);
        return std.math.order(a.offset, b.offset);
    }

    pub fn lessThan(a: Key, b: Key) bool {
        return a.order(b) == .lt;
    }

    pub fn eql(a: Key, b: Key) bool {
        return a.order(b) == .eq;
    }

    /// 紧接着的下一个键（遍历时用），已经是最大的键时返回 null。
    pub fn successor(k: Key) ?Key {
        var n = k;
        n._pad = @splat(0);
        if (n.offset != std.math.maxInt(u64)) {
            n.offset += 1;
        } else if (n.type != std.math.maxInt(u8)) {
            n.type += 1;
            n.offset = 0;
        } else if (n.objectid != std.math.maxInt(u64)) {
            n.objectid += 1;
            n.type = 0;
            n.offset = 0;
        } else return null;
        return n;
    }
};

pub const Header = extern struct {
    /// crc32c，覆盖这一块从 csum 之后到末尾的所有字节（写盘时算，读盘时验）
    csum: u32,
    nritems: u16,
    /// 0 是叶子，往上加一
    level: u8,
    _pad: u8 = 0,
    /// 这一块自己的块号：读到的块号不对，说明磁盘把数据写错了地方
    blockno: u64,
    /// 写出这个节点的事务号。父节点的 Ptr 里也记着它，两边不一致说明这次写丢了
    generation: u64,
};

pub const Item = extern struct {
    key: Key,
    /// 数据在块里的偏移
    offset: u32,
    size: u32,
};

pub const Ptr = extern struct {
    key: Key,
    blockno: u64,
    generation: u64,
};

comptime {
    std.debug.assert(@sizeOf(Key) == 24 and @sizeOf(Header) == 24 and @sizeOf(Item) == 32 and @sizeOf(Ptr) == 40);
}

/// 叶子里放条目和数据的空间
pub const leaf_space = block_size - @sizeOf(Header);
/// 一个条目的数据最多多大：保证叶子满了从中间分开之后，新条目一定放得进其中一半（见 splitLeaf）
pub const max_data = leaf_space / 4 - @sizeOf(Item);
/// 一个内部节点最多几个指针。单元测试里故意设得很小，少量数据就能长出好几层，测到各层的分裂
pub const max_ptrs: usize = if (builtin.is_test) 5 else (block_size - @sizeOf(Header)) / @sizeOf(Ptr);

/// 一块数据当作节点来看。块按 4 KiB 对齐（缓冲区的数据是页对齐的），Header、Item、Ptr 都对齐。
pub const Node = struct {
    data: *align(8) Block,

    pub fn of(data: *align(8) Block) Node {
        return .{ .data = data };
    }

    pub fn header(n: Node) *Header {
        return @ptrCast(n.data);
    }

    pub fn nritems(n: Node) usize {
        return n.header().nritems;
    }

    pub fn level(n: Node) u8 {
        return n.header().level;
    }

    pub fn isLeaf(n: Node) bool {
        return n.level() == 0;
    }

    /// 清空成一个空节点。
    pub fn init(n: Node, level_: u8, blockno: u64, generation: u64) void {
        @memset(n.data, 0);
        n.header().* = .{ .csum = 0, .nritems = 0, .level = level_, .blockno = blockno, .generation = generation };
    }

    /// 第 i 个条目或指针的键。
    pub fn key(n: Node, i: usize) Key {
        return if (n.isLeaf()) n.items()[i].key else n.ptrs()[i].key;
    }

    // ---- 校验和 ----

    pub fn computeCsum(n: Node) u32 {
        return std.hash.crc.@"CRC-32/ISCSI".hash(n.data[@sizeOf(u32)..]);
    }

    pub fn setCsum(n: Node) void {
        n.header().csum = n.computeCsum();
    }

    pub fn csumOk(n: Node) bool {
        return n.header().csum == n.computeCsum();
    }

    // ---- 叶子 ----

    fn itemArray(n: Node) [*]Item {
        return @ptrCast(@alignCast(n.data[@sizeOf(Header)..]));
    }

    pub fn items(n: Node) []Item {
        std.debug.assert(n.isLeaf());
        return n.itemArray()[0..n.nritems()];
    }

    pub fn itemData(n: Node, i: usize) []u8 {
        const it = n.items()[i];
        return n.data[it.offset..][0..it.size];
    }

    /// 数据区的起点（最后一个条目的数据的开头），没有条目时是块的末尾。
    fn dataStart(n: Node) usize {
        const its = n.items();
        return if (its.len == 0) block_size else its[its.len - 1].offset;
    }

    /// 叶子还剩多少空闲字节。
    pub fn leafFree(n: Node) usize {
        return n.dataStart() - @sizeOf(Header) - n.nritems() * @sizeOf(Item);
    }

    /// 放下一个 size 字节的条目要占多少空间。
    pub fn itemCost(size: usize) usize {
        return @sizeOf(Item) + size;
    }

    /// 在叶子里找 k：返回第一个 >= k 的条目的下标，以及它是不是正好等于 k。
    pub fn leafSearch(n: Node, k: Key) struct { usize, bool } {
        const its = n.items();
        var lo: usize = 0;
        var hi: usize = its.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (its[mid].key.lessThan(k)) lo = mid + 1 else hi = mid;
        }
        return .{ lo, lo < its.len and its[lo].key.eql(k) };
    }

    /// 在下标 i 插入一个条目（调用方保证放得下、键的顺序正确）。数据放在第 i-1 个条目的数据前面，
    /// 第 i 个以后的条目的数据整体往前挪 data.len 字节。
    pub fn leafInsert(n: Node, i: usize, k: Key, data: []const u8) void {
        std.debug.assert(n.leafFree() >= itemCost(data.len) and i <= n.nritems());
        const count = n.nritems();
        const its = n.itemArray();
        const end = if (i == 0) block_size else its[i - 1].offset; // 新数据的末尾
        const start = n.dataStart();
        // 第 i..count 个条目的数据在 [start, end)，往前挪
        std.mem.copyForwards(u8, n.data[start - data.len .. end - data.len], n.data[start..end]);
        var j = count;
        while (j > i) : (j -= 1) {
            its[j] = its[j - 1];
            its[j].offset -= @intCast(data.len);
        }
        its[i] = .{ .key = k, .offset = @intCast(end - data.len), .size = @intCast(data.len) };
        @memcpy(n.data[end - data.len .. end], data);
        n.header().nritems += 1;
    }

    /// 删掉第 i 个条目，后面条目的数据往后挪，填上空出来的地方。
    pub fn leafRemove(n: Node, i: usize) void {
        const count = n.nritems();
        std.debug.assert(i < count);
        const its = n.itemArray();
        const gone = its[i];
        const start = n.dataStart();
        // 第 i+1.. 个条目的数据在 [start, gone.offset)，往后挪 gone.size 字节
        std.mem.copyBackwards(u8, n.data[start + gone.size .. gone.offset + gone.size], n.data[start..gone.offset]);
        for (i..count - 1) |j| {
            its[j] = its[j + 1];
            its[j].offset += gone.size;
        }
        @memset(n.data[start .. start + gone.size], 0);
        its[count - 1] = std.mem.zeroes(Item);
        n.header().nritems -= 1;
    }

    /// 把满了的叶子 n 分成两半：后一半的条目搬到空叶子 right（调用方 init 过）里。
    /// 按字节数从中间分：前一半的条目和数据加起来刚超过总数的一半为止。
    /// 因为一个条目最多占 leaf_space / 4，分完之后两边都至少空出 leaf_space / 4，新条目放哪边都放得下。
    pub fn splitLeaf(n: Node, right: Node) void {
        std.debug.assert(n.isLeaf() and right.isLeaf() and right.nritems() == 0);
        const its = n.items();
        var total: usize = 0;
        for (its) |it| total += itemCost(it.size);
        var mid: usize = 0;
        var left_bytes: usize = 0;
        while (mid < its.len - 1 and left_bytes < total / 2) : (mid += 1) left_bytes += itemCost(its[mid].size);
        // 后一半依次插到 right 的末尾
        for (mid..its.len) |i| right.leafInsert(right.nritems(), its[i].key, n.itemData(i));
        // n 去掉后一半：它们的数据在数据区的最前面，直接截掉，前一半不用动
        const cut = n.items()[mid - 1].offset;
        @memset(n.data[n.dataStart()..cut], 0);
        @memset(std.mem.sliceAsBytes(n.itemArray()[mid..its.len]), 0);
        n.header().nritems = @intCast(mid);
    }

    // ---- 内部节点 ----

    fn ptrArray(n: Node) [*]Ptr {
        return @ptrCast(@alignCast(n.data[@sizeOf(Header)..]));
    }

    pub fn ptrs(n: Node) []Ptr {
        std.debug.assert(!n.isLeaf());
        return n.ptrArray()[0..n.nritems()];
    }

    /// 在内部节点里找 k 应该往哪个子节点走：最后一个 key <= k 的下标（ptrs[0].key 不算，当作负无穷）。
    pub fn childFor(n: Node, k: Key) usize {
        const ps = n.ptrs();
        var lo: usize = 1;
        var hi: usize = ps.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (k.lessThan(ps[mid].key)) hi = mid else lo = mid + 1;
        }
        return lo - 1;
    }

    pub fn ptrInsert(n: Node, i: usize, p: Ptr) void {
        const count = n.nritems();
        std.debug.assert(count < max_ptrs and i <= count);
        const ps = n.ptrArray();
        var j = count;
        while (j > i) : (j -= 1) ps[j] = ps[j - 1];
        ps[i] = p;
        n.header().nritems += 1;
    }

    pub fn ptrRemove(n: Node, i: usize) void {
        const count = n.nritems();
        std.debug.assert(i < count);
        const ps = n.ptrArray();
        for (i..count - 1) |j| ps[j] = ps[j + 1];
        ps[count - 1] = std.mem.zeroes(Ptr);
        n.header().nritems -= 1;
    }

    /// 把内部节点 n 的后一半指针搬到空的内部节点 right 里。
    pub fn splitPtrs(n: Node, right: Node) void {
        std.debug.assert(!n.isLeaf() and right.level() == n.level() and right.nritems() == 0);
        const ps = n.ptrs();
        const mid = ps.len / 2;
        for (ps[mid..], 0..) |p, i| right.ptrInsert(i, p);
        @memset(std.mem.sliceAsBytes(n.ptrArray()[mid..ps.len]), 0);
        n.header().nritems = @intCast(mid);
    }
};

// ---- 单元测试 ----

var test_blocks: [2]Block align(4096) = undefined;

fn testNode(i: usize, level_: u8) Node {
    const n = Node.of(&test_blocks[i]);
    n.init(level_, 100 + i, 1);
    return n;
}

fn tk(o: u64) Key {
    return .init(o, 1, 0);
}

/// 叶子里的条目按键排好、数据挤在末尾、互不重叠，内容是 "键号 重复 size 次"。
fn expectLeaf(n: Node, keys: []const u64, sizes: []const usize) !void {
    try std.testing.expectEqual(keys.len, n.nritems());
    var end: usize = block_size;
    for (n.items(), keys, sizes, 0..) |it, o, size, i| {
        try std.testing.expect(it.key.eql(tk(o)));
        try std.testing.expectEqual(end - size, it.offset);
        end = it.offset;
        for (n.itemData(i)) |c| try std.testing.expectEqual(@as(u8, @truncate(o)), c);
    }
    try std.testing.expectEqual(end - @sizeOf(Header) - keys.len * @sizeOf(Item), n.leafFree());
}

fn insertFilled(n: Node, o: u64, size: usize) void {
    var buf: [max_data]u8 = undefined;
    @memset(buf[0..size], @truncate(o));
    const i, const found = n.leafSearch(tk(o));
    std.debug.assert(!found);
    n.leafInsert(i, tk(o), buf[0..size]);
}

test "键的顺序：objectid、type、offset；successor" {
    try std.testing.expect(Key.init(1, 9, 9).lessThan(.init(2, 0, 0)));
    try std.testing.expect(Key.init(1, 1, 9).lessThan(.init(1, 2, 0)));
    try std.testing.expect(Key.init(1, 1, 1).lessThan(.init(1, 1, 2)));
    try std.testing.expect(Key.init(1, 1, 1).eql(.init(1, 1, 1)));
    try std.testing.expect(Key.init(1, 1, std.math.maxInt(u64)).successor().?.eql(.init(1, 2, 0)));
    try std.testing.expect(Key.init(1, 255, std.math.maxInt(u64)).successor().?.eql(.init(2, 0, 0)));
    try std.testing.expectEqual(null, Key.max.successor());
}

test "叶子：按顺序插入、数据挤在末尾、删除后挪回去" {
    const n = testNode(0, 0);
    insertFilled(n, 5, 10);
    insertFilled(n, 1, 3);
    insertFilled(n, 9, 0);
    insertFilled(n, 7, 20);
    try expectLeaf(n, &.{ 1, 5, 7, 9 }, &.{ 3, 10, 20, 0 });
    try std.testing.expectEqual(.{ 2, true }, n.leafSearch(tk(7)));
    try std.testing.expectEqual(.{ 2, false }, n.leafSearch(tk(6)));
    try std.testing.expectEqual(.{ 4, false }, n.leafSearch(tk(10)));
    n.leafRemove(1);
    try expectLeaf(n, &.{ 1, 7, 9 }, &.{ 3, 20, 0 });
    n.leafRemove(0);
    n.leafRemove(1);
    try expectLeaf(n, &.{7}, &.{20});
    n.leafRemove(0);
    try expectLeaf(n, &.{}, &.{});
    try std.testing.expectEqual(leaf_space, n.leafFree());
}

test "叶子分裂：按字节数分成两半，两边都空出至少四分之一" {
    const n = testNode(0, 0);
    const right = testNode(1, 0);
    var o: u64 = 0;
    var sizes: [64]usize = undefined;
    // 大小不一的条目，塞到放不下一个最大的条目为止
    while (n.leafFree() >= Node.itemCost(max_data)) : (o += 1) {
        sizes[o] = (o * 97) % max_data;
        insertFilled(n, o * 2, sizes[o]);
    }
    n.splitLeaf(right);
    try std.testing.expect(n.nritems() > 0 and right.nritems() > 0);
    try std.testing.expectEqual(o, n.nritems() + right.nritems());
    try std.testing.expect(n.leafFree() >= Node.itemCost(max_data) and right.leafFree() >= Node.itemCost(max_data));
    var keys: [64]u64 = undefined;
    for (0..o) |i| keys[i] = i * 2;
    const m = n.nritems();
    try expectLeaf(n, keys[0..m], sizes[0..m]);
    try expectLeaf(right, keys[m..o], sizes[m..o]);
}

test "内部节点：childFor 把 ptrs[0].key 当作负无穷；插入、删除、分裂" {
    const n = testNode(0, 1);
    for ([_]u64{ 10, 20, 30 }, 0..) |o, i| n.ptrInsert(i, .{ .key = tk(o), .blockno = o, .generation = 1 });
    try std.testing.expectEqual(0, n.childFor(tk(5))); // 比 ptrs[0].key 还小，也走第 0 个
    try std.testing.expectEqual(0, n.childFor(tk(19)));
    try std.testing.expectEqual(1, n.childFor(tk(20)));
    try std.testing.expectEqual(2, n.childFor(tk(99)));
    n.ptrInsert(1, .{ .key = tk(15), .blockno = 15, .generation = 1 });
    n.ptrRemove(0);
    try std.testing.expectEqual(3, n.nritems());
    try std.testing.expectEqual(15, n.ptrs()[0].blockno);
    try std.testing.expectEqual(30, n.ptrs()[2].blockno);
    const right = testNode(1, 1);
    n.ptrInsert(3, .{ .key = tk(40), .blockno = 40, .generation = 1 });
    n.splitPtrs(right);
    try std.testing.expectEqual(2, n.nritems());
    try std.testing.expectEqual(2, right.nritems());
    try std.testing.expectEqual(30, right.ptrs()[0].blockno);
}

test "校验和覆盖 csum 之后的所有字节" {
    const n = testNode(0, 0);
    insertFilled(n, 1, 10);
    n.setCsum();
    try std.testing.expect(n.csumOk());
    n.data[block_size - 1] ^= 1;
    try std.testing.expect(!n.csumOk());
}
