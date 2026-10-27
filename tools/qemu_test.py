#!/usr/bin/env python3
"""在 QEMU 里测试内核：构建，启动，按提示符逐条输入命令，检查输出。

检查分成几个用例（--list 查看），每个用例写明它覆盖哪些源文件：
  python3 tools/qemu_test.py                  # 全部用例，safe 模式
  python3 tools/qemu_test.py --changed        # 只跑和未提交的改动有关的用例
  python3 tools/qemu_test.py shell fork       # 只跑指定的用例
  python3 tools/qemu_test.py --all-modes      # 四种优化模式都跑（改了汇编、中断、页表、进出 U 模式时用）

每种模式只构建一次（带上 user/tests/ 里的测试程序），所有用例共用一次启动。启动日志每次都检查；
结束时比较前后两次 mem 的空闲页数（不能漏页）、shutdown 后 QEMU 的退出码必须为 0、输出里不能有 KERNEL PANIC。
"""

import argparse
import os
import re
import subprocess
import sys
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
MODES = ["debug", "safe", "fast", "small"]
QEMU = ["qemu-system-riscv64", "-machine", "virt", "-smp", "1", "-m", "128M", "-nographic", "-bios", "default"]

BOOT_TIMEOUT = 60  # 秒：从启动 QEMU 到出现第一个提示符
COMMAND_TIMEOUT = 60  # 秒：每条命令从发出到出现下一个提示符
PROMPT = "\n> "  # 串口把 \n 输出成 \r\n，比较前统一换成 \n
SPIN_SECONDS = 0.5  # 让 spin 转多久再按 Ctrl-C
MIN_SPIN_TICKS = 10  # 这段时间里至少要有多少次时钟中断（100 Hz 下理论上约 50 次）
TIMEBASE_HZ = 10_000_000  # QEMU virt 的 time CSR 频率

# 用户地址空间里栈下面那一页保护页（src/proc.zig）
GUARD_PAGE = (0x7FFFB000, 0x7FFFC000)
USER_SPACE = (0x40000000, 0x80000000)
MAX_PROCS = 8  # src/abi.zig 的 max_procs，其中两个槽位是 init 和 sh
SPIN_STARTED = re.compile(r"pid (\d+) spinning in U-mode")


class Failure(Exception):
    pass


class Qemu:
    """启动 QEMU，后台线程持续读取串口输出；按提示符一条一条地发命令。"""

    def __init__(self, kernel):
        self.proc = subprocess.Popen(
            QEMU + ["-kernel", kernel],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        self.raw = bytearray()
        self.cond = threading.Condition()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        while True:
            chunk = self.proc.stdout.read1(4096)
            with self.cond:
                if not chunk:
                    self.cond.notify_all()
                    return
                self.raw += chunk
                self.cond.notify_all()

    def text(self):
        with self.cond:
            return self.raw.decode("utf-8", errors="replace").replace("\r\n", "\n")

    def wait_for(self, predicate, timeout, what):
        """等到 predicate(当前全部输出) 为真。QEMU 提前退出或者超时都算失败。"""
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                text = self.raw.decode("utf-8", errors="replace").replace("\r\n", "\n")
                if predicate(text):
                    return text
                if self.proc.poll() is not None and not self.reader.is_alive():
                    raise Failure(f"QEMU exited (code {self.proc.returncode}) while waiting for {what}")
                left = deadline - time.monotonic()
                if left <= 0:
                    raise Failure(f"timed out after {timeout}s waiting for {what}")
                self.cond.wait(min(left, 0.5))

    def send(self, data):
        self.proc.stdin.write(data.encode())
        self.proc.stdin.flush()

    def command(self, line):
        """发一条命令，等下一个提示符，返回这条命令产生的输出。"""
        start = len(self.text())
        prompts = self.text().count(PROMPT)
        self.send(line + "\r")
        text = self.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, f"the prompt after '{line}'")
        return text[start:]

    def finish(self, timeout):
        """等 QEMU 自己退出，返回退出码；超时就杀掉并报错。"""
        try:
            return self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.kill()
            raise Failure(f"QEMU did not exit within {timeout}s after shutdown")

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


