//! 进程和调度，照 xv6 的结构写：
//!
//! - 调度器 scheduler() 在启动栈上永远循环，依次扫描进程表，遇到 runnable 的进程就切过去，
//!   等它切回来再接着往下扫。它只管调度，别的什么都不做。
//! - 进程（用户进程，以及 shell 这个内核线程）要让出 CPU 时，先改自己的状态，再调用 sched()
//!   切回调度器：yield（时间片用完）、sleep（等某件事）、exit 都是这样。
//! - 等待用 sleep(chan) / wakeup(chan)：chan 是任意一个地址，代表“在等什么”。等时钟的 sleep 系统调用
//!   睡在 &timer.ticks 上，等键盘的 shell 睡在 uart.rx_chan 上，等前台进程结束的 shell 睡在那个进程上。
//! - kill 只做标记、叫醒在睡的进程；被杀的进程回到 U 模式之前自己结束（checkKilled）。
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
    /// 可以运行，等调度器挑到它
    runnable,
    /// 正在 CPU 上运行（current 指向它）
    running,
    /// 在 sleep(chan) 里等某件事，wakeup(chan) 把它改回 runnable
    sleeping,
    /// 已经结束，切回调度器之后马上被回收。别的代码看不到这个状态
    zombie,
};

pub const Process = struct {
    state: State = .unused,
    pid: usize = 0,
    name: []const u8 = "",
    /// 用户进程的根页表。内核线程没有自己的地址空间，为 null，运行时用内核页表
    space: ?*vm.PageTable = null,
    /// 不在运行时，它的内核上下文保存在这里（见 switchContext）
    context: Context = undefined,
    /// sleeping 时等的“通道”，wakeup 用同一个地址叫醒它
    chan: ?*const anyopaque = null,
    /// 被 kill 了的话是原因。进程回到 U 模式之前看到它就自己结束（见 checkKilled）
    killed: ?[]const u8 = null,
    /// 在 U 模式运行期间来过的时钟中断数，大致就是用掉的 CPU 时间（单位 10 ms）
    ticks: u64 = 0,
};

/// 进程表。槽位 i 的进程用 kernel_stacks[i] 作内核栈。
pub var table: [max_procs]Process = @splat(.{});

/// 正在运行的进程。在调度器里时为 null。
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

/// 调度器切到进程时保存的上下文，进程调用 sched() 时切回这里。
var scheduler_context: Context = undefined;

pub const SpawnError = error{ TooManyProcesses, OutOfMemory, BadElf };

fn allocSlot() error{TooManyProcesses}!usize {
    for (&table, 0..) |*p, i| {
        if (p.state == .unused) return i;
    }
    return error.TooManyProcesses;
}

/// 加载一个用户程序，放进进程表，状态为 runnable，返回 pid。由 shell 调用，真正开始运行要等调度器挑到它。
pub fn spawn(program: *const Program) SpawnError!usize {
    const slot = try allocSlot();
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
        // SIE 必须清掉：trapExit 一开始就写回 sstatus，SIE = 1 的话恢复寄存器的途中就可能被中断打断。
        // （现在 shell 是关着中断调用这里的，但不依赖这一点。）
        .sstatus = (riscv.read(.sstatus) & ~(riscv.sstatus_spp | riscv.sstatus_sie)) | riscv.sstatus_spie,
    };
    frame.regs[2] = stack_top;

    // 第一次被调度时，switchContext 恢复这个上下文后 ret 到 forkret，sp 正指向初始 TrapFrame
    table[slot] = .{
        .state = .runnable,
        .pid = next_pid,
        .name = program.name,
        .space = space,
        .context = .{ .ra = @intFromPtr(&forkret), .sp = @intFromPtr(frame), .s = @splat(0) },
    };
    next_pid += 1;
    return table[slot].pid;
}

