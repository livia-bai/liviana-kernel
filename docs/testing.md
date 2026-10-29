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
| `src/dtb.zig` | 用测试里的 `TestFdt` 按 FDT 格式拼一份设备树，检查解析出的内存、时钟频率、保留区、hart 列表（`reg` 写在 `device_type` 前面的也算，被禁用的 cpu 节点和 `cpu-map` 不算）；截断、魔数不对、缺少时钟频率时返回错误 |
| `src/page.zig` | 先分配低地址、分配时清零、跳过保留区、内存用完时报 `OutOfMemory` |
| `src/vm.zig` | 能用大页时用大页（比较用掉的页表数）；`copyFromUser` 只读得到 U 模式可读的用户页，`copyToUser` 只写得进 U 模式可写的页，`checkUser` 检查整个范围（跨页、溢出、长度 0）；`cloneUserSpace` 复制内容和权限、两边互不影响；`growUser`/`shrinkUser` 按页映射和释放、跨 2 MiB 时页表也释放、内存不够时不留下半截；释放用户空间后不漏页 |
| `src/proc.zig` | 加载真正的用户程序 `hello`（`build.zig` 把用户程序的 ELF 也交给了单元测试）；拒绝截断、魔数不对、不是 RISC-V、程序头越界、没有权限的段；命令行参数在栈顶的布局（16 字节对齐、指向正确的字节、没有参数时 `sp` 是栈顶）和堆的起点；`wakeup` 只叫醒睡在同一个通道上的进程；`kill` 只做标记、叫醒在睡的进程、只记第一次的原因、拒绝 init 和不存在的 pid；`wait` 只找自己的子进程、按 pid 挑，找到的 zombie 拿着锁返回；`reparent` 把子进程交给 init 并叫醒它；测完所有进程锁都放开了；`setfg` 检查 pid，Ctrl-C 找的是前台进程和它的子孙；`fill` 换掉除了锁以外的所有字段 |
| `src/abi.zig` | 系统调用返回值和错误码的互相转换 |
| `src/spinlock.zig` | 拿锁、放锁、`holding`、记录拿着几把锁 |
| `src/pipe.zig` | 管道不需要等待的路径：环形缓冲区回绕、有多少读多少、坏地址时数据不动、写端关了读到结尾、读端关了写返回 `BrokenPipe`、两端都关了释放 |
| `src/file.zig` | `dup` 加引用、最后一个 `close` 才关掉管道；文件表满了 `openPipe` 失败且不漏 |

为什么页表能在主机上测：内核对物理内存做了恒等映射，页表里的地址就是能直接用的指针。测试拿一块按 4 KiB 对齐的数组交给页分配器当作“物理内存”，页表就建在这块数组里，代码不用改。只有 `vm.activate` 这类写 CSR 的函数不能在主机上调用，测试也不会用到它们：Zig 只编译被用到的函数，所以这些文件里的 RISC-V 内联汇编不影响在主机上编译。例外是被测的函数在不会走到的路径上调用了它们：管道的读写在等待时调用 `proc.sleep` → `proc.sched`（读 `sstatus`、切换上下文），测试只走不需要等待的路径，但 `sched` 照样要编译。所以 `sched` 开头在主机上直接 `@panic`（编译期判断，不是 RISC-V 时后面的汇编不会被编译），`Spinlock.acquire` 在主机上不检查 `sstatus`。

## QEMU 测试（tools/qemu_test.py）

```sh
python3 tools/qemu_test.py --changed      # 只跑和还没提交的改动有关的用例（平时用这个）
python3 tools/qemu_test.py                # 全部用例，safe 模式，单核和 4 核各一遍，约 20 秒
python3 tools/qemu_test.py shell fork     # 只跑指定的用例
python3 tools/qemu_test.py --all-modes    # debug、safe、fast、small 四种模式都跑
python3 tools/qemu_test.py --smp 8        # 只用 8 个 hart 跑（可以给几个：--smp 2 --smp 8）
python3 tools/qemu_test.py --list         # 列出用例和它们覆盖的文件
```

每种模式只构建一次（带上 `user/tests/` 里的测试程序），然后对每个 hart 数（默认 `-smp 1` 和 `-smp 4`）各启动一次 QEMU，等提示符出现再一条条输入命令、检查输出。不管跑哪些用例，都会检查启动日志（包括 `[ok] N harts running` 里的 N 等于 `-smp` 给的数）；结束时还要求前后两次 `mem` 的空闲页数相同（不能漏页）、`shutdown` 后 QEMU 的退出码为 0、输出里没有 `KERNEL PANIC`。