class Checks:
    """收集一组检查的结果。"""

    def __init__(self):
        self.failures = []
        self.count = 0

    def expect(self, cond, message):
        self.count += 1
        if not cond:
            self.failures.append(message)

    def contains(self, output, pattern, what):
        m = re.search(pattern, output)
        self.expect(m is not None, f"{what}: expected /{pattern}/ in output:\n{indent(output)}")
        return m


def indent(text):
    lines = text.strip("\n").splitlines()[-15:]
    return "\n".join("      | " + line for line in lines)


def free_pages(output):
    m = re.search(r"(\d+) of (\d+) pages free", output)
    return (int(m.group(1)), int(m.group(2))) if m else None


def check_killed(c, out, name, exception, stval_range=None, stval=None, stval_mask=~0):
    m = c.contains(out, rf"\[proc\] pid \d+ \({name}\) killed: {exception} at 0x[0-9a-f]+, stval=0x([0-9a-f]+)", f"run {name}")
    if m:
        value = int(m.group(1), 16)
        if stval_range:
            lo, hi = stval_range
            c.expect(lo <= value < hi, f"run {name}: stval=0x{value:x} not in [0x{lo:x}, 0x{hi:x})")
        if stval is not None:
            c.expect(value & stval_mask == stval, f"run {name}: stval=0x{value:x}, expected 0x{stval:x}")


def exited(c, out, name, code):
    c.contains(out, rf"\[proc\] pid \d+ \({name}\) exited with code {code}\b", f"run {name}")


# ---- 用例 ----


def case_shell(q, c, mode):
    c.contains(q.command("help"), r"run NAME", "help")
    c.contains(q.command("uptime"), r"up \d+\.\d\ds\n", "uptime")
    c.contains(q.command("nope"), r"unknown command: nope", "unknown command")
    c.contains(q.command("run"), r"programs: init sh hello", "run without a name")
    c.contains(q.command("run nope"), r"no such program: nope\nprograms: ", "run nope")


def case_interrupts(q, c, mode):
    # spin 在 U 模式里死循环。这段时间里内核只能靠中断拿回 CPU，
    # 所以前后两次 uptime（精度是一个 tick，10 ms）的差说明时钟中断在 U 模式下照常发生；Ctrl-C 靠串口中断送进来
    before = uptime_ticks(q, c)
    run_and_interrupt(q, c, SPIN_SECONDS)
    after = uptime_ticks(q, c)
    if before is not None and after is not None:
        c.expect(after - before >= MIN_SPIN_TICKS,
                 f"uptime: only {after - before} timer interrupts while spin ran for {SPIN_SECONDS}s")
    # 在 shell 里按的 Ctrl-C 不应该影响之后运行的程序
    q.send("\x03")
    exited(c, q.command("run hello"), "hello", 0)


def run_and_interrupt(q, c, seconds):
    """在前台运行 spin，等它开始转，seconds 秒后按 Ctrl-C，检查它被结束。返回它的 pid。"""
    start = len(q.text())
    prompts = q.text().count(PROMPT)
    q.send("run spin\r")
    q.wait_for(lambda t: SPIN_STARTED.search(t[start:]), COMMAND_TIMEOUT, "spin to start")
    pid = int(SPIN_STARTED.search(q.text()[start:]).group(1))
    time.sleep(seconds)
    q.send("\x03")
    out = q.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, "the prompt after Ctrl-C")[start:]
    c.contains(out, rf"\^C\n\[proc\] pid {pid} \(spin\) killed: interrupted by Ctrl-C", "run spin + Ctrl-C")
    return pid


def uptime_ticks(q, c):
    """uptime 显示到 1/100 秒，正好是 tick 数。"""
    m = c.contains(q.command("uptime"), r"up (\d+)\.(\d\d)s", "uptime")
    return int(m.group(1)) * 100 + int(m.group(2)) if m else None


def case_user(q, c, mode):
    out = q.command("run hello")
    c.contains(out, r"Hello from U-mode! I am pid \d+, the kernel has been up for \d+ ms\.", "run hello")
    c.contains(out, r"write\(\) refused a kernel pointer: BadAddress", "run hello")
    exited(c, out, "hello", 0)
    check_killed(c, q.command("run fault"), "fault", "load_page_fault", stval=0x80200000)
    out = q.command("run t_panic")
    if mode in ("debug", "safe"):
        c.contains(out, r"panic: integer overflow", "run t_panic")
        exited(c, out, "t_panic", 255)
    else:  # 没有溢出检查：250 + 10 回绕成 4
        exited(c, out, "t_panic", 4)
    out = q.command("run t_time")
    m = c.contains(out, r"rdtime from U-mode = (\d+)", "run t_time")
    if m:
        c.expect(int(m.group(1)) > 0, "run t_time: time CSR read as 0")
    exited(c, out, "t_time", 0)


