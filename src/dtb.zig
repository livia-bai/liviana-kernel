//! 扁平设备树（FDT，文件格式叫 DTB）解析。OpenSBI 把设备树的物理地址放在 a1 里交给内核，
//! 里面描述了内存的位置和大小、时钟频率、各个外设等硬件信息，内核据此初始化，而不是把这些值写死。
//!
//! 格式见 Devicetree 规范第 5 章。所有整数都是大端序。文件由几块组成：
//! - 文件头：魔数、总长度、其他各块的偏移
//! - 内存保留块：一串 (地址, 长度) 对，以 (0, 0) 结尾，描述不能被内核使用的内存
//! - 结构块：一串 4 字节对齐的 token，按深度优先顺序描述节点树：
//!   BEGIN_NODE 名字 / PROP 长度 名字偏移 值 / END_NODE / END
//! - 字符串块：属性名，结构块里只存它们的偏移
//!
//! 设备树来自固件，这里不信任它的内容：每次读取都检查边界，格式不对就返回错误。

const std = @import("std");

pub const Region = struct {
    base: usize,
    size: usize,

    /// 用饱和加法：数值来自设备树，不能因为它写错了就让内核溢出 panic。
    pub fn end(r: Region) usize {
        return r.base +| r.size;
    }
};

pub const Info = struct {
    /// 物理内存。只取第一个 memory 节点的第一段（QEMU virt 只有一段，从 0x80000000 开始）。
    memory: Region,
    /// time CSR 每秒增加的次数，来自 /cpus 节点的 timebase-frequency。
    timebase_hz: u64,
    /// 不能分配出去的内存：设备树自己、内存保留块里的条目、/reserved-memory 的子节点。
    reserved_buf: [max_reserved]Region,
    reserved_len: usize,

    pub fn reserved(info: *const Info) []const Region {
        return info.reserved_buf[0..info.reserved_len];
    }
};

pub const Error = error{
    BadMagic,
    UnsupportedVersion,
    Truncated,
    BadToken,
    TooDeep,
    TooManyReserved,
    UnsupportedCells,
    NoMemory,
    NoTimebase,
};

const magic: u32 = 0xd00dfeed;
const max_reserved = 16;
const max_depth = 16;

const Token = enum(u32) {
    begin_node = 1,
    end_node = 2,
    prop = 3,
    nop = 4,
    end = 9,
    _,
};

/// 带边界检查的大端序读取。
fn readBe(comptime T: type, bytes: []const u8, offset: usize) Error!T {
    const n = @sizeOf(T);
    if (offset > bytes.len or bytes.len - offset < n) return error.Truncated;
    return std.mem.readInt(T, bytes[offset..][0..n], .big);
}

/// 取出 bytes[offset..] 开头的、以 0 结尾的字符串（不含结尾的 0）。
fn readStr(bytes: []const u8, offset: usize) Error![]const u8 {
    if (offset >= bytes.len) return error.Truncated;
    const rest = bytes[offset..];
    const len = std.mem.findScalar(u8, rest, 0) orelse return error.Truncated;
    return rest[0..len];
}

/// 读一个由 cells 个 32 位单元组成的数（#address-cells / #size-cells 一般是 1 或 2）。
fn readCells(bytes: []const u8, offset: usize, cells: u32) Error!u64 {
    return switch (cells) {
        1 => try readBe(u32, bytes, offset),
        2 => try readBe(u64, bytes, offset),
        else => error.UnsupportedCells,
    };
}

/// 结构块里正在访问的一个节点。
const Node = struct {
    name: []const u8,
    /// 本节点的 #address-cells / #size-cells，决定子节点的 reg 怎么解读。规范规定的默认值是 2 和 1。
    address_cells: u32 = 2,
    size_cells: u32 = 1,
    /// device_type = "memory"
    is_memory: bool = false,
    reg: ?[]const u8 = null,
};

pub fn parse(addr: usize) Error!Info {
    // 先只看文件头里的总长度，再把整个文件当成一个切片，之后所有读取都在这个范围内
    const header: *const [8]u8 = @ptrFromInt(addr);
    if (std.mem.readInt(u32, header[0..4], .big) != magic) return error.BadMagic;
    const total = std.mem.readInt(u32, header[4..8], .big);
    return parseBlob(@as([*]const u8, @ptrFromInt(addr))[0..total]);
}

