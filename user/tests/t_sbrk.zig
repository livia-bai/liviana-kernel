//! 回归测试：sbrk。堆的增长、缩小、清零、按页释放、越界、fork 复制堆。
//! 失败的项打印 "FAIL: ..."，最后打印通过的项数。漏页的话 qemu_test.py 比较前后的 mem 会发现。

const std = @import("std");
const sys = @import("sys");
const abi = sys.abi;

var failures: u8 = 0;
var checks: usize = 0;

fn expect(ok: bool, comptime what: []const u8, args: anytype) void {
    checks += 1;
    if (!ok) {
        failures += 1;
        sys.print("FAIL: " ++ what ++ "\n", args);
    }
}

const page = 4096;

fn heap(addr: usize, len: usize) []u8 {
    return @as([*]u8, @ptrFromInt(addr))[0..len];
}

/// fork 一个子进程去碰地址 addr（写），返回它的结束状态。
fn touch(addr: usize) u32 {
    const pid = sys.fork() catch return 999;
    if (pid == 0) {
        @as(*volatile u8, @ptrFromInt(addr)).* = 1;
        sys.exit(0);
    }
    return (sys.wait(pid, false) catch return 999).?.status;
}

pub fn main() u8 {
    const base = sys.sbrk(0) catch 0;
    expect(base % page == 0 and base > 0x4000_0000 and base < 0x8000_0000, "heap starts at 0x{x}", .{base});
    // 一开始堆是空的：base 那一页没有映射
    expect(touch(base) == abi.killed_status, "touching the empty heap", .{});

    // 长 3 页多一点：返回原来的末尾，新内存清零、可读写
    const size = 3 * page + 100;
    expect((sys.sbrk(size) catch 0) == base, "sbrk returns the old break", .{});
    expect((sys.sbrk(0) catch 0) == base + size, "break after growing", .{});
    const mem = heap(base, size);
    expect(std.mem.allEqual(u8, mem, 0), "new heap memory is zeroed", .{});
    for (mem, 0..) |*b, i| b.* = @truncate(i);
    // 最后一页的页尾也映射了（按页映射），再往后没有
    expect(touch(base + 4 * page - 1) == 0, "touching the end of the last heap page", .{});
    expect(touch(base + 4 * page) == abi.killed_status, "touching past the heap", .{});

    // 内核也能读写堆里的内存：通过管道把前 100 字节绕一圈
    {
        const p = sys.pipe() catch unreachable;
        _ = sys.write(p[1], mem[0..100]) catch {};
        _ = sys.read(p[0], mem[size - 100 ..]) catch {};
        sys.close(p[0]) catch {};
        sys.close(p[1]) catch {};
        expect(std.mem.eql(u8, mem[0..100], mem[size - 100 ..]), "pipe through the heap", .{});
    }

    // fork 复制堆：子进程看到同样的内容，改了不影响父进程
    {
        const pid = sys.fork() catch unreachable;
        if (pid == 0) {
            const ok = mem[page + 1] == @as(u8, @truncate(page + 1)) and (sys.sbrk(0) catch 0) == base + size;
            mem[page + 1] = 0xff;
            sys.exit(if (ok) 0 else 1);
        }
        const r = (sys.wait(pid, false) catch null).?;
        expect(r.status == 0, "child sees the heap: status {d}", .{r.status});
        expect(mem[page + 1] == @as(u8, @truncate(page + 1)), "child's write leaked into the parent", .{});
    }

    // 缩到第 2 页中间：第 2 页还在（内容不变），第 3、4 页释放了
    expect((sys.sbrk(-(2 * page - 100)) catch 0) == base + size, "shrinking returns the old break", .{});
    expect(mem[page + 10] == @as(u8, @truncate(page + 10)), "memory below the break keeps its content", .{});
    expect(touch(base + 2 * page - 1) == 0, "touching the page holding the break", .{});
    expect(touch(base + 2 * page) == abi.killed_status, "touching a freed heap page", .{});
    // 再长回来：重新映射的页是清零的
    _ = sys.sbrk(2 * page) catch {};
    expect(heap(base + 2 * page, page)[0] == 0, "regrown heap memory is zeroed", .{});

    // 不能缩到堆的起点下面，不能长进栈；物理内存不够时失败，不留下半截（qemu_test.py 检查 mem）
    const now = sys.sbrk(0) catch 0;
    expect(sys.sbrk(-@as(isize, @intCast(now - base + 1))) == error.InvalidArgument, "shrinking below the heap start", .{});
    expect(sys.sbrk(std.math.minInt(isize)) == error.InvalidArgument, "sbrk(minInt)", .{});
    expect(sys.sbrk(0x4000_0000) == error.OutOfMemory, "growing into the stack", .{});
    expect(sys.sbrk(std.math.maxInt(isize)) == error.OutOfMemory, "sbrk(maxInt)", .{});
    const free = sys.meminfo().free_pages;
    expect(sys.sbrk(@intCast((free + 10) * page)) == error.OutOfMemory, "growing past physical memory", .{});
    expect(sys.meminfo().free_pages == free, "failed sbrk leaked pages: {d} -> {d}", .{ free, sys.meminfo().free_pages });
    expect((sys.sbrk(0) catch 0) == now, "failed sbrk moved the break", .{});

    // 一个字节一个字节地长，跨过页边界
    {
        const start = sys.sbrk(0) catch 0;
        for (0..page + 2) |i| {
            const old = sys.sbrk(1) catch break;
            if (old != start + i) break;
            heap(old, 1)[0] = 'a';
        }
        expect((sys.sbrk(0) catch 0) == start + page + 2, "growing one byte at a time", .{});
    }

    // 全部还回去
    const end = sys.sbrk(0) catch 0;
    _ = sys.sbrk(-@as(isize, @intCast(end - base))) catch {};
    expect((sys.sbrk(0) catch 0) == base, "heap back to empty", .{});
    expect(touch(base) == abi.killed_status, "touching the emptied heap", .{});

    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}
