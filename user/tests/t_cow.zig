//! 回归测试：写时复制的 fork。fork 不复制页；父子进程（和内核替它们写的时候）谁先写哪一页谁复制，
//! 互不影响；只剩一个进程在用的页直接改回可写，不再复制；内存用完时，内核写不进 cow 页返回 EFAULT，
//! 进程自己写的话被结束（out of memory）。
//! 失败的项打印 "FAIL: ..."，最后打印检查了几项、失败了几项。漏页由 qemu_test.py 比较前后的 mem 发现。

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

fn fork() usize {
    return sys.fork() catch |err| {
        sys.print("FAIL: fork: {s}\n", .{@errorName(err)});
        sys.exit(200);
    };
}

fn pipe() [2]sys.Fd {
    return sys.pipe() catch |err| {
        sys.print("FAIL: pipe: {s}\n", .{@errorName(err)});
        sys.exit(201);
    };
}

/// 等子进程 pid 结束，返回它的结束状态。
fn waitStatus(pid: usize) u32 {
    const r = (sys.wait(pid, false) catch null) orelse return 999;
    return r.status;
}

fn signal(fd: sys.Fd) void {
    _ = sys.write(fd, "!") catch {};
}

fn await(fd: sys.Fd) void {
    var b: [1]u8 = undefined;
    _ = sys.read(fd, &b) catch {};
}

fn freePages() u64 {
    return sys.meminfo().free_pages;
}

const page = 4096;
/// 堆的页数：每一页都写过，fork 时都是可写的页
const heap_pages = 64;
var heap: [*]volatile u8 = undefined;

fn heapPage(i: usize) usize {
    return @intFromPtr(heap) + i * page;
}

/// 全局变量在数据段里
var global: u32 = 1;

pub fn main() u8 {
    heap = @ptrFromInt(sys.sbrk(heap_pages * page) catch {
        sys.print("FAIL: sbrk\n", .{});
        return 1;
    });
    for (0..heap_pages) |i| heap[i * page] = @truncate(i + 1);

    // 1. fork 不复制页：子进程刚开始时，整个系统只多用了它的页表和父子两边刚写过的几页栈
    {
        const before = freePages();
        const pid = fork();
        if (pid == 0) sys.exit(@intCast(@min(before -| freePages(), 255)));
        const used = waitStatus(pid);
        expect(used < heap_pages / 4, "fork of a {d}-page heap used {d} pages", .{ heap_pages, used });
        sys.print("fork of a process with a {d}-page heap used {d} pages\n", .{ heap_pages, used });
    }

    // 2. 内容一样，各改各的：子进程改堆、全局变量，父进程看不到；父进程之后改的，子进程也看不到
    {
        const to_child = pipe();
        const to_parent = pipe();
        const pid = fork();
        if (pid == 0) {
            var bad: u8 = 0;
            for (0..heap_pages) |i| {
                if (heap[i * page] != @as(u8, @truncate(i + 1))) bad |= 1;
            }
            heap[0] = 0xaa;
            global = 2;
            signal(to_parent[1]);
            await(to_child[0]);
            if (heap[page] != 2) bad |= 2; // 父进程改了它那一份
            if (heap[0] != 0xaa or global != 2) bad |= 4;
            sys.exit(bad);
        }
        await(to_parent[0]);
        expect(heap[0] == 1 and global == 1, "child's writes leaked into the parent: {d} {d}", .{ heap[0], global });
        heap[page] = 0xbb;
        signal(to_child[1]);
        const status = waitStatus(pid);
        expect(status == 0, "child saw wrong contents: status {d}", .{status});
        expect(heap[page] == 0xbb, "parent lost its own write", .{});
        for ([_]sys.Fd{ to_child[0], to_child[1], to_parent[0], to_parent[1] }) |fd| sys.close(fd) catch {};
    }

    // 3. 内核替子进程往 cow 页里写（read、pipe、meminfo、wait 的输出参数）：也只改子进程那一份
    {
        const p = pipe();
        _ = sys.write(p[1], "hello") catch {};
        const pid = fork();
        if (pid == 0) {
            var bad: u8 = 0;
            const buf: [*]u8 = @ptrFromInt(heapPage(2));
            if ((sys.read(p[0], buf[0..5]) catch 0) != 5 or !std.mem.eql(u8, buf[0..5], "hello")) bad |= 1;
            if (sys.syscall(.pipe, heapPage(3), 0, 0) != 0) bad |= 2;
            if (sys.syscall(.meminfo, heapPage(4), 0, 0) != 0) bad |= 4;
            const grandchild = sys.fork() catch sys.exit(100);
            if (grandchild == 0) sys.exit(42);
            if (sys.syscall(.wait, grandchild, heapPage(5), 0) != grandchild or heap[5 * page] != 42) bad |= 8;
            sys.exit(bad);
        }
        const status = waitStatus(pid);
        expect(status == 0, "kernel writes into the child's cow pages failed: status {d}", .{status});
        for (2..6) |i| {
            expect(heap[i * page] == i + 1, "kernel write into the child's page {d} leaked into the parent: {d}", .{ i, heap[i * page] });
        }
        sys.close(p[0]) catch {};
        sys.close(p[1]) catch {};
    }

    // 4. 父进程先写，复制走了自己那一份；这一页只剩子进程在用，子进程再写时不再复制
    {
        const go = pipe();
        const pid = fork();
        if (pid == 0) {
            await(go[0]);
            // 先调用两次 meminfo：让它和之后的调用用到的栈页都已经是自己的
            _ = freePages();
            const before = freePages();
            heap[6 * page] = 0xcc;
            sys.exit(if (freePages() == before and heap[6 * page] == 0xcc) 0 else 1);
        }
        heap[6 * page] = 0xdd;
        signal(go[1]);
        const status = waitStatus(pid);
        expect(status == 0, "writing a page no one else uses any more copied it", .{});
        expect(heap[6 * page] == 0xdd, "parent's page changed", .{});
        sys.close(go[0]) catch {};
        sys.close(go[1]) catch {};
    }

    outOfMemory();

    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}

