# 0009 QEMU 自动测试和回归测试程序

- 日期：2026-10-25
- 提交：本记录对应的提交（Add automated QEMU tests and regression test programs）
- 涉及文件：`tools/qemu_test.py`（新）、`user/tests/`（新：`t_sys.zig`、`t_wx.zig`、`t_stack.zig`、`t_priv.zig`、`t_panic.zig`、`t_time.zig`、`t_noperm.zig`、`noperm.ld`）、`build.zig`、`docs/testing.md`、`docs/build.md`、`docs/user-programs.md`、`docs/process.md`、`docs/README.md`、`docs/changes/0006-docs.md`、`AGENTS.md`、`README.md`

## 目标

维护者从改进建议里选了这一条：之前的验证靠人对着 QEMU 的输出逐行比，规则越来越多，容易漏；开发 U 模式时写过的边界测试都是临时的，测完就删了。要做到：

- 一个脚本跑完四种优化模式，自动判定通过与否；
- 把 [0005](0005-user-mode-and-syscalls.md) 里的临时测试程序固定下来，变成回归测试。

## 改动

- **`user/tests/`**：7 个回归测试程序，内容和 0005 里的临时程序一致，另外加了 0006 里用过的 `t_time`。`t_noperm` 改成不依赖 `hello.zig`：自己有一个写过的全局变量，保证数据段非空。`noperm.ld` 由 `user/linker.ld` 复制而来，只把数据段的权限改成 `FLAGS(0)`。
- **`build.zig`**：
  - 程序列表从名字数组改成 `UserProgram` 结构体数组（名字、目录、链接脚本，后两项有默认值）。
  - 新增选项 `-Dtest-programs=true`：把 `test_programs` 也编进内核。默认关闭，平时 `run` 列表里只有三个演示程序。
  - `build_options` 的名字列表改成根据选中的程序动态生成。