def start_background(q, c, name):
    """后台运行 name，返回 pid；是 spin 的话还要等它打印出第一行，免得这行混进下一条命令的输出。"""
    start = len(q.text())
    m = c.contains(q.command(f"run {name} &"), rf"\[proc\] pid (\d+) \({name}\) started in the background",
                   f"run {name} &")
    if not m:
        return None
    pid = int(m.group(1))
    if name == "spin":
        q.wait_for(lambda t: f"pid {pid} spinning" in t[start:], COMMAND_TIMEOUT, f"spin (pid {pid}) to start")
    return pid


def ps_table(q, c):
    """运行 ps，返回 {pid: (状态, ticks, 名字)}，不含 init 和 sh（检查它们的父进程和状态）。"""
    out = q.command("ps")
    c.contains(out, r"PID +PPID STATE +TICKS NAME", "ps")
    rows = [(int(m.group(1)), int(m.group(2)), m.group(3), int(m.group(4)), m.group(5))
            for m in re.finditer(r"^ *(\d+) +(\d+) (\w+) +(\d+) (\w+)$", out, re.M)]
    init = [r for r in rows if r[4] == "init"]
    sh = [r for r in rows if r[4] == "sh"]
    c.expect([r[:3] for r in init] == [(1, 0, "sleeping")], f"ps: expected init as pid 1, sleeping: {rows}")
    c.expect(len(sh) == 1 and sh[0][1:3] == (1, "running"), f"ps: expected one running sh, child of init: {rows}")
    return {r[0]: (r[2], r[3], r[4]) for r in rows if r[4] not in ("init", "sh")}


def case_sched(q, c, mode):
    # 两个后台进程死循环，前台程序和 shell 照样能运行
    spinners = [start_background(q, c, "spin") for _ in range(2)]
    if None in spinners:
        return
    exited(c, q.command("run hello"), "hello", 0)
    out = q.command("run t_sleep")
    m = c.contains(out, r"slept (\d+) ms", "run t_sleep")
    if m:
        c.expect(200 <= int(m.group(1)) < 1000, f"run t_sleep: slept {m.group(1)} ms, expected 200..1000")
    c.contains(out, r"yield ok", "run t_sleep")
    exited(c, out, "t_sleep", 0)

    # 两个后台进程都分到了 CPU：时间片轮转，0.5 秒里各自至少拿到几个 tick
    before = ps_table(q, c)
    time.sleep(SPIN_SECONDS)
    after = ps_table(q, c)
    for pid in spinners:
        c.expect(after.get(pid, ("", 0, ""))[0] == "runnable", f"ps: spin (pid {pid}) not listed as runnable: {after}")
        got = after.get(pid, ("", 0, ""))[1] - before.get(pid, ("", 0, ""))[1]
        c.expect(got >= MIN_SPIN_TICKS // 2, f"ps: spin (pid {pid}) got only {got} ticks in {SPIN_SECONDS}s")

    # Ctrl-C 只结束前台进程，后台的还在
    fg = run_and_interrupt(q, c, 0.2)
    table = ps_table(q, c)
    c.expect(fg not in table and all(pid in table for pid in spinners), f"ps after Ctrl-C: {table}")

    # 在 sleep 里睡着的前台进程，Ctrl-C 也要能叫醒它、结束它
    start = len(q.text())
    prompts = q.text().count(PROMPT)
    q.send("run ticker\r")
    time.sleep(0.2)
    q.send("\x03")
    out = q.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, "the prompt after Ctrl-C on ticker")[start:]
    c.contains(out, r"\^C\n\[proc\] pid \d+ \(ticker\) killed: interrupted by Ctrl-C", "run ticker + Ctrl-C")
    c.expect("tick 1" not in out, f"run ticker + Ctrl-C: ticker kept running:\n{indent(out)}")

    # sleep 的进程不占 CPU。刚启动时它还是 runnable（紧接着的 ps 可能抢在它第一次运行之前），所以多看几次
    ticker = start_background(q, c, "ticker")
    for _ in range(10):
        table = ps_table(q, c)
        if table.get(ticker, ("",))[0] == "sleeping":
            break
        time.sleep(0.05)
    c.expect(table.get(ticker, ("",))[0] == "sleeping", f"ps: ticker (pid {ticker}) not sleeping: {table}")

    # kill
    for pid in spinners + [ticker]:
        c.contains(q.command(f"kill {pid}"), rf"\[proc\] pid {pid} \(\w+\) killed: kill\(\)", "kill")
    c.contains(q.command("kill 9999"), r"kill: no such process: 9999", "kill 9999")
    c.contains(q.command("kill 1"), r"kill: cannot kill pid 1: permission denied", "kill init")
    c.contains(q.command("kill"), r"usage: kill PID", "kill")
    c.expect(ps_table(q, c) == {}, "ps: processes left after killing all of them")

    # 进程表满了（init 和 sh 占着两个槽位）
    full = [start_background(q, c, "spin") for _ in range(MAX_PROCS - 2)]
    c.contains(q.command("run hello"), rf"run: too many processes \(at most {MAX_PROCS}\)", "run with a full table")
    for pid in full:
        if pid is not None:
            q.command(f"kill {pid}")
    c.expect(ps_table(q, c) == {}, "ps: processes left after killing all of them")


