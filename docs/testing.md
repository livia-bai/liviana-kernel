# 测试与调试

内核的测试分两层：

- **单元测试**（`zig build test`）：在你的电脑上直接运行，测不碰硬件的纯逻辑，每次只要几毫秒。
- **QEMU 测试**（`tools/qemu_test.py`）：在 QEMU 里启动内核、输入命令、检查输出，测只有在真的 CPU 上才看得到的东西。

两层各管一半：陷阱的进出汇编、进入 U 模式、中断、硬件的权限检查，单元测试都测不到；反过来，设备树解析器遇到坏数据会怎样，在 QEMU 里很难构造。

## 单元测试（zig build test）

```sh
zig build test                 # 没有输出就是全部通过
zig build test --summary all   # 显示通过了几个
```

入口是 `src/tests.zig`，它引用了下面这些文件，各文件末尾的 `test` 块就是测试：

| 文件 | 测什么 |
| --- | --- |
| `src/dtb.zig` | 用测试里的 `TestFdt` 按 FDT 格式拼一份设备树，检查解析出的内存、时钟频率、保留区；截断、魔数不对、缺少时钟频率时返回错误 |
| `src/page.zig` | 先分配低地址、分配时清零、跳过保留区、内存用完时报 `OutOfMemory` |
| `src/vm.zig` | 能用大页时用大页（比较用掉的页表数）；`copyFromUser` 只读得到 U 模式可读的用户页；释放用户空间后不漏页 |
| `src/proc.zig` | 加载真正的用户程序 `hello`（`build.zig` 把用户程序的 ELF 也交给了单元测试）；拒绝截断、魔数不对、不是 RISC-V、程序头越界、没有权限的段 |
| `src/abi.zig` | 系统调用返回值和错误码的互相转换 |

为什么页表能在主机上测：内核对物理内存做了恒等映射，页表里的地址就是能直接用的指针。测试拿一块按 4 KiB 对齐的数组交给页分配器当作“物理内存”，页表就建在这块数组里，代码不用改。只有 `vm.activate` 这类写 CSR 的函数不能在主机上调用，测试也不会用到它们：Zig 只编译被用到的函数，所以这些文件里的 RISC-V 内联汇编不影响在主机上编译。

## QEMU 测试（tools/qemu_test.py）

```sh
python3 tools/qemu_test.py --changed      # 只跑和还没提交的改动有关的用例（平时用这个）
python3 tools/qemu_test.py                # 全部用例，safe 模式，约 5 秒
python3 tools/qemu_test.py shell panic    # 只跑指定的用例
python3 tools/qemu_test.py --all-modes    # debug、safe、fast、small 四种模式都跑
python3 tools/qemu_test.py --list         # 列出用例和它们覆盖的文件
```

每种模式只构建一次（带上 `user/tests/` 里的测试程序），然后启动 QEMU，等提示符出现再一条条输入命令、检查输出。不管跑哪些用例，都会检查启动日志；结束时还要求前后两次 `mem` 的空闲页数相同（不能漏页）、`shutdown` 后 QEMU 的退出码为 0、输出里没有 `KERNEL PANIC`。

| 用例 | 做什么 | 覆盖的文件 |
| --- | --- | --- |
| `shell` | `help`、`uptime`、不认识的命令、`ebreak` | `src/shell.zig` |
| `interrupts` | `spin` 在 U 模式死循环 0.5 秒，时钟中断至少来 10 次，Ctrl-C 能结束它；在 shell 里按的 Ctrl-C 不会误杀下一个程序 | `src/timer.zig`、`src/sbi.zig`、`src/plic.zig`、`src/proc.zig`、`user/spin.zig` |
| `user` | `hello`（系统调用、拒绝内核指针）、`fault`（读内核内存被杀）、`t_panic`、`t_time` | `src/proc.zig`、`src/syscall.zig`、`src/abi.zig`、`user/` 的运行时和程序 |
| `syscall` | `t_sys`：`write` 的各种边界情况、不存在的调用号 | `src/syscall.zig`、`src/abi.zig`、`user/sys.zig` |
| `protection` | `t_wx`、`t_stack`、`t_priv`、`t_fp`、`t_noperm`：硬件和加载器的各种保护 | `src/proc.zig`、`user/linker.ld`、对应的测试程序 |
| `panic` | `crash` 之后检查 panic 信息，并检查停机后 1 秒内 QEMU 用掉的 CPU 时间不超过一半（读 `/proc`，只能在 Linux 上运行） | 只由核心文件触发 |

`build.zig`、链接脚本、`src/main.zig`、`riscv.zig`、`trap.zig`、`vm.zig`、`page.zig`、`dtb.zig`、`uart.zig` 是核心文件，改了它们就跑全部用例；没登记过的内核文件也一样。只改了文档时，`--changed` 什么都不跑。