/// 解析内存里的一份完整设备树。和地址无关，单元测试直接喂字节进来。
pub fn parseBlob(blob: []const u8) Error!Info {
    if (try readBe(u32, blob, 0) != magic) return error.BadMagic;
    const total = blob.len;
    const off_struct = try readBe(u32, blob, 8);
    const off_strings = try readBe(u32, blob, 12);
    const off_rsvmap = try readBe(u32, blob, 16);
    const version = try readBe(u32, blob, 20);
    const last_comp_version = try readBe(u32, blob, 24);
    const size_strings = try readBe(u32, blob, 32);
    const size_struct = try readBe(u32, blob, 36);
    // 版本 17 向下兼容到 16，这里用到的格式在 16 里就已经定下来了
    if (version < 16 or last_comp_version > 17) return error.UnsupportedVersion;
    if (off_strings > total or total - off_strings < size_strings) return error.Truncated;
    if (off_struct > total or total - off_struct < size_struct) return error.Truncated;
    const strings = blob[off_strings..][0..size_strings];
    const structure = blob[off_struct..][0..size_struct];

    var info: Info = .{
        .memory = .{ .base = 0, .size = 0 },
        .timebase_hz = 0,
        .reserved_buf = undefined,
        .reserved_len = 0,
    };
    try addReserved(&info, .{ .base = @intFromPtr(blob.ptr), .size = total });

    // 内存保留块
    var pos: usize = off_rsvmap;
    while (true) : (pos += 16) {
        const base = try readBe(u64, blob, pos);
        const size = try readBe(u64, blob, pos + 8);
        if (base == 0 and size == 0) break;
        try addReserved(&info, .{ .base = base, .size = size });
    }

    // 结构块。stack[0..depth] 是从根节点到当前节点的路径。
    var stack: [max_depth]Node = undefined;
    var depth: usize = 0;
    pos = 0;
    while (true) {
        const token: Token = @fromBackingInt(try readBe(u32, structure, pos));
        pos += 4;
        switch (token) {
            .begin_node => {
                if (depth == max_depth) return error.TooDeep;
                const name = try readStr(structure, pos);
                pos = std.mem.alignForward(usize, pos + name.len + 1, 4);
                stack[depth] = .{ .name = name };
                depth += 1;
            },
            .end_node => {
                if (depth == 0) return error.BadToken;
                // reg 要等节点结束再处理：device_type 可能排在 reg 后面。
                // reg 的格式由父节点的 #address-cells / #size-cells 决定。
                const node = stack[depth - 1];
                if (node.reg != null and depth >= 2) {
                    const parent = stack[depth - 2];
                    if (node.is_memory and info.memory.size == 0) {
                        info.memory = .{
                            .base = try readCells(node.reg.?, 0, parent.address_cells),
                            .size = try readCells(node.reg.?, 4 * parent.address_cells, parent.size_cells),
                        };
                    }
                    if (depth == 3 and std.mem.eql(u8, parent.name, "reserved-memory")) {
                        try addReservedReg(&info, node.reg.?, parent);
                    }
                }
                depth -= 1;
            },
            .prop => {
                if (depth == 0) return error.BadToken;
                const len = try readBe(u32, structure, pos);
                const name = try readStr(strings, try readBe(u32, structure, pos + 4));
                pos += 8;
                if (pos > structure.len or structure.len - pos < len) return error.Truncated;
                const value = structure[pos..][0..len];
                pos = std.mem.alignForward(usize, pos + len, 4);
                try handleProp(&info, stack[0..depth], name, value);
            },
            .nop => {},
            .end => break,
            _ => return error.BadToken,
        }
    }

    if (info.memory.size == 0) return error.NoMemory;
    if (info.timebase_hz == 0) return error.NoTimebase;
    return info;
}

