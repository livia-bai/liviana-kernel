# 进程：创建、调度和结束

涉及文件：`src/proc.zig`（以及 `src/trap.zig` 的 `trapExit`、`src/vm.zig` 的用户地址空间函数；调用方：`src/main.zig`、`src/trap.zig`、`src/syscall.zig`）

进程表里最多同时有 8 个进程，按时间片轮转（round-robin）抢占式调度。进程的创建、调度和结束都照搬 [xv6](https://github.com/mit-pdos/xv6-riscv)（`kernel/proc.c`）的结构：

- **第一个进程 init 由内核创建**（`userinit`），pid 1。之后的进程都是 `fork` 出来的：init 用 `fork` + `exec` 启动 shell，shell 再用同样的办法运行程序（[user-programs.md](user-programs.md#init-和-sh)）。
- **调度器 `proc.scheduler()` 只管调度**。`kmain` 初始化完之后调用它，它在启动栈上永远循环：依次扫描进程表，遇到 `runnable` 的进程就切过去，等它切回来再接着往下扫。
- **进程自己让出 CPU**：先改自己的状态，再调用 `sched()` 切回调度器。时间片用完（`yield`）、等某件事（`sleep`）、结束（`exit`）都是这样。进程之间从不直接切换。
- **等待用 `sleep(chan)` / `wakeup(chan)`**：`chan` 是任意一个地址，代表“在等什么”。
- **结束的进程变成 zombie，由父进程 `wait` 回收**。父进程先结束的，子进程交给 init。
- **`kill` 只做标记**，被杀的进程回到 U 模式之前自己结束。

## 程序表

```zig
pub const Program = struct {
    name: []const u8,
    image: []const u8,   // ELF 文件的全部字节
};

pub const programs = blk: {
    var list: [build_options.user_programs.len]Program = undefined;
    for (&list, build_options.user_programs) |*p, name| p.* = .{ .name = name, .image = @embedFile(name) };
    const final = list;
    break :blk final;
};

pub fn find(name: []const u8) ?*const Program
```

- 在编译期遍历 `build_options.user_programs`（程序名列表），对每个名字 `@embedFile(name)`，得到构建系统作为匿名模块交进来的 ELF（[build.md](build.md#用户程序)）。ELF 的字节放在内核的 `.rodata` 里，只读。
- `const final = list;` 是 Zig 编译期代码的固定写法：`list` 是编译期的 `var`，不能直接从块里“泄漏”出去，要先复制成 `const`。
- `find` 按名字线性查找，`userinit` 和 `exec` 用它。用户程序通过 `listprog` 系统调用按下标读出程序名（shell 的 `run` 不带参数时列出它们）。

## 进程表

```zig
pub const max_procs = abi.max_procs;   // 8，shell 也要知道，所以放在 abi.zig
pub const State = abi.ProcState;       // procinfo 原样交给用户程序

pub const ProcState = enum(u8) { unused, runnable, running, sleeping, zombie };   // abi.zig

pub const Process = struct {
    state: State = .unused,
    pid: usize = 0,
    name: []const u8 = "",             // 程序名，exec 时换掉；fork 出来的子进程沿用父进程的
    space: *vm.PageTable = undefined,  // 根页表
    parent: ?*Process = null,          // 父进程；init 没有
    context: Context = undefined,      // 不在运行时保存的内核上下文
    chan: ?*const anyopaque = null,    // sleeping 时等的通道
    killed: ?[]const u8 = null,        // 被 kill 了的话是原因
    xstatus: u32 = 0,                  // zombie 的结束状态，父进程 wait 时取走
    ticks: u64 = 0,                    // 在 U 模式运行期间来过的时钟中断数
};

pub var table: [max_procs]Process = @splat(.{});
pub var current: ?*Process = null;     // 正在运行的进程；在调度器里时为 null
var next_pid: usize = 1;               // 每次创建进程加 1，从不复用
var init_proc: ?*Process = null;       // 孤儿交给它
pub var foreground: usize = 0;         // 前台进程的 pid（setfg），按 Ctrl-C 时杀掉它

var kernel_stacks: [max_procs][16 * 1024]u8 align(16) = undefined;  // 槽位 i 的进程用第 i 块
var scheduler_context: Context = undefined;  // 调度器切到进程时保存的上下文
```

状态名和 xv6 一样（xv6 还有一个 `USED`，表示“槽位已占、还在初始化”，这里创建进程是一口气做完的，用不着）。状态的变化：

| 从 | 到 | 什么时候 | 谁做的 |
| --- | --- | --- | --- |
| `unused` | `runnable` | 启动时创建 init；`fork` 系统调用 | `userinit`、`fork` |
| `runnable` | `running` | 调度器扫到它 | `scheduler` |
| `running` | `runnable` | 时钟中断打断了 U 模式（时间片用完），或者 `yield` 系统调用 | `yield` |
| `running` | `sleeping` | 等某件事：`sleep` 系统调用等时钟，`read` 等键盘，`wait` 等子进程结束 | `sleep` |
| `sleeping` | `runnable` | 等的事发生了（时钟中断、串口中断、子进程结束），或者被 kill | `wakeup`、`kill` |
| `running` | `zombie` | `exit` 系统调用，或者 U 模式下出了异常，或者发现自己被 kill 了 | `exit`、`killCurrent`（经 `finish`） |
| `zombie` | `unused` | 父进程 `wait` 到它 | `reap` |

- **每个进程一块 16 KiB 的内核栈**，静态分配在 `.bss` 里（8 块共 128 KiB）。不从页分配器要：它一次只给一页，给不出连续的 16 KiB。实测 Debug 模式下跑完全部 QEMU 测试，最深用了 6463 字节，small 模式下 1127 字节。测法：`.bss` 启动时清零，`shutdown` 时从每块栈的底部找第一个不为 0 的字节，取最大值（临时加的代码，没有留在仓库里）。内核栈两侧没有保护页：内核内存是用大页恒等映射的，要在中间挖出不映射的页得拆大页，现在没做。
- init 和 shell 一直占着两个槽位，所以同时最多运行 6 个别的程序。
- `current` 只在 `scheduler` 切到进程前设置、切回来后清回 `null`。系统调用和陷阱处理程序用 `current.?` 取当前进程，Debug/safe 模式下没有进程时会 panic。
- **不需要锁**：只有一个 hart，进程在内核里和调度器都关着中断运行，中断只在 U 模式和调度器开头那一下才会进来。中断处理程序对进程表只做 `wakeup`、`kill`（只改状态和标志）和给 `current.ticks` 加 1。xv6 每个进程一把锁，是因为它有多个 CPU，而且内核里也开着中断。

## 用户地址空间

所有用户映射都在根页表第 1 项覆盖的 `vm.user_base..vm.user_end`（`0x4000_0000..0x8000_0000`）里，原因见 [paging.md](paging.md#用户地址空间)。

| 用户地址 | 内容 | 权限 |
| --- | --- | --- |
| `0x4000_0000` 起 | ELF 的各个 PT_LOAD 段（代码 / 只读数据 / 数据和 `.bss`） | 按程序头：`R-X` / `R--` / `RW-`，都带 U |
| …… | 不映射 | |
| `0x7fff_b000..0x7fff_c000` | 保护页，不映射 | 栈溢出时触发缺页异常，而不是悄悄踩坏别的数据 |
| `0x7fff_c000..0x8000_0000` | 用户栈，16 KiB（4 页） | `RW-`，带 U |

运行 `hello`（Debug 模式）时在 `syscall.dispatch` 处停下，用 GDB 的 `monitor info mem` 看到的完整映射：

```
vaddr            paddr            size             attr
000000000c000000 000000000c000000 0000000000600000 rw--gad    ┐ 内核映射（共用），没有 u
0000000010000000 0000000010000000 0000000000001000 rw--gad    ┘
0000000040000000 00000000802cb000 0000000000001000 r-xu-ad    ┐
0000000040001000 00000000802ce000 0000000000012000 r-xu-ad    │ 代码段（物理页不连续：中间穿插着页表页）
0000000040013000 00000000802e0000 0000000000004000 r--u-ad    │ 只读数据段
0000000040017000 00000000802e4000 0000000000001000 rw-u-ad    │ 数据段
000000007fffc000 00000000802e5000 0000000000001000 rw-u-ad    │ 用户栈
000000007fffd000 00000000802e7000 0000000000003000 rw-u-ad    ┘
0000000080200000 0000000080200000 000000000004c000 r-x-gad    ┐
000000008024c000 000000008024c000 0000000000063000 r---gad    │ 内核映射（共用），没有 u
00000000802af000 00000000802af000 0000000000151000 rw--gad    │
0000000080400000 0000000080400000 0000000007c00000 rw--gad    ┘
```

`0x7fffb000` 那一页没有出现，就是保护页。用户映射没有 `g`（全局）位，内核映射都有。

## ELF 加载器

```zig
fn load(space: *vm.PageTable, image: []const u8) LoadError!usize   // 返回入口地址
fn loadSegment(space: *vm.PageTable, image: []const u8, phdr: elf.Elf64.Phdr) LoadError!void
const LoadError = error{ BadElf, OutOfMemory };
```

ELF 是构建时嵌进来的，按理是可信的；但加载器按“输入可能是坏的”来写，每个字段都检查，坏的 ELF 只会得到 `BadElf`，不会让内核读写到不该碰的地方。头部结构用 `std.elf.Elf64.Ehdr` / `Elf64.Phdr`（0.17 里字段是带类型的枚举和 packed struct，旧的 `Elf64_Ehdr` 已弃用），用 `std.mem.bytesToValue` 从字节复制出来，所以不要求 `image` 对齐。

**ELF 头的检查**（任何一条不满足都是 `BadElf`）：

| 检查 | 原因 |
| --- | --- |
| 长度至少是一个 ELF 头 | 防止越界读 |
| 魔数 `\x7fELF`、64 位、小端 | 必须是 RV64 的 ELF |
| `e_type == EXEC` | 只支持静态链接的可执行文件，不处理重定位 |
| `e_machine == RISCV` | |
| `e_phentsize == sizeof(Elf64_Phdr)` | 程序头大小对得上才能按数组读 |
| 每个程序头的 `[e_phoff + i * 56, +56)` 在文件内（加法检查溢出） | 防止越界读 |

只处理 `PT_LOAD` 且 `p_memsz > 0` 的程序头，其他类型跳过。现在的用户 ELF 有 3 个 `PT_LOAD` 和 1 个链接器自动加的 `PT_RISCV_ATTRIBUTES`（`llvm-readelf -l` 显示为 `ATTRIBUTES`）。

**每个段的检查**（`loadSegment`）：

| 检查 | 原因 |
| --- | --- |
| `p_vaddr` 按页对齐 | 每一页只属于一个段，才能按段设置权限（`user/linker.ld` 保证这一点） |
| `p_vaddr >= user_base`，`p_vaddr + p_memsz` 不溢出且 `<= 栈底 - 4096` | 整段在用户区内，并且在保护页之下，不会和栈重叠 |
| `p_filesz <= p_memsz` | 文件里的内容不能比内存里的段还长 |
| `[p_offset, p_offset + p_filesz)` 在文件内 | 防止越界读 |
| 段必须可读（`p_flags.R`） | R/W/X 全为 0 的页表项会被 CPU 当成指向下一级页表的指针；W 无 R 是保留组合。见下面的说明 |
| 和已经映射的页重叠 → `BadElf` | `allocUserPage` 返回 `AlreadyMapped` 时转换过来 |

然后逐页 `vm.allocUserPage(space, p_vaddr + offset, {R, W, X})`：分配一页清零的物理内存、映射上，把文件里对应的内容复制进去；`p_filesz` 之后的部分（`.bss`）保持清零。

**为什么一定要拒绝不可读的段**：如果一个段的 R/W/X 全为 0，`map` 写出的页表项只有 V = 1，硬件会把它当成“指向下一级页表”的项，而它指向的是一页用户数据。只要用户程序（或者构造 ELF 的人）往那一页里写入精心构造的页表项，就能把任意物理内存映射进自己的地址空间。这个漏洞是写完加载器后复查代码时发现的，现在加载器拒绝这样的段，`vm.map` 也断言了叶子权限合法。回归测试 `t_noperm`（[testing.md](testing.md#回归测试程序)）一直在检查这一点：故意去掉这条检查时，Debug 模式下 `vm.map` 的断言让内核 panic，small 模式下断言被编译掉，那一页真的被当成了页表。

所有段加载完后，映射用户栈：`[栈底, 0x8000_0000)` 的 4 页，`RW-`。前面已经保证段都在保护页之下，所以这里不会 `AlreadyMapped`（写成 `unreachable`）。

## 创建进程

```zig
pub const SpawnError = error{ TooManyProcesses, OutOfMemory, BadElf };
pub fn userinit() SpawnError!void                          // kmain 调用，创建 init

pub const ForkError = error{ TooManyProcesses, OutOfMemory };
pub fn fork() ForkError!usize                              // fork 系统调用，返回子进程的 pid

pub const ExecError = error{ NoSuchProgram, OutOfMemory, BadElf };
pub fn exec(name: []const u8) ExecError!void               // exec 系统调用
```

三个函数都要准备一个“下次被调度时从哪里开始”的状态。用户进程第一次被调度时的路径都一样：

```
scheduler → switchContext ─ret→ forkret → checkKilled → trapExit ─sret→ U 模式
```

- **初始的内核上下文**（`firstContext`）：`ra` = `forkret`，`sp` = 这个槽位的 `TrapFrame` 的地址，`s0..s11` = 0。`switchContext` 恢复它之后 `ret` 就跳进 `forkret`。
- **`TrapFrame` 总在内核栈的最顶端**（`frameOf(p)`）：必须放在栈顶下方正好 `@sizeOf(TrapFrame)` 处，`trapExit` 回到 U 模式时会把“TrapFrame 地址 + 272”当作内核栈顶写进 `sscratch`（[trap.md](trap.md#trapexit)）；之后从 U 模式陷入时，`trapEntry` 也正好把 `TrapFrame` 压在这里。
- **`forkret`**（名字来自 xv6）是一个裸函数：

  ```zig
  fn forkret() callconv(.naked) noreturn {
      asm volatile (
          \\call %[checkKilled]
          \\tail %[trapExit]
          ...
      );
  }
  ```

  先调用 `checkKilled`（还没运行就被 kill 了的话，在这里结束，见[结束进程](#结束进程)），再跳进 `trapExit`。`sp` 一直指向 `TrapFrame`（`checkKilled` 是普通函数，只用 `sp` 以下的栈），于是 `trapExit` 按它恢复寄存器、`sret` 进入 U 模式。

### userinit

和 xv6 的 `userinit` 一样，只在启动时调用一次：找一个空槽位；`vm.createUserSpace()` 新建地址空间（复制内核的根页表），`load` 加载嵌在内核里的 `init` 程序（[ELF 加载器](#elf-加载器)）；用 `startFrame(frame, entry)` 构造从入口开始运行的 `TrapFrame`；状态设为 `runnable`，pid 是 1，记进 `init_proc`。没有 `init` 程序是构建配置错了，直接 `@panic`；其他错误 `kmain` 会 panic。

`startFrame` 构造的 `TrapFrame`：所有寄存器为 0，`sepc` = 入口地址，`regs[2]`（`sp`）= `0x8000_0000`，`sstatus = (当前 sstatus & ~(SPP | SIE)) | SPIE`：

- `SPP = 0` 让 `sret` 回到 U 模式；`SPIE = 1` 让 U 模式下中断是开着的（时钟和键盘照常工作，抢占和 Ctrl-C 都靠它）。
- **`SIE` 必须清掉**：`trapExit` 第一步就把 `frame.sstatus` 写回 `sstatus`，`SIE = 1` 的话恢复寄存器的途中就可能被中断打断，而那时 `sscratch` 已经指向进程的内核栈，栈和寄存器都是一半新一半旧的状态。内核代码都是关着中断运行的，读到的 `SIE` 本来就是 0，但不依赖这一点（更早的版本里 shell 在内核里开着中断调用过这里，踩过这个坑）。
- 其他位保持内核当前的值，其中 `SUM = 0`、`FS = Off`（`kmain` 启动时清的，见 [riscv-sbi.md](riscv-sbi.md#位定义)），所以 U 模式同样不能用浮点。

### fork

```zig
pub fn fork() ForkError!usize {
    const parent = current.?;
    const child = try allocSlot();
    const space = try vm.cloneUserSpace(parent.space);
    const frame = frameOf(child);
    frame.* = frameOf(parent).*;
    frame.regs[10] = 0;
    child.* = .{ .state = .runnable, .pid = next_pid, .name = parent.name, .space = space,
                 .parent = parent, .context = firstContext(child) };
    next_pid += 1;
    return child.pid;
}
```

- **地址空间逐页复制**（`vm.cloneUserSpace`，[paging.md](paging.md#复制用户地址空间)）：子进程的每一页都是新分配的，内容和权限和父进程一样，之后各改各的。没有写时复制（copy-on-write）。
- **`TrapFrame` 原样复制**，只把 `a0` 改成 0。`fork` 是在系统调用里调用的，这时 `handleTrap` 已经把父进程 `TrapFrame` 的 `sepc` 加过 4 了，所以子进程第一次被调度时，经 `forkret` → `trapExit` 回到 U 模式，正好从 `ecall` 的下一条指令继续，看到 `fork` 返回了 0。父进程照常从系统调用返回，`a0` 是子进程的 pid。
- 进程表满了是 `TooManyProcesses`，`fork` 系统调用返回 `-EAGAIN`；内存不够是 `OutOfMemory`（`-ENOMEM`），`cloneUserSpace` 自己释放已经复制的部分。

### exec

```zig
pub fn exec(name: []const u8) ExecError!void {
    const p = current.?;
    const program = find(name) orelse return error.NoSuchProgram;
    const space = try vm.createUserSpace();
    errdefer vm.destroyUserSpace(space);
    const entry = try load(space, program.image);
    const old = p.space;
    p.space = space;
    vm.activate(space);
    vm.destroyUserSpace(old);
    p.name = program.name;
    startFrame(frameOf(p), entry);
}
```

- 先把新程序完整加载进**新的**地址空间，全部成功之后才换掉旧的。失败时旧的地址空间和 `TrapFrame` 都没动，系统调用返回错误，原来的程序接着运行（xv6 也是这样）。
- **释放旧的页表之前必须先切走**：这时 `satp` 还指着旧的根页表。
- 改写 `TrapFrame`：从新程序的入口开始，寄存器全为 0。系统调用返回值写进 `a0` 的是 0，所以新程序看到的寄存器除了 `sp` 都是 0，和 init 第一次运行时一样。
- pid、父进程、`ticks`、`killed` 都不变；名字换成新程序的。

## 调度

```zig
pub fn scheduler() noreturn            // kmain 最后调用，不返回
fn sched() void                        // 当前进程切回调度器
pub fn yield() void
pub fn sleep(chan: *const anyopaque) void
pub fn wakeup(chan: *const anyopaque) void
```

### 调度器

```zig
pub fn scheduler() noreturn {
    while (true) {
        riscv.enableInterrupts();
        riscv.disableInterrupts();
        var found = false;
        for (&table) |*p| {
            if (p.state != .runnable) continue;
            p.state = .running;
            current = p;
            vm.activate(p.space);
            switchContext(&scheduler_context, &p.context);
            vm.activate(vm.kernel_root);
            current = null;
            found = true;
        }
        if (!found) riscv.wfi();
    }
}
```

和 xv6 的 `scheduler()` 一句一句对得上：

1. **开一下中断再关上**。进程和调度器都是关着中断运行的，中断只在这里（以及 U 模式）才会被处理。挂起的中断（时钟、键盘）在这一刻进来，中断处理程序可能 `wakeup` 某个进程。
2. **扫一遍进程表**，每个 `runnable` 的进程：状态设为 `running`，`current` 指向它，切到它的地址空间，`switchContext(&scheduler_context, &p.context)` 切过去。进程要么第一次运行（`forkret`），要么从它上次调用 `sched()` 的地方继续。
3. 进程调用 `sched()` 之后，执行回到这里：切回内核页表，`current = null`，接着扫下一个槽位。切回内核页表是因为这个进程可能已经结束了，父进程回收它时要释放它的页表，那时不能还有人在用。
4. **一整圈都没有可运行的进程就 `wfi`**，等下一个中断。

**轮转**：每扫一圈，每个 `runnable` 的进程运行一次，所以就绪的进程轮流运行，不需要记“上次运行的是谁”。

**先关中断再扫描、再 `wfi`，顺序不能改**，原因是一个经典的竞争：如果开着中断扫描，可能出现“扫描时没有可运行的进程 → 正要执行 `wfi` 时键盘中断来了，叫醒了 shell → `wfi` 睡下去”，shell 要等到下一个中断（最长 10 ms 后的时钟中断）才能运行。关着中断扫描就没有这个问题：中断只是挂起（`sip` 里的位置 1）而不会被处理；`wfi` 只看 `sie` 和 `sip`、不看 `sstatus.SIE`，有挂起的中断就立即返回；下一轮开头开中断，挂起的中断马上被处理。xv6 的注释里讲的也是这件事。

### sched、yield

```zig
fn sched() void {
    const p = current.?;
    std.debug.assert(p.state != .running);
    std.debug.assert(riscv.read(.sstatus) & riscv.sstatus_sie == 0);
    switchContext(&p.context, &scheduler_context);
}

pub fn yield() void {
    current.?.state = .runnable;
    sched();
}
```

`sched` 是进程切回调度器的唯一入口，切换前检查两件事：状态已经改掉了（不再是 `running`，否则调度器会以为它还在跑），中断是关着的。xv6 的 `sched` 还检查持有的锁，这里没有锁。等调度器下次挑中这个进程时，`switchContext` 才返回，执行从 `sched` 之后继续。

`yield` 由陷阱处理程序调用：时钟中断打断 U 模式时（时间片用完，[trap.md](trap.md#分发)），以及 `yield` 系统调用。只有时钟中断让出 CPU，串口中断不让（和 xv6 一样）：串口中断只是叫醒在 `read` 里等输入的进程（通常是 shell），它最多等当前进程用完这个时间片（10 ms）。

**时间片**：时钟中断是全局的每 10 ms 一次，不是按进程计时的，所以一个进程刚被调度就碰上时钟中断时，它的时间片会不足 10 ms。`ticks` 只在时钟中断打断这个进程时加 1，是它用掉的 CPU 时间的近似值（单位 10 ms），`ps` 显示它。两个死循环的进程一起跑时，`ticks` 的增速几乎相同。

### sleep、wakeup

```zig
pub fn sleep(chan: *const anyopaque) void {
    const p = current.?;
    p.chan = chan;
    p.state = .sleeping;
    sched();
    p.chan = null;
}

pub fn wakeup(chan: *const anyopaque) void {
    for (&table) |*p| {
        if (p.state == .sleeping and p.chan == chan) p.state = .runnable;
    }
}
```

`chan` 只是一个地址，用来配对 `sleep` 和 `wakeup`，内核不会去读它指向的内容。现在用到的通道：

| 谁在等 | 等什么 | 通道 | 谁叫醒 |
| --- | --- | --- | --- |
| `sleep` 系统调用 | 时钟走够 | `&timer.ticks` | 每个时钟中断（`trap.handleTrap`） |
| `read` 系统调用 | 键盘输入 | `uart.rx_chan`（`&rx_buf`） | 串口中断（`trap.handleExternal`） |
| `wait` 系统调用 | 子进程结束 | 自己的 `*Process` | 子进程结束时（`finish` 叫醒父进程）；孤儿交给 init 时（`reparent` 叫醒 init） |

规矩是**醒来之后自己检查条件，不满足就再睡**：`while (!条件) sleep(chan);`。醒来不代表条件满足：时钟通道每个 tick 都叫醒所有在等的进程，各自数够了没有；两个进程同时 `read`，一个字符只能给其中一个；被 `kill` 也会醒。`wakeup` 只改状态、不切换，所以中断处理程序里也能调用。

**不需要 xv6 那把锁**。xv6 的 `sleep(chan, lk)` 要带一把锁，防止“检查完条件、还没睡下时 `wakeup` 已经发生”（lost wakeup：等的人永远睡下去）。这里进程关着中断运行，从检查条件到 `sleep` 里状态变成 `sleeping`，中间不会有中断处理程序插进来；`wakeup` 只可能在它真正睡下之后才执行。

`sleep` 系统调用（`syscall.zig`）就是 xv6 的 `sys_sleep`：

```zig
const n = (ms *| timer.tick_hz +| 999) / 1000;
const start = timer.ticks;
while (timer.ticks - start < n and proc.current.?.killed == null) proc.sleep(&timer.ticks);
```

要睡的 tick 数 `⌈ms × 100 / 1000⌉`，乘法和加法都是饱和运算，`ms` 再大也不会溢出（最多睡到永远，只能被 `kill`）。用户程序看到的 `uptime()` 也是按 tick 算的，所以醒来后 `uptime()` 至少增加了 `ms`；按真实时间算，可能比 `ms` 少不到一个 tick（睡下去时当前 tick 已经过了一部分）。`ms = 0` 时不睡，直接返回。被 kill 了就提前返回，回到陷阱处理程序后结束。

## 切换上下文

### 保存的上下文

```zig
const Context = extern struct {
    ra: usize,
    sp: usize,
    s: [12]usize,   // s0..s11
};
```

按 RISC-V 的 C 调用约定，函数调用前后需要保持不变的只有 `sp` 和 `s0..s11`（被调用者保存），再加上返回地址 `ra`。其他寄存器（`t0..t6`、`a0..a7`）调用方本来就不指望它们保持原值。所以“暂停”一段内核代码只需要保存这 14 个寄存器，就像协程切换一样。保存/恢复它们的指令由 `contextAsm(op, base)` 在编译期生成，并在编译期断言寄存器个数和 `Context` 的大小一致。

### switchContext

```zig
fn switchContext(from: *Context, to: *const Context) void {
    asm volatile (
        \\mv a0, %[from]
        \\mv a1, %[to]
        \\call %[switchNaked]
        :
        : [from] "r" (from),
          [to] "r" (to),
          [switchNaked] "X" (&switchNaked),
        : .{ .ra = true, .t0 = true, ..., .t6 = true, .a0 = true, ..., .a7 = true, .memory = true });
}

fn switchNaked() callconv(.naked) noreturn {
    asm volatile (contextAsm("sd", "a0") ++   // 把 ra、sp、s0..s11 存进 from
        contextAsm("ld", "a1") ++             // 从 to 恢复 ra、sp、s0..s11
        "ret\n");                             // 跳到恢复出来的 ra
}
```

- `call` 把返回地址（`call` 的下一条指令）放进 `ra`，`switchNaked` 把它存进 `from`；恢复 `to` 之后 `ret` 跳到的是**另一次** `switchContext` 调用里 `call` 的下一条指令，`sp` 也换成了那边的栈。对那边来说，它的 `switchContext` 刚刚返回。
- 新进程的 `context` 是 `firstContext` 构造的：`ra` = `forkret`，`sp` = 它的 `TrapFrame`，所以 `ret` 跳进 `forkret`，最后 `sret` 进入 U 模式。
- 只用在两处：调度器切到进程（`scheduler`），进程切回调度器（`sched`）。进程之间从不直接切换，总是经过调度器。
- 真正的切换在裸函数 `switchNaked` 里（它要直接改 `sp`，不能有序言和尾声）。Zig 不允许直接调用裸函数，所以在一段内联汇编里 `call` 它。
- 对编译器来说，这段内联汇编就是“会破坏 `ra`、`t0..t6`、`a0..a7` 和内存的一段代码”，正好对应一次 C 函数调用的效果；编译器不会对裸函数本身做任何假设。`from` 和 `to` 用 `"r"` 约束传进任意寄存器，再在汇编里 `mv` 到 `a0`、`a1`，而不是直接用 `"{a0}"`、`"{a1}"` 约束：`a0`、`a1` 已经声明为被破坏，被破坏的寄存器不应该同时用作输入（GCC 的内联汇编规则明确禁止），这样写就不依赖编译器怎么处理这种重叠。被声明为被破坏的寄存器也不会被分配给 `"r"` 输入，所以两条 `mv` 不会互相覆盖。
- `switchNaked` 声明成 `noreturn`：它用 `ret` 跳走，不会走到函数体结尾。这没关系，因为它只从内联汇编里调用，编译器看不到这个调用。**曾经踩过的坑**：单进程版本最初把裸函数 `@ptrCast` 成 C 调用约定的函数指针来调用，而裸函数被声明成了 `noreturn`。release 模式下编译器据此认为调用之后的代码永远不会执行，把切回内核页表、释放内存这些代码都删掉了，进程一退出内核就崩溃。现在的写法不依赖裸函数的签名。
- 切换全程关着中断：调度器关着中断扫描进程表，进程这边是在陷阱处理程序里。

### 栈的变化

```
启动栈（调度器在用）               进程 A 的内核栈（16 KiB）          进程 B 的内核栈
┌─────────────────────┐          ┌─────────────────────┐ ← 栈顶     ┌─────────────────────┐
│ kmain → scheduler → │          │ TrapFrame（272 字节）│            │ 初始 TrapFrame       │ ← B.context.sp
│ switchContext       │ ←        ├─────────────────────┤            └─────────────────────┘
│                     │ scheduler│ handleTrap →        │              （还没运行过，
└─────────────────────┘ _context │ yield → sched →     │                ra = forkret）
                          .sp    │ switchContext       │ ← A.context.sp
                                 └─────────────────────┘
```

- 调度器切到进程时，它的调用链（`kmain → scheduler → switchContext`）留在启动栈上，`scheduler_context.sp` 记住它的位置。`kmain` 永远不会返回，启动栈从此归调度器用。
- 每次从 U 模式陷入，`trapEntry` 都从 `sscratch`（这个进程的内核栈顶）开始压 `TrapFrame`。陷阱处理程序让出 CPU 时，它的调用链就停在这个进程的内核栈上，等下次轮到它再继续。同一时刻每块进程内核栈上最多只有一层陷阱。
- 进程结束时它的内核栈上的内容直接丢弃，下一个用这个槽位的进程从头再用。`fork` 出来的子进程的内核栈上只有复制来的 `TrapFrame`，没有父进程的调用链：它从 `forkret` 开始，不经过 `handleTrap` 的后半段。
## 结束进程

```zig
pub fn exit(code: u8) noreturn                                          // exit 系统调用
pub fn killCurrent(comptime reason: []const u8, args: anytype) noreturn // U 模式下的异常
pub fn checkKilled() callconv(.c) void                                  // 回到 U 模式之前
fn finish(p: *Process, status: u32) noreturn

pub fn waitChild(pid: usize, nohang: bool) WaitError!?*Process          // wait 系统调用
pub fn reap(c: *Process) void

pub fn kill(pid: usize, reason: []const u8) KillError!void              // kill 系统调用、Ctrl-C
pub const KillError = error{ NoSuchProcess, PermissionDenied };
```

### exit：变成 zombie

`exit`、`killCurrent` 打印一行信息，然后调用 `finish(p, status)`（xv6 的 `exit` 的后半部分）：

```zig
fn finish(p: *Process, status: u32) noreturn {
    const init = init_proc.?;
    if (p == init) std.debug.panic("init exited (status {d})", .{status});
    reparent(p, init);
    p.xstatus = status;
    p.state = .zombie;
    wakeup(p.parent.?);
    sched();
    unreachable;
}
```

1. **init 不能结束**：所有孤儿都靠它回收，它没了内核就 panic（xv6 也是 `panic("init exiting")`）。正常情况下 init 从不退出，`kill` 也不允许杀它。
2. **`reparent`：子进程交给 init**。被交过去的子进程可能已经是 zombie 了，所以顺便叫醒 init，让它的 `wait` 重新看一遍。
3. 记下结束状态：`exit(code)` 是退出码（0..255），被杀的是 `abi.killed_status`（`0x100`），两者不会混淆。
4. 状态改成 `zombie`，叫醒父进程（它可能在 `wait` 里睡着），切回调度器，再也不回来。

**不在这里释放内存**：进程这时还在用自己的内核栈和地址空间（`satp` 指着它的页表）。地址空间由父进程在 `wait` 里回收，那时运行的是父进程，用的是父进程的页表。zombie 只占一个槽位和它的用户内存，直到被回收。

### wait：回收子进程

```zig
pub fn waitChild(pid: usize, nohang: bool) WaitError!?*Process {
    const p = current.?;
    while (true) {
        if (try findZombieChild(p, pid)) |c| return c;
        if (nohang or p.killed != null) return null;
        sleep(p);
    }
}
```

- `findZombieChild` 扫一遍进程表，看 `parent == p` 的进程（`pid` 不是 `abi.wait_any` 时只看这一个 pid）：有 zombie 就返回它；有符合条件的子进程但都没结束返回 `null`；一个都没有是 `NoChildren`（`-ECHILD`）。它只看进程表，单元测试直接测它。
- 都没结束就**睡在自己身上**（`sleep(p)`），子进程的 `finish` 用 `wakeup(p.parent)` 叫醒它。醒来再扫一遍。`nohang` 时不睡，返回 `null`（系统调用返回 0）；被 kill 了也不睡，回到陷阱处理程序后结束。
- 找到的 zombie 先交给系统调用处理程序：它把 `xstatus` 写进用户给的地址（写不进去就返回 `-EFAULT`，**不回收**，子进程还在，可以再 `wait`），然后调用 `reap`：释放地址空间，槽位清回 `unused`。xv6 也是先 `copyout` 再 `freeproc`。

### kill：只做标记

**杀别的进程**（`kill`），照 xv6 的做法：**只记下原因（`killed`），在睡的改成 `runnable`，不当场结束它**。被杀的进程可能停在内核栈上的任何地方（`sleep` 里、`yield` 里），只有它自己知道怎么安全地收尾，所以让它自己来：

- 陷阱处理程序回到 U 模式之前调用 `checkKilled()`（[trap.md](trap.md#分发)），新进程第一次进入 U 模式之前 `forkret` 也调用它。`killed` 不为空就 `killCurrent("{s}", .{reason})`。所以**被杀的进程不会再执行一条用户指令**。
- 睡着的进程被改成 `runnable`，醒来后在 `sleep`、`read`、`wait` 的循环里看到 `killed`，提前返回，接着在 `checkKilled` 里结束。
- 正在 U 模式运行的进程（Ctrl-C 时前台进程多半是这样）：串口中断打断它，中断处理程序调用 `kill`，回到 U 模式之前 `checkKilled` 就结束它。
- `kill` 只改标志和状态，所以中断处理程序里也能调用。同一个进程被杀两次，保留第一次的原因。zombie 也能“杀”，什么都不变。
- 杀 init 是 `PermissionDenied`（`-EPERM`），没有这个进程是 `NoSuchProcess`（`-ESRCH`）。

输出：

```
[proc] pid 3 (hello) exited with code 0
[proc] pid 6 (fault) killed: load_page_fault at 0x40011462, stval=0x80200000
[proc] pid 7 (spin) killed: interrupted by Ctrl-C
[proc] pid 8 (spin) killed: kill()
```

| 原因 | 谁调用 | 输出 | `wait` 拿到的状态 |
| --- | --- | --- | --- |
| `exit(code)` 系统调用，或 `main` 返回 | `syscall.dispatch` → `proc.exit` | `exited with code N` | `N` |
| 用户程序 panic（Debug/safe 模式下的安全检查失败等） | `user/start.zig` 打印 `panic: ...` 后调用 `exit(255)` | `exited with code 255` | 255 |
| U 模式下的任何异常（缺页、非法指令、`ebreak` 等） | `trap.handleTrap` → `proc.killCurrent` | `killed: <异常名> at <sepc>, stval=<stval>` | `0x100` |
| 前台进程运行期间按了 Ctrl-C | 串口中断 → `proc.interruptForeground` → `proc.kill`，之后 `checkKilled` | `^C`，然后 `killed: interrupted by Ctrl-C` | `0x100` |
| `kill` 系统调用（shell 的 `kill PID`） | `syscall` → `proc.kill`，之后 `checkKilled` | `killed: kill()` | `0x100` |

## Ctrl-C

Ctrl-C 结束的是**前台进程**：shell 用 `fork` 启动前台程序后，调用 `setfg(pid)` 告诉内核，等它结束后再 `setfg(0)`（[shell.md](shell.md#前台和后台)）。内核只记一个 pid（`proc.foreground`），后台进程不受影响。

1. 串口中断处理程序看到 `0x03`，不放进输入缓冲区，只置位 `ctrl_c_pressed`（[devices.md](devices.md#ctrl-c)）。
2. 同一个中断里，`trap.handleExternal` 接着调用 `uart.takeCtrlC()`，为真就调用 `proc.interruptForeground()`：前台进程存在、没结束、不是 init 的话，打印 `^C`，`proc.kill(pid, "interrupted by Ctrl-C")`；否则什么也不做，所以在 shell 里随手按的 Ctrl-C 不会留到下一个程序。这和 xv6 的 `consoleintr` 在中断里直接处理控制字符是一个思路。
3. 前台进程在 U 模式运行的话，这次中断返回之前 `checkKilled` 就结束它；在 `sleep`、`read`、`wait` 里睡着的话，它被叫醒后结束；`runnable` 的话，下次被调度时结束。用户程序就算死循环、从不做系统调用，也不会再回到 U 模式。
4. 它结束时叫醒在 `wait` 里等它的 shell。

## 限制和以后可以做的

- 只有一个 hart，调度器不需要锁。多核时就要像 xv6 那样：进程表、页分配器都加锁，`sleep` 带锁，每个 hart 一个调度器上下文和 `current`。
- 内核代码不可抢占：进程在内核里关着中断运行，直到自己调用 `sched`。xv6 在内核里也开着中断，内核代码被时钟中断打断时也会 `yield`。这里内核里没有长时间的计算，不需要。
- 进程之间没有优先级。
- 进程表固定 8 项，内核栈是静态的，两侧没有保护页。
- `fork` 逐页复制整个地址空间，没有写时复制；紧接着 `exec` 的话，复制的内容马上就扔掉了。
- 没有文件系统，`exec` 只能运行嵌在内核里的程序；没有文件描述符，`read`/`write` 直接对着串口。
- 没有命令行参数：`exec` 可以在新的用户栈顶放 `argc`/`argv`，通过 `TrapFrame` 的 `a0`、`a1` 传给 `_start`。
- 只有一个前台进程，没有进程组和信号：Ctrl-C 只杀 `setfg` 设置的那一个进程，它 `fork` 出来的子进程不受影响。
- 进程不能申请更多内存（没有 `brk`/`mmap`）；用户栈固定 16 KiB，不能增长。