def case_syscall(q, c, mode):
    out = q.command("run t_sys")
    for pattern in [
        r"abcd\npartial write -> 4\n",
        r"abcdhuge write -> 4\n",
        r"empty write -> 0\n",
        r"\.{4191}\ncross-page write -> 4192\n",
        r"syscall 999 -> -38\n",
    ]:
        c.contains(out, pattern, "run t_sys")
    exited(c, out, "t_sys", 42)


def case_protection(q, c, mode):
    check_killed(c, q.command("run t_wx"), "t_wx", "store_page_fault", stval_range=USER_SPACE)
    check_killed(c, q.command("run t_stack"), "t_stack", "store_page_fault", stval_range=GUARD_PAGE)
    # stval 是那条指令的编码：csrr rd, sstatus（= csrrs rd, sstatus, x0）。rd（第 7..11 位）随寄存器分配变化，不比较
    check_killed(c, q.command("run t_priv"), "t_priv", "illegal_instruction", stval=0x10002073, stval_mask=~(0x1F << 7))
    # sstatus.FS = Off，浮点指令是非法指令。stval 是 fmv.d.x f1, a0 的编码
    check_killed(c, q.command("run t_fp"), "t_fp", "illegal_instruction", stval=0xF20500D3)
    out = q.command("run t_noperm")
    c.contains(out, r"run: cannot load t_noperm: BadElf", "run t_noperm")
    c.expect("should never run" not in out, "run t_noperm: the program ran")


def case_fork(q, c, mode):
    # t_fork 自己检查 fork、exec、wait、kill 等的边界情况，失败的项打印 FAIL
    out = q.command("run t_fork")
    c.contains(out, r"\d+ checks, 0 failed", "run t_fork")
    c.expect("FAIL" not in out, f"run t_fork:\n{indent(out)}")
    m = c.contains(out, r"child pid (\d+) execs hello", "run t_fork")
    if m:  # exec 之后 pid 不变
        c.contains(out, rf"Hello from U-mode! I am pid {m.group(1)},", "run t_fork: exec keeps the pid")
    c.contains(out, r"orphan's parent is pid 1\n", "run t_fork: orphans go to init")
    c.contains(out, rf"forked {MAX_PROCS - 3} children before the table was full", "run t_fork")
    exited(c, out, "t_fork", 0)

    # read：一行分几次读完；之后对睡在 read 里的进程按 Ctrl-C
    start = len(q.text())
    prompts = q.text().count(PROMPT)
    q.send("run t_read\r")
    q.wait_for(lambda t: "reading\n" in t[start:], COMMAND_TIMEOUT, "t_read to start")
    q.send("hello world\r")
    out = q.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, "the prompt after t_read")[start:]
    m = c.contains(out, r'got "hello world" in (\d+) reads', "run t_read")
    if m:
        c.expect(int(m.group(1)) >= 4, f"run t_read: a 12-byte line in {m.group(1)} reads of at most 3 bytes")
    exited(c, out, "t_read", 0)
    start = len(q.text())
    prompts = q.text().count(PROMPT)
    q.send("run t_read\r")
    q.wait_for(lambda t: "reading\n" in t[start:], COMMAND_TIMEOUT, "t_read to start")
    q.send("\x03")
    out = q.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, "the prompt after Ctrl-C on t_read")[start:]
    c.contains(out, r"\^C\n\[proc\] pid \d+ \(t_read\) killed: interrupted by Ctrl-C", "run t_read + Ctrl-C")

    # shell 被杀之后 init 重新启动一个
    out = q.command("ps")
    m = re.search(r"^ *(\d+) +1 running +\d+ sh$", out, re.M)
    c.expect(m is not None, f"ps: no running sh:\n{indent(out)}")
    if m:
        out = q.command(f"kill {m.group(1)}")
        c.contains(out, rf"\[proc\] pid {m.group(1)} \(sh\) killed: kill\(\)\ninit: sh exited, restarting it\n"
                   r"Type 'help' for commands\.", "kill sh")
        exited(c, q.command("run hello"), "hello", 0)


