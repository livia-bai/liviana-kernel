# AGENTS.md

用 Zig 写的最小 RISC-V 64 位内核，跑在 QEMU `virt` 机器上，由 OpenSBI 引导，内核运行在 S 模式，用户程序运行在 U 模式。

详细文档在 [docs/](docs/README.md)，里面有“源码文件 → 文档”的对照表。改某个文件之前，先读它对应的文档；想知道一段代码为什么写成这样，先查 [docs/changes/](docs/changes/README.md)。

本文说的**涉及内核的改动**，指改了 `src/`、`user/`、`build.zig`、`linker.ld`、`user/linker.ld` 中任何一个的改动。只改文档（README.md、AGENTS.md、`docs/`）、开发脚本（`tools/`）或者做仓库操作（分支、提交作者等）的不算。QEMU 验证和修改记录都只针对涉及内核的改动。

## 环境

- 必须用 Zig **0.17.0**。0.17 的 API 和旧版差别很大，不要照搬旧教程或训练数据里的写法，拿不准时直接查标准库源码（路径见 `zig env` 输出里的 `std_dir`）。和旧版的差别、踩过的坑见 [docs/zig-0.17.md](docs/zig-0.17.md)。
- `qemu-system-riscv64`（Debian/Ubuntu 包名 `qemu-system-misc`，自带 OpenSBI）。
- 可选：`gdb-multiarch`（调试）、`device-tree-compiler`（`dtc`，看设备树）、`llvm-readelf`/`llvm-objdump`（看 ELF）。用法见 [docs/testing.md](docs/testing.md#调试工具)。

## 常用命令

```sh
zig build                              # 编译，产物在 zig-out/bin/kernel
zig build -Doptimize=small             # 可选 debug|safe|fast|small（0.17 起是小写）
zig build run                          # 在 QEMU 中启动，Ctrl-A X 退出
zig build run -- -d int -D q.log       # -- 之后的参数传给 QEMU
zig fmt --check build.zig src/ user/   # 格式检查
python3 tools/check_links.py           # 检查文档里的相对链接和锚点，必须 0 broken
```

## 如何验证改动

按改动的范围：

| 改了什么 | 必须做的检查 |
| --- | --- |
| 涉及内核（见开头的定义） | `zig fmt --check`；构建输出为空；在 QEMU 里跑下面的标准测试脚本，需要时四种模式都跑 |
| 文档（任何 Markdown 文件） | `python3 tools/check_links.py` 必须 `0 broken`；文档里新写的命令、输出要实际跑过 |
| `tools/` 里的脚本 | 实际运行一遍脚本，包括故意构造出错的情况，确认它能报出来 |
| 仓库操作 | 操作前后核对状态（比如删分支前确认内容已经在 `main` 上） |

不涉及内核的改动不需要编译和跑 QEMU。

涉及内核的改动没有单元测试，改完要在 QEMU 里实际跑一遍。用管道喂键盘输入，加超时防止卡住：

```sh
(sleep 1.5; for c in help uptime mem ebreak 'run hello' 'run fault' 'run spin' '\003' mem; do printf '%b\r' "$c"; sleep 0.4; done; printf 'shutdown\r'; sleep 2) \
  | timeout 20 qemu-system-riscv64 -machine virt -smp 1 -m 128M -nographic -bios default -kernel zig-out/bin/kernel
```

- `shutdown` 成功时 QEMU 退出码为 0；124 是超时（内核 panic 停机或卡住）。`\003` 是 Ctrl-C，用来结束 `spin`。
- 前后两次 `mem` 的空闲页数必须相同，否则就是运行用户程序漏了页。
- 构建输出必须是空的。链接器的警告会以 `error: warning(link): ...` 的形式出现，但 `zig build` 的退出码仍是 0，只看退出码会漏掉。
- 涉及内联汇编、MMIO、中断、页表、陷阱、进出 U 模式的改动，**四种 `-Doptimize` 模式都要跑**：release 模式最容易暴露漏写 `volatile`、clobber，或者 `noreturn` 写错的问题。
- 新功能和 bug 修复还要针对性地测边界情况（临时用户程序、临时插桩，测完删掉）。方法、期望输出的逐项含义、调试工具和症状速查表见 [docs/testing.md](docs/testing.md)。

## 约定

通用：

- 代码注释和文档用中文，内核和用户程序打印的信息用英文。
- 目标 CPU 是 rv64imac，不启用 F/D 扩展：不要用浮点，陷阱处理也不保存浮点寄存器。
- CSR 读写统一走 `src/riscv.zig`，新用到的 CSR 加到 `Csr` 枚举里。
- 内存范围和时钟频率来自设备树（`src/dtb.zig`）；外设地址和 PLIC 中断号仍按 QEMU `virt` 写死，改的话要连注释一起改。

绑在一起、改一边就要同步改另一边的：

- `trap.TrapFrame` 的布局 ↔ `trap.trapEntry`、`trap.trapExit` 的汇编 ↔ `proc.run` 构造初始 `TrapFrame` ↔ `syscall.dispatch` 读参数的下标（[docs/trap.md](docs/trap.md#trapframe)）。
- `proc.Context` ↔ `proc.contextAsm`（[docs/process.md](docs/process.md#进出-u-模式)）。
- `linker.ld` 里各段的 4 KiB 对齐和 `__text_start`、`__rodata_start`、`__data_start`、`__kernel_end` ↔ `vm.init` 设置的页权限（[docs/boot.md](docs/boot.md#链接脚本)）。
- `user/linker.ld` 的页对齐、可读的段 ↔ `proc.loadSegment` 的检查。
- `src/abi.zig` 同时被内核和用户程序使用：新增系统调用时 `abi.zig`、`syscall.zig`、`user/sys.zig`、[docs/syscalls.md](docs/syscalls.md) 一起改。

不能破坏的不变量：

- `sscratch`：在 U 模式运行时存进程内核栈顶，在内核里为 0（[docs/trap.md](docs/trap.md#sscratch-约定)）。
- 陷阱处理和系统调用全程关中断执行（[docs/trap.md](docs/trap.md#中断开关不变量)）。
- 主循环检查输入缓冲区前要先关中断，再 `wfi`，然后开中断（[docs/boot.md](docs/boot.md#主循环)）。
- 用户地址空间只能用 Sv39 根页表的第 1 项（`vm.user_base..vm.user_end`），内核映射不能放进这个范围（[docs/paging.md](docs/paging.md#用户地址空间)）。
- 内核碰用户内存只能通过 `vm.copyFromUser` 这类先查页表的函数，不要打开 `sstatus.SUM` 直接解引用用户指针（[docs/syscalls.md](docs/syscalls.md#访问用户内存)）。
- 页表叶子必须可读或可执行，可写必须可读；ELF 加载器拒绝不可读的段（[docs/process.md](docs/process.md#elf-加载器)）。

用户程序：放在 `user/<名字>.zig`，提供 `pub fn main() u8`，用 `@import("sys")`（不是 `"sys.zig"`），再把名字加到 `build.zig` 的 `user_programs` 里（[docs/user-programs.md](docs/user-programs.md#写一个新程序)）。

## 文档

- 改了代码，就同步改 [docs/](docs/README.md) 里对应的文档（对照表在 `docs/README.md`）；新增源码文件要加进对照表。
- README.md 只放简介、运行方法、shell 命令和文档索引，细节写进 `docs/`。
- 改了任何 Markdown 文件都要跑 `python3 tools/check_links.py`，输出必须是 `0 broken`（[docs/testing.md](docs/testing.md#必做的检查)）。
- 文档里写的命令、输出、数字、结论必须是实际验证过的；没验证的推测要明确写“推测”。写文档时发现之前的说法有错，改掉并写明改了什么：涉及内核的改动写在这次的修改记录里，只改文档的提交写在提交信息里。

## 修改与验错记录

每一次涉及内核的改动都要在 [docs/changes/](docs/changes/README.md) 里写一篇记录，和代码放在**同一个提交**里。

- **哪些要写**：涉及内核的改动（见开头的定义）。
- **哪些不写**：只改文档、开发脚本，以及仓库方面的操作。这类提交按“如何验证改动”里对应的那一行检查，但不写记录。
- **文件名**：`NNNN-简短英文描述.md`，编号接着最后一篇往下排，四位数。
- **索引**：在 `docs/changes/README.md` 的索引表里加一行。
- **内容**：按 `docs/changes/README.md` 末尾的模板写，必须包括：
  - 目标：维护者的原始要求。
  - 改动：按文件列出。
  - 设计决策：为什么这样做，考虑过但没选的做法。
  - 验证：环境（Zig、QEMU、OpenSBI 版本）、实际运行的命令、每种优化模式的结果、关键输出。临时测试代码也贴进来，方便以后重复。
  - 发现的问题：验证过程中发现的**每一个**问题，包括自己写错又改掉的地方，各写现象（原样贴报错或输出）、根本原因、修复、怎么确认修好了。没有发现问题也要写明测了哪些情况。
  - 遗留问题。
- **提交哈希**：写记录时还没有这次提交的哈希，写“本记录对应的提交”；之后的下一次提交（不管是不是涉及内核）顺手把哈希补上（索引表里也补上）。
- 记录写的是当时的事实，以后不要回头改写结论；后来发现记录里有错，在旧记录里加一句注，写明错在哪里、正确的是什么。如果是在某次涉及内核的改动里发现的，也在那次的记录里说明，注里指向它。

## 提交与推送

- 仓库只有一位维护者：提交直接推到 `main`，不开分支，也不开 PR。
- 提交的作者和提交者都用维护者本人（照 `git log` 里已有提交的作者设置 `git config user.name` / `user.email`），提交信息末尾保留 `Co-Authored-By: Claude ...` 一行。
- 提交信息里不要带 session 链接（`Claude-Session:` 之类的行）。
- 推送前按“如何验证改动”的表格做完对应的检查；涉及内核的改动，修改记录已经写好。

## Zig 0.17 的坑（摘要）

完整列表和原因见 [docs/zig-0.17.md](docs/zig-0.17.md)。

- 用 `std.lang`，不用 `std.builtin`；用 `@backingInt` / `@fromBackingInt`，不用 `@intFromEnum` / `@enumFromInt`。
- 内联汇编的 clobber 写成结构体：`.{ .memory = true }`。
- 根文件里的 `pub const panic` 必须是 `pub`。`std.debug.simple_panic` 在 0.17.0 里编译不过（#36986）。
- 构建脚本里用 `addArtifactArg2`、`addPassthruArgs`，`b.args` 已经没有了。
- 裸函数不能直接调用：在内联汇编里 `call`，并声明调用者保存的寄存器为 clobber；如果转成函数指针调用，会返回的裸函数不能声明成 `noreturn`。
- 入口符号要在根文件里导出；写在被导入文件里的 `comptime { @export(...) }` 不一定会执行。
- 一个文件在一次编译里只能属于一个模块。
