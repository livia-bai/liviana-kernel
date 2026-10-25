//! 用户进程。一次只运行一个：shell 的 run 命令调用 run()，它把程序装进一个新的地址空间，
//! 切到 U 模式执行，直到程序调用 exit、出了异常或者被 Ctrl-C 打断，再回到 shell。
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

pub const Process = struct {
    pid: usize,
    name: []const u8,
    space: *vm.PageTable,
};

/// 正在运行的进程，没有时为 null。
pub var current: ?Process = null;
var next_pid: usize = 1;

/// 进程陷入内核时用的栈。一次只有一个进程，一块静态的栈就够了。
/// 实测最深的路径（Debug 模式下杀进程时格式化输出）用了不到 4 KiB。
var kernel_stack: [16 * 1024]u8 align(16) = undefined;

/// 进入 U 模式前保存的内核上下文。按 C 调用约定，跨函数调用需要保持不变的只有
/// ra、sp 和 s0..s11，其他寄存器调用方本来就不指望它们保持原值。
const Context = extern struct {
    ra: usize,
    sp: usize,
    s: [12]usize,
};

/// 进程结束时从这里恢复，回到 run() 里。
var shell_context: Context = undefined;

/// 加载并运行一个用户程序，等它结束后返回。
pub fn run(program: *const Program) void {
    const space = vm.createUserSpace() catch {
        uart.write("run: out of memory\n");
        return;
    };
    defer vm.destroyUserSpace(space);
    const entry = load(space, program.image) catch |err| {
        uart.print("run: cannot load {s}: {s}\n", .{ program.name, @errorName(err) });
        return;
    };

    current = .{ .pid = next_pid, .name = program.name, .space = space };
    next_pid += 1;
    defer current = null;

    // 进入 U 模式的初始状态：除了 sp 以外寄存器全为 0，从 ELF 的入口地址开始执行。
    // trapExit 要求 TrapFrame 正好在内核栈顶下面（见 trap.trapExit）。
    const frame: *trap.TrapFrame = @ptrCast(@alignCast(kernel_stack[kernel_stack.len - @sizeOf(trap.TrapFrame) ..]));
    frame.* = .{ .regs = @splat(0), .sepc = entry, .sstatus = undefined };
    frame.regs[2] = stack_top;

    // 切换期间不能被中断打断：中断处理程序会看到一半新一半旧的 sscratch 和 sstatus
    const interrupts_were_on = riscv.read(.sstatus) & riscv.sstatus_sie != 0;
    riscv.disableInterrupts();
    // SPP = 0：sret 回到 U 模式；SPIE = 1：回到 U 模式后打开中断，时钟和键盘照常工作
    frame.sstatus = (riscv.read(.sstatus) & ~riscv.sstatus_spp) | riscv.sstatus_spie;
    _ = uart.takeCtrlC(); // 忽略运行之前按下的 Ctrl-C

    vm.activate(space);
    switchToUser(frame); // 进程结束后才从这里返回
    vm.activate(vm.kernel_root);

    if (interrupts_were_on) riscv.enableInterrupts();
}

/// 当前进程调用了 exit。由系统调用处理程序调用，不返回。
pub fn exit(code: u8) noreturn {
    const p = current.?;
    uart.print("[proc] pid {d} ({s}) exited with code {d}\n", .{ p.pid, p.name, code });
    switchBack(&shell_context);
}

/// 强行结束当前进程。由陷阱处理程序调用，不返回。
pub fn kill(comptime reason: []const u8, args: anytype) noreturn {
    const p = current.?;
    uart.print("[proc] pid {d} ({s}) killed: " ++ reason ++ "\n", .{ p.pid, p.name } ++ args);
    switchBack(&shell_context);
}

/// 保存当前的内核上下文到 shell_context，然后用 frame 进入 U 模式。进程结束时
/// switchBack 恢复这里保存的上下文，于是看起来就像这个函数刚刚返回。
///
/// 实际的切换在裸函数 switchToUserNaked 里。Zig 不允许直接调用裸函数，这里在内联汇编里
/// call 它：对编译器来说这只是一段会破坏若干寄存器的汇编，它不会对裸函数做任何假设。
/// （如果转成函数指针来调，签名就必须写对：这个调用是会返回的，声明成 noreturn 的话，
/// 编译器会把调用之后的代码全部删掉，release 模式下就出过这个问题。）
/// 按 C 调用约定，调用者保存的寄存器在调用前后可能变化，所以都声明为被破坏；
/// ra、sp、s0..s11 由 switchToUserNaked 保存、switchBack 恢复，保持不变。
fn switchToUser(frame: *trap.TrapFrame) void {
    asm volatile (
        \\mv a0, %[frame]
        \\mv a1, %[ctx]
        \\call %[switchToUserNaked]
        :
        : [frame] "r" (frame),
          [ctx] "r" (&shell_context),
          [switchToUserNaked] "X" (&switchToUserNaked),
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

/// a0 = frame，a1 = ctx。最后跳进 trapExit，自己的函数体不会走到结尾，所以是 noreturn；
/// 只从 switchToUser 的内联汇编里调用。
fn switchToUserNaked() callconv(.naked) noreturn {
    asm volatile (contextAsm("sd", "a1") ++
            \\mv sp, a0
            \\tail %[trapExit]
        :
        : [trapExit] "X" (&trap.trapExit),
    );
}

/// 恢复 switchToUser 保存的内核上下文，从 switchToUser 里的 call 之后继续执行。
/// 进程陷入内核以来用过的那段内核栈直接丢弃。
fn switchBack(ctx: *const Context) noreturn {
    asm volatile (contextAsm("ld", "a0") ++ "ret\n"
        :
        : [ctx] "{a0}" (ctx),
    );
    unreachable;
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