# 每个用例覆盖的文件。改了 CORE 里的文件（或者没列出的内核文件）就跑全部用例。
CORE = ["build.zig", "linker.ld", "src/main.zig", "src/riscv.zig", "src/trap.zig", "src/vm.zig", "src/page.zig",
        "src/dtb.zig", "src/uart.zig", "src/proc.zig", "src/syscall.zig", "src/abi.zig", "user/start.zig",
        "user/sys.zig", "user/init.zig", "user/sh.zig", "tools/qemu_test.py"]
NOT_KERNEL = ["src/tests.zig"]  # 只在单元测试里用
CASES = {
    # 名字: (函数, 覆盖的文件)
    "shell": (case_shell, []),
    "interrupts": (case_interrupts, ["src/timer.zig", "src/sbi.zig", "src/plic.zig", "user/spin.zig"]),
    "user": (case_user, ["user/linker.ld", "user/hello.zig", "user/fault.zig", "user/tests/t_panic.zig",
                         "user/tests/t_time.zig"]),
    "sched": (case_sched, ["src/timer.zig", "user/spin.zig", "user/ticker.zig", "user/hello.zig",
                           "user/tests/t_sleep.zig"]),
    "syscall": (case_syscall, ["user/tests/t_sys.zig"]),
    "fork": (case_fork, ["user/hello.zig", "user/tests/t_fork.zig", "user/tests/t_read.zig"]),
    "protection": (case_protection, ["user/linker.ld", "user/tests/t_wx.zig", "user/tests/t_stack.zig",
                                     "user/tests/t_priv.zig", "user/tests/t_fp.zig", "user/tests/t_noperm.zig",
                                     "user/tests/noperm.ld"]),
}


def changed_files():
    """工作区里相对 HEAD 改过的文件，加上还没被 git 跟踪的新文件。"""
    out = []
    for cmd in (["git", "diff", "--name-only", "HEAD"], ["git", "ls-files", "--others", "--exclude-standard"]):
        out += subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, text=True, check=True).stdout.split()
    return sorted(set(out))


def cases_for(files):
    """按改动的文件挑出要跑的用例。返回 (用例名的集合, 每个文件选中了什么的说明)。"""
    selected, notes = set(), []
    for f in files:
        kernel = f.startswith(("src/", "user/")) or f in CORE
        hits = [name for name, (_, covers) in CASES.items() if f in covers]
        if f in NOT_KERNEL or not kernel:
            continue
        if f.startswith("user/tests/") and not os.path.exists(os.path.join(ROOT, f)):
            continue  # 删掉的测试程序
        if f in CORE or not hits:
            selected |= set(CASES)
            notes.append(f"{f} -> all")
        else:
            selected |= set(hits)
            notes.append(f"{f} -> {', '.join(hits)}")
    return selected, notes


def build(mode, prefix):
    cmd = ["zig", "build", f"-Doptimize={mode}", "-p", prefix, "-Dtest-programs=true"]
    r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    # 链接器的警告会以 "error: warning(link)" 打印出来，但 zig build 仍然返回 0，所以输出必须为空
    if r.returncode != 0 or r.stdout.strip():
        raise Failure(f"`{' '.join(cmd)}` failed (exit {r.returncode}) or printed output:\n{indent(r.stdout)}")


