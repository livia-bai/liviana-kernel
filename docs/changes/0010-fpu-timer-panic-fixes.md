# 0010 关掉浮点单元、修正时钟漂移、panic 停机不再忙等

- 日期：2026-10-26
- 提交：本记录对应的提交
- 涉及文件：`src/main.zig`、`src/riscv.zig`、`src/timer.zig`、`user/tests/t_fp.zig`（新）、`user/tests/t_clock.zig`（新）、`build.zig`、`tools/qemu_test.py`、`docs/build.md`、`docs/riscv-sbi.md`、`docs/process.md`、`docs/user-programs.md`、`docs/boot.md`、`docs/devices.md`、`docs/architecture.md`、`docs/testing.md`、`AGENTS.md`

## 目标

维护者请 Claude 看看内核现在的样子、有什么可以改进。Claude 读代码时发现三处可疑，在 QEMU 里复现之后列了出来（复现方法见“验证”）。维护者的回复是：“先修这 3 个问题吧，推到 main”。三个问题是：

1. **浮点单元是开着的**。文档里写着 `sstatus.FS` 始终为 Off，实际上 OpenSBI 交过来时是 3（Dirty），内核没有清它。用户程序能直接执行浮点指令，浮点寄存器又不在 `TrapFrame` 里，于是会跨进程泄漏：一个进程往 `f1` 写的值，下一个进程能读到。
2. **`uptime` 越走越慢**，比 `time` CSR 慢 2%～3%。
3. **内核 panic 之后 QEMU 占满一个 CPU 核**。

## 改动

- **`src/riscv.zig`**：新增 `sstatus_fs = 3 << 13`。
- **`src/main.zig`**：
  - `kmain` 的第一件事是 `riscv.clear(.sstatus, riscv.sstatus_fs)`。
  - `kernelPanic` 进入 `wfi` 循环之前先 `riscv.write(.sie, 0)`。
- **`src/timer.zig`**：
  - 新增 `deadline`（下一次中断预约在 `time` 的哪个值），`init` 把它设成当前的 `time`。
  - `arm()` 从 `setTimer(time + 周期)` 改成 `deadline += 周期; setTimer(deadline)`。
- **回归测试**：
  - `user/tests/t_fp.zig`：执行手工编码的 `fmv.d.x f1, a0`，期望被 `illegal_instruction` 结束。
  - `user/tests/t_clock.zig`：忙等到 `uptime()` 走过 3 秒，打印这段时间里 `uptime()` 和 `rdtime` 各走了多少。
  - `build.zig` 的 `test_programs` 加上这两个程序。
- **`tools/qemu_test.py`**：
  - 回归轮加上 `t_fp` 和 `t_clock` 的检查。`t_clock` 把 `rdtime` 按 10 MHz 换算成毫秒，要求和 `uptime()` 相差不超过 20 ms。
  - 新增 panic 轮：`crash` 之后检查 panic 信息，再量停机后 1 秒内 QEMU 用掉的 CPU 时间，不能超过 0.5 秒。
  - `Qemu.cpu_seconds()` 读 `/proc/<pid>/stat` 统计 CPU 时间；`run_round` 加了 `halts` 参数，panic 轮不比较 `mem`、不 `shutdown`，也允许出现 `KERNEL PANIC`。
  - 新增常量 `TIMEBASE_HZ`，启动日志的检查也改用它。
- **文档**：
  - `build.md`、`riscv-sbi.md`、`process.md`、`user-programs.md`、`architecture.md`：关于浮点的说法改正，见问题 1。
  - `boot.md`：初始化顺序表加了第 1 步，后面依次顺延；panic 处理一节更新。
  - `devices.md`：定时器一节改写预约方式，解释为什么以上一次的预约时刻为基准。
  - `testing.md`：三轮测试、新的检查和测试程序、示例输出和耗时，症状速查加了三行。
  - AGENTS.md：测试的描述改成三轮；不变量里加了 `sstatus.FS` 保持 Off。

## 设计决策

### 浮点

- **关掉浮点单元，而不是支持浮点**。支持浮点要在 `TrapFrame` 里保存 `f0..f31` 和 `fcsr`（或者按 `FS` 的状态懒保存），还要改编译目标；现在没有这个需求。关掉之后由硬件保证“没有浮点”，和编译目标的约定一致，手写的浮点指令也挡得住。
- **在 `kmain` 开头清，而不是在 `proc.run` 构造 `frame.sstatus` 时清**。放在开头对 S 模式也生效（内核自己也不该用浮点），而 `proc.run` 的 `sstatus` 本来就从内核当前的值派生，自然也是 Off。考虑过两处都清：只要 `kmain` 清过，就没有代码会把它重新打开，第二处没有必要。不变量写进了 AGENTS.md。
- 也可以写在 `_start` 的汇编里。最后选了 `kmain`，因为这样用的是 `riscv.zig` 的函数，符合“CSR 读写统一走 `riscv.zig`”的约定；`_start` 和 `kmain` 都不会生成浮点指令，放在哪里效果一样。