/// 用户栈的范围（src/proc.zig）。
const stack_top = 0x8000_0000;
const stack_bottom = stack_top - 16 * 1024;

/// 把整个栈的每一页都读出来再原样写回去：fork 之后共用的栈页就都变成了自己的。
fn ownStack() void {
    var addr: usize = stack_bottom;
    while (addr < stack_top) : (addr += page) {
        const p: *volatile u8 = @ptrFromInt(addr);
        p.* = p.*;
    }
}

/// 5. 内存用完时的写时复制。子进程先睡着；父进程把空闲页全部用掉（堆和管道），再叫醒它。
/// 子进程让内核往 cow 页里写（meminfo），应该得到 EFAULT，页的内容不变；它自己再写一个 cow 页，
/// 应该被内核结束（out of memory），而不是 panic、卡住或者改到父进程的页。
///
/// 内存用完之后，父子进程都不能再写任何还和对方共用的页（包括栈和全局变量），否则自己也会被结束：
/// 两边都先 ownStack，父进程把结果先记在栈上，放开内存之后才调用 expect（它要写全局变量）。
fn outOfMemory() void {
    const go = pipe();
    const result = pipe();
    const pid = fork();
    ownStack();
    if (pid == 0) {
        signal(result[1]); // 栈已经是自己的了，父进程可以开始用完内存
        await(go[0]);
        const ok = sys.syscall(.meminfo, heapPage(7), 0, 0) == abi.fail(.fault) and heap[7 * page] == 8;
        _ = sys.write(result[1], if (ok) "y" else "n") catch {};
        heap[8 * page] = 0xee; // 没有内存复制它：内核结束这个进程
        sys.exit(1);
    }
    await(result[0]);

    // 把内存用完：堆每次长 1 MiB，长不动了减半，直到一页也长不动；剩下的零星几页（新的页表要用）给管道
    const start = sys.sbrk(0) catch unreachable;
    var chunk: isize = 1 << 20;
    while (chunk >= page) {
        _ = sys.sbrk(chunk) catch {
            chunk = @divExact(chunk, 2);
        };
    }
    var pipes: [8][2]sys.Fd = undefined;
    var npipes: usize = 0;
    while (npipes < pipes.len) : (npipes += 1) pipes[npipes] = sys.pipe() catch break;
    const free = freePages();

    signal(go[1]);
    var answer: [1]u8 = undefined;
    _ = sys.read(result[0], &answer) catch {};
    const status = waitStatus(pid);
    const unchanged = heap[7 * page] == 8 and heap[8 * page] == 9;

    for (pipes[0..npipes]) |p| {
        sys.close(p[0]) catch {};
        sys.close(p[1]) catch {};
    }
    _ = sys.sbrk(@as(isize, @intCast(start)) - @as(isize, @intCast(sys.sbrk(0) catch unreachable))) catch {};
    for ([_]sys.Fd{ go[0], go[1], result[0], result[1] }) |fd| sys.close(fd) catch {};

    expect(free == 0, "could not use up memory: {d} pages left", .{free});
    expect(answer[0] == 'y', "kernel write into a cow page without memory did not return EFAULT", .{});
    expect(status == abi.killed_status, "child writing a cow page without memory: status {d}", .{status});
    expect(unchanged, "parent's pages changed", .{});
}