/// path 是从根节点到当前节点的路径，最后一个元素就是属性所在的节点。
fn handleProp(info: *Info, path: []Node, name: []const u8, value: []const u8) Error!void {
    const node = &path[path.len - 1];
    if (std.mem.eql(u8, name, "#address-cells")) {
        node.address_cells = try readBe(u32, value, 0);
    } else if (std.mem.eql(u8, name, "#size-cells")) {
        node.size_cells = try readBe(u32, value, 0);
    } else if (std.mem.eql(u8, name, "device_type")) {
        node.is_memory = std.mem.eql(u8, value, "memory\x00");
    } else if (std.mem.eql(u8, name, "reg")) {
        node.reg = value;
    } else if (std.mem.eql(u8, name, "timebase-frequency")) {
        // 一般写在 /cpus 上；也允许写在各个 /cpus/cpu@N 上。长度是 4 或 8 字节。
        const in_cpus = (path.len == 2 and std.mem.eql(u8, node.name, "cpus")) or
            (path.len == 3 and std.mem.eql(u8, path[1].name, "cpus"));
        if (in_cpus and info.timebase_hz == 0) {
            info.timebase_hz = if (value.len == 8) try readBe(u64, value, 0) else try readBe(u32, value, 0);
        }
    }
}

fn addReserved(info: *Info, region: Region) Error!void {
    if (info.reserved_len == max_reserved) return error.TooManyReserved;
    info.reserved_buf[info.reserved_len] = region;
    info.reserved_len += 1;
}

/// reg 属性里可以有多段 (地址, 长度)，每段都加进保留区。
fn addReservedReg(info: *Info, reg: []const u8, parent: Node) Error!void {
    const entry_size = 4 * (parent.address_cells + parent.size_cells);
    if (entry_size == 0) return;
    var offset: usize = 0;
    while (offset + entry_size <= reg.len) : (offset += entry_size) {
        try addReserved(info, .{
            .base = try readCells(reg, offset, parent.address_cells),
            .size = try readCells(reg, offset + 4 * parent.address_cells, parent.size_cells),
        });
    }
}

/// 测试用：按 FDT 格式拼一份设备树。结构块和字符串块先分别写好，finish 时再和文件头、内存保留块拼起来。
const TestFdt = struct {
    structure: [1024]u8 = undefined,
    struct_len: usize = 0,
    strings: [256]u8 = undefined,
    strings_len: usize = 0,
    rsvmap: [4]Region = undefined,
    rsvmap_len: usize = 0,
    out: [2048]u8 align(8) = undefined,

    fn put32(f: *TestFdt, value: u32) void {
        std.mem.writeInt(u32, f.structure[f.struct_len..][0..4], value, .big);
        f.struct_len += 4;
    }

    /// 写入字节，再用 0 补齐到 4 字节对齐
    fn putBytes(f: *TestFdt, bytes: []const u8) void {
        @memcpy(f.structure[f.struct_len..][0..bytes.len], bytes);
        const padded = std.mem.alignForward(usize, bytes.len, 4);
        @memset(f.structure[f.struct_len + bytes.len ..][0 .. padded - bytes.len], 0);
        f.struct_len += padded;
    }

    fn beginNode(f: *TestFdt, comptime name: []const u8) void {
        f.put32(@backingInt(Token.begin_node));
        f.putBytes(name ++ "\x00");
    }

    fn endNode(f: *TestFdt) void {
        f.put32(@backingInt(Token.end_node));
    }

    fn prop(f: *TestFdt, comptime name: []const u8, value: []const u8) void {
        // 属性名放进字符串块，结构块里只存偏移
        const name_offset = f.strings_len;
        @memcpy(f.strings[name_offset..][0 .. name.len + 1], name ++ "\x00");
        f.strings_len += name.len + 1;
        f.put32(@backingInt(Token.prop));
        f.put32(@intCast(value.len));
        f.put32(@intCast(name_offset));
        f.putBytes(value);
    }

    /// 值是一串大端序的 32 位单元，比如 reg = <0x0 0x80000000 0x0 0x8000000>
    fn propCells(f: *TestFdt, comptime name: []const u8, comptime cells: []const u32) void {
        var bytes: [4 * cells.len]u8 = undefined;
        for (cells, 0..) |cell, i| std.mem.writeInt(u32, bytes[4 * i ..][0..4], cell, .big);
        f.prop(name, &bytes);
    }

    fn finish(f: *TestFdt) []const u8 {
        f.put32(@backingInt(Token.end));
        const off_rsvmap = 40;
        const off_struct = off_rsvmap + 16 * (f.rsvmap_len + 1);
        const off_strings = off_struct + f.struct_len;
        const total = off_strings + f.strings_len;
        const header = [_]u32{ magic, @intCast(total), @intCast(off_struct), @intCast(off_strings), off_rsvmap, 17, 16, 0, @intCast(f.strings_len), @intCast(f.struct_len) };
        for (header, 0..) |value, i| std.mem.writeInt(u32, f.out[4 * i ..][0..4], value, .big);
        for (f.rsvmap[0..f.rsvmap_len], 0..) |r, i| {
            std.mem.writeInt(u64, f.out[off_rsvmap + 16 * i ..][0..8], r.base, .big);
            std.mem.writeInt(u64, f.out[off_rsvmap + 16 * i + 8 ..][0..8], r.size, .big);
        }
        @memset(f.out[off_struct - 16 .. off_struct], 0); // 内存保留块以 (0, 0) 结尾
        @memcpy(f.out[off_struct..off_strings], f.structure[0..f.struct_len]);
        @memcpy(f.out[off_strings..total], f.strings[0..f.strings_len]);
        return f.out[0..total];
    }
};

