//! 用户进程和调度。进程表里最多 max_procs 个进程，每个有自己的地址空间、内核栈和保存的内核上下文。
//!
//! 调度器就是内核的主循环（main.zig），它在启动栈上运行，每一轮调用 schedule() 挑一个就绪的进程
//! 切过去。进程在 U 模式运行，直到下一次中断（时钟每 10 ms 一次，所以时间片是一个 tick）、
//! 调用 yield/sleep、exit，或者出了异常，再切回主循环。主循环在两个时间片之间处理键盘输入，
//! 所以有进程在跑时 shell 照样能用。
//!
//! 用户地址空间（都在 vm.user_base..vm.user_end 之内）：
//!   0x4000_0000 起    程序的各个段（user/linker.ld），按段设置 R/W/X，都带 U 位
//!   ...              不映射
//!   栈底下面一页      不映射，栈溢出时触发缺页异常，而不是悄悄踩坏别的数据
//!   0x8000_0000 往下  16 KiB 用户栈，可读写

const std = @import("std");
const elf = std.elf;
const build_options = @import("build_options");
const riscv = @import("riscv.zig");
const uart = @import("uart.zig");
const page = @import("page.zig");
const vm = @import("vm.zig");
const trap = @import("trap.zig");
const timer = @import("timer.zig");

pub const Program = struct {
    name: []const u8,
    image: []const u8,
};

/// 编译时嵌进内核的用户程序（见 build.zig），image 是 ELF 文件的内容。
pub const programs = blk: {
    var list: [build_options.user_programs.len]Program = undefined;
    for (&list, build_options.user_programs) |*p, name| p.* = .{ .name = name, .image = @embedFile(name) };
    const final = list;
    break :blk final;
};