- **`tools/qemu_test.py`**：
  - 对每种模式跑标准、回归两轮，每轮先用 `zig build -p zig-out/qemu-test/<模式>-<轮次>` 构建（不影响 `zig-out/bin/kernel`），要求退出码为 0 并且**没有任何输出**。
  - 启动 QEMU，后台线程读串口，等提示符 `> ` 出现再发下一条命令，检查每条命令的输出。
  - 每轮最后比较前后两次 `mem`，`shutdown` 后要求退出码 0，全程不能有 `KERNEL PANIC`。
  - 串口输出保存到 `serial.log`。
  - 检查项的完整列表见 [testing.md](../testing.md#自动测试toolsqemu_testpy)。
- **文档**：
  - `testing.md`：前半部分重写，自动测试成为必做检查，加了“回归测试程序”“加一个回归测试”两节；原来的手动脚本保留在“手动运行”一节，命令前加了 `zig build &&`，并删掉了“一键四种模式”的循环。
  - AGENTS.md：验证一节改成以 `qemu_test.py` 为准。
  - `build.md`、`user-programs.md`、`process.md`、`docs/README.md`、README：同步更新。
  - `docs/changes/0006-docs.md`：它链接的 `testing.md#标准测试脚本` 这一节改名了，链接改成说明文字加一句注（不改原来的结论）。

## 设计决策

- **按提示符驱动，而不是固定的 `sleep`**：每条命令都等下一个 `\n> ` 出现。机器慢（比如 CI）时不会错位，机器快时也不浪费时间。命令的输出都不含 `\n> `，提示符个数正好每条命令加一。
- **检查按命令切分**：每条命令只检查它自己的那段输出，失败信息能直接指出是哪条命令、贴出那段输出的最后 15 行。
- **构建装到单独的目录**：测试不会把用户的 `zig-out/bin/kernel` 换成带测试程序的版本；也从根本上避免了“构建失败却跑了旧内核”。这个问题手动测试时已经发生过两次（[0005](0005-user-mode-and-syscalls.md)、[0006](0006-docs.md)）。
- **测试程序默认不编进内核**：用 `-Dtest-programs` 控制。代价是普通构建和测试构建的内核镜像不同，所以标准轮用普通构建测，回归轮用测试构建测。
- **把“时钟中断在 U 模式下照常发生”变成一条检查**：自动驱动太快，开机后第一条 `uptime` 的计数是 0，原来“计数大于 0”这条检查没有意义（见问题 1）。改成在 `spin` 前后各取一次 `uptime`、让 `spin` 转 0.5 秒，要求计数至少增加 10。`spin` 死循环期间内核只能靠中断拿回 CPU，这条检查比原来的更有意义。
- **`t_priv` 的 `stval` 不比较 rd 字段**：`stval` 是指令编码，里面的目标寄存器号随寄存器分配变化。目前四种模式碰巧都是 `a0`（`0x10002573`），但不应该依赖这一点。检查的是 `stval & ~(0x1f << 7) == 0x10002073`，也就是 `csrr rd, sstatus`。
- **用 Python**：和 `tools/check_links.py` 一样，只依赖标准库。

## 验证

### 环境

Zig 0.17.0、QEMU 8.2.2、OpenSBI v1.3、Python 3.13.17。

### 正常情况

- `zig build` 和 `zig build -Dtest-programs=true -p <临时目录>`：两种构建都没有输出；前者 `zig-out/user/` 下是 3 个程序，后者是 10 个。
- `t_noperm` 的数据段在四种模式下都非空、权限为空（`llvm-readelf -l`，例如 Debug 下 `LOAD ... 0x000024 0x000024     0x1000`，Flg 一栏为空）。所以这个测试在每种模式下都真的测到了加载器的检查。
- `python3 tools/qemu_test.py`：

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

  构建命中缓存时总共约 9 秒；`rm -rf .zig-cache zig-out` 后从零开始约 22 秒（Zig 的全局缓存是热的）。`zig-out/bin/kernel` 没有被改动。
- 看过回归轮的 `serial.log`，确认每个测试程序都真的运行了，输出和 0005 里手动测试时一致。`spin` 转的 0.5 秒里计数从 2 涨到 51。
- testing.md 里改过的手动运行命令（加了 `zig build &&`）实际执行过：结果正常，退出码 0。

### 故障注入：确认测试会失败

每次只注入一个故障，只跑 Debug 模式（第 1 项另外跑了 small），测完还原：

| 注入的故障 | 结果 |
| --- | --- |
| 删掉 `proc.loadSegment` 里的 `!phdr.flags.R` 检查 | Debug：回归轮 `FAIL`，`run t_noperm` 时内核 `KERNEL PANIC: reached unreachable code`（`vm.map` 里的断言），之后等提示符超时。small：断言被编译掉了，加载“成功”，程序访问数据段时 `killed: load_page_fault at 0x40000020, stval=0x40002000`：那一页确实被当成了下一级页表。两种模式都因为没有出现 `BadElf` 而 `FAIL` |
| 删掉 `proc.run` 里的 `defer vm.destroyUserSpace(space)` | 两轮都 `FAIL`：`mem: free pages changed from (32052, 32057) to (31956, 32057) (leak?)`；回归轮从 31882 变成 31630 |
| `user/tests/t_wx.zig` 里删掉一个分号 | 回归轮 `FAIL`，报告构建命令失败，并贴出编译器的错误 `expected ';' after statement`；标准轮不受影响，照常 `PASS` |
| `timer.onInterrupt` 里不再调用 `arm()` | 标准轮 `FAIL`：`timed out after 60s waiting for the prompt after 'run hello'`。时钟中断一直挂着，回到 U 模式就立刻又陷入，用户程序没法前进 |

第 1 项的两种表现正是 [0005](0005-user-mode-and-syscalls.md) 问题 4 说的漏洞，也说明 `vm.map` 的断言只在 Debug/safe 模式下兜底，真正的防线是加载器的检查。

## 发现的问题

### 问题 1：“开机后计数大于 0”的检查在自动驱动下不成立

- 现象：第一次运行，标准轮报 `uptime: no timer interrupts counted`，日志里是 `up 0.00s (0 timer interrupts)`。
- 原因：脚本一看到提示符就发命令，第一条 `uptime` 离打开时钟中断不到 10 ms。手动脚本开头 `sleep 1.5`，所以从来没暴露。是检查本身的问题，内核没错。
- 修复：改成测 `spin` 运行 0.5 秒期间的计数增量（见“设计决策”）。
- 确认：之后四种模式都通过，增量约 49。

### 问题 2：还原故障时，没被 git 跟踪的新文件不会被 `git checkout` 还原

- 现象：故障注入第 3 项之后，`t_wx.zig` 里的语法错误还在，用的还原命令是 `git checkout -q user/tests/t_wx.zig 2>/dev/null || true`。
- 原因：`user/tests/` 当时还没有提交，`git checkout` 对未跟踪的文件不起作用，而错误被 `|| true` 吞掉了。
- 修复：手动改回，再跑一遍确认全部通过。testing.md 的“边界情况的临时测试”一节加了一句：新建的文件 `git checkout` 还原不了。
- 确认：之后完整的四种模式测试全部 `PASS`，`git status` 里只有本次要提交的文件。

## 遗留问题

- 超时都是 60 秒，内核卡住时一轮要等 60 秒才失败。
- 标准轮和回归轮用的是不同的内核镜像（后者多嵌了测试程序），回归轮测不到“只有演示程序时”的某些差异；目前没有发现这会漏掉什么。
- 主机上的单元测试（比如用坏的设备树测解析器）没有做，那是另一条改进建议。