### 时钟

- **选了“上一次的预约时刻 + 一个周期”**。另一个做法是让 `uptimeMs()` 直接从 `time` CSR 算，精度更高，也不依赖中断。没选它，原因有两个：
  - shell 的 `uptime` 命令本来就是用来展示时钟中断的（会显示中断次数），两个计时来源会不一致；
  - `time` 从 QEMU 启动时开始计数，不是从打开时钟中断开始，`uptime` 的语义也得跟着改。

  现在的改法只改了一行逻辑，`ticks` 仍然正好等于中断次数。
- **晚了超过一个周期时，靠“立刻再来一次中断”追上**。考虑过在中断处理里用循环一次补齐（`while (deadline <= now) { ticks += 1; deadline += 周期; }`），没选：那样 `ticks` 就不再等于中断次数，而这种情况本来就少见。
- 周期是 `timebase_hz / tick_hz`，整数除法。timebase 不是 100 的倍数时，每个周期最多短 1 个计数，会有一点系统误差；QEMU 上是 10 MHz，正好整除。

### panic

- **清零 `sie`**：panic 之后不需要任何中断。规范允许 `wfi` 无故返回，所以循环保留。
- **没有改成 panic 后关机**：关机会让 QEMU 直接退出，用 GDB 查看 panic 现场就不方便了。保持“打印后原地停住”的行为。
- **`sbi.shutdown` 末尾的 `wfi` 循环没改**。那是固件不支持 SRST 时的退路，shell 调用它时中断是开着的，时钟中断照常被处理和重新预约，不会出现这次的忙等；QEMU 支持 SRST，这条路径也测不到。

### 测试

- **先加测试、确认它们在修复前的内核上失败，再修内核**（结果见“验证”）。
- **`t_fp` 只用一个程序**。最初复现时用了两个程序演示跨进程泄漏，但 `FS` 为 Off 时，第一条浮点指令就会被结束，泄漏根本不会发生；`FS` 不是 Off 时，`t_fp` 会正常退出，检查同样会失败。一个程序就够了。`stval` 整个比较：指令里的寄存器是写死的（`a0` 和 `f1`），不会随寄存器分配变化，这一点和 `t_priv` 不同。
- **`t_clock` 按 `uptime()` 决定忙等多久，而不是按 `rdtime`**：用户程序不知道 timebase，换算放在脚本里（脚本本来就会从启动日志检查 timebase 是 10 MHz）。
- **误差分析和阈值**：
  - `uptime()` 按 tick 取整，开始那次读到的值最多落后实际时间一个 tick；循环在 `uptime()` 刚跨过 3000 时退出，结束那次几乎不落后。所以修复后应该有 `uptime 走过的 - rdtime 走过的 ∈ (−处理延迟, +10 ms)`，实测是 +1.5～+7.3 ms。
  - 修复前慢 1.6%～2.4%，3 秒里差 49.5～72.7 ms。阈值取 20 ms，两边都有足够的余量。
  - 窗口取 3 秒，是为了让修复前后的差距足够大；代价是回归轮每种模式多花 3 秒。
- **panic 单独一轮**：panic 之后内核停住了，没法再 `shutdown`，所以不能塞进标准轮的末尾。这一轮顺便第一次把 `crash` 命令纳入了自动测试。
- **CPU 时间读 `/proc`**，只支持 Linux（CI 是 Ubuntu）。考虑过 `resource.getrusage(RUSAGE_CHILDREN)`，它是跨平台的，但只能在 QEMU 退出后拿到整个生命周期的 CPU 时间，混进了启动的开销，阈值不好定。阈值取 0.5（一个核的一半）：修复前实测 97%～99%，修复后 0%。

## 验证

### 环境

Zig 0.17.0、QEMU 8.2.2（Debian 1:8.2.2+ds-0ubuntu1.18）、OpenSBI v1.3、Python 3.13.17。

### 复现问题（修复前，临时代码，测完已删除）

在仓库的副本里做，没有动工作目录。