优化模式默认只用 safe：既有安全检查（整数溢出、越界），也开了优化。改了内联汇编、MMIO、中断、页表、进出 U 模式的代码时，再加 `--all-modes`：release 模式下编译器会更激进地利用类型系统的承诺，漏写的 `volatile`、clobber，写错的 `noreturn`，往往只在 release 模式下出问题。

失败时会列出没通过的检查，以及串口日志的位置（`zig-out/qemu-test/<模式>/serial.log`，`panic` 用例是 `panic.log`）：

```
FAIL  safe   shell       4 checks
    - unknown command: expected /unknown command: nope/ in output:
      | nope
      | unknwon command: nope (try 'help')
      | > 
    serial log: zig-out/qemu-test/safe/serial.log
```

## 回归测试程序

`user/tests/` 里的程序只在 `-Dtest-programs=true` 时编进内核（`qemu_test.py` 会自动加上），平时 `run` 列表里看不到它们。

| 程序 | 测什么 | 期望结果 |
| --- | --- | --- |
| `t_sys` | `write` 的部分越界、长度溢出、零长度、跨页；不存在的调用号 | 部分写返回已写字节数；零长度返回 0；未知调用号返回 -38；退出码 42 |
| `t_wx` | 往自己的代码段写 | `store_page_fault`，进程被杀 |
| `t_stack` | 无限递归 | 撞到保护页：`store_page_fault`，`stval` 在 `0x7fffb000..0x7fffc000` |
| `t_priv` | U 模式执行 `csrr sstatus` | `illegal_instruction`，进程被杀 |
| `t_fp` | U 模式执行浮点指令 `fmv.d.x f1, a0`（手工编码） | `illegal_instruction`，`stval=0xf20500d3`（`sstatus.FS = Off`） |
| `t_panic` | 整数溢出 | Debug/safe：`panic: integer overflow`，退出码 255；fast/small 没有检查，回绕成 4 |
| `t_time` | U 模式执行 `rdtime` | 正常返回（`scounteren` 允许，见 [user-programs.md](user-programs.md#写一个新程序)） |
| `t_noperm` | 数据段 `FLAGS(0)` 的 ELF（用 `user/tests/noperm.ld` 链接） | `run: cannot load t_noperm: BadElf` |

### 加一个回归测试

1. 新建 `user/tests/t_xxx.zig`（`const sys = @import("sys");`，`pub fn main() u8`），用打印的内容或者退出码表达结果。
2. 在 `build.zig` 的 `test_programs` 里加一项：`.{ .name = "t_xxx", .dir = "user/tests" }`。
3. 在 `tools/qemu_test.py` 的某个用例函数里加上 `q.command("run t_xxx")` 和对输出的检查，并把这个文件加进那个用例覆盖的文件列表。
4. 能在主机上测的逻辑，优先写成单元测试。

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
| 内核 panic 停机后 QEMU 仍然占满一个 CPU 核 | `wfi` 被一直挂着的中断反复唤醒：停机前没有把 `sie` 清零 | `qemu_test.py panic` 会报 `busy-waiting?`；看 `kernelPanic` |
| `uptime` 比实际时间越走越慢 | 下一次时钟中断按“处理时的 `time` + 周期”预约，每个 tick 都丢掉了处理延迟 | 看 `timer.arm` |
| 改了代码，运行结果却和改之前一样（或者出现早已修复的问题） | 这次构建失败了，手动运行的 QEMU 跑的是上一次的内核 | 看构建输出；手动运行时用 `zig build && qemu-system-riscv64 ...`，或者直接用 `qemu_test.py` |
| 编译错误 `unable to call function with calling convention 'naked'` | 直接调用了裸函数 | 在内联汇编里 `call`（[process.md](process.md#switchtouser)） |
| 编译错误 `unused argument in '...'` | `std.fmt.comptimePrint` 的参数结构体里有格式串用不到的字段 | 删掉多余字段，或者改用汇编操作数（如 `"i"` 约束） |
| 编译错误 `name shadows primitive 'u0'` | 变量名和原始类型重名：`u0`、`u1`、`i8` 这类“字母 u/i + 位宽”的名字都是整数类型 | 改名 |
| 编译错误 `file exists in modules 'sys' and 'program'` | 用户程序按路径 `@import("sys.zig")` | 改成 `@import("sys")` |
| 编译错误 `@ptrCast increases pointer alignment` | 指针转换后对齐要求变高 | 外面再套一层 `@alignCast(...)` |
| 构建输出里有 `error: warning(link): unexpected LLD stderr: ld.lld: warning: cannot find entry symbol _start`，构建树里对应的用户程序标着 `failure` | 原因同第一行。**注意**：实测这时 `zig build` 的退出码仍然是 0，内核照样生成，所以不能只看退出码，要看构建输出里有没有 `error:` | 同第一行 |
