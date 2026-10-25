# 0003 解析设备树

- 日期：2026-10-25
- 提交：`8cd0230` Parse the device tree for memory and timebase
- 涉及文件：`src/dtb.zig`（新）、`src/main.zig`、`src/timer.zig`、`README.md`、`AGENTS.md`

## 目标

维护者的要求：“解析设备树、物理页分配加 Sv39 分页、U 模式加系统调用”。这是第一部分：从 OpenSBI 传来的设备树里得到内存大小和时钟频率，替换写死的值（当时 README“可以继续做的方向”的第一条）。

## 改动

- `src/dtb.zig`：FDT 解析器。`parse(addr) Error!Info`，返回第一段物理内存、`timebase-frequency`、保留区列表（设备树自身、内存保留块、`/reserved-memory` 的子节点）。
- `src/main.zig`：陷阱向量装好之后解析设备树，打印 `[ok] device tree: 128 MiB RAM at 0x80000000, timebase 10000000 Hz`；失败就 panic。
- `src/timer.zig`：`timebase_hz` 从常量改成 `init(hz)` 传入。
- README：新增“设备树”一节；AGENTS.md：外设地址写死的约定改为“内存和时钟频率来自设备树，外设地址仍写死”。

细节见 [devicetree.md](../devicetree.md)。

## 设计决策

- **不信任设备树的内容**：先只读文件头的 8 字节确定 `totalsize`，之后所有读取都通过带边界检查的函数，结构块和字符串块各自切成子切片。`Region.end()` 用饱和加法，离谱的数值不会让 Debug 模式下的内核因为整数溢出 panic。
- **`reg` 推迟到 `END_NODE` 再解析**：同一个节点里 `device_type` 可能排在 `reg` 后面。
- **用父节点的 `#address-cells`/`#size-cells`**：维护一个节点栈，每个节点记自己的这两个值，解析子节点的 `reg` 时取栈里的上一层。规范的默认值（2 和 1）放在 `Node` 的字段默认值里。
- **不分配内存**：这时页分配器还没初始化，所以节点栈（16 层）、保留区（16 段）都是固定大小的数组，超出就返回错误。
- **在陷阱向量之后解析**：解析出错（访问坏地址）时能得到带 `sepc`/`stval` 的 panic 信息。
- 只做维护者要求的内存和时钟频率；串口、PLIC 的地址仍然写死，因为串口要在解析设备树之前就能打印。

## 验证

### 环境

开始时容器里没有 Zig 和 QEMU：

- Zig 0.17.0：从 `https://ziglang.org/download/index.json` 取得官方 tarball 地址，下载后用 index 里给的 sha256（`1cbe9df9...`）校验，解压到 `/opt/zig`。
- QEMU：`apt-get install qemu-system-misc`，得到 QEMU 8.2.2（Ubuntu 包），自带 OpenSBI v1.3。
- 后来维护者把安装命令加进了环境的初始化脚本。

改动前先编译并运行了原有的内核，确认基线正常（`help`、`uptime`、`ebreak`、`shutdown` 都正常，退出码 0）。

### 步骤和结果

设备树解析和分页是一起开发的，之后拆成两个提交。这个提交单独验证过：把 `kmain` 里分页相关的几行临时去掉，四种优化模式各跑一遍：

```sh
for m in debug safe fast small; do
  zig build -Doptimize=$m
  (sleep 1.5; printf 'uptime\r'; sleep 0.4; printf 'shutdown\r'; sleep 2) \
    | timeout 20 qemu-system-riscv64 -machine virt -smp 1 -m 128M -nographic -bios default -kernel zig-out/bin/kernel \
    | grep -E "device tree|up "
done
```

四种模式结果相同：

```
SBI: OpenSBI, spec v1.0 | hart 0 | device tree at 0x87e00000
[ok] device tree: 128 MiB RAM at 0x80000000, timebase 10000000 Hz
up 1.33s (133 timer interrupts)
```

`uptime` 和等待时间吻合，说明从设备树读到的时钟频率是对的。退出码都是 0。

**保留区**：临时在 `kmain` 里打印解析出的保留区和 `__kernel_end`（和分页一起测的）：

```zig
for (info.reserved()) |r| uart.print("  reserved 0x{x}..0x{x}\n", .{ r.base, r.end() });
uart.print("  kernel_end 0x{x}\n", .{vm.kernelEnd()});
```

输出：

```
  reserved 0x87e00000..0x87e01516
  reserved 0x80000000..0x80040000
  reserved 0x80040000..0x80060000
  kernel_end 0x80275000
```

第一段是设备树自身（5398 字节），后两段是 OpenSBI 在 `/reserved-memory` 里登记的自己（和启动横幅里的 Domain0 Region 一致）。测完删掉了这段代码。

**对照 QEMU 的设备树**：用 `-machine virt,dumpdtb=virt.dtb` 导出、`dtc` 反编译，确认根节点 `#address-cells = #size-cells = 2`、`memory@80000000` 的 `reg` 是 128 MiB、`/cpus` 的 `timebase-frequency = <0x989680>`（10000000）。

## 发现的问题

测试中没有发现问题。写代码时自查改掉的几处：

- `END_NODE` 的处理一开始写成了嵌套的 `if (node.reg) |reg| if (depth >= 2) {...};`，改成更直白的写法。
- `addReservedReg` 在 `#address-cells + #size-cells == 0` 时会无限循环，加了提前返回。
- `Region.end()` 改成饱和加法（见上）。

提交时 README 里 small 模式“代码段约 7.6 KB”的数字已经不准（实测 `.text` 0x1fba 字节，约 7.9 KB），在 [0004](0004-page-allocator-and-sv39.md) 里更新。

## 遗留问题

- 只用第一段内存。
- 外设地址和中断号仍然写死（[devicetree.md](../devicetree.md#扩展)）。
