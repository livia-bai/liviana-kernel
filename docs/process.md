# 进程：加载和运行用户程序

涉及文件：`src/proc.zig`（以及 `src/trap.zig` 的 `trapExit`、`src/vm.zig` 的用户地址空间函数；调用方：`src/shell.zig`、`src/trap.zig`、`src/syscall.zig`）

一次只运行一个进程，没有调度：shell 的 `run NAME` 调用 `proc.run`，它新建地址空间、加载 ELF、切到 U 模式，直到程序调用 `exit`、出了异常、或者被 Ctrl-C 打断，再像普通函数一样返回到 shell。

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

## 进程状态

```zig
pub const Process = struct {
    pid: usize,
    name: []const u8,
    space: *vm.PageTable,   // 这个进程的根页表
};
pub var current: ?Process = null;   // 正在运行的进程；没有时为 null
var next_pid: usize = 1;            // 每次 run 加 1，从不复用

var kernel_stack: [16 * 1024]u8 align(16) = undefined;   // 进程陷入内核时用的栈
var shell_context: Context = undefined;                  // 进入 U 模式前保存的内核上下文
```

- 一次只有一个进程，所以进程内核栈是一块静态数组（在 `.bss` 里）。实测最深的路径（Debug 模式下杀进程时格式化输出一行信息）用了 3600 字节，release 模式下约 1 KiB，16 KiB 绰绰有余。测法：进入 U 模式前把整个栈填成 `0xaa`，进程结束后从栈底找第一个不是 `0xaa` 的字节。
- `current` 在 `run` 里设置，`run` 返回前（`defer`）清回 `null`。系统调用和杀进程的代码用 `current.?` 取当前进程，Debug/safe 模式下没有进程时会 panic。

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