**浮点**：在 `kmain` 开头临时加一行打印，入口处 `sstatus = 0x8000000200006000`，其中 `FS`（第 13、14 位）= 3，汇总位 SD（第 63 位）= 1。再写两个用户程序，加进 `test_programs`：

```zig
// t_fpset.zig：fmv.d.x f1, a0（目标是 rv64imac，汇编器不认浮点指令，手工编码）
const sys = @import("sys");
pub fn main() u8 {
    asm volatile (".word 0xF20500D3"
        :
        : [v] "{a0}" (@as(usize, 0x1234_5678_9abc_def0)),
        : .{ .memory = true });
    sys.print("put secret into f1\n", .{});
    return 0;
}

// t_fpget.zig：fmv.x.d a0, f1
const sys = @import("sys");
pub fn main() u8 {
    const v = asm volatile (".word 0xE2008553"
        : [r] "={a0}" (-> usize),
        :
        : .{ .memory = true });
    sys.print("f1 = 0x{x}\n", .{v});
    return 0;
}
```

先后运行这两个程序：

```
put secret into f1
[proc] pid 1 (t_fpset) exited with code 0
f1 = 0x123456789abcdef0
[proc] pid 2 (t_fpget) exited with code 0
```

**时钟**：用一个程序同时打印 `rdtime / 10000`（毫秒）和 `uptime()`，在开机后、shell 空闲 20 秒后、`spin` 跑 20 秒后各运行一次：

| 区间 | `rdtime` 走了 | `uptime()` 走了 | 慢了 |
| --- | --- | --- | --- |
| shell 空闲 20 秒 | 20123 ms | 19580 ms | 543 ms（2.7%） |
| `spin` 跑 20 秒 | 20173 ms | 19780 ms | 393 ms（1.9%） |

**panic**：启动后先量 5 秒，再执行 `crash`、等到 `system halted.` 之后量 5 秒。QEMU 进程的 CPU 时间从 `/proc/<pid>/stat` 的第 14、15 项（utime、stime）读：

```
idle at shell prompt: 1% CPU
after kernel panic:   99% CPU
```

### 先加测试，在修复前的内核上运行

只加了 `t_fp`、`t_clock` 和 panic 轮，内核没改。`python3 tools/qemu_test.py`（中间修过一次测试程序的编译错误，见问题 2），四种模式的回归轮和 panic 轮全部 `FAIL`：

```
PASS  debug  standard    23 checks    1.2s
FAIL  debug  regression  35 checks    5.6s
    - run t_fp: expected /\[proc\] pid \d+ \(t_fp\) killed: illegal_instruction at 0x[0-9a-f]+, stval=0x([0-9a-f]+)/ in output:
    - run t_clock: uptime() advanced 3000 ms while rdtime advanced 3049.5 ms (tolerance 20 ms)
FAIL  debug  panic       9 checks    1.2s
    - crash: QEMU used 99% of a CPU during 1.0s after the kernel halted (busy-waiting?)
（safe、fast、small 相同，t_clock 分别是 3072.7、3052.3、3060.8 ms，panic 后分别是 99%、97%、98%）
```

串口日志里，四种模式都是 `[proc] pid 6 (t_fp) exited with code 0`：浮点指令执行成功了。

### 修复后

- `zig fmt --check build.zig src/ user/`：没有输出。
- 在副本里临时打印 `sstatus`：入口 `0x8000000200006000`，清掉 `FS` 之后是 `0x200000000`。`SUM`（第 18 位）、`MXR`（第 19 位）在入口处就是 0。
- `python3 tools/qemu_test.py`（构建命中缓存，总共约 23 秒）：

  ```
  PASS  debug  standard    23 checks    1.4s
  PASS  debug  regression  36 checks    3.2s
  PASS  debug  panic       9 checks    1.2s
  PASS  safe   standard    23 checks    0.7s
  PASS  safe   regression  36 checks    3.9s
  PASS  safe   panic       9 checks    1.2s
  PASS  fast   standard    23 checks    0.7s
  PASS  fast   regression  35 checks    4.0s
  PASS  fast   panic       9 checks    1.2s
  PASS  small  standard    23 checks    0.7s
  PASS  small  regression  35 checks    3.2s
  PASS  small  panic       9 checks    1.2s
  ```

