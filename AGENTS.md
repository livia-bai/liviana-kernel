# AGENTS.md

用 Zig 写的最小 RISC-V 64 位内核，跑在 QEMU `virt` 机器上，由 OpenSBI 引导，内核运行在 S 模式。各文件的职责见 `README.md`。

## 环境

- 必须用 Zig **0.17.0**。0.17 的 API 和旧版差别很大，不要照搬旧教程或训练数据里的写法，拿不准时直接查 `$(dirname $(which zig))/lib/std` 里的源码。
- `qemu-system-riscv64`（Debian/Ubuntu 包名 `qemu-system-misc`，自带 OpenSBI）。

## 常用命令

```sh
zig build                              # 编译，产物在 zig-out/bin/kernel
zig build -Doptimize=small             # 可选 debug|safe|fast|small（0.17 起是小写）
zig build run                          # 在 QEMU 中启动，Ctrl-A X 退出
zig fmt --check build.zig src/ user/   # 格式检查
```

## 如何验证改动

没有单元测试，改完要在 QEMU 里实际跑一遍。用管道喂键盘输入，加超时防止卡住：

```sh
(sleep 1.5; for c in help uptime mem ebreak 'run hello' 'run fault' 'run spin' '\003' mem; do printf '%b\r' "$c"; sleep 0.4; done; printf 'shutdown\r'; sleep 2) \
  | timeout 20 qemu-system-riscv64 -machine virt -smp 1 -m 128M -nographic -bios default -kernel zig-out/bin/kernel
```

`shutdown` 成功时 QEMU 退出码为 0。`\003` 是 Ctrl-C，用来结束 `spin`。前后两次 `mem` 的空闲页数应该相同，否则就是运行用户程序漏了页。涉及内联汇编、MMIO、中断、页表或进出 U 模式的改动，四种 `-Doptimize` 模式都要跑：优化模式最容易暴露漏写 `volatile` 或 clobber 的问题。

## 约定

- 代码注释用中文，内核打印的信息用英文。
- 目标 CPU 是 rv64imac，不启用 F/D 扩展：内核里不要用浮点，陷阱处理也不保存浮点寄存器。
- CSR 读写统一走 `src/riscv.zig`，新用到的 CSR 加到 `Csr` 枚举里。
- `TrapFrame` 的布局和 `trap.trapEntry`、`trap.trapExit` 里的汇编是绑在一起的，改一边就要同步改另一边。`proc.Context` 和 `proc.contextAsm` 也一样。
- `sscratch` 的约定：在 U 模式运行时存内核栈顶，在内核里为 0（见 `trap.trapEntry` 的注释）。改陷阱入口时不能破坏它。
- `linker.ld` 里各段要保持 4 KiB 对齐，`vm.zig` 按 `__text_start`、`__rodata_start`、`__data_start`、`__kernel_end` 给内核设置页权限。
- 内存范围和时钟频率来自设备树（`src/dtb.zig`）；外设地址和 PLIC 中断号目前仍按 QEMU `virt` 写死，改的话要连注释一起改。
- 主循环检查输入缓冲区前要先关中断，再 `wfi`，然后开中断（见 `kmain` 里的注释）。不要把这个顺序改掉。
- 用户地址空间只能用 Sv39 根页表的第 1 项（`vm.user_base..vm.user_end`），内核映射不能放进这个范围，否则进程会和内核共用页表。
- 系统调用号和错误码定义在 `src/abi.zig`，内核和用户程序共用；新增系统调用时两边一起改，README 里的表也要更新。
- 系统调用和陷阱处理全程关中断执行。内核碰用户内存只能通过 `vm.copyFromUser` 这类先查页表的函数，不要打开 `sstatus.SUM` 直接解引用用户指针。
- 新的用户程序放在 `user/<名字>.zig`（提供 `pub fn main() u8`，用 `@import("sys")`），再把名字加到 `build.zig` 的 `user_programs` 里。

## 提交与推送

- 仓库只有一位维护者：提交直接推到 `main`，不开分支，也不开 PR。
- 提交信息里不要带 session 链接（`Claude-Session:` 之类的行）。

## Zig 0.17 的坑

- 用 `std.lang`，不用 `std.builtin`（已弃用）；用 `@backingInt` / `@fromBackingInt`，不用 `@intFromEnum` / `@enumFromInt`。
- 内联汇编的 clobber 写成结构体：`.{ .memory = true }`。
- 根文件里的 `pub const panic` 必须是 `pub`，因为 0.17 起 `@hasDecl` 只认公开声明。`std.debug.simple_panic` 在 0.17.0 里编译不过（#36986），不要用。
- 构建脚本里用 `addArtifactArg2`、`addPassthruArgs`。`b.args` 已经没有了。
- 裸函数（`callconv(.naked)`）不能直接调用。要在内联汇编里 `call`，并把调用者保存的寄存器声明为 clobber（见 `proc.switchToUser`）。转成函数指针来调也能编译，但签名必须如实：调用后还会回来的裸函数声明成 `noreturn`，release 模式下调用之后的代码会被删掉。
- `comptime { @export(...) }` 只有在所在文件被引用到时才会执行。入口符号要放在根文件里（用户程序的 `_start` 在 `user/start.zig`），否则 release 模式下可能根本没有导出。