**为什么一定要拒绝不可读的段**：如果一个段的 R/W/X 全为 0，`map` 写出的页表项只有 V = 1，硬件会把它当成“指向下一级页表”的项，而它指向的是一页用户数据。只要用户程序（或者构造 ELF 的人）往那一页里写入精心构造的页表项，就能把任意物理内存映射进自己的地址空间。这个漏洞是写完加载器后复查代码时发现的，现在加载器拒绝这样的段，`vm.map` 也断言了叶子权限合法；验证方法见 [changes/0005](changes/0005-user-mode-and-syscalls.md)。回归测试 `t_noperm`（[testing.md](testing.md#回归测试程序)）一直在检查这一点：故意去掉这条检查时，Debug 模式下 `vm.map` 的断言让内核 panic，small 模式下断言被编译掉，那一页真的被当成了页表（[changes/0009](changes/0009-qemu-test.md)）。

所有段加载完后，映射用户栈：`[栈底, 0x8000_0000)` 的 4 页，`RW-`。前面已经保证段都在保护页之下，所以这里不会 `AlreadyMapped`（写成 `unreachable`）。

## run 的步骤

```zig
pub fn run(program: *const Program) void
```

1. `vm.createUserSpace()`：新的根页表，复制内核的根页表。失败打印 `run: out of memory`。之后用 `defer vm.destroyUserSpace(space)` 保证无论怎么返回都会释放。
2. `load(space, program.image)`：失败打印 `run: cannot load NAME: BadElf`（或 `OutOfMemory`）后返回。
3. 设置 `current`，分配 pid。
4. 在 `kernel_stack` 的最顶端构造初始 `TrapFrame`：所有寄存器为 0，`sepc` = 入口地址，`regs[2]`（`sp`）= `0x8000_0000`。必须放在栈顶下方正好 `@sizeOf(TrapFrame)` 处：`trapExit` 回到 U 模式时会把“TrapFrame 地址 + 272”当作内核栈顶写进 `sscratch`（[trap.md](trap.md#trapexit)）。
5. 记下当前的中断状态，**关中断**。切换过程中不能被打断：`sscratch`、`sstatus`、`satp` 会处于一半新一半旧的状态。
6. `frame.sstatus = (当前 sstatus & ~SPP) | SPIE`：`SPP = 0` 让 `sret` 回到 U 模式；`SPIE = 1` 让 U 模式下中断是开着的（时钟和键盘照常工作，这也是 Ctrl-C 能生效的前提）。其他位（`SUM = 0`、`FS = Off` 等）保持内核当前的值。
7. `uart.takeCtrlC()`：丢掉运行之前按下的 Ctrl-C。
8. `vm.activate(space)`：切到进程的地址空间。内核映射是共用的，切换之后内核代码照常执行。
9. `switchToUser(frame)`：进入 U 模式。**进程结束后才从这里返回。**
10. `vm.activate(vm.kernel_root)`：切回内核页表。必须在释放进程的页表之前。
11. 如果进入前中断是开着的，重新打开。
12. 函数返回，`defer` 依次执行：`current = null`，`vm.destroyUserSpace(space)` 释放进程的所有页和页表。

## 进出 U 模式

### 保存的上下文

```zig
const Context = extern struct {
    ra: usize,
    sp: usize,
    s: [12]usize,   // s0..s11
};
```

按 RISC-V 的 C 调用约定，函数调用前后需要保持不变的只有 `sp` 和 `s0..s11`（被调用者保存），再加上返回地址 `ra`。其他寄存器（`t0..t6`、`a0..a7`）调用方本来就不指望它们保持原值。所以“暂停”内核的执行只需要保存这 14 个寄存器，就像协程切换一样。保存/恢复它们的指令由 `contextAsm(op, base)` 在编译期生成，并在编译期断言寄存器个数和 `Context` 的大小一致。

### switchToUser

```zig
fn switchToUser(frame: *trap.TrapFrame) void {
    asm volatile (
        \\mv a0, %[frame]
        \\mv a1, %[ctx]
        \\call %[switchToUserNaked]
        :
        : [frame] "r" (frame),
          [ctx] "r" (&shell_context),
          [switchToUserNaked] "X" (&switchToUserNaked),
        : .{ .ra = true, .t0 = true, ..., .t6 = true, .a0 = true, ..., .a7 = true, .memory = true });
}

fn switchToUserNaked() callconv(.naked) noreturn {
    asm volatile (contextAsm("sd", "a1") ++   // 把 ra、sp、s0..s11 存进 ctx
        \\mv sp, a0                           // sp 指向初始 TrapFrame
        \\tail %[trapExit]                    // 按 TrapFrame 恢复寄存器，sret 进入 U 模式
        :
        : [trapExit] "X" (&trap.trapExit),
    );
}
```

- 真正的切换在裸函数 `switchToUserNaked` 里（它要直接改 `sp`，不能有序言和尾声）。Zig 不允许直接调用裸函数，所以在一段内联汇编里 `call` 它。
- 对编译器来说，这段内联汇编就是“会破坏 `ra`、`t0..t6`、`a0..a7` 和内存的一段代码”，正好对应一次 C 函数调用的效果；编译器不会对裸函数本身做任何假设。`frame` 和 `ctx` 用 `"r"` 约束传进任意寄存器，再在汇编里 `mv` 到 `a0`、`a1`，而不是直接用 `"{a0}"`、`"{a1}"` 约束：`a0`、`a1` 已经声明为被破坏，被破坏的寄存器不应该同时用作输入（GCC 的内联汇编规则明确禁止），这样写就不依赖编译器怎么处理这种重叠。被声明为被破坏的寄存器也不会被分配给 `"r"` 输入，所以两条 `mv` 不会互相覆盖。
- **曾经踩过的坑**：最初是把裸函数 `@ptrCast` 成 C 调用约定的函数指针来调用，而裸函数被声明成了 `noreturn`。release 模式下编译器据此认为调用之后的代码永远不会执行，把切回内核页表、释放内存这些代码都删掉了，进程一退出内核就崩溃（详见 [changes/0005](changes/0005-user-mode-and-syscalls.md)）。现在的写法不依赖裸函数的签名。

`call` 指令把返回地址（`call` 的下一条指令）放进 `ra`，`switchToUserNaked` 再把这个 `ra` 存进 `shell_context`，这就是将来“返回”的地方。

### switchBack

```zig
fn switchBack(ctx: *const Context) noreturn {
    asm volatile (contextAsm("ld", "a0") ++ "ret\n"
        :
        : [ctx] "{a0}" (ctx),
    );
    unreachable;
}
```

从 `ctx` 恢复 `ra`、`sp`、`s0..s11`，然后 `ret` 跳到 `ra`，也就是 `switchToUser` 里 `call` 的下一条指令。从 `run` 的角度看，`switchToUser` 就像一次普通的函数调用刚刚返回。

### 栈的变化

```
启动栈（shell 在用）                   进程内核栈 kernel_stack（16 KiB）
┌──────────────────────┐              ┌──────────────────────┐ ← 栈顶 = sscratch（在 U 模式时）
│ kmain → shell.feed → │              │ TrapFrame（272 字节） │   初始的、以及每次从 U 模式陷入时压的
│ execute → run →      │              ├──────────────────────┤
│ switchToUser         │ ← shell_     │ handleTrap、         │   陷阱处理程序的栈帧
│                      │   context.sp │ syscall.dispatch …   │
└──────────────────────┘              └──────────────────────┘
```

- 进入 U 模式时，shell 那边的调用链（直到 `switchToUser`）原封不动地留在启动栈上，`shell_context.sp` 记住它的位置。
- 每次从 U 模式陷入，`trapEntry` 都从 `sscratch`（进程内核栈顶）开始压 `TrapFrame`，所以同一时刻进程内核栈上最多只有一层陷阱。
- 进程结束时 `switchBack` 把 `sp` 恢复成 `shell_context.sp`，进程内核栈上的内容（包括 `TrapFrame` 和陷阱处理程序的栈帧）直接丢弃，不需要“返回”。下一次 `run` 从头再用这块栈。

## 结束进程

```zig
pub fn exit(code: u8) noreturn                                    // exit 系统调用
pub fn kill(comptime reason: []const u8, args: anytype) noreturn  // 异常或 Ctrl-C
```

两者都打印一行信息，然后 `switchBack(&shell_context)`：

```
[proc] pid 1 (hello) exited with code 0
[proc] pid 2 (fault) killed: load_page_fault at 0x40011454, stval=0x80200000
[proc] pid 3 (spin) killed: interrupted by Ctrl-C
```

它们都在陷阱处理程序里调用（关着中断，在进程内核栈上）。`switchBack` 之后执行回到 `run` 的第 10 步，由 `run` 负责切页表和释放内存，所以清理工作不在陷阱上下文里做。

结束的原因和对应的输出：

| 原因 | 谁调用 | 输出 |
| --- | --- | --- |
| `exit(code)` 系统调用，或 `main` 返回 | `syscall.dispatch` | `exited with code N` |
| 用户程序 panic（Debug/safe 模式下的安全检查失败等） | `user/start.zig` 打印 `panic: ...` 后调用 `exit(255)` | `exited with code 255` |
| U 模式下的任何异常（缺页、非法指令、`ebreak` 等） | `trap.handleTrap` | `killed: <异常名> at <sepc>, stval=<stval>` |
| 运行期间按了 Ctrl-C | `trap.handleTrap` | `^C`，然后 `killed: interrupted by Ctrl-C` |

## Ctrl-C

用户程序可能死循环、从不做系统调用。这时内核仍然能拿回 CPU：U 模式下中断是开着的，时钟中断每 10 ms 一次，串口在收到字符时也会产生中断。

1. 串口中断处理程序看到 `0x03`，不放进输入缓冲区，只置位 `ctrl_c_pressed`（[devices.md](devices.md#ctrl-c)）。
2. `handleTrap` 处理完**来自 U 模式**的中断后调用 `uart.takeCtrlC()`，为真就 `proc.kill`。
3. 检查放在 PLIC `complete` 之后，所以杀进程不会让 PLIC 一直以为串口中断还在处理中。

只在 `from_user` 时检查：用户程序运行期间，内核代码（陷阱处理、系统调用）都关着中断，中断只可能打断 U 模式；shell 运行时按的 Ctrl-C 会被 `run` 开头的 `takeCtrlC()` 丢掉。

## 限制和以后可以做的

- **一次一个进程，没有调度**。要支持多进程：每个进程一块内核栈（可以从页分配器分配，并在两侧留不映射的保护页）、一个 `Context`；时钟中断里保存当前进程、选下一个、切换 `satp` 和 `sscratch`。`trapEntry`/`trapExit` 的 `sscratch` 约定不需要改。
- 没有命令行参数：可以在用户栈顶放 `argc`/`argv`，通过初始 `TrapFrame` 的 `a0`、`a1` 传给 `_start`。
- 进程不能申请更多内存（没有 `brk`/`mmap`）。
- 用户栈固定 16 KiB，不能增长。