/// 创建一个内核线程：在 S 模式运行 entry，用这个槽位的内核栈和内核页表，状态为 runnable。
/// 它和用户进程一样由调度器调度，关着中断运行，要等待时调用 sleep 让出 CPU。现在只有 shell 一个。
pub fn spawnKernel(name: []const u8, entry: *const fn () callconv(.c) noreturn) error{TooManyProcesses}!usize {
    const slot = try allocSlot();
    const stack = &kernel_stacks[slot];
    // 第一次被调度时，switchContext 恢复这个上下文后 ret 到 entry，sp 是空的内核栈顶
    table[slot] = .{
        .state = .runnable,
        .pid = next_pid,
        .name = name,
        .context = .{ .ra = @intFromPtr(entry), .sp = @intFromPtr(stack) + stack.len, .s = @splat(0) },
    };
    next_pid += 1;
    return table[slot].pid;
}

/// 新的用户进程第一次被调度时从这里开始（对应 xv6 的 forkret），sp 指向 spawn 构造的初始 TrapFrame。
/// 和陷阱返回一样，进入 U 模式之前先检查是不是已经被杀了，然后经 trapExit 进入 U 模式。
/// checkKilled 是普通函数，只用 sp 以下的栈，不会碰到 TrapFrame。
fn forkret() callconv(.naked) noreturn {
    asm volatile (
        \\call %[checkKilled]
        \\tail %[trapExit]
        :
        : [checkKilled] "X" (&checkKilled),
          [trapExit] "X" (&trap.trapExit),
    );
}

/// 调度器（对应 xv6 的 scheduler()）。kmain 初始化完之后调用，在启动栈上永远循环：
/// 依次扫描进程表，遇到 runnable 的就切过去运行，等它调用 sched() 切回来，再接着往下扫。
/// 所以每个 runnable 的进程每一圈运行一次，自然就是轮转。
pub fn scheduler() noreturn {
    while (true) {
        // 进程和调度器都是关着中断运行的，中断只在这里打开一下：处理挂起的中断（它们可能叫醒进程），
        // 再关上。关着中断扫描、wfi：扫完发现没有可运行的进程、正要 wfi 时来了中断的话，
        // 中断保持挂起，wfi 立刻返回（wfi 只看 sie，不看 sstatus.SIE），不会白睡一觉。
        riscv.enableInterrupts();
        riscv.disableInterrupts();
        var found = false;
        for (&table) |*p| {
            if (p.state != .runnable) continue;
            p.state = .running;
            current = p;
            if (p.space) |space| vm.activate(space);
            switchContext(&scheduler_context, &p.context);
            // 进程让出了 CPU。先切回内核页表，回收进程时才能释放它的页表
            if (p.space != null) vm.activate(vm.kernel_root);
            current = null;
            if (p.state == .zombie) release(p);
            found = true;
        }
        if (!found) riscv.wfi();
    }
}

/// 当前进程切回调度器（对应 xv6 的 sched()）。调用前要先把自己的状态改掉（不再是 running）。
/// 等调度器下次挑中这个进程时，switchContext 才返回，从这里接着往下执行。
fn sched() void {
    const p = current.?;
    std.debug.assert(p.state != .running);
    std.debug.assert(riscv.read(.sstatus) & riscv.sstatus_sie == 0);
    switchContext(&p.context, &scheduler_context);
}

/// 当前进程让出 CPU，别的 runnable 进程先运行，轮到它时返回。由陷阱处理程序调用（关着中断）。
pub fn yield() void {
    current.?.state = .runnable;
    sched();
}

/// 当前进程睡在 chan 上，直到别人调用 wakeup(chan)。
///
/// 醒来不代表等的条件已经满足（同一个 chan 上可能有好几个进程在等不同的东西，也可能被 kill 叫醒），
/// 所以调用方要在循环里检查条件：`while (!条件) sleep(chan);`。
/// xv6 要传一把锁进来防止“检查完条件、还没睡下时 wakeup 已经发生”（lost wakeup）。这里只有一个 hart，
/// 进程和调度器都关着中断运行，检查条件到睡下之间不会有中断处理程序插进来，所以不需要锁。
pub fn sleep(chan: *const anyopaque) void {
    const p = current.?;
    p.chan = chan;
    p.state = .sleeping;
    sched();
    p.chan = null;
}