单核、多核都要跑：多核时进程真的同时在跑，加锁的错误才会暴露出来；单核时所有进程只能轮流用一个 hart，“等别的进程让出 CPU”的路径（时间片轮转、调度器空转时的 `wfi`）才走得到。有的检查要按 hart 数写：`ps` 里死循环的后台进程，单核时是 `runnable`，多核时可能是 `running`；`ps` 可能正好看到 shell 刚 `fork` 出来、还没 `exec` 的子进程（名字还是 `sh`，父进程是 shell），所以认 shell 时看的是“父进程是 init 的那个 `sh`”。

| 用例 | 做什么 | 覆盖的文件 |
| --- | --- | --- |
| `shell` | `help`、`uptime`、不认识的命令、`run` 不带参数和找不到的程序 | 只由核心文件触发 |
| `interrupts` | `spin` 在前台死循环 0.5 秒，时钟中断至少来 10 次（`uptime` 的差），Ctrl-C 能结束它；在 shell 里按的 Ctrl-C 不会误杀下一个程序 | `src/timer.zig`、`src/sbi.zig`、`src/plic.zig`、`user/spin.zig` |
| `user` | `hello`（系统调用、拒绝内核指针）、`fault`（读内核内存被杀）、`t_panic`、`t_time` | `user/linker.ld` 和这几个程序 |
| `sched` | 两个后台 `spin` 死循环时，前台的 `hello`、`t_sleep` 照样跑完；0.5 秒里两个 `spin` 各自至少拿到 5 个 tick（`ps` 的 `TICKS`），状态是 `runnable` 或 `running`；`ps` 里 init 是 pid 1、在睡，sh 是它的子进程、在运行；Ctrl-C 只结束前台进程，也能结束睡在 `sleep` 里的前台进程；后台的 `ticker` 在 `ps` 里是 `sleeping`；`kill` 正常的、不存在的、缺参数的 pid 和 init；开满进程表后再 `run` 报 `too many processes` | `src/timer.zig`、`user/spin.zig`、`user/ticker.zig`、`user/hello.zig`、`user/tests/t_sleep.zig` |
| `syscall` | `t_sys`：`write` 的各种边界情况、不存在的调用号 | `user/tests/t_sys.zig` |
| `fork` | `t_fork`（自己检查 37 项，见下文）；`t_read` 分几次读完一行，睡在 `read` 里时按 Ctrl-C 能结束它；杀掉 shell 后 init 重新启动一个 | `user/hello.zig`、`user/tests/t_fork.zig`、`user/tests/t_read.zig` |
| `protection` | `t_wx`、`t_stack`、`t_priv`、`t_fp`、`t_noperm`：硬件和加载器的各种保护 | `user/linker.ld`、对应的测试程序 |
| `args` | shell 按空格拆参数（多个空格算一个），`t_args` 看到的 argc、argv、退出码；`echo` 带参数、不带参数；超过 16 个参数时 shell 报错；`t_args check`（自己检查 11 项） | `user/echo.zig`、`user/tests/t_args.zig` |
| `pipe` | `t_pipe`（自己检查 31 项）；shell 的管道：`echo \| wc`、`echo \| cat \| cat \| wc`、`t_args \| wc` 的结果，找不到的程序、空的一段、超过 4 个程序时报错；后台管道；对 `cat \| wc` 按 Ctrl-C 杀掉三个进程（组长、cat、wc），之后 `ps` 里没有剩下的；对 `cat \| wc` 输入 `abc` 再按 Ctrl-D，wc 打印 `0 1 3` | `src/pipe.zig`、`user/echo.zig`、`user/cat.zig`、`user/wc.zig`、`user/tests/t_pipe.zig`、`user/tests/t_args.zig` |
| `sbrk` | `t_sbrk`（自己检查 25 项） | `user/tests/t_sbrk.zig` |
| `smp` | `t_smp`（自己检查 17 项，见下文）；至少 3 个 hart 时，两个后台 `spin` 0.5 秒里加起来拿到的 tick 要多于 65 个（一个 hart 最多给 50 个，所以它们一定是同时在两个 hart 上跑的。实测 4 核时约 100 个） | `src/timer.zig`、`src/plic.zig`、`src/pipe.zig`、`user/spin.zig`、`user/tests/t_smp.zig` |