def check_boot(q, c):
    text = q.wait_for(lambda t: "Type 'help' for commands.\n> " in t or "KERNEL PANIC" in t, BOOT_TIMEOUT, "the first prompt")
    for pattern in [
        r"Hello from a Zig kernel on RISC-V!",
        r"\[ok\] trap vector installed",
        r"\[trap\] breakpoint at 0x[0-9a-f]+, skipping it",
        rf"\[ok\] device tree: \d+ MiB RAM at 0x80000000, timebase {TIMEBASE_HZ} Hz",
        r"\[ok\] page allocator: \d+ free pages",
        r"\[ok\] Sv39 paging enabled",
        r"\[ok\] interrupts enabled: timer at 100 Hz",
    ]:
        c.contains(text, pattern, "boot log")


def run_session(kernel, log_path, names, mode):
    """启动一次 QEMU，依次运行 names 里的用例。返回 [(名字, Checks)]，第一项是启动和收尾的检查。"""
    session = Checks()
    results = [("boot", session)]
    current = session  # 出错时，错误记在正在跑的那一项上
    q = Qemu(kernel)
    try:
        check_boot(q, session)
        before = free_pages(q.command("mem"))
        for name in names:
            current = Checks()
            results.append((name, current))
            CASES[name][0](q, current, mode)
        current = session  # 收尾的检查也记在 boot 上
        after = free_pages(q.command("mem"))
        session.expect(before is not None and before == after, f"mem: free pages changed from {before} to {after} (leak?)")
        q.send("shutdown\r")
        code = q.finish(COMMAND_TIMEOUT)
        session.expect(code == 0, f"shutdown: QEMU exit code {code}, expected 0")
    except Failure as e:
        current.failures.append(str(e))  # 之后的用例没有运行
    finally:
        q.kill()
        with open(log_path, "w", encoding="utf-8") as f:
            f.write(q.text())
    if "KERNEL PANIC" in q.text():
        session.failures.append("KERNEL PANIC in the serial output")
    return results


def run_mode(mode, names):
    prefix = os.path.join(ROOT, "zig-out", "qemu-test", mode)
    try:
        build(mode, prefix)
    except Failure as e:
        return [("build", Checks(), str(e), None)]
    kernel = os.path.join(prefix, "bin", "kernel")
    log = os.path.join(prefix, "serial.log")
    return [(n, c, None, log) for n, c in run_session(kernel, log, names, mode)]


def main():
    parser = argparse.ArgumentParser(description="Run the kernel in QEMU and check the results.")
    parser.add_argument("cases", nargs="*", help=f"cases to run (default: all): {', '.join(CASES)}")
    parser.add_argument("--changed", action="store_true", help="only run the cases covering files changed since HEAD")
    parser.add_argument("--mode", action="append", choices=MODES, help="optimize mode (repeatable; default: safe)")
    parser.add_argument("--all-modes", action="store_true", help="test all four optimize modes")
    parser.add_argument("--list", action="store_true", help="list the cases and the files they cover")
    args = parser.parse_args()

    if args.list:
        print(f"{'(all)':<11} {' '.join(CORE)}")
        for name, (_, covers) in CASES.items():
            print(f"{name:<11} {' '.join(covers) or '(only the files above)'}")
        return 0
    unknown = [n for n in args.cases if n not in CASES]
    if unknown:
        parser.error(f"unknown case(s): {', '.join(unknown)}; choose from {', '.join(CASES)}")
    if args.changed:
        selected, notes = cases_for(changed_files())
        for note in notes:
            print(f"changed: {note}")
        if not selected:
            print("no kernel-related changes, nothing to test")
            return 0
    else:
        selected = set(args.cases) or set(CASES)
    names = [n for n in CASES if n in selected]
    modes = MODES if args.all_modes else (args.mode or ["safe"])

    failed = False
    for mode in modes:
        started = time.monotonic()
        results = run_mode(mode, names)
        for name, c, error, log in results:
            if error:
                c.failures.append(error)
            status = "PASS" if not c.failures else "FAIL"
            print(f"{status}  {mode:<5}  {name:<10}  {c.count} checks")
            for f in c.failures:
                print(f"    - {f}")
            if c.failures:
                failed = True
                if log:
                    print(f"    serial log: {os.path.relpath(log, ROOT)}")
        print(f"      {mode:<5}  {time.monotonic() - started:.1f}s")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