/// 和 QEMU virt 给的设备树结构相同的一份（只保留解析器关心的节点和属性）
fn testTree(f: *TestFdt, comptime with_timebase: bool) []const u8 {
    f.rsvmap[0] = .{ .base = 0x8700_0000, .size = 0x1000 };
    f.rsvmap_len = 1;
    f.beginNode(""); // 根节点的名字是空字符串
    f.propCells("#address-cells", &.{2});
    f.propCells("#size-cells", &.{2});
    f.beginNode("reserved-memory");
    f.propCells("#address-cells", &.{2});
    f.propCells("#size-cells", &.{2});
    f.beginNode("mmode_resv0@80000000");
    f.propCells("reg", &.{ 0, 0x8000_0000, 0, 0x6_0000 });
    f.endNode();
    f.endNode();
    f.beginNode("memory@80000000");
    // reg 写在 device_type 前面：解析器要等节点结束才知道它是不是内存节点
    f.propCells("reg", &.{ 0, 0x8000_0000, 0, 0x800_0000 });
    f.prop("device_type", "memory\x00");
    f.endNode();
    f.beginNode("cpus");
    f.propCells("#address-cells", &.{1});
    f.propCells("#size-cells", &.{0});
    if (with_timebase) f.propCells("timebase-frequency", &.{10_000_000});
    f.beginNode("cpu@0");
    f.propCells("reg", &.{0});
    f.endNode();
    f.endNode();
    f.endNode();
    return f.finish();
}

test "解析 QEMU virt 风格的设备树" {
    var f: TestFdt = .{};
    const blob = testTree(&f, true);
    const info = try parseBlob(blob);
    try std.testing.expectEqual(Region{ .base = 0x8000_0000, .size = 128 << 20 }, info.memory);
    try std.testing.expectEqual(10_000_000, info.timebase_hz);
    // 保留区：设备树自己、内存保留块里的一项、/reserved-memory 的子节点
    try std.testing.expectEqualSlices(Region, &.{
        .{ .base = @intFromPtr(blob.ptr), .size = blob.len },
        .{ .base = 0x8700_0000, .size = 0x1000 },
        .{ .base = 0x8000_0000, .size = 0x6_0000 },
    }, info.reserved());
}

test "缺少必需的信息、格式不对时返回错误" {
    var f: TestFdt = .{};
    try std.testing.expectError(error.NoTimebase, parseBlob(testTree(&f, false)));

    var g: TestFdt = .{};
    const blob = testTree(&g, true);
    // 截掉末尾：文件头里记的字符串块超出了实际的数据
    try std.testing.expectError(error.Truncated, parseBlob(blob[0 .. blob.len - 8]));
    try std.testing.expectError(error.Truncated, parseBlob(blob[0..2]));
    var bad = g.out;
    bad[0] = 0;
    try std.testing.expectError(error.BadMagic, parseBlob(bad[0..blob.len]));
}