`build.zig`、链接脚本、`src/` 下的 `main.zig`、`riscv.zig`、`trap.zig`、`vm.zig`、`page.zig`、`dtb.zig`、`uart.zig`、`proc.zig`、`syscall.zig`、`abi.zig`、`spinlock.zig`、`hart.zig`、`file.zig`，以及 `user/` 下的 `start.zig`、`sys.zig`、`init.zig`、`sh.zig` 是核心文件：所有用例都要经过 init、shell 和系统调用，改了它们就跑全部用例；没登记过的内核文件也一样。只改了文档时，`--changed` 什么都不跑。

优化模式默认只用 safe：既有安全检查（整数溢出、越界），也开了优化。改了内联汇编、MMIO、中断、页表、进出 U 模式的代码时，再加 `--all-modes`：release 模式下编译器会更激进地利用类型系统的承诺，漏写的 `volatile`、clobber，写错的 `noreturn`，往往只在 release 模式下出问题。

失败时会列出没通过的检查，以及串口日志的位置（`zig-out/qemu-test/<模式>/serial-smp<N>.log`）。例如多核支持刚写好时，4 核下 `sched` 用例失败过一次，是测试脚本的问题（上面说的还没 `exec` 的子进程）：

```
FAIL  safe   smp4   sched       61 checks
    - ps: expected one running sh, child of init: [(1, 0, 'sleeping', 0, 'init'), (2, 1, 'running', 3, 'sh'), (3, 2, 'running', 115, 'spin'), (4, 2, 'running', 114, 'spin'), (9, 2, 'running', 0, 'sh')]
    serial log: zig-out/qemu-test/safe/serial-smp4.log
```

多核下的竞争不一定每次都出现。改了加锁、调度、进程生命周期的代码之后，最好多跑几遍、多试几种 hart 数，比如 `for i in 1 2 3 4 5; do python3 tools/qemu_test.py --mode debug --mode fast --smp 2 --smp 4 --smp 8; done`。