- `rm -rf .zig-cache zig-out` 之后再跑一遍：全部 `PASS`，总共约 42 秒。
- 回归轮 `serial.log` 里的结果：

  | 模式 | `t_fp` | `t_clock`：`rdtime` 走了 | 差 |
  | --- | --- | --- | --- |
  | debug | `killed: illegal_instruction at 0x40011450, stval=0xf20500d3` | 29926885（2992.7 ms） | +7.3 ms |
  | safe | `killed: illegal_instruction at 0x4000052a, stval=0xf20500d3` | 29972480（2997.2 ms） | +2.8 ms |
  | fast | `killed: illegal_instruction at 0x40000010, stval=0xf20500d3` | 29951447（2995.1 ms） | +4.9 ms |
  | small | `killed: illegal_instruction at 0x40000008, stval=0xf20500d3` | 29968797（2996.9 ms） | +3.1 ms |

  `t_clock` 的 `uptime()` 都是走了 3000 ms。
- 用下面的脚本在 safe 模式下连续跑 10 次 `t_clock`：差在 +1.5～+3.7 ms，平均 +2.4 ms；panic 之后 5 秒内 QEMU 的 CPU 占用是 0%。
- 按复现时的方法量 shell 空闲 20 秒：`rdtime` 走了 20014.2 ms，`uptime` 走了 20010 ms，差 −4.2 ms（修复前是 −543 ms）。
- 提交前把下面两个脚本从本记录里原样提取出来，在仓库根目录再跑了一遍：10 次 `t_clock` 的差在 +1.6～+4.3 ms，panic 之后 0%，空闲 20 秒差 −0.9 ms。
- `python3 tools/check_links.py`：`0 broken`。

测量脚本（放在仓库外，借用 `tools/qemu_test.py` 的 `Qemu` 类；参数是 `zig-out/qemu-test/` 下对应轮次构建出的内核）：

```python
# measure.py <回归轮的内核> <标准轮或 panic 轮的内核> <次数>
import sys, time, re, statistics
sys.path.insert(0, "tools")
import qemu_test as qt
kernel_reg, kernel_std, runs = sys.argv[1], sys.argv[2], int(sys.argv[3])
diffs = []
q = qt.Qemu(kernel_reg)
q.wait_for(lambda t: "Type 'help' for commands.\n> " in t, 60, "boot")
for i in range(runs):
    out = q.command("run t_clock")
    m = re.search(r"uptime\(\) advanced (\d+) ms, rdtime advanced (\d+)", out)
    diffs.append(int(m.group(1)) - int(m.group(2)) / 10000)
q.kill()
print(f"t_clock x{runs}: uptime - rdtime = min {min(diffs):.1f} ms, max {max(diffs):.1f} ms, mean {statistics.mean(diffs):.1f} ms")
q = qt.Qemu(kernel_std)
q.wait_for(lambda t: "Type 'help' for commands.\n> " in t, 60, "boot")
q.send("crash\r")
q.wait_for(lambda t: "system halted." in t, 60, "halt")
c0 = q.cpu_seconds(); time.sleep(5); print(f"after panic: {(q.cpu_seconds() - c0) / 5:.0%} CPU over 5 s")
q.kill()
```

```python
# idle.py <回归轮的内核>：shell 空闲 20 秒前后各取一次 rdtime（t_time）和 uptime（hello）
import sys, time, re
sys.path.insert(0, "tools")
import qemu_test as qt
q = qt.Qemu(sys.argv[1])
q.wait_for(lambda t: "Type 'help' for commands.\n> " in t, 60, "boot")
def sample():
    r = int(re.search(r"rdtime from U-mode = (\d+)", q.command("run t_time")).group(1))
    u = int(re.search(r"up for (\d+) ms", q.command("run hello")).group(1))
    return r / 10000, u
r0, u0 = sample(); time.sleep(20); r1, u1 = sample()
print(f"idle 20 s: rdtime advanced {r1 - r0:.1f} ms, uptime advanced {u1 - u0} ms, diff {(u1 - u0) - (r1 - r0):+.1f} ms")
q.send("shutdown\r"); q.finish(10)
```

## 发现的问题

### 问题 1：文档里有几处说法和实际不符

- 现象：
  - `build.md` 写着 “`sstatus.FS` 始终为 Off”；`riscv-sbi.md` 写着 `FS`“没有浮点所以一直是 Off”；`process.md` 写着进入 U 模式时 “`FS = Off` 等保持内核当前的值”。实测入口处 `FS` = 3（见上文）。
  - `user-programs.md` 写着“没有浮点硬件”。实测 QEMU 的 CPU 有浮点单元，`fmv.d.x` 在 U 模式下能执行。
  - `devices.md` 写着，按“处理中断的时刻”预约，“计时会略微变慢。对演示用的 `uptime` 来说足够了”。实测慢 2%～3%，空闲 20 秒慢半秒多，算不上“略微”。
  - `devices.md` 和 `syscalls.md` 写着 `uptime` 的“精度 10 ms”。修复前误差随时间累积，这句话不成立。
  - `boot.md` 的 panic 一节写着“中断关着时 `wfi` 仍可能被唤醒（有使能的中断挂起），所以要放在循环里”。这话本身没错，但没有意识到时钟中断会一直挂着，循环就成了忙等。
