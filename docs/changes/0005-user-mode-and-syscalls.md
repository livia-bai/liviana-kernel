# 0005 U 模式用户程序和系统调用

- 日期：2026-10-25
- 提交：`0752ca1` Run user programs in U-mode with system calls
- 涉及文件：`src/abi.zig`（新）、`src/proc.zig`（新）、`src/syscall.zig`（新）、`user/`（新：`start.zig`、`sys.zig`、`linker.ld`、`hello.zig`、`fault.zig`、`spin.zig`）、`build.zig`、`src/trap.zig`、`src/vm.zig`、`src/riscv.zig`、`src/uart.zig`、`src/timer.zig`、`src/shell.zig`、`README.md`、`AGENTS.md`

## 目标

维护者要求的第三部分：U 模式用户程序 + 系统调用（`ecall` 从 U 模式陷入）。

## 改动

- **构建**（`build.zig`）：每个用户程序以 `user/start.zig` 为根、`user/<名字>.zig` 为 `program` 模块编译成 ELF，链接到 `0x4000_0000`，作为匿名模块嵌进内核；程序名列表通过 `build_options` 传给内核。用户程序 `strip`、不生成 unwind 表、打开 gc-sections。
- **ABI**（`src/abi.zig`）：调用号 `exit`/`write`/`getpid`/`uptime`，错误码 EFAULT/ENOSYS，返回值编码（负数为 -errno）。内核和用户程序共用。
- **用户运行时**（`user/start.zig`、`user/sys.zig`）：`_start` 入口、panic（打印后 `exit(255)`）、系统调用封装、基于 `std.Io.Writer` 的 `print`。
- **示例程序**：`hello`（系统调用演示，故意传内核指针给 `write`）、`fault`（读内核内存被杀）、`spin`（死循环，Ctrl-C 结束）。
- **陷阱**（`src/trap.zig`）：入口用 `sscratch` 交换出内核栈（来自 U 模式时）；拆出 `pub fn trapExit`，回到 U 模式时把内核栈顶写进 `sscratch`；`trap.init` 清零 `sscratch`；分发区分 `from_user`：U 模式的 `ecall` 交给 `syscall.dispatch`，其他 U 模式异常杀进程，中断后检查 Ctrl-C。
- **进程**（`src/proc.zig`）：程序表、ELF 加载器、用户栈和保护页、`run`（建地址空间、构造初始 `TrapFrame`、切换）、`switchToUser`/`switchBack`（保存/恢复 `ra`、`sp`、`s0..s11`）、`exit`/`kill`。
- **系统调用**（`src/syscall.zig`）：分发；`write` 逐页经 `vm.copyFromUser` 复制到内核缓冲区再输出。
- **页表**（`src/vm.zig`）：`user_base`/`user_end`（根页表第 1 项），`map` 的断言（用户映射只在用户区、内核映射不进用户区、叶子权限合法），`createUserSpace`、`destroyUserSpace`、`allocUserPage`、`translateUser`、`copyFromUser`。
- 其他：`riscv.zig` 加 `sscratch` 和 `SPIE`/`SPP` 位；`uart.zig` 加 Ctrl-C 标志；`timer.zig` 加 `uptimeMs()`；`shell.zig` 加 `run [NAME]` 和参数解析。

细节见 [user-programs.md](../user-programs.md)、[process.md](../process.md)、[syscalls.md](../syscalls.md)、[trap.md](../trap.md)。

## 设计决策

