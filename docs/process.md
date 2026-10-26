# 进程：加载、调度和运行用户程序

涉及文件：`src/proc.zig`（以及 `src/trap.zig` 的 `trapExit`、`src/vm.zig` 的用户地址空间函数；调用方：`src/main.zig` 的主循环、`src/shell.zig`、`src/trap.zig`、`src/syscall.zig`）

进程表里最多同时有 8 个进程，按时间片轮转（round-robin）抢占式调度：

- shell 的 `run NAME` 调用 `proc.spawn`：新建地址空间、加载 ELF、在进程表里占一个槽位，状态为 `ready`。这时程序还没开始运行。
- **调度器就是内核的主循环**（[boot.md](boot.md#主循环)）。它在启动栈上运行，每一轮调用 `proc.schedule()`：挑一个就绪的进程，切换到它的地址空间和内核栈，进入 U 模式。
- 进程运行到下一次中断（时钟每 10 ms 一次，所以时间片就是一个 tick）、调用 `yield`/`sleep`、`exit`，或者出了异常，就切回主循环。主循环处理键盘输入后再挑下一个进程。所以有进程在死循环时 shell 照样能用。

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
- `find` 按名字线性查找，shell 的 `run` 用它；`run` 不带参数时遍历 `programs` 列出所有名字。

## 进程表

```zig
pub const max_procs = 8;

pub const State = enum { unused, ready, running, sleeping, exited };

pub const Process = struct {
    state: State = .unused,
    pid: usize = 0,
    name: []const u8 = "",
    space: *vm.PageTable = undefined,  // 这个进程的根页表
    context: Context = undefined,      // 不在运行时保存的内核上下文
    wake_tick: u64 = 0,                // sleeping 时：timer.ticks 到这个值就醒
    ticks: u64 = 0,                    // 在 U 模式运行期间来过的时钟中断数
};

pub var table: [max_procs]Process = @splat(.{});
pub var current: ?*Process = null;     // 正在运行的进程；在主循环里时为 null
var next_pid: usize = 1;               // 每次 spawn 加 1，从不复用

var kernel_stacks: [max_procs][16 * 1024]u8 align(16) = undefined;  // 槽位 i 的进程用第 i 块
var scheduler_context: Context = undefined;  // 主循环切到进程时保存的上下文
var last_slot: usize = max_procs - 1;        // 上一次运行的槽位
```

状态的变化：

| 从 | 到 | 什么时候 | 谁做的 |
| --- | --- | --- | --- |
| `unused` | `ready` | shell 的 `run` | `spawn` |
| `ready` | `running` | 轮到它 | `schedule` |
| `running` | `ready` | 中断打断了 U 模式（时间片用完、有键盘输入），或者 `yield` 系统调用 | `yield` |
| `running` | `sleeping` | `sleep` 系统调用 | `sleep` |
| `sleeping` | `ready` | `timer.ticks >= wake_tick` | `pickNext` |
| `running` | `exited` | `exit` 系统调用，或者 U 模式下出了异常 | `exit`、`killCurrent` |
| `exited` | `unused` | 切回主循环之后马上 | `schedule` 回收 |
| `ready`、`sleeping` | `unused` | shell 的 `kill` 命令，或者对前台进程按 Ctrl-C | `kill` |

- **每个进程一块 16 KiB 的内核栈**，静态分配在 `.bss` 里（8 块共 128 KiB）。不从页分配器要：它一次只给一页，给不出连续的 16 KiB。实测最深的路径（Debug 模式下杀进程时格式化输出一行信息）用了 3520 字节，small 模式下 1056 字节。测法：`spawn` 时把整块栈填成 `0xaa`，回收进程时从栈底找第一个不是 `0xaa` 的字节，跑一遍全部 QEMU 测试取最大值。内核栈两侧没有保护页：内核内存是用大页恒等映射的，要在中间挖出不映射的页得拆大页，现在没做。
- `current` 只在 `schedule` 切到进程前设置、切回来后清回 `null`。系统调用和陷阱处理程序用 `current.?` 取当前进程，Debug/safe 模式下没有进程时会 panic。主循环里（包括 shell 执行命令时）`current` 总是 `null`，这时进程表里没有 `running` 的进程。
- 进程表只在主循环里（`spawn`、`schedule`、`kill`）和陷阱处理程序里（当前进程改自己的状态）修改。中断处理程序不碰进程表，只有时钟中断打断 U 模式时给 `current.ticks` 加 1，那时主循环不在运行，所以不需要锁。
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
pub fn spawn(program: *const Program) SpawnError!usize   // 返回 pid
```

1. 找一个 `unused` 的槽位，没有就是 `TooManyProcesses`（shell 打印 `run: too many processes (at most 8)`）。
2. `vm.createUserSpace()`：新的根页表，复制内核的根页表。之后用 `errdefer vm.destroyUserSpace(space)` 保证出错时释放。
3. `load(space, program.image)`：失败时 shell 打印 `run: cannot load NAME: BadElf`（或 `OutOfMemory`）。
4. 在这个槽位的内核栈最顶端构造初始 `TrapFrame`：所有寄存器为 0，`sepc` = 入口地址，`regs[2]`（`sp`）= `0x8000_0000`。必须放在栈顶下方正好 `@sizeOf(TrapFrame)` 处：`trapExit` 回到 U 模式时会把“TrapFrame 地址 + 272”当作内核栈顶写进 `sscratch`（[trap.md](trap.md#trapexit)）。
5. `frame.sstatus = (当前 sstatus & ~(SPP | SIE)) | SPIE`：
   - `SPP = 0` 让 `sret` 回到 U 模式；`SPIE = 1` 让 U 模式下中断是开着的（时钟和键盘照常工作，抢占和 Ctrl-C 都靠它）。
   - **`SIE` 必须清掉**。shell 是开着中断调用 `spawn` 的，这时读到的 `sstatus` 里 `SIE = 1`；`trapExit` 第一步就把 `frame.sstatus` 写回 `sstatus`，`SIE = 1` 的话恢复寄存器的途中就可能被中断打断，而那时 `sscratch` 已经指向进程的内核栈，栈和寄存器都是一半新一半旧的状态。（单进程版本的 `run` 是先关中断再读 `sstatus`，所以没有这个问题。）
   - 其他位保持内核当前的值，其中 `SUM = 0`、`FS = Off`（`kmain` 启动时清的，见 [riscv-sbi.md](riscv-sbi.md#位定义)），所以 U 模式同样不能用浮点。
6. 初始的内核上下文：`ra` = `trap.trapExit`，`sp` = 初始 `TrapFrame` 的地址，`s0..s11` = 0。第一次被调度时，`switchContext` 恢复这个上下文后 `ret`，就跳进了 `trapExit`，而 `sp` 正指向初始 `TrapFrame`，于是 `sret` 进入 U 模式，从入口地址开始执行。
7. 状态设为 `ready`，分配 pid，返回。

## 调度

```zig
pub fn schedule() bool                 // 主循环调用，关着中断
fn pickNext(procs: []Process, last: usize, now: u64) ?usize
```

`schedule` 做一次调度：

1. `pickNext`：先把睡够了（`timer.ticks >= wake_tick`）的 `sleeping` 进程改回 `ready`；再从上一次运行的槽位的**下一个**开始，绕一圈找第一个 `ready` 的进程。所以就绪的进程轮流运行；只有一个就绪时，每次选的都是它。没有就返回 `false`，主循环就去 `wfi`。
2. 状态设为 `running`，`current` 指向它，`vm.activate(p.space)` 切到它的地址空间。
3. `switchContext(&scheduler_context, &p.context)`：保存主循环的上下文，恢复进程的上下文。进程要么从 `trapExit` 第一次进入 U 模式，要么从它上次让出 CPU 的地方（`yield`/`sleep` 里的 `switchContext`）继续。
4. 进程让出 CPU 后，执行回到这里：切回内核页表，`current = null`。状态是 `exited` 的话回收它（释放地址空间，槽位清回 `unused`），必须在切回内核页表之后。
5. 返回 `true`。

`pickNext` 只看进程表的状态，不碰硬件，单元测试直接测它（`src/proc.zig` 末尾）。

**时间片**：进程在 U 模式运行时中断是开着的。`trap.handleTrap` 处理完一个打断 U 模式的中断后调用 `proc.yield()`（[trap.md](trap.md#分发)）：

- 时钟中断：时间片用完了，轮到下一个进程。时钟中断是全局的每 10 ms 一次，不是按进程计时的，所以一个进程刚被调度就碰上时钟中断时，它的时间片会不足 10 ms。
- 串口中断：有键盘输入，要回到主循环交给 shell、检查 Ctrl-C。

`ticks` 只在时钟中断打断这个进程时加 1，是它用掉的 CPU 时间的近似值（单位 10 ms），`ps` 显示它。两个死循环的进程一起跑时，`ticks` 的增速几乎相同。

**主循环和进程交替**：主循环每一轮最多运行一个进程的一个时间片，下一轮先处理 Ctrl-C 和键盘输入。键盘输入优先：有字符要交给 shell 的那一轮不调度进程。

```zig
pub fn yield() void        // 当前进程让出 CPU（状态改回 ready）
pub fn sleep(ms: u64) void // 当前进程睡 ms 毫秒（状态改成 sleeping）
```

两者都由陷阱处理程序调用（`yield` 来自中断或 `yield` 系统调用，`sleep` 来自 `sleep` 系统调用），关着中断，在进程自己的内核栈上：改状态，然后 `switchContext(&p.context, &scheduler_context)` 切回主循环。下次轮到这个进程时，`switchContext` 才返回，陷阱处理程序接着往下走，最后经 `trapExit` 回到 U 模式。

`sleep` 的醒来时刻：`wake_tick = timer.ticks + ⌈ms × 100 / 1000⌉`，乘法和加法都是饱和运算，`ms` 再大也不会溢出（最多睡到永远，只能被 `kill`）。用户程序看到的 `uptime()` 也是按 tick 算的，所以醒来后 `uptime()` 至少增加了 `ms`；按真实时间算，可能比 `ms` 少不到一个 tick（睡下去时当前 tick 已经过了一部分）。`ms = 0` 时醒来时刻就是现在，效果和 `yield` 一样。
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
- 新进程的 `context` 是 `spawn` 构造的：`ra` = `trapExit`，`sp` = 初始 `TrapFrame`，所以 `ret` 直接跳进 `trapExit`、`sret` 进入 U 模式。
- 用到的三处：主循环切到进程（`schedule`），进程切回主循环（`yield`、`sleep`、`finish`）。进程之间从不直接切换，总是经过主循环。
- 真正的切换在裸函数 `switchNaked` 里（它要直接改 `sp`，不能有序言和尾声）。Zig 不允许直接调用裸函数，所以在一段内联汇编里 `call` 它。
- 对编译器来说，这段内联汇编就是“会破坏 `ra`、`t0..t6`、`a0..a7` 和内存的一段代码”，正好对应一次 C 函数调用的效果；编译器不会对裸函数本身做任何假设。`from` 和 `to` 用 `"r"` 约束传进任意寄存器，再在汇编里 `mv` 到 `a0`、`a1`，而不是直接用 `"{a0}"`、`"{a1}"` 约束：`a0`、`a1` 已经声明为被破坏，被破坏的寄存器不应该同时用作输入（GCC 的内联汇编规则明确禁止），这样写就不依赖编译器怎么处理这种重叠。被声明为被破坏的寄存器也不会被分配给 `"r"` 输入，所以两条 `mv` 不会互相覆盖。
- `switchNaked` 声明成 `noreturn`：它用 `ret` 跳走，不会走到函数体结尾。这没关系，因为它只从内联汇编里调用，编译器看不到这个调用。**曾经踩过的坑**：单进程版本最初把裸函数 `@ptrCast` 成 C 调用约定的函数指针来调用，而裸函数被声明成了 `noreturn`。release 模式下编译器据此认为调用之后的代码永远不会执行，把切回内核页表、释放内存这些代码都删掉了，进程一退出内核就崩溃。现在的写法不依赖裸函数的签名。
- 切换全程关着中断：主循环在调用 `schedule` 前关中断，进程这边是在陷阱处理程序里。

### 栈的变化

```
启动栈（主循环在用）               进程 A 的内核栈（16 KiB）          进程 B 的内核栈
┌─────────────────────┐          ┌─────────────────────┐ ← 栈顶     ┌─────────────────────┐
│ kmain → schedule →  │          │ TrapFrame（272 字节）│            │ 初始 TrapFrame       │ ← B.context.sp
│ switchContext       │ ←        ├─────────────────────┤            └─────────────────────┘
│                     │ scheduler│ handleTrap →        │              （还没运行过，
└─────────────────────┘ _context │ yield →             │                ra = trapExit）
                          .sp    │ switchContext       │ ← A.context.sp
                                 └─────────────────────┘
```

- 主循环切到进程时，它的调用链（`kmain → schedule → switchContext`）留在启动栈上，`scheduler_context.sp` 记住它的位置。
- 每次从 U 模式陷入，`trapEntry` 都从 `sscratch`（这个进程的内核栈顶）开始压 `TrapFrame`。陷阱处理程序让出 CPU 时，它的调用链就停在这个进程的内核栈上，等下次轮到它再继续。同一时刻每块进程内核栈上最多只有一层陷阱。
- 进程结束时它的内核栈上的内容直接丢弃，下一个用这个槽位的进程从头再用。
## 结束进程

```zig
pub fn exit(code: u8) noreturn                                         // exit 系统调用
pub fn killCurrent(comptime reason: []const u8, args: anytype) noreturn // U 模式下的异常
pub fn kill(pid: usize, comptime reason: []const u8) bool               // shell：kill 命令、Ctrl-C
```

**当前进程自己结束**（`exit`、`killCurrent`）：打印一行信息，状态设为 `exited`，`switchContext` 切回主循环，不返回。这时进程还在用自己的内核栈和地址空间，不能自己释放，所以由 `schedule` 在切回来、换回内核页表之后回收。

**shell 结束别的进程**（`kill`）：这时 CPU 在主循环里，没有进程在运行，目标进程处于 `ready` 或 `sleeping`，它停在内核栈上的调用链没用了，直接释放地址空间、清空槽位即可。找不到这个 pid 返回 `false`。

输出：

```
[proc] pid 1 (hello) exited with code 0
[proc] pid 2 (fault) killed: load_page_fault at 0x40011454, stval=0x80200000
[proc] pid 3 (spin) killed: interrupted by Ctrl-C
[proc] pid 4 (spin) killed: kill command
```

| 原因 | 谁调用 | 输出 |
| --- | --- | --- |
| `exit(code)` 系统调用，或 `main` 返回 | `syscall.dispatch` → `proc.exit` | `exited with code N` |
| 用户程序 panic（Debug/safe 模式下的安全检查失败等） | `user/start.zig` 打印 `panic: ...` 后调用 `exit(255)` | `exited with code 255` |
| U 模式下的任何异常（缺页、非法指令、`ebreak` 等） | `trap.handleTrap` → `proc.killCurrent` | `killed: <异常名> at <sepc>, stval=<stval>` |
| 前台进程运行期间按了 Ctrl-C | 主循环 → `shell.interrupt` → `proc.kill` | `^C`，然后 `killed: interrupted by Ctrl-C` |
| shell 的 `kill PID` | `shell` → `proc.kill` | `killed: kill command` |

没有 `wait`，退出码只打印出来，不保存；进程结束后槽位立刻回收，不留僵尸进程。
## Ctrl-C

Ctrl-C 结束的是 shell 的**前台进程**（`run NAME` 不带 `&` 启动的那个，[shell.md](shell.md#前台和后台)），后台进程不受影响。

1. 串口中断处理程序看到 `0x03`，不放进输入缓冲区，只置位 `ctrl_c_pressed`（[devices.md](devices.md#ctrl-c)）。
2. 如果这时 CPU 在 U 模式，中断处理完后 `handleTrap` 调用 `proc.yield()`，回到主循环。用户程序就算死循环、从不做系统调用，也最多再跑完这个中断就让出 CPU。
3. 主循环每一轮先调用 `uart.takeCtrlC()`，为真就调用 `shell.interrupt()`：有前台进程就打印 `^C`、`proc.kill(pid, "interrupted by Ctrl-C")`；没有就什么也不做，所以在 shell 里随手按的 Ctrl-C 不会留到下一个程序。
## 限制和以后可以做的

- 只有一个 hart，调度器不需要锁。多核时进程表、页分配器都要加锁，每个 hart 一个调度器上下文。
- 进程之间没有优先级，也没有父子关系：没有 `fork`/`exec`/`wait`，进程只能由 shell 启动，退出码不保存。
- 进程表固定 8 项，内核栈是静态的，两侧没有保护页。
- 阻塞只有 `sleep` 一种。阻塞读键盘的 `read` 可以照着做：加一个状态，主循环收到字符时唤醒。
- 没有命令行参数：可以在用户栈顶放 `argc`/`argv`，通过初始 `TrapFrame` 的 `a0`、`a1` 传给 `_start`。
- 进程不能申请更多内存（没有 `brk`/`mmap`）；用户栈固定 16 KiB，不能增长。