- 原因：浮点的说法是从“编译目标不开 F/D”推出来的，没有去读 `sstatus` 的实际值；时钟的“略微”没有量过。
- 修复：
  - 关于浮点的几处按修复后的实际情况改写，并写明 OpenSBI 交过来时是 Dirty。
  - `devices.md` 改写预约方式，写上修复前后的实测数字。
  - `boot.md` 写明为什么要清零 `sie`。
  - `syscalls.md` 的“精度 10 ms（一个时钟 tick）”在修复后成立，没有改。
  - 查了以前的修改记录（`grep FS`、`grep 精度`），这些说法只出现在功能文档里，没有需要加注的旧记录。
- 确认：改后的说法都对应“验证”一节里的实测；`check_links.py` 为 `0 broken`。

### 问题 2：`t_clock` 编译失败，`u0` 是 Zig 的原始类型名

- 现象：先加测试的那次运行，四种模式的回归轮都在构建时失败：

  ```
  user/tests/t_clock.zig:18:11: error: name shadows primitive 'u0'
      const u0 = sys.uptime();
            ^~
  user/tests/t_clock.zig:18:11: note: consider using @"u0" to disambiguate
  ```

- 原因：Zig 里 `u` 或 `i` 加位宽的名字都是整数类型（`u0` 是 0 位的无符号整数，`u1` 是 1 位），变量不能和它们同名。是我写测试程序时的错误。
- 修复：改名为 `up0`、`up1`。`testing.md` 的症状速查表加了一行。
- 确认：重新构建没有输出，之后的运行里回归轮能正常执行到 `t_fp`、`t_clock`。

### 问题 3：测量脚本等提示符等得太早

- 现象：第一次运行 `measure.py`：

  ```
    File ".../measure.py", line 12, in <module>
      diffs.append(int(m.group(1)) - int(m.group(2)) / 10000)
                       ^^^^^^^
  AttributeError: 'NoneType' object has no attribute 'group'
  ```

- 原因：脚本看到 `Type 'help'` 就开始发命令，那时提示符 `> ` 还没打印出来。`Qemu.command` 记下的提示符个数是 0，看到第一个提示符就返回了，返回的输出里没有 `t_clock` 的结果。这是临时脚本的问题，和内核无关；`qemu_test.py` 的 `check_boot` 等的是 `Type 'help' for commands.\n> `，没有这个问题。
- 修复：改成和 `check_boot` 一样等完整的 `Type 'help' for commands.\n> `。
- 确认：之后 10 次都取到了结果（见“验证”）。另外，这个脚本 import 了 `qemu_test`，Python 在 `tools/` 下生成了 `__pycache__/`，提交前已经删掉。

### 问题 4：文档草稿里写了没验证过的说法

- 现象：`devices.md` 的草稿写着，处理晚了超过一个周期的情况“在这个内核里也不应该出现：关中断的代码路径都远短于 10 ms”。
- 原因：这是推测。在 QEMU 里串口输出几乎不花时间，但在 115200 波特率的真实串口上，`t_sys` 一次写出 4192 个字节就要约 360 ms（按每字节 10 位估算），这期间中断是关着的。
- 修复：删掉这句，只保留“这种情况没有实测过”。
- 确认：提交前重读了这次改过的所有文档，把每一个数字都和上面的实测结果对了一遍。

## 遗留问题

- 浮点：以后要支持浮点的话，需要保存和恢复 `f0..f31`、`fcsr`（可以按 `FS` 的状态懒保存），并修改编译目标。
- 时钟：
  - 处理晚了超过一个周期时靠连续中断追上，这种情况没有实测过。
  - timebase 不能被 100 整除时，每个周期有不到 1 个计数的系统误差。
- `t_clock` 的阈值是 20 ms。推测：如果宿主机恰好在读 `uptime()` 和 `rdtime` 之间把 QEMU 暂停超过约 10 ms，可能误报。目前在本地没有遇到。
- panic 轮只能在 Linux 上跑。
- `sbi.shutdown` 在固件不支持 SRST 时的退路没有测过。
- `qemu_test.py` 跑完一遍的时间从约 10 秒变成约 23 秒（构建命中缓存时）。