/// 叫醒所有睡在 chan 上的进程。只改状态，不切换，中断处理程序里也能调用。
pub fn wakeup(chan: *const anyopaque) void {
    for (&table) |*p| {
        if (p.state == .sleeping and p.chan == chan) p.state = .runnable;
    }
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

/// 当前进程被 kill 过的话就结束它，否则返回。陷阱处理程序回到 U 模式之前、新进程第一次进入 U 模式之前调用，
/// 所以被杀的进程不会再执行一条用户指令。
pub fn checkKilled() callconv(.c) void {
    const p = current.?;
    if (p.killed) |reason| killCurrent("{s}", .{reason});
}

/// 变成 zombie，叫醒等它结束的（shell），切回调度器，由调度器回收。
/// 进程正在用自己的内核栈和地址空间，不能自己释放。
fn finish(p: *Process) noreturn {
    p.state = .zombie;
    wakeup(p);
    sched();
    unreachable; // 调度器不会再切回已经结束的进程
}

pub const KillError = error{ NoSuchProcess, KernelThread };

/// 杀掉进程 pid（对应 xv6 的 kill()）：只记下原因，在睡的叫醒，不当场结束它——
/// 它可能停在内核栈上的任何地方（sleep 里、yield 里），只有它自己知道怎么安全地收尾。
/// 它下一次被调度、回到 U 模式之前会在 checkKilled 里结束。只改标志和状态，中断处理程序里也能调用（Ctrl-C）。
/// 内核线程从不检查 killed，所以不能杀。
pub fn kill(pid: usize, reason: []const u8) KillError!void {
    const p = findPid(pid) orelse return error.NoSuchProcess;
    if (p.space == null) return error.KernelThread;
    if (p.killed == null) p.killed = reason;
    if (p.state == .sleeping) p.state = .runnable;
}

pub fn findPid(pid: usize) ?*Process {
    for (&table) |*p| {
        if (p.state != .unused and p.pid == pid) return p;
    }
    return null;
}

/// 释放进程的地址空间（所有用户页和页表），腾出槽位。内核栈是静态的，留给下一个用这个槽位的进程。
fn release(p: *Process) void {
    if (p.space) |space| vm.destroyUserSpace(space);
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

test "wakeup 只叫醒睡在同一个通道上的进程；kill 只做标记，叫醒在睡的进程" {
    const expectEqual = std.testing.expectEqual;
    defer table = @splat(.{});
    var space: vm.PageTable = undefined; // 只用来区分用户进程和内核线程，不会被访问
    var a: u8 = 0;
    var b: u8 = 0;
    table[0] = .{ .state = .sleeping, .pid = 1, .chan = &a }; // 内核线程
    table[1] = .{ .state = .sleeping, .pid = 2, .chan = &a, .space = &space };
    table[2] = .{ .state = .sleeping, .pid = 3, .chan = &b, .space = &space };
    table[3] = .{ .state = .runnable, .pid = 4, .space = &space };

    wakeup(&a);
    try expectEqual(.runnable, table[0].state);
    try expectEqual(.runnable, table[1].state);
    try expectEqual(.sleeping, table[2].state);

    // kill 叫醒在睡的进程，只记第一次的原因；runnable 的进程状态不变，等它自己结束
    try kill(3, "first");
    try kill(3, "second");
    try expectEqual(.runnable, table[2].state);
    try std.testing.expectEqualStrings("first", table[2].killed.?);
    try kill(4, "x");
    try expectEqual(.runnable, table[3].state);
    try std.testing.expectError(error.KernelThread, kill(1, "x"));
    try expectEqual(null, table[0].killed);
    try std.testing.expectError(error.NoSuchProcess, kill(99, "x"));
}
