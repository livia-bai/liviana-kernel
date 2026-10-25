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
zig fmt --check build.zig src/         # 格式检查
```

## 如何验证改动

没有单元测试，改完要在 QEMU 里实际跑一遍。用管道喂键盘输入，加超时防止卡住：

```sh
(sleep 1.5; printf 'help\r'; sleep 0.3; printf 'uptime\r'; sleep 0.3; printf 'ebreak\r'; sleep 0.3; printf 'shutdown\r'; sleep 2) \
  | timeout 15 qemu-system-riscv64 -machine virt -smp 1 -m 128M -nographic -bios default -kernel zig-out/bin/kernel
```

`shutdown` 成功时 QEMU 退出码为 0。涉及内联汇编、MMIO 或中断的改动，四种 `-Doptimize` 模式都要跑：优化模式最容易暴露漏写 `volatile` 或 clobber 的问题。

## 约定

- 代码注释用中文，内核打印的信息用英文。
- 目标 CPU 是 rv64imac，不启用 F/D 扩展：内核里不要用浮点，陷阱处理也不保存浮点寄存器。
- CSR 读写统一走 `src/riscv.zig`，新用到的 CSR 加到 `Csr` 枚举里。
- `TrapFrame` 的布局和 `trap.trapEntry` 里的汇编是绑在一起的，改一边就要同步改另一边。
- 内存范围和时钟频率来自设备树（`src/dtb.zig`）；外设地址和 PLIC 中断号目前仍按 QEMU `virt` 写死，改的话要连注释一起改。
- 主循环检查输入缓冲区前要先关中断，再 `wfi`，然后开中断（见 `kmain` 里的注释）。不要把这个顺序改掉。

## 提交与推送

- 仓库只有一位维护者：提交直接推到 `main`，不开分支，也不开 PR。
- 提交信息里不要带 session 链接（`Claude-Session:` 之类的行）。

## Zig 0.17 的坑

- 用 `std.lang`，不用 `std.builtin`（已弃用）；用 `@backingInt` / `@fromBackingInt`，不用 `@intFromEnum` / `@enumFromInt`。
- 内联汇编的 clobber 写成结构体：`.{ .memory = true }`。
- 根文件里的 `pub const panic` 必须是 `pub`，因为 0.17 起 `@hasDecl` 只认公开声明。`std.debug.simple_panic` 在 0.17.0 里编译不过（#36986），不要用。
- 构建脚本里用 `addArtifactArg2`、`addPassthruArgs`。`b.args` 已经没有了。