- **用户空间放在根页表第 1 项**（`0x4000_0000..0x8000_0000`）：内核是低地址的恒等映射，外设在第 0 项、内存从第 2 项开始，第 1 项空着。每个进程只复制内核根页表，下面的页表共用；陷入内核不切换页表。没有选 xv6 那种“用户页表里只有跳板页、陷入时切换 `satp`”的方案，因为那需要跳板代码映射在两个地址空间的同一位置，复杂得多。
- **一次只运行一个进程，`run` 同步等待**：用类似协程的方式保存 shell 的上下文（只需 `ra`、`sp`、`s0..s11`），进程结束时恢复，`run` 像普通函数一样返回。进程内核栈是一块 16 KiB 的静态数组。这为以后的多进程留了余地，但没有提前实现调度。
- **用户程序是独立编译的 ELF，内核自己加载**：比“把用户代码放进内核的一个特殊段”更真实，能按 ELF 程序头分别设置 R/X、R、RW 权限。加载器按“输入不可信”的标准检查每个字段。
- **用户态 crt0 风格的根文件**（`user/start.zig`）：程序本身只写 `main`，不用写样板代码。
- **内核从不直接解引用用户指针**：`sstatus.SUM` 始终为 0，`write` 用软件查页表（要求 U + R），从物理地址复制。传内核地址只会得到 EFAULT。
- **用户程序的任何异常只杀进程**；**Ctrl-C** 通过串口中断处理，即使用户程序从不做系统调用也能结束它。
- **系统调用编号和错误码风格沿用 Linux**（`a7` 放调用号、负数返回 -errno），但调用号是自己定的。

## 验证

### 环境

Zig 0.17.0、QEMU 8.2.2、OpenSBI v1.3（同 [0003](0003-device-tree.md)）。

### 正常路径

四种优化模式各跑一遍（AGENTS.md 里的标准脚本）：

```sh
(sleep 1.5; for c in help uptime mem ebreak 'run hello' 'run fault' 'run spin' '\003' mem; do printf '%b\r' "$c"; sleep 0.4; done; printf 'shutdown\r'; sleep 2) \
  | timeout 20 qemu-system-riscv64 -machine virt -smp 1 -m 128M -nographic -bios default -kernel zig-out/bin/kernel
```

