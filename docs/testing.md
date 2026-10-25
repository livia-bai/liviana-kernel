# 测试与调试

这个项目的测试都在 QEMU 里跑：`tools/qemu_test.py` 自动构建内核、启动 QEMU、按提示符逐条输入命令，并判定输出是否符合预期。涉及内核的改动（改了 `src/`、`user/`、`build.zig` 或链接脚本）都要跑它。本文给出必做的检查、自动测试做了什么、回归测试程序、边界情况的测试方法、调试工具的用法，以及遇到过的症状和对应的原因。

## 必做的检查

按改动的范围决定（和 [AGENTS.md](../AGENTS.md#如何验证改动) 的表格一致）：

- **涉及内核的改动**：下面的第 1–3 条。改动里有 Markdown 的话，再加第 4 条。
- **只改文档**：只做第 4 条，另外文档里新写的命令和输出要实际跑过。不需要编译和跑 QEMU。
- **只改 `tools/` 里的脚本**：实际运行脚本，包括故意构造出错的情况，确认它能报出来。不需要编译和跑 QEMU（改的就是 `qemu_test.py` 的话，当然要跑它）。

1. **格式**：`zig fmt --check build.zig src/ user/`
2. **自动测试**：`python3 tools/qemu_test.py`，必须全部 `PASS`。默认四种优化模式各跑标准、回归两轮。只想快速看一眼时可以 `--mode debug`，但提交前要跑全部四种：改动涉及内联汇编、MMIO、中断、页表、进出 U 模式、陷阱处理时尤其不能省。
3. **新功能、修复的 bug**：针对性地测边界情况。能固定下来的，加成回归测试程序（见“回归测试程序”一节）；一次性的实验可以用临时代码，测完删掉。测了什么、结果如何写进 [changes/](changes/README.md) 的记录。
4. **文档链接**：改了任何 Markdown 文件（包括新增的修改记录），运行 `python3 tools/check_links.py`，必须输出 `0 broken`。它检查 README.md、AGENTS.md 和 `docs/` 下所有相对链接指向的文件是否存在，`#锚点` 是否对应目标文件里的某个标题（按 GitHub 生成锚点的规则：转小写、去掉标点、空格换成 `-`，同名标题依次加 `-1`、`-2`）。外部链接不检查。有错误时逐条打印、退出码为 1。例如在本文末尾加上 `[a](nope.md) [b](trap.md#没有这个标题)` 时的实际输出：

   ```
   docs/testing.md: missing file: nope.md
   docs/testing.md: missing anchor: trap.md#没有这个标题
   checked 215 links, 2 broken
   ```

   中文标题的锚点不好手算：标题 `PLIC（plic.zig）` 的锚点是 `#plicpliczig`（全角括号、反引号、`.` 都被去掉）。写好链接后跑一遍脚本最可靠。

为什么要四种模式都跑：release 模式下编译器会更激进地利用类型系统的承诺。漏写 `volatile` 的 MMIO 访问会被合并或删除；漏写的 clobber 会让编译器以为寄存器或内存没变；声明成 `noreturn` 的函数如果实际返回了，调用之后的代码已经被删掉了。这个项目在 U 模式的开发中就有两个 bug 只在 release 模式下出现（[changes/0005](changes/0005-user-mode-and-syscalls.md)）。反过来，Debug/safe 模式有安全检查，能暴露整数溢出、越界、对齐错误这类问题。

## 自动测试：tools/qemu_test.py

```sh
python3 tools/qemu_test.py                          # 四种模式 × 标准、回归两轮
python3 tools/qemu_test.py --mode debug             # 只测一种模式（可以写多次 --mode）
python3 tools/qemu_test.py --mode small --no-regression
```

输出（全部通过时，构建命中缓存的情况下约 10 秒，从零构建约 20 秒）：

```
PASS  debug  standard    23 checks    2.3s
PASS  debug  regression  31 checks    1.3s
PASS  safe   standard    23 checks    0.7s
PASS  safe   regression  31 checks    0.8s
PASS  fast   standard    23 checks    0.7s
PASS  fast   regression  30 checks    0.2s
PASS  small  standard    23 checks    1.4s
PASS  small  regression  30 checks    1.0s
```

全部通过时退出码为 0，否则为 1。fast/small 的回归轮少一项检查，是因为 `t_panic` 在没有安全检查的模式下只检查退出码。

### 每一轮做了什么

1. **构建**：`zig build -Doptimize=<模式> -p zig-out/qemu-test/<模式>-<轮次>`，回归轮再加 `-Dtest-programs=true`。退出码不为 0、或者有**任何输出**都算失败：链接器的警告会以 `error: warning(link): ...` 打印出来，但 `zig build` 仍然返回 0（见“症状速查”）。构建装到单独的目录，不影响 `zig-out/bin/kernel`；也因为每轮都先构建、构建失败就停下，不会出现“构建失败了却跑了旧内核”的情况。
2. **启动 QEMU**，等第一个提示符，检查启动日志里每一行 `[ok]` 和启动时的断点自检都在。
3. **逐条执行命令**：每发一条命令，就等下一个提示符 `> ` 出现，再检查这条命令的输出。不靠固定的 `sleep`，机器慢也不会错位；每条命令最多等 60 秒，启动最多等 60 秒。
4. **收尾**：再执行一次 `mem`，和开头那次比较空闲页数；`shutdown`，要求输出 `bye!`、QEMU 的退出码为 0；整个输出里不能有 `KERNEL PANIC`。

**标准轮**（普通构建，只有 `hello`、`fault`、`spin`）：

| 命令 | 检查 |
| --- | --- |
| `help` | 有 `run NAME` 这一行 |
| `uptime` | 格式正确 |
| `mem` | 记下空闲页数 |
| `ebreak` | `[trap] breakpoint at 0x..., skipping it` |
| `run hello` | pid 1、开机毫秒数、`write() refused a kernel pointer: BadAddress`、`exited with code 0` |
| `run fault` | `killed: load_page_fault at 0x..., stval=0x80200000` |
| `uptime`，`run spin`，转 0.5 秒后发 Ctrl-C，`uptime` | `spin` 被 `interrupted by Ctrl-C` 结束；前后两次 `uptime` 的计数至少差 10。`spin` 在 U 模式死循环期间内核只能靠中断拿回 CPU，所以这一项验证了时钟中断在 U 模式下照常发生（实测 0.5 秒约 49 次） |
| `mem`、`shutdown` | 见上面的“收尾” |

**回归轮**（`-Dtest-programs=true`，多了 `user/tests/` 里的程序）：

| 步骤 | 检查 |
| --- | --- |
| 在 shell 里先按 Ctrl-C，再 `run hello` | 正常退出，没有被之前的 Ctrl-C 误杀 |
| `run t_sys` | `partial write -> 4`（前面输出了 `abcd`）、`huge write -> 4`、`empty write -> 0`、4191 个点加换行后 `cross-page write -> 4192`、`syscall 999 -> -38`、退出码 42 |
| `run t_wx` | `killed: store_page_fault`，`stval` 在用户区 |
| `run t_stack` | `killed: store_page_fault`，`stval` 在保护页 `0x7fffb000..0x7fffc000` |
| `run t_priv` | `killed: illegal_instruction`，`stval` 是 `csrr rd, sstatus` 的编码（不比较 rd） |
| `run t_panic` | Debug/safe：`panic: integer overflow`、退出码 255；fast/small：退出码 4 |
| `run t_time` | `rdtime from U-mode = N`（N > 0）、退出码 0 |
| `run t_noperm` | `run: cannot load t_noperm: BadElf`，程序没有运行 |

### 失败时

失败的那一轮会列出每一条没通过的检查，并给出串口日志的位置：

```
FAIL  debug  standard    23 checks    1.9s
    - mem: free pages changed from (32052, 32057) to (31956, 32057) (leak?)
    serial log: zig-out/qemu-test/debug-standard/serial.log
```

`serial.log` 是那一轮的完整串口输出（`\r\n` 已换成 `\n`），每一轮都会保存，通过时也有。

写这个脚本时故意往内核里注入过故障，确认它能抓到（详见 [changes/0009](changes/0009-qemu-test.md)）：去掉 ELF 加载器的可读检查、不释放进程的内存、用户程序编译错误、定时器不再预约下一次中断，都会报 `FAIL`。

## 手动运行

想亲眼看输出、或者交互地试一些命令时，直接 `zig build run`，或者用管道喂输入：

```sh
zig build && (sleep 1.5; for c in help uptime mem ebreak 'run hello' 'run fault' 'run spin' '\003' mem; do printf '%b\r' "$c"; sleep 0.4; done; printf 'shutdown\r'; sleep 2) \
  | timeout 20 qemu-system-riscv64 -machine virt -smp 1 -m 128M -nographic -bios default -kernel zig-out/bin/kernel
echo "exit=$?"
```

- 开头的 `zig build &&` 保证构建失败时不会运行旧内核。
- 用管道往 QEMU 的标准输入喂键盘输入，每条命令之间等 0.4 秒，开头等 1.5 秒让 OpenSBI 和内核启动完。
- `printf '%b\r'` 会解释 `\003`，也就是 Ctrl-C，用来结束 `spin`。紧跟在 Ctrl-C 后面的 `\r` 会在 shell 里产生一个空行，无害。
- `timeout 20` 防止卡住。**退出码**：`shutdown` 成功时 QEMU 退出码是 0；`124` 表示超时，也就是内核 panic 停机了，或者卡住了。
- 输出里有非文本字节，用 `grep` 过滤时要加 `-a`，否则只会打印 `binary file matches`。

### 期望的输出

去掉 OpenSBI 横幅后（地址、页数、毫秒数随优化模式和时机变化）：

```
Hello from a Zig kernel on RISC-V!
SBI: OpenSBI, spec v1.0 | hart 0 | device tree at 0x87e00000
[ok] trap vector installed
[trap] breakpoint at 0x80215d34, skipping it
[ok] device tree: 128 MiB RAM at 0x80000000, timebase 10000000 Hz
[ok] page allocator: 32057 free pages (128228 KiB)
[ok] Sv39 paging enabled: kernel mapped 1:1, text r-x, rodata r--, data rw-
[ok] interrupts enabled: timer at 100 Hz, keyboard via UART + PLIC
Type 'help' for commands.
> help
...（命令列表）
> uptime
up 1.18s (118 timer interrupts)
> mem
32052 of 32057 pages free (128208 KiB), 4 KiB each
> ebreak
[trap] breakpoint at 0x80216562, skipping it
> run hello
Hello from U-mode! I am pid 1, the kernel has been up for 2360 ms.
write() refused a kernel pointer: BadAddress
[proc] pid 1 (hello) exited with code 0
> run fault
reading kernel memory at 0x80200000 from U-mode...
[proc] pid 2 (fault) killed: load_page_fault at 0x40011454, stval=0x80200000
> run spin
spinning in U-mode without making syscalls, press Ctrl-C to stop
^C
[proc] pid 3 (spin) killed: interrupted by Ctrl-C
>
> mem
32052 of 32057 pages free (128208 KiB), 4 KiB each
> shutdown
bye!
exit=0
```

逐项的含义：

| 看什么 | 说明什么 |
| --- | --- |
| 每一行 `[ok]` 都在，没有 `KERNEL PANIC` | 启动的每一步都成功 |
| 两行 `[trap] breakpoint` | 内核态异常能进能出（启动自检一次，`ebreak` 命令一次） |
| `uptime` 的计数大致等于秒数 × 100 | 时钟中断正常，频率来自设备树 |
| shell 能回显、能执行命令 | 串口中断、PLIC、环形缓冲区正常 |
| `hello` 输出了 pid 和毫秒数，`write()` 被拒绝 | U 模式、系统调用、用户指针检查正常 |
| `fault` 被 `load_page_fault` 杀掉，`stval=0x80200000` | U 位保护正常，用户程序的异常不会让内核 panic |
| `spin` 被 Ctrl-C 杀掉 | U 模式下中断正常，内核能从死循环的程序手里拿回 CPU |
| **两次 `mem` 的数字完全相同** | 三个程序（包括被杀掉的）占用的页都还回来了，没有泄漏 |
| `exit=0` | 能正常关机 |

## 回归测试程序

`user/tests/` 里的程序只在 `-Dtest-programs=true` 时编进内核（平时 `run` 列表里看不到它们），由 `qemu_test.py` 的回归轮运行。它们最初是开发 U 模式时的临时测试（[changes/0005](changes/0005-user-mode-and-syscalls.md)），后来固定成了回归测试（[changes/0009](changes/0009-qemu-test.md)）。

| 程序 | 测什么 | 期望结果 |
| --- | --- | --- |
| `t_sys` | `write` 的部分越界、长度溢出、零长度、跨页；不存在的调用号 | 部分写返回已写字节数；零长度返回 0；未知调用号返回 -38；退出码 42 |
| `t_wx` | 往自己的代码段写 | `store_page_fault`，进程被杀 |
| `t_stack` | 无限递归 | 撞到保护页：`store_page_fault`，`stval` 在 `0x7fffb000..0x7fffc000` |
| `t_priv` | U 模式执行 `csrr sstatus` | `illegal_instruction`，进程被杀 |
| `t_panic` | 整数溢出 | Debug/safe：`panic: integer overflow`，退出码 255；fast/small 没有检查，回绕成 4 |
| `t_time` | U 模式执行 `rdtime` | 正常返回（`scounteren` 允许，见 [user-programs.md](user-programs.md#写一个新程序)） |
| `t_noperm` | 数据段 `FLAGS(0)` 的 ELF（用 `user/tests/noperm.ld` 链接） | `run: cannot load t_noperm: BadElf` |

### 加一个回归测试

1. 新建 `user/tests/t_xxx.zig`（`const sys = @import("sys");`，`pub fn main() u8`）。程序的输出要能让脚本判断对错：打印确定的结果，或者用退出码表达。
2. 在 `build.zig` 的 `test_programs` 里加一项：`.{ .name = "t_xxx", .dir = "user/tests" }`；需要特殊的链接脚本就再写 `.linker_script = "..."`。
3. 在 `tools/qemu_test.py` 的 `regression_round` 里加上 `q.command("run t_xxx")` 和对它输出的检查。
4. 跑一遍 `python3 tools/qemu_test.py`，确认新检查通过；再故意把被测的内核行为改坏，确认它会失败，然后还原。
5. 更新本文的表格。

## 边界情况的临时测试

有些测试不适合固定下来（要改内核本身、或者只是一次性的测量），可以写临时代码，测完还原：

- 打印设备树解析出的保留区、`__kernel_end`，确认页分配器跳过了哪些页。
- 往 `kmain` 的代码页写一个字，确认 W^X 生效（应该得到 `store_page_fault`）。
- 测栈用量：运行前把栈填成 `0xaa`，运行后从栈底找第一个不是 `0xaa` 的字节。
- 故意把内核改坏，确认 `qemu_test.py` 能发现（[changes/0009](changes/0009-qemu-test.md) 里有例子）。
- 用 `git stash` 或者先复制一份原文件，保证能干净地还原；新建的文件 `git checkout` 还原不了，要手动删。
- **每次临时改动后都要确认构建成功（输出为空）再看运行结果。** 构建失败时 `zig-out/bin/kernel` 还是上一次的产物，手动运行 QEMU 时跑的是旧内核，看到的结果和这次的改动无关。这个项目里发生过两次：一次看到了早已修复的 bug 的症状，一次让实验结果无效（[changes/0005](changes/0005-user-mode-and-syscalls.md#开发中遇到的编译错误)、[changes/0006](changes/0006-docs.md#问题-2草稿里没核实就写下的说法)）。手动运行时写成 `zig build && qemu-system-riscv64 ...`；`qemu_test.py` 已经处理了这一点。

### 泄漏检查

`mem` 显示的空闲页数在运行用户程序前后应该完全相同，`qemu_test.py` 每一轮都检查。想知道程序运行时占了多少页，用 GDB 在 `proc.switchToUser` 处读 `page.free_pages`（见下文）。

## 调试工具

### QEMU 的陷阱日志

`-d int` 让 QEMU 记录每一次陷阱（包括 M 模式的），`-D` 指定日志文件：

```sh
qemu-system-riscv64 ... -kernel zig-out/bin/kernel -d int -D qemu.log
zig build run -- -d int -D qemu.log      # 通过构建系统运行时，-- 之后的参数会传给 QEMU
```

每一行形如：

```
riscv_cpu_do_interrupt: hart:0, async:0, cause:000000000000000d, epc:0x0000000040011454, tval:0x0000000080200000, desc=load_page_fault
```

- `async:1` 是中断，`async:0` 是异常；`cause` 是编号，`epc`、`tval` 对应 `sepc`/`mepc`、`stval`/`mtval`。
- 日志里也有 OpenSBI 自己的陷阱：启动时一串 `illegal_instruction`（`epc` 在 `0x8000_xxxx`，是 OpenSBI 在探测 CSR），每次 SBI 调用一行 `supervisor_ecall`，以及 M 模式的定时器中断。
- 用户程序的系统调用是 `desc=user_ecall`，可以用 `grep -c user_ecall qemu.log` 数一个程序做了多少次系统调用。
- 内核在开分页、进 U 模式之类的地方“一声不响地卡住”时，日志的最后几行通常就是答案（比如同一个地址反复缺页）。

### GDB

需要 `gdb-multiarch`（Debian/Ubuntu 的包名同名，不在默认环境里）。QEMU 加 `-s -S`：`-s` 在 1234 端口开 GDB 服务，`-S` 让 CPU 停在第一条指令等待连接。

```sh
qemu-system-riscv64 -machine virt -smp 1 -m 128M -nographic -bios default -kernel zig-out/bin/kernel -s -S &
gdb-multiarch -q -ex 'set architecture riscv:rv64' -ex 'file zig-out/bin/kernel' -ex 'target remote :1234'
```

之后就是普通的 GDB。实际用过的命令：

```
(gdb) break vm.init                 # Zig 的函数名是“文件名.函数名”：main.kmain、vm.init、proc.switchToUser、syscall.dispatch
(gdb) continue
(gdb) bt 3
#0  vm.init (memory=...) at src/vm.zig:73
#1  0x0000000080215ec2 in main.kmain (hartid=0, dtb_addr=2279604224) at src/main.zig:70
(gdb) print 'page.free_pages'       # 全局变量的名字里有点，要加单引号
$1 = 32020
(gdb) info registers scounteren     # CSR 也能读
(gdb) monitor info mem              # QEMU 监视器命令：当前 satp 下的所有映射（见 paging.md）
(gdb) x/2wx 0x87e00000              # 看内存（注意按小端显示）
(gdb) dump binary memory out.bin 0x87e00000 0x87e01516
(gdb) kill
```

- 只在 Debug 模式下有意义：release 模式的内核 ELF 不带符号表。
- 要和 shell 交互时，把喂输入的管道接在 QEMU 前面（`(sleep 2; printf 'run hello\r'; sleep 3) | qemu-system-riscv64 ... -s -S &`），GDB 断点设在想停的地方。
- 用户程序被 strip 过，没有符号；需要调试用户程序时可以临时去掉 `build.zig` 里的 `.strip = true`。
- 批处理模式（`-batch` 加一串 `-ex`）适合在脚本里取几个值，本仓库文档里的很多实测数字就是这样取得的。

### 查看 ELF

`llvm-readelf`、`llvm-objdump`、`llvm-nm`（或者 binutils 的 `riscv64-*-objdump` 等）：

```sh
llvm-readelf -S zig-out/bin/kernel          # 段的地址和大小：检查各段是否按页对齐、孤儿段落在哪里
llvm-readelf -l zig-out/bin/kernel          # 程序头：QEMU 按它加载
llvm-nm zig-out/bin/kernel | grep __        # 链接脚本里的符号（Debug 模式）
llvm-objdump -d zig-out/bin/kernel | less   # 反汇编：确认内联汇编、编译器生成的代码
llvm-readelf -hl zig-out/user/hello       # 用户程序：入口地址、段布局
```

用户程序的入口地址是 0、或者没有 `LOAD` 段，说明 `_start` 没有被导出（见下表）。

### 设备树

```sh
qemu-system-riscv64 -machine virt,dumpdtb=virt.dtb -smp 1 -m 128M -nographic -bios default
dtc -I dtb -O dts virt.dtb
```

这是 QEMU 生成的原始版本。内核实际收到的版本（OpenSBI 改过）要用 GDB 从内存里导出来，见 [devicetree.md](devicetree.md#qemu-给的设备树长什么样)。

## 症状速查

都是这个项目里实际遇到过、或者按设计必然出现的情况：

| 症状 | 可能的原因 | 怎么查 |
| --- | --- | --- |
| `run` 一个程序就 `killed: instruction_page_fault at 0x0, stval=0x0` | 用户 ELF 的入口是 0：`_start` 没有导出（release 模式下尤其要注意） | `llvm-readelf -h` 看 `Entry point`；`_start` 必须在根文件 `user/start.zig` 里 |
| 进程结束后 `KERNEL PANIC: page.free: 0x.. was not handed out by the page allocator` | `switchBack` 回到 `run` 之后状态不对：典型的是调用 `switchToUser` 之后的代码被优化掉了 | 只在 release 模式出现时，怀疑 `noreturn`、clobber、`volatile`；对照 `llvm-objdump -d` 看 `proc.run` |
| 内核 `store_page_fault`，`stval` 在内核的代码或只读数据里 | 往只读段写了数据（W^X 生效了） | 用 `llvm-nm` 查 `stval` 落在哪个符号 |
| 内核 `load_page_fault`，`stval` 很小或是 0 | 空指针解引用（`crash` 命令就是这样） | `sepc` 对应的源码行：GDB 里 `info line *0x...` |
| 内核 `load/store_page_fault`，`stval` 在 `0x4000_0000..0x8000_0000` | 内核直接解引用了用户指针（`SUM` 是 0） | 改成 `vm.copyFromUser` |
| 只有 OpenSBI 横幅，内核什么都没打印 | `_start` 不在 `0x8020_0000`，或者串口初始化之前就出错 | `llvm-readelf -S` 看 `.text` 起始；`-d int` 看第一个异常 |
| `cannot parse device tree at 0x...: <错误>` | 设备树格式不对，或者解析器有 bug | [devicetree.md](devicetree.md#错误) 的错误表；导出设备树用 `dtc` 看 |
| QEMU 卡住、`timeout` 返回 124 | 内核 panic 停机（看输出最后几行），或者死循环、陷阱风暴 | `-d int` 日志的最后几行 |
| `run` 完一个程序 `mem` 的数字变小了 | 有页没释放 | 检查 `destroyUserSpace`、新加的分配路径 |
| 改了代码，运行结果却和改之前一样（或者出现早已修复的问题） | 这次构建失败了，手动运行的 QEMU 跑的是上一次的内核 | 看构建输出；手动运行时用 `zig build && qemu-system-riscv64 ...`，或者直接用 `qemu_test.py` |
| 编译错误 `unable to call function with calling convention 'naked'` | 直接调用了裸函数 | 在内联汇编里 `call`（[process.md](process.md#switchtouser)） |
| 编译错误 `unused argument in '...'` | `std.fmt.comptimePrint` 的参数结构体里有格式串用不到的字段 | 删掉多余字段，或者改用汇编操作数（如 `"i"` 约束） |
| 编译错误 `file exists in modules 'sys' and 'program'` | 用户程序按路径 `@import("sys.zig")` | 改成 `@import("sys")` |
| 编译错误 `@ptrCast increases pointer alignment` | 指针转换后对齐要求变高 | 外面再套一层 `@alignCast(...)` |
| 构建输出里有 `error: warning(link): unexpected LLD stderr: ld.lld: warning: cannot find entry symbol _start`，构建树里对应的用户程序标着 `failure` | 原因同第一行。**注意**：实测这时 `zig build` 的退出码仍然是 0，内核照样生成，所以不能只看退出码，要看构建输出里有没有 `error:` | 同第一行 |