内核 panic 之后停机的行为（停机后不能忙等）没有自动测试：触发内核 panic 的 shell 命令随着 shell 搬到用户态一起去掉了。

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
| `t_sleep` | `sleep(200)` 前后的 `uptime()`；`sleep(0)`、`yield()` | 睡了 200..1000 ms（按 tick 算至少 200）；之后打印 `yield ok`，退出码 0 |
| `t_time` | U 模式执行 `rdtime` | 正常返回（`scounteren` 允许，见 [user-programs.md](user-programs.md#写一个新程序)） |
| `t_noperm` | 数据段 `FLAGS(0)` 的 ELF（用 `user/tests/noperm.ld` 链接） | `run: cannot load t_noperm: BadElf` |
| `t_fork` | `fork` 的返回值和地址空间复制；`wait` 的退出码、nohang、没有子进程、别人的子进程、坏的 options、写不进状态时不回收；`kill` 睡着的子进程、init、不存在的 pid；`setfg` 不存在的 pid；`exec` 不存在的程序、太长的名字、坏 ELF、坏指针，成功后 pid 不变；孤儿交给 init（孙进程的 `getppid()` 变成 1）；`fork` 到进程表满（`EAGAIN`）再全部回收；`procinfo`、`meminfo`、`listprog`、`read` 的坏参数和边界 | 每项失败打印 `FAIL: ...`；最后 `N checks, 0 failed`，退出码 0 |
| `t_read` | 每次最多 `read` 3 个字节，读到回车为止 | 输入 `hello world` 回车：`got "hello world" in N reads`，N ≥ 4 |
| `t_args` | 不带 `check` 时打印 argc、每个参数、总字节数，退出码是 argc。`t_args check`：`argv` 在栈顶那一页、16 字节对齐；17 个参数、1026 字节的参数返回 `ArgsTooLong`；`argv` 指针、参数指针指向内核时 `EFAULT`；长度为 0 的参数不检查指针；正好 16 个参数、1024 字节；没有参数。要看子进程收到的参数时，把它的 stdout 接到管道上读回来比较 | 每项失败打印 `FAIL: ...`；最后 `N checks, 0 failed`，退出码 0 |
| `t_pipe` | 基本读写、fd 编号最小；往读端写、从写端读是 `BadFd`；写端关了读到结尾；子进程写 5000 字节（比缓冲区大，要等）、父进程读完一字不差且读了至少 3 次；读的一方先睡下；读端关了写返回 `BrokenPipe`；写满之后读端才关，睡着的写者被叫醒、只写出一部分；睡在管道读、写里时被 kill；坏的 fd、坏指针；`dup` 到 fd 表满、`pipe` 在只剩一个空位时失败且不漏；`fork` 继承 fd、子进程关 stdout 不影响父进程 | 同上 |
| `t_smp` | 6 个工作进程同时（多核时在不同的 hart 上）各做 30 次 `fork`/`exit`/`wait`、各往同一个管道写 30 × 64 字节（父进程读完，按字节数对账）、各做 30 次 `sbrk` 长 3 页再缩回去，最后各留下一个交给 init 的孤儿；然后杀掉 3 个在 U 模式死循环的子进程（多核时它们正在别的 hart 上跑），`wait` 拿到的都是被杀的状态 | 每项失败打印 `FAIL: ...`；最后 `N checks, 0 failed`，退出码 0；前后 `mem` 一样 |
| `t_sbrk` | 堆一开始是空的；长 3 页多：返回原来的末尾、清零、按页映射（最后一页的页尾能写，下一页缺页）；内核通过管道读写堆里的内存；`fork` 复制堆；缩到页中间：这一页还在，后面的页缺页；再长回来是清零的；缩到起点下面、`minInt`、长进栈、`maxInt`、超过物理内存都失败，失败时不漏页、`brk` 不变；一个字节一个字节地长过页边界；全部还回去 | 同上；中间有几行 `killed: store_page_fault`，是故意去碰没映射的页的子进程 |

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

需要 `gdb-multiarch`（Debian/Ubuntu 的包名同名，不在默认环境里）。QEMU 加 `-s -S`：`-s` 在 1234 端口开 GDB 服务，`-S` 让 CPU 停在第一条指令等待连接。下面用 `-smp 1`，简单些；多个 hart 时 GDB 把每个 hart 当成一个线程（`info threads`、`thread N`，推测和 QEMU 别的架构一样，没有实际用过）。

```sh
qemu-system-riscv64 -machine virt -smp 1 -m 128M -nographic -bios default -kernel zig-out/bin/kernel -s -S &
gdb-multiarch -q -ex 'set architecture riscv:rv64' -ex 'file zig-out/bin/kernel' -ex 'target remote :1234'
```

之后就是普通的 GDB。实际用过的命令：

```
(gdb) break vm.init                 # Zig 的函数名是“文件名.函数名”：main.kmain、vm.init、proc.scheduler、syscall.dispatch
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
llvm-nm zig-out/bin/kernel | grep -E ' (__(text|rodata|data|bss|kernel)_|boot_stacks$)'   # 链接脚本里的符号和启动栈（Debug 模式）
llvm-objdump -d zig-out/bin/kernel | less   # 反汇编：确认内联汇编、编译器生成的代码
llvm-readelf -hl zig-out/user/hello       # 用户程序：入口地址、段布局
```

用户程序的入口地址是 0、或者没有 `LOAD` 段，说明 `_start` 没有被导出（见下表）。

### 设备树

```sh
qemu-system-riscv64 -machine virt,dumpdtb=virt.dtb -smp 4 -m 128M -nographic -bios default
dtc -I dtb -O dts virt.dtb
```

这是 QEMU 生成的原始版本。内核实际收到的版本（OpenSBI 改过）要用 GDB 从内存里导出来，见 [devicetree.md](devicetree.md#qemu-给的设备树长什么样)。

## 症状速查

都是这个项目里实际遇到过、或者按设计必然出现的情况：

| 症状 | 可能的原因 | 怎么查 |
| --- | --- | --- |
| `run` 一个程序就 `killed: instruction_page_fault at 0x0, stval=0x0` | 用户 ELF 的入口是 0：`_start` 没有导出（release 模式下尤其要注意） | `llvm-readelf -h` 看 `Entry point`；`_start` 必须在根文件 `user/start.zig` 里 |
| 进程结束后 `KERNEL PANIC: page.free: 0x.. was not handed out by the page allocator` | 切回调度器之后状态不对：典型的是调用 `switchContext` 之后的代码被优化掉了（单进程版本出过一次） | 只在 release 模式出现时，怀疑 `noreturn`、clobber、`volatile`；对照 `llvm-objdump -d` 看 `proc.scheduler` |
| 内核 `store_page_fault`，`stval` 在内核的代码或只读数据里 | 往只读段写了数据（W^X 生效了） | 用 `llvm-nm` 查 `stval` 落在哪个符号 |
| 内核 `load_page_fault`，`stval` 很小或是 0 | 空指针解引用 | `sepc` 对应的源码行：GDB 里 `info line *0x...` |
| 内核 `load/store_page_fault`，`stval` 在 `0x4000_0000..0x8000_0000` | 内核直接解引用了用户指针（`SUM` 是 0） | 改成 `vm.copyFromUser` / `vm.copyToUser` |
| 只有 OpenSBI 横幅，内核什么都没打印 | `_start` 不在 `0x8020_0000`，或者串口初始化之前就出错 | `llvm-readelf -S` 看 `.text` 起始；`-d int` 看第一个异常 |
| `cannot parse device tree at 0x...: <错误>` | 设备树格式不对，或者解析器有 bug | [devicetree.md](devicetree.md#错误) 的错误表；导出设备树用 `dtc` 看 |
| QEMU 卡住、`timeout` 返回 124 | 内核 panic 停机（看输出最后几行），或者死循环、陷阱风暴 | `-d int` 日志的最后几行 |
| `run` 完一个程序 `mem` 的数字变小了 | 有页没释放；或者有结束了的进程没人 `wait`（`ps` 里是 `zombie`） | 检查 `destroyUserSpace`、新加的分配路径；看 `ps` |
| `KERNEL PANIC: init exited` | init 结束了（被异常杀掉，或者 `main` 返回了） | 看 panic 前面打印的 `[proc] pid 1 (init) ...` |
| 内核 panic 停机后 QEMU 仍然占满一个 CPU 核 | `wfi` 被一直挂着的中断反复唤醒：停机前没有把 `sie` 清零 | 看 `kernelPanic` |
| `uptime` 比实际时间越走越慢 | 下一次时钟中断按“处理时的 `time` + 周期”预约，每个 tick 都丢掉了处理延迟 | 看 `timer.arm` |
| 改了代码，运行结果却和改之前一样（或者出现早已修复的问题） | 这次构建失败了，手动运行的 QEMU 跑的是上一次的内核 | 看构建输出；手动运行时用 `zig build && qemu-system-riscv64 ...`，或者直接用 `qemu_test.py` |
| `KERNEL PANIC on hart N: sched: 2 spinlocks held` | 拿着别的锁调用了 `sleep`/`yield`/`exit`（`sched` 只允许拿着进程自己的锁） | 看 panic 前在做什么；要拿着锁等待就用 `sleep(chan, lock)` |
| `KERNEL PANIC on hart N: acquire: lock X is already held by this hart` | 同一个 hart 重复拿同一把锁：比如拿着 `uart.lockOutput()` 又 `print`，或者 `wakeup` 时调用方拿着某个进程的锁 | 看 `X` 是哪把锁，对照 [process.md](process.md#锁) 的加锁顺序 |
| 多核时卡住不动，单核正常 | 推测是死锁：两个 hart 按相反的顺序拿两把锁（没有实际遇到过） | 对照 [process.md](process.md#锁) 的加锁顺序；GDB 看每个 hart 停在哪个 `acquire` 里 |
| 链接错误 `ld.lld: undefined symbol: a0`（或别的寄存器名） | 内联汇编里用 `"X"` 约束传了一个变量的地址（比如 `&boot_stacks`）：编译器先把地址算进一个寄存器，再把寄存器名代进 `la` 这类要符号的指令 | 把变量 `export` 出来，汇编里直接写符号名（[boot.md](boot.md#每个-hart-的启动栈)） |
| 编译错误 `unable to call function with calling convention 'naked'` | 直接调用了裸函数 | 在内联汇编里 `call`（[process.md](process.md#switchcontext)） |
| 编译错误 `unused argument in '...'` | `std.fmt.comptimePrint` 的参数结构体里有格式串用不到的字段 | 删掉多余字段，或者改用汇编操作数（如 `"i"` 约束） |
| 编译错误 `name shadows primitive 'u0'` | 变量名和原始类型重名：`u0`、`u1`、`i8` 这类“字母 u/i + 位宽”的名字都是整数类型 | 改名 |
| 编译错误 `file exists in modules 'sys' and 'program'` | 用户程序按路径 `@import("sys.zig")` | 改成 `@import("sys")` |
| 编译错误 `@ptrCast increases pointer alignment` | 指针转换后对齐要求变高 | 外面再套一层 `@alignCast(...)` |
| 构建输出里有 `error: warning(link): unexpected LLD stderr: ld.lld: warning: cannot find entry symbol _start`，构建树里对应的用户程序标着 `failure` | 原因同第一行。**注意**：实测这时 `zig build` 的退出码仍然是 0，内核照样生成，所以不能只看退出码，要看构建输出里有没有 `error:` | 同第一行 |