四种模式下 `hello` 正常退出、`fault` 被 `load_page_fault` 杀掉（`stval=0x80200000`）、`spin` 被 Ctrl-C 杀掉，前后两次 `mem` 的数字相同，`shutdown` 退出码 0。完整的期望输出见 [testing.md](../testing.md#期望的输出)。

### 边界情况：临时用户程序

以下程序都是临时加进 `build.zig` 的 `user_programs` 测试的，测完已删除。四种优化模式都跑过。

**`t_sys`**：`write` 的各种边界、不存在的调用号。

```zig
const std = @import("std");
const sys = @import("sys");
var page_buf: [8192]u8 align(4096) = undefined;
pub fn main() u8 {
    // 跨越栈顶：最后 4 个字节有效，超出 0x8000_0000 的部分无效
    const top: [*]const u8 = @ptrFromInt(0x8000_0000 - 4);
    @memcpy(@as([*]u8, @ptrFromInt(0x8000_0000 - 4))[0..4], "abcd");
    const r = sys.write(top[0..10]);
    sys.print("\npartial write -> {any}\n", .{r});
    // 长度让地址空间溢出
    const r2 = sys.write(top[0 .. std.math.maxInt(usize) - 0x8000_0000]);
    sys.print("huge write -> {any}\n", .{r2});
    // 零长度、几乎是空指针
    const r3 = sys.write(@as([*]const u8, @ptrFromInt(8))[0..0]);
    sys.print("empty write -> {any}\n", .{r3});
    // 跨页的大写入（.bss 里的两页）
    @memset(&page_buf, '.');
    page_buf[8191] = '\n';
    const r4 = sys.write(page_buf[4000..]);
    sys.print("cross-page write -> {any}\n", .{r4});
    // 不存在的系统调用
    const ret = asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [n] "{a7}" (@as(usize, 999)),
        : .{ .memory = true });
    sys.print("syscall 999 -> {d}\n", .{@as(isize, @bitCast(ret))});
    return 42;
}
```

修复后（见问题 3）的输出，四种模式相同：

```
abcd
partial write -> 4
abcdhuge write -> 4
empty write -> 0
................（4192 个点）
cross-page write -> 4192
syscall 999 -> -38
[proc] pid 1 (t_sys) exited with code 42
```

**`t_wx`**：往自己的代码段写。

```zig
pub fn main() u8 {
    const code: *volatile u16 = @ptrFromInt(@intFromPtr(&main) & ~@as(usize, 1));
    code.* = 0;
    return 0;
}
```

结果：`killed: store_page_fault at 0x40011472, stval=0x4001143e`（Debug）。

**`t_stack`**：无限递归，撞保护页。

```zig
fn recurse(n: usize) usize {
    var buf: [256]u8 = undefined;
    buf[n % 256] = @truncate(n);
    const v: *volatile u8 = &buf[0];
    return recurse(n + 1) + v.*;
}
pub fn main() u8 {
    return @truncate(recurse(0));
}
```

结果：`killed: store_page_fault at 0x40011460, stval=0x7fffbf00`。`stval` 落在保护页 `0x7fffb000..0x7fffc000` 里。

**`t_priv`**：U 模式读 S 模式的 CSR。

```zig
pub fn main() u8 {
    const s = asm volatile ("csrr %[r], sstatus" : [r] "=r" (-> usize));
    return @truncate(s);
}
```

结果：`killed: illegal_instruction at 0x40011446, stval=0x10002573`（`stval` 是指令编码）。非法指令异常没有委托给 S 模式，是 OpenSBI 转交过来的。

**`t_panic`**：用户程序 panic。

```zig
pub fn main() u8 {
    var x: u8 = 250;
    const p: *volatile u8 = &x;
    p.* += 10;
    return x;
}
```

结果：Debug/safe 模式下 `panic: integer overflow`，`exited with code 255`；fast/small 模式没有溢出检查，回绕成 4，`exited with code 4`。符合预期。

**`t_noperm`**：数据段没有任何权限的 ELF（验证问题 4 的修复）。程序内容复制自 `hello.zig`，配一个临时链接脚本 `user/t_noperm.ld`（由 `user/linker.ld` 把 `data PT_LOAD FLAGS(6)` 改成 `FLAGS(0)` 得到），`build.zig` 里临时让它用这个脚本：

```zig
program.setLinkerScript(b.path(if (std.mem.eql(u8, name, "t_noperm")) "user/t_noperm.ld" else "user/linker.ld"));
```

结果：`run: cannot load t_noperm: BadElf`，四种模式相同。

**Ctrl-C 的时机**：在 shell 里先按 Ctrl-C，再 `run hello`：`hello` 正常运行到结束，没有被误杀。

**泄漏**：每轮测试开头和结尾各执行一次 `mem`，数字完全相同（例如 Debug 下 `31470 of 31476`，临时程序多时内核更大，页数比平时少）。

### 进程内核栈的用量

临时插桩：进入 U 模式前把 `kernel_stack` 填成 `0xaa`，`run` 返回前从栈底找第一个不是 `0xaa` 的字节：

```zig
@memset(&kernel_stack, 0xaa);   // 在构造 TrapFrame 之前
// ...
const used = kernel_stack.len - (std.mem.findNone(u8, &kernel_stack, &.{0xaa}) orelse kernel_stack.len);
uart.print("  (kernel stack used: {d} bytes)\n", .{used});
```

结果：Debug 模式最多 3600 字节（杀进程时格式化输出那条路径），safe/fast/small 约 1 KiB。16 KiB 足够，没有改小。测完删掉。

## 发现的问题

### 问题 1：release 模式下用户程序是空的，入口地址为 0

- 现象：Debug 模式一切正常；safe/fast/small 模式下 `run` 任何程序都立即 `killed: instruction_page_fault at 0x0, stval=0x0`。构建输出里有：

  ```
  +- compile exe t_stack safe riscv64-freestanding-none failure
  error: warning(link): unexpected LLD stderr:
         ld.lld: warning: cannot find entry symbol _start; not setting start address
  ```

  `llvm-readelf` 看 release 版的用户 ELF：入口地址 0，没有任何可加载的段，只剩 `.riscv.attributes`、`.comment` 等。
- 原因：`_start` 最初写在 `user/sys.zig` 里，用 `comptime { @export(&start, .{ .name = "_start" }); }` 导出。Zig 按需分析，这个 `comptime` 块只有在 `sys.zig` 被分析到时才执行；程序文件里虽然写了 `const sys = @import("sys.zig");`，但这个声明本身没被引用时不会去解析 `@import`。没有入口，链接器的 gc-sections 把所有代码都当作没用的回收掉了。用 `zig build-obj` 单独编译验证过：Debug 和 small 模式下目标文件里都没有 `_start`。
  至于 Debug 模式的 `build-exe` 为什么碰巧导出了入口，没有深究。推测是 Debug 模式下编译器会提前分析根文件的 `panic` 声明（当时每个程序都写了 `pub const panic = sys.panic;`），从而间接分析了 `sys.zig`；safe 模式同样有安全检查却也失败了，说明不是“有没有安全检查”的区别。不管机制如何，结论是入口不能依赖被导入文件的 `comptime @export`。
- 修复：改成 crt0 结构，`user/start.zig` 作为每个用户程序的根文件，在里面 `export fn _start`、定义 `panic`、调用 `@import("program").main()`；`sys.zig` 改成普通模块。程序文件不再需要 `pub const panic = sys.panic;`。
- 确认：四种模式下用户 ELF 的入口都不为 0（Debug 下 `0x40011426`，small 下 `0x40000000`），所有程序正常运行。
- 附带发现：上面的链接器警告虽然以 `error:` 开头、构建树里标了 `failure`，`zig build` 的退出码却是 0，内核照样生成（在 [0006](0006-docs.md) 里专门复现确认过）。所以当时没有立刻注意到，直到运行时才发现。

### 问题 2：release 模式下进程结束后内核崩溃

- 现象：和问题 1 同时出现。用户程序因为入口为 0 被杀掉之后，内核接着 panic：

  ```
  [proc] pid 1 (t_sys) killed: instruction_page_fault at 0x0, stval=0x0
  !!! KERNEL PANIC: page.free: 0x41 was not handed out by the page allocator
  ```

  （fast 模式下是 `page.free: 0x0`；small 模式下碰巧没有 panic，但之后输入的几条 `run` 命令都没有任何输出，直到 `shutdown`。）
- 原因：当时进入 U 模式的写法是把裸函数转成 C 调用约定的函数指针来调用：

  ```zig
  const switchToUser: *const fn (*trap.TrapFrame, *Context) callconv(.c) void = @ptrCast(&switchToUserNaked);
  fn switchToUserNaked() callconv(.naked) noreturn { ... }
  ```

  裸函数被声明成了 `noreturn`（从它自己的函数体看确实不会走到结尾），但对调用方来说这个调用是会“返回”的：`switchBack` 恢复上下文后回到调用点。编译器看到被调用的是一个 `noreturn` 函数，就认为调用之后的代码永远不会执行，release 模式下把 `vm.activate(kernel_root)`、`defer` 里的 `destroyUserSpace` 等全部删掉了。`switchBack` 回来后执行的是垃圾代码，最终拿着错误的值调用了 `page.free`。Debug 模式下不做这种优化，所以没有暴露。
- 修复：改成在内联汇编里 `call` 裸函数，把调用者保存的寄存器（`ra`、`t0..t6`、`a0..a7`）和 memory 声明为 clobber。编译器只把它当作一段汇编，不再根据裸函数的声明做任何推断（[process.md](../process.md#switchtouser)）。
- 确认：四种模式下进程正常退出、被杀之后都能回到 shell，`mem` 前后一致。
- 提交前的核实：修复后起初在代码注释、README 和 AGENTS.md 里把原因写成了“LLVM 会从函数体推断裸函数不返回”。提交前专门做了实验：保留函数指针的写法，只把裸函数的返回类型改成 `void`，safe 和 small 模式下都工作正常。所以真正的原因是**声明成了 `noreturn`**，不是编译器自己推断的。提交前已经把三处的说法都改正了，代码仍然保留内联汇编的写法（它不依赖裸函数的签名）。

### 问题 3：部分越界的 write 整体失败

- 现象：`t_sys` 写 `[0x7ffffffc, 0x80000006)`（前 4 个字节有效）返回 `error.BadAddress`，而不是写出 4 个字节。
- 原因：`write` 每次最多复制 128 字节，一块可能跨过有效页和无效页的边界；`copyFromUser` 对整块要么全部成功、要么失败，前面有效的部分也就没有输出。和文档承诺的“返回已经写出的字节数”不符。
- 修复：每一块额外不超过当前页的末尾（`page.size - va % page.size`）。这样一块失败就说明这一页整个无效，之前的块都已完整输出。
- 确认：`partial write -> 4`，并且输出了 `abcd`；`huge write` 同样输出 `abcd` 并返回 4。

### 问题 4（安全）：没有权限的 ELF 段会变成指向用户数据的页表指针

- 现象：没有实际触发，是写完加载器后复查代码时发现的。
- 原因：加载器把程序头的 R/W/X 直接交给 `vm.map`。如果某个段的三个权限位都是 0，`map` 写出的页表项只有 V = 1，硬件会把它当成“指向下一级页表”的非叶子项，指向的却是一页用户可写的数据。构造这样一个 ELF，就能往那一页里写入任意的页表项，把任意物理内存映射进用户空间。W = 1、R = 0 的组合在规范里是保留的，同样不能出现。
- 修复：加载器要求每个段必须可读（`p_flags.R`），否则返回 `BadElf`；`vm.map` 断言 `(r or x) and (r or !w)`。
- 确认：`t_noperm` 得到 `run: cannot load t_noperm: BadElf`。

### 问题 5：Debug 模式下用户程序太大

- 现象：Debug 版 `hello` 的 ELF 有 336 KB，可加载内容约 351 KB；三个程序让内核的 `.rodata` 多出约 1 MB（临时程序多时 Debug 内核的 `.rodata` 达到 2.7 MB）。
- 原因：Debug 模式默认不做 gc-sections，整个 compiler_rt（`sin`、`log10`、`rem_pio2l` 这些软件浮点函数）、ubsan 运行时都被链接进来；另外还有 unwind 表（`.eh_frame` 约 37 KB）。用 `llvm-nm --size-sort` 看到最大的符号大多是 `compiler_rt.*` 和 `fmt.float.*`，按名字前缀统计有 469 个 `compiler_rt` 符号、46 个 `ubsan_rt` 符号。
- 修复：用户程序打开 `link_gc_sections`、设置 `.unwind_tables = .none`。
- 确认：可加载内容 351 KB → 125 KB（gc-sections）→ 91 KB（再去掉 unwind 表）；Debug 内核的 `.rodata` 从 2.7 MB 降到 847 KB（当时包含 8 个程序）。

### 开发中遇到的编译错误

- `unable to call function with calling convention 'naked'`：Zig 不允许直接调用裸函数。最初改用函数指针，后来因为问题 2 改成内联汇编。
- `unused argument in '...'`：`trapEntry` 和 `trapExit` 共用一个给 `comptimePrint` 的偏移量结构体，`trapEntry` 用不到其中的 `spp` 字段。先把各段汇编模板用 `++` 拼起来、统一调用一次 `comptimePrint`，再把 `spp` 改成内联汇编的 `"i"`（立即数）操作数。
- `@ptrCast increases pointer alignment`：`destroyUserSpace` 释放根页表时 `*[512]Pte` → `*align(4096) [4096]u8`，加 `@alignCast`。
- `file exists in modules 'sys' and 'program'`：改成 crt0 结构后，临时测试程序还在按路径 `@import("sys.zig")`。这次构建失败后跑的是旧的内核，一度看到了已经修复的问题 2 的症状，查明后改成 `@import("sys")`。

## 发布

这个工作会话被配置为推送到分支 `claude/focused-pascal-bc28g3`，和 AGENTS.md 的“直接推 `main`”冲突。当时先把三个提交（0003–0005）推到了那个分支，没有开 PR，并请维护者决定。维护者确认推 `main`，并要求提交者为维护者本人和 Claude，于是在 [0006](0006-docs.md#发布) 那一轮把三个提交的作者和提交者改为维护者（保留 `Co-Authored-By: Claude`），快进推送到 `main`，内容（tree）与改动前完全一致。本文开头的提交哈希是改写之后的。

## 遗留问题

- 一次只能运行一个进程，没有调度。
- 系统调用只有四个，没有 `read`、`sleep`、内存分配，也没有命令行参数。
- 内核和用户的 `gp`、`tp` 不隔离（内核不使用它们，见 [trap.md](../trap.md#trapentry)）。
