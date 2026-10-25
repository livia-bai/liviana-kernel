# 0001 最小内核

- 日期：2026-10-25
- 提交：`df54315` Add minimal RISC-V kernel written in Zig 0.17
- 涉及文件：`.gitignore`、`AGENTS.md`、`README.md`、`build.zig`、`linker.ld`、`src/main.zig`、`src/riscv.zig`、`src/sbi.zig`、`src/uart.zig`、`src/trap.zig`、`src/plic.zig`、`src/timer.zig`、`src/shell.zig`

> 这篇记录是在建立修改与验错记录制度（[0006](0006-docs.md)）时事后整理的，依据是提交内容本身和当时的 README。当时的验证过程没有留下记录。

## 目标

用 Zig 0.17 写一个能在 QEMU `virt` 上由 OpenSBI 引导、运行在 S 模式的最小 RISC-V 64 位内核。

## 改动

- `build.zig`：目标 riscv64-freestanding、rv64imac（不开 F/D），代码模型 `medany`，链接脚本，`zig build run` 启动 QEMU。
- `linker.ld`：从 `0x8020_0000` 开始，`.text.boot` 排在最前面，`.bss` 后面是 64 KiB 内核栈。
- `src/main.zig`：裸函数 `_start`（设栈、清 `.bss`、跳到 `kmain`）、`kmain`、panic 处理（`std.debug.FullPanic`）。
- `src/riscv.zig`：CSR 读写、开关中断、`wfi`。
- `src/sbi.zig`：SBI 版本查询、实现名、设置定时器、关机。
- `src/uart.zig`：NS16550A 驱动，轮询输出、中断输入，256 字节环形缓冲区，`std.Io.Writer` 适配。
- `src/trap.zig`：`TrapFrame`、陷阱入口汇编（`comptime` 生成保存/恢复寄存器的指令）、按 `scause` 分发，断点异常跳过、其他异常 panic。
- `src/plic.zig`：把串口中断（10 号）路由到 hart 0 的 S 模式上下文。
- `src/timer.zig`：每 10 ms 一次的时钟中断，时钟频率写死为 10 MHz。
- `src/shell.zig`：逐字符读取、回显、退格，命令 `help`、`uptime`、`ebreak`、`crash`、`shutdown`。
- `README.md`、`AGENTS.md`：说明和工作规则，包括 Zig 0.17 和旧版本的差别。

## 设计决策

（从代码和当时的 README 归纳）

- 不开 F/D 扩展，陷阱处理不保存浮点寄存器（和 Linux 内核的做法一样）。
- 主循环“关中断 → 查缓冲区 → `wfi` → 开中断”的顺序，避免检查和休眠之间到达的字符被延迟处理（[boot.md](../boot.md#主循环)）。
- 内核只在 S 模式运行，陷阱时直接在当前栈上压 `TrapFrame`（后来在 [0005](0005-user-mode-and-syscalls.md) 里为了支持 U 模式加了 `sscratch` 换栈）。

## 验证

没有留下记录。当时的 AGENTS.md 规定了用管道喂输入的 QEMU 测试方法，涉及内联汇编、MMIO、中断的改动要四种优化模式都跑。

## 发现的问题

事后（[0006](0006-docs.md) 写文档时）发现的：

- `trap.zig` 里 `regsAsm` 的注释说生成“31 条指令”，README 说保存/恢复寄存器共“62 条指令”。实际是 x1、x3..x31 共 30 个寄存器，存、取各 30 条，共 60 条。在 0006 里改正了注释和文档。
- README 里 `-Doptimize=small` 时“代码段约 7.6 KB”，到 [0003](0003-device-tree.md) 时实测已是约 7.9 KB（`.text` 0x1fba 字节），在 0004 里更新。

## 遗留问题

当时 README 列出的后续方向：解析设备树（→ 0003）、物理页分配器和 Sv39 分页（→ 0004）、U 模式和系统调用（→ 0005）、多核。