pub fn find(name: []const u8) ?*const Program {
    for (&programs) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

const stack_size = 16 * 1024;
const stack_top = vm.user_end;
const stack_bottom = stack_top - stack_size;

pub const max_procs = 8;

pub const State = enum {
    unused,
    /// 等着被调度
    ready,
    /// 正在 CPU 上运行（current 指向它）
    running,
    /// 调用了 sleep，timer.ticks 到 wake_tick 之后回到 ready
    sleeping,
    /// 调用了 exit 或者被杀，等调度器回收
    exited,
};

pub const Process = struct {
    state: State = .unused,
    pid: usize = 0,
    name: []const u8 = "",
    space: *vm.PageTable = undefined,
    /// 不在运行时，它的内核上下文保存在这里（见 switchContext）
    context: Context = undefined,
    wake_tick: u64 = 0,
    /// 在 U 模式运行期间来过的时钟中断数，大致就是用掉的 CPU 时间（单位 10 ms）
    ticks: u64 = 0,
};

/// 进程表。槽位 i 的进程用 kernel_stacks[i] 作内核栈。
pub var table: [max_procs]Process = @splat(.{});

/// 正在运行的进程。在主循环里（调度器、shell）时为 null。
pub var current: ?*Process = null;
var next_pid: usize = 1;

/// 每个进程陷入内核时用的栈，静态分配：页分配器只能一页一页地给，给不出连续的 16 KiB。
/// 实测最深的路径（Debug 模式下杀进程时格式化输出）用了不到 4 KiB。
var kernel_stacks: [max_procs][16 * 1024]u8 align(16) = undefined;

/// 切换时保存的内核上下文。按 C 调用约定，跨函数调用需要保持不变的只有
/// ra、sp 和 s0..s11，其他寄存器调用方本来就不指望它们保持原值。
const Context = extern struct {
    ra: usize,
    sp: usize,
    s: [12]usize,
};

/// 调度器（主循环）切到进程时保存的上下文，进程让出 CPU 时切回这里。
var scheduler_context: Context = undefined;
/// 上一次运行的槽位，下一次从它后面开始找，这样就绪的进程轮流运行。
var last_slot: usize = max_procs - 1;

pub const SpawnError = error{ TooManyProcesses, OutOfMemory, BadElf };

/// 加载一个用户程序，放进进程表，状态为 ready，返回 pid。由 shell 调用，真正开始运行要等主循环调度到它。
pub fn spawn(program: *const Program) SpawnError!usize {
    const slot = for (&table, 0..) |*p, i| {
        if (p.state == .unused) break i;
    } else return error.TooManyProcesses;
    const space = try vm.createUserSpace();
    errdefer vm.destroyUserSpace(space);
    const entry = try load(space, program.image);

    // 进入 U 模式的初始状态：除了 sp 以外寄存器全为 0，从 ELF 的入口地址开始执行。
    // trapExit 要求 TrapFrame 正好在内核栈顶下面（见 trap.trapExit）。
    const stack = &kernel_stacks[slot];
    const frame: *trap.TrapFrame = @ptrCast(@alignCast(stack[stack.len - @sizeOf(trap.TrapFrame) ..]));
    frame.* = .{
        .regs = @splat(0),
        .sepc = entry,
        // SPP = 0：sret 回到 U 模式；SPIE = 1：回到 U 模式后打开中断，时钟和键盘照常工作。
        // SIE 必须清掉：shell 是开着中断调用这里的，trapExit 一开始就写回 sstatus，
        // SIE = 1 的话恢复寄存器的途中就可能被中断打断
        .sstatus = (riscv.read(.sstatus) & ~(riscv.sstatus_spp | riscv.sstatus_sie)) | riscv.sstatus_spie,
    };
    frame.regs[2] = stack_top;

    // 第一次被调度时，switchContext 恢复这个上下文后 ret 到 trapExit，sp 正指向初始 TrapFrame
    table[slot] = .{
        .state = .ready,
        .pid = next_pid,
        .name = program.name,
        .space = space,
        .context = .{ .ra = @intFromPtr(&trap.trapExit), .sp = @intFromPtr(frame), .s = @splat(0) },
    };
    next_pid += 1;
    return table[slot].pid;
}

/// 调度一次：挑一个就绪的进程，切到它的地址空间运行，等它让出 CPU、睡眠或者结束再返回 true。
/// 没有就绪的进程时返回 false。只由主循环调用，调用时中断必须是关着的。
pub fn schedule() bool {
    std.debug.assert(current == null);
    const slot = pickNext(&table, last_slot, timer.ticks) orelse return false;
    last_slot = slot;
    const p = &table[slot];
    p.state = .running;
    current = p;
    vm.activate(p.space);
    switchContext(&scheduler_context, &p.context);
    // 进程让出了 CPU。先切回内核页表，回收进程时才能释放它的页表
    vm.activate(vm.kernel_root);
    current = null;
    if (p.state == .exited) release(p);
    return true;
}

/// 从 last 的下一个槽位开始轮着找，返回第一个就绪的进程的槽位。睡够了的进程先改回 ready。
fn pickNext(procs: []Process, last: usize, now: u64) ?usize {
    for (procs) |*p| {
        if (p.state == .sleeping and now >= p.wake_tick) p.state = .ready;
    }
    for (1..procs.len + 1) |k| {
        const i = (last + k) % procs.len;
        if (procs[i].state == .ready) return i;
    }
    return null;
}

/// 当前进程让出 CPU，回到调度器；下次轮到它时从这里返回。由陷阱处理程序调用（关着中断）。
pub fn yield() void {
    const p = current.?;
    p.state = .ready;
    switchContext(&p.context, &scheduler_context);
}

/// 当前进程睡 ms 毫秒（按 tick 向上取整），期间不会被调度。
pub fn sleep(ms: u64) void {
    const p = current.?;
    p.wake_tick = timer.ticks +| (ms *| timer.tick_hz +| 999) / 1000;
    p.state = .sleeping;
    switchContext(&p.context, &scheduler_context);
}

/// 当前进程调用了 exit。由系统调用处理程序调用，不返回。
pub fn exit(code: u8) noreturn {
    const p = current.?;
    uart.print("[proc] pid {d} ({s}) exited with code {d}\n", .{ p.pid, p.name, code });
    finish(p);
}

/// 强行结束当前进程。由陷阱处理程序调用，不返回。
pub fn killCurrent(comptime reason: []const u8, args: anytype) noreturn {
    const p = current.?;
    uart.print("[proc] pid {d} ({s}) killed: " ++ reason ++ "\n", .{ p.pid, p.name } ++ args);
    finish(p);
}

/// 回到调度器，由它回收这个进程。进程正在用自己的内核栈和地址空间，不能自己释放。
fn finish(p: *Process) noreturn {
    p.state = .exited;
    switchContext(&p.context, &scheduler_context);
    unreachable; // 调度器不会再切回已经结束的进程
}

/// 结束进程 pid。由 shell 调用：这时 CPU 在主循环里，没有进程在运行，
/// 它停在内核栈上的状态直接丢掉就行。找不到这个进程时返回 false。
pub fn kill(pid: usize, comptime reason: []const u8) bool {
    std.debug.assert(current == null);
    const p = findPid(pid) orelse return false;
    uart.print("[proc] pid {d} ({s}) killed: " ++ reason ++ "\n", .{ p.pid, p.name });
    release(p);
    return true;
}

pub fn findPid(pid: usize) ?*Process {
    for (&table) |*p| {
        if (p.state != .unused and p.pid == pid) return p;
    }
    return null;
}

/// 释放进程的地址空间（所有用户页和页表），腾出槽位。内核栈是静态的，留给下一个用这个槽位的进程。
fn release(p: *Process) void {
    vm.destroyUserSpace(p.space);
    p.* = .{};
}

/// 把当前的内核上下文保存到 from，再恢复 to 里保存的上下文：恢复出来的 ra、sp 是别处
/// 调用 switchContext 时留下的，所以执行从那次调用之后继续。对这里的调用者来说，
/// 要等到别人切回 from 时，这个函数才“返回”。
///
/// 实际的切换在裸函数 switchNaked 里。Zig 不允许直接调用裸函数，这里在内联汇编里
/// call 它：对编译器来说这只是一段会破坏若干寄存器的汇编，它不会对裸函数做任何假设。
/// （如果转成函数指针来调，签名就必须写对：这个调用是会返回的，声明成 noreturn 的话，
/// 编译器会把调用之后的代码全部删掉，release 模式下就出过这个问题。）
/// 按 C 调用约定，调用者保存的寄存器在调用前后可能变化，所以都声明为被破坏；
/// ra、sp、s0..s11 由 switchNaked 保存和恢复，保持不变。
fn switchContext(from: *Context, to: *const Context) void {
    asm volatile (
        \\mv a0, %[from]
        \\mv a1, %[to]
        \\call %[switchNaked]
        :
        : [from] "r" (from),
          [to] "r" (to),
          [switchNaked] "X" (&switchNaked),
        : .{
          .ra = true,
          .t0 = true,
          .t1 = true,
          .t2 = true,
          .t3 = true,
          .t4 = true,
          .t5 = true,
          .t6 = true,
          .a0 = true,
          .a1 = true,
          .a2 = true,
          .a3 = true,
          .a4 = true,
          .a5 = true,
          .a6 = true,
          .a7 = true,
          .memory = true,
        });
}

/// a0 = from，a1 = to。最后的 ret 跳到恢复出来的 ra，不会走到函数体结尾，所以是 noreturn；
/// 只从 switchContext 的内联汇编里调用。
fn switchNaked() callconv(.naked) noreturn {
    asm volatile (contextAsm("sd", "a0") ++ contextAsm("ld", "a1") ++ "ret\n");
}

/// 在编译期生成保存/恢复 Context 里 14 个寄存器的指令，base 是存放 Context 地址的寄存器。
fn contextAsm(comptime op: []const u8, comptime base: []const u8) []const u8 {
    const regs = [_][]const u8{ "ra", "sp", "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11" };
    comptime std.debug.assert(regs.len * @sizeOf(usize) == @sizeOf(Context));
    var s: []const u8 = "";
    for (regs, 0..) |reg, i| {
        s = s ++ std.fmt.comptimePrint("{s} {s}, {d}({s})\n", .{ op, reg, i * @sizeOf(usize), base });
    }
    return s;
}

const LoadError = error{ BadElf, OutOfMemory };

/// 把 ELF 镜像的各个 PT_LOAD 段装进地址空间、映射用户栈，返回入口地址。
fn load(space: *vm.PageTable, image: []const u8) LoadError!usize {
    const Ehdr = elf.Elf64.Ehdr;
    const Phdr = elf.Elf64.Phdr;
    if (image.len < @sizeOf(Ehdr)) return error.BadElf;
    const ehdr = std.mem.bytesToValue(Ehdr, image[0..@sizeOf(Ehdr)]);
    if (!std.mem.eql(u8, &ehdr.ident.magic, elf.MAGIC) or ehdr.ident.class != .@"64" or
        ehdr.ident.data != .@"2LSB" or ehdr.type != .EXEC or ehdr.machine != .RISCV or
        ehdr.phentsize != @sizeOf(Phdr))
    {
        return error.BadElf;
    }

    for (0..ehdr.phnum) |i| {
        const offset = std.math.add(usize, ehdr.phoff, i * @sizeOf(Phdr)) catch return error.BadElf;
        if (offset > image.len or image.len - offset < @sizeOf(Phdr)) return error.BadElf;
        const phdr = std.mem.bytesToValue(Phdr, image[offset..][0..@sizeOf(Phdr)]);
        if (phdr.type != .LOAD or phdr.memsz == 0) continue;
        try loadSegment(space, image, phdr);
    }

    var addr = stack_bottom;
    while (addr < stack_top) : (addr += page.size) {
        _ = vm.allocUserPage(space, addr, .{ .r = true, .w = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AlreadyMapped => unreachable, // loadSegment 保证了段都在栈下面
        };
    }
    return ehdr.entry;
}

fn loadSegment(space: *vm.PageTable, image: []const u8, phdr: elf.Elf64.Phdr) LoadError!void {
    // 段要从页边界开始（user/linker.ld 保证），整段落在用户区里、在栈下面的保护页之下，
    // 文件内容不能超出镜像。段必须可读：R/W/X 全为 0 的页表项会被 CPU 当成指向下一级页表的指针，
    // 而只写不读的组合在 RISC-V 里是保留的。
    const end = std.math.add(usize, phdr.vaddr, phdr.memsz) catch return error.BadElf;
    if (phdr.vaddr % page.size != 0 or phdr.vaddr < vm.user_base or end > stack_bottom - page.size or
        phdr.filesz > phdr.memsz or phdr.offset > image.len or image.len - phdr.offset < phdr.filesz or
        !phdr.flags.R)
    {
        return error.BadElf;
    }
    const data = image[phdr.offset..][0..phdr.filesz];
    const perm: vm.Perm = .{ .r = phdr.flags.R, .w = phdr.flags.W, .x = phdr.flags.X };

    var offset: usize = 0;
    while (offset < phdr.memsz) : (offset += page.size) {
        const p = vm.allocUserPage(space, phdr.vaddr + offset, perm) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AlreadyMapped => return error.BadElf, // 两个段重叠了
        };
        // 文件里有的部分复制进来，剩下的（.bss）保持分配时清的零
        if (offset < data.len) {
            const n = @min(page.size, data.len - offset);
            @memcpy(p[0..n], data[offset..][0..n]);
        }
    }
}

/// 测试用的“物理内存”，用法见 vm.zig 里的测试。
var test_memory: [256 * page.size]u8 align(page.size) = undefined;

/// 把 image 加载进一个新的地址空间，检查完之后释放，确认没有漏页。
fn testLoad(image: []const u8) !usize {
    const base = @intFromPtr(&test_memory);
    page.init(base, base + test_memory.len, &.{});
    vm.kernel_root = @ptrCast(try page.alloc());
    const before = page.free_pages;
    const space = try vm.createUserSpace();
    defer {
        vm.destroyUserSpace(space);
        std.testing.expectEqual(before, page.free_pages) catch @panic("leaked pages");
    }
    const entry = try load(space, image);
    // 入口可读，栈的两端可读，栈下面的保护页没有映射
    var buf: [2]u8 = undefined;
    try std.testing.expect(entry >= vm.user_base and entry < stack_bottom);
    vm.copyFromUser(space, &buf, entry) catch return error.BadElf;
    vm.copyFromUser(space, &buf, stack_bottom) catch return error.BadElf;
    vm.copyFromUser(space, &buf, stack_top - 2) catch return error.BadElf;
    try std.testing.expectError(error.BadAddress, vm.copyFromUser(space, &buf, stack_bottom - 2));
    return entry;
}

test "加载真正的用户程序 hello" {
    _ = try testLoad(@embedFile("hello"));
}

test "ELF 加载器拒绝坏文件" {
    const good = @embedFile("hello");
    const image = try std.testing.allocator.dupe(u8, good);
    defer std.testing.allocator.free(image);

    try std.testing.expectError(error.BadElf, testLoad(good[0..32])); // 比文件头还短
    image[0] = 0; // 魔数不对
    try std.testing.expectError(error.BadElf, testLoad(image));
    @memcpy(image, good);
    std.mem.writeInt(u16, image[18..20], @backingInt(elf.EM.X86_64), .little); // 不是 RISC-V
    try std.testing.expectError(error.BadElf, testLoad(image));
    @memcpy(image, good);
    std.mem.writeInt(u64, image[32..40], image.len - 8, .little); // 程序头表超出文件
    try std.testing.expectError(error.BadElf, testLoad(image));
    // 数据段 R/W/X 全为 0（用 user/tests/noperm.ld 链接的）
    try std.testing.expectError(error.BadElf, testLoad(@embedFile("t_noperm")));
}

test "调度器轮流挑就绪的进程，睡够了的进程醒来" {
    const expectEqual = std.testing.expectEqual;
    var procs: [4]Process = @splat(.{});
    procs[0].state = .ready;
    procs[1].state = .sleeping;
    procs[1].wake_tick = 10;
    procs[3].state = .ready;

    // 从上次运行的槽位后面开始找，跳过空槽位和还在睡的进程，绕回开头
    try expectEqual(3, pickNext(&procs, 0, 5));
    try expectEqual(0, pickNext(&procs, 3, 5));
    try expectEqual(.sleeping, procs[1].state);
    // 到了 wake_tick，1 号醒来，紧跟在 0 号后面被选中
    try expectEqual(1, pickNext(&procs, 0, 10));
    try expectEqual(.ready, procs[1].state);

    // 只有一个就绪的进程时总是选它（包括刚运行完的那个）；没有就绪的返回 null
    procs[0].state = .unused;
    procs[1].state = .exited;
    try expectEqual(3, pickNext(&procs, 3, 10));
    procs[3].state = .sleeping;
    procs[3].wake_tick = std.math.maxInt(u64);
    try expectEqual(null, pickNext(&procs, 3, 1000));
}
