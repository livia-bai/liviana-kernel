//! 回归测试：sbrk。堆的增长、缩小、清零、按页释放、越界、fork 复制堆；按需分配（sbrk 只挪末尾，
//! 页用到才分配；内存不够时访问它的进程被结束）。
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

    // 不能缩到堆的起点下面，不能长进栈；一次要的比整个物理内存还多时失败；失败时什么都不变
    const now = sys.sbrk(0) catch 0;
    expect(sys.sbrk(-@as(isize, @intCast(now - base + 1))) == error.InvalidArgument, "shrinking below the heap start", .{});
    expect(sys.sbrk(std.math.minInt(isize)) == error.InvalidArgument, "sbrk(minInt)", .{});
    expect(sys.sbrk(0x4000_0000) == error.OutOfMemory, "growing into the stack", .{});
    expect(sys.sbrk(std.math.maxInt(isize)) == error.OutOfMemory, "sbrk(maxInt)", .{});
    const info = sys.meminfo();
    expect(sys.sbrk(@intCast((info.total_pages + 1) * page)) == error.OutOfMemory, "growing past physical memory", .{});
    expect(sys.meminfo().free_pages == info.free_pages, "failed sbrk used pages: {d} -> {d}", .{ info.free_pages, sys.meminfo().free_pages });
    expect((sys.sbrk(0) catch 0) == now, "failed sbrk moved the break", .{});
    demandPaging(base);

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

/// 按需分配：sbrk 只挪末尾，页用到才分配；比空闲内存还多（但不比整个物理内存多）的 sbrk 也成功，
/// 真的都用上时，访问它的进程被结束（out of memory），内核替进程写的话返回 EFAULT。
fn demandPaging(heap_start: usize) void {
    // 内存用完的那一会儿，自己不能再用到还没分配的页（不然自己也会被结束）：先把程序的每一页都读进来，
    // 栈最上面 16 KiB 也都分配好
    var addr: usize = 0x4000_0000;
    while (addr < heap_start) : (addr += page) _ = @as(*const volatile u8, @ptrFromInt(addr)).*;
    addr = 0x8000_0000 - 16 * 1024;
    while (addr < 0x8000_0000) : (addr += page) {
        const p: *volatile u8 = @ptrFromInt(addr);
        p.* = p.*;
    }
    const zero = sys.open("/dev/zero", .{}) catch {
        expect(false, "open /dev/zero", .{});
        return;
    };
    defer sys.close(zero) catch {};

    // 从页边界开始：brk 所在的那一页之前已经属于堆了，碰它不算这里分配的
    const brk = sys.sbrk(0) catch 0;
    _ = sys.sbrk(@intCast((page - brk % page) % page)) catch {};
    const start = sys.sbrk(0) catch 0;
    const free = sys.meminfo().free_pages;
    // 长 4 MiB：一页都不用
    const big = 4 << 20;
    expect((sys.sbrk(big) catch 0) == start, "sbrk 4 MiB", .{});
    expect(sys.meminfo().free_pages == free, "sbrk 4 MiB used {d} pages before touching them", .{free -| sys.meminfo().free_pages});
    // 碰其中两页（隔得很远）：只用这两页，加上装它们的页表（每 2 MiB 一张）
    const mem = heap(start, big);
    mem[0] = 1;
    mem[big - 1] = 2;
    const used = free -| sys.meminfo().free_pages;
    expect(used >= 2 and used <= 5, "touching 2 pages of a 4 MiB heap used {d} pages", .{used});
    expect(mem[1] == 0 and mem[big - 2] == 0 and mem[page * 100] == 0, "untouched heap memory is zeroed", .{});
    // 缩回去：用过的都还回去了（页表也是）
    _ = sys.sbrk(-@as(isize, big)) catch {};
    expect(sys.meminfo().free_pages == free, "shrinking a sparse heap leaked {d} pages", .{free -| sys.meminfo().free_pages});

    // 比空闲内存多：sbrk 成功；子进程把它一页一页写满，内存用完时被结束（qemu_test.py 检查那一行），父进程照常
    // 多几页就够了（页表也要用内存）；多太多的话超过了整个物理内存，sbrk 会拒绝
    const n = sys.meminfo().free_pages + 4;
    const over = sys.sbrk(@intCast(n * page)) catch {
        expect(false, "sbrk of more than the free memory", .{});
        return;
    };
    const pid = sys.fork() catch unreachable;
    if (pid == 0) {
        for (0..n) |i| @as(*volatile u8, @ptrFromInt(over + i * page)).* = 1;
        sys.exit(0); // 不应该走到这里
    }
    const r = (sys.wait(pid, false) catch null).?;
    expect(r.status == abi.killed_status, "child that used up memory: status {d}", .{r.status});
    // 内核替自己写一大片还没分配的堆（读 /dev/zero）：写到没内存了就停下，返回 EFAULT，自己不会被结束。
    // 内存用完了，马上缩回去还掉，之后才调用 expect
    const ok = sys.read(zero, heap(over, n * page)) == error.BadAddress;
    _ = sys.sbrk(-@as(isize, @intCast(n * page))) catch {};
    expect(ok, "kernel writing a heap larger than memory did not return EFAULT", .{});
    expect((sys.sbrk(0) catch 0) == start, "heap back to where it was", .{});
    _ = sys.sbrk(@as(isize, @intCast(brk)) - @as(isize, @intCast(start))) catch {};
}
