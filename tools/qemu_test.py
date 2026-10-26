#!/usr/bin/env python3
"""在 QEMU 里测试内核：构建，启动，按提示符逐条输入命令，检查输出。

检查分成几个用例（--list 查看），每个用例写明它覆盖哪些源文件：
  python3 tools/qemu_test.py                  # 全部用例，safe 模式
  python3 tools/qemu_test.py --changed        # 只跑和未提交的改动有关的用例
  python3 tools/qemu_test.py shell panic      # 只跑指定的用例
  python3 tools/qemu_test.py --all-modes      # 四种优化模式都跑（改了汇编、中断、页表、进出 U 模式时用）

每种模式只构建一次（带上 user/tests/ 里的测试程序），所有用例共用一次启动；
panic 用例让内核停机，单独启动一次。启动日志每次都检查；结束时比较前后两次 mem 的空闲页数
（不能漏页）、shutdown 后 QEMU 的退出码必须为 0、输出里不能有 KERNEL PANIC。
panic 用例读 /proc/<pid>/stat 统计 QEMU 的 CPU 时间，只能在 Linux 上运行。
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
HALT_SECONDS = 1.0  # panic 停机后量多久 QEMU 的 CPU 时间
MAX_HALT_CPU = 0.5  # 停机期间 QEMU 最多占用一个核的多少（忙等时接近 100%，正常接近 0）

# 用户地址空间里栈下面那一页保护页（src/proc.zig）
GUARD_PAGE = (0x7FFFB000, 0x7FFFC000)
USER_SPACE = (0x40000000, 0x80000000)


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

    def cpu_seconds(self):
        """QEMU 进程（所有线程）到目前为止用掉的 CPU 时间，单位秒。读 /proc，只支持 Linux。"""
        try:
            with open(f"/proc/{self.proc.pid}/stat", encoding="ascii") as f:
                # 第 2 项是括号里的进程名，可能含空格，所以从最后一个 ')' 之后开始数：
                # 之后的第 0 项是第 3 项 state，utime、stime 是第 14、15 项
                fields = f.read().rsplit(")", 1)[1].split()
        except OSError as e:
            raise Failure(f"cannot read QEMU's CPU time from /proc (Linux only): {e}")
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")

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
    c.contains(q.command("uptime"), r"up \d+\.\d\ds \(\d+ timer interrupts\)", "uptime")
    c.contains(q.command("nope"), r"unknown command: nope", "unknown command")
    c.contains(q.command("ebreak"), r"\[trap\] breakpoint at 0x[0-9a-f]+, skipping it", "ebreak")


def case_interrupts(q, c, mode):
    # spin 在 U 模式里死循环。这段时间里内核只能靠中断拿回 CPU，
    # 所以前后两次 uptime 的差说明时钟中断在 U 模式下照常发生；Ctrl-C 靠串口中断送进来
    before = uptime_ticks(q, c)
    start = len(q.text())
    prompts = q.text().count(PROMPT)
    q.send("run spin\r")
    q.wait_for(lambda t: "press Ctrl-C to stop" in t[start:], COMMAND_TIMEOUT, "spin to start")
    time.sleep(SPIN_SECONDS)
    q.send("\x03")
    out = q.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, "the prompt after Ctrl-C")[start:]
    c.contains(out, r"\^C\n\[proc\] pid \d+ \(spin\) killed: interrupted by Ctrl-C", "run spin + Ctrl-C")
    after = uptime_ticks(q, c)
    if before is not None and after is not None:
        c.expect(after - before >= MIN_SPIN_TICKS,
                 f"uptime: only {after - before} timer interrupts while spin ran for {SPIN_SECONDS}s")
    # 在 shell 里按的 Ctrl-C 不应该影响之后运行的程序
    q.send("\x03")
    exited(c, q.command("run hello"), "hello", 0)


def uptime_ticks(q, c):
    m = c.contains(q.command("uptime"), r"up \d+\.\d\ds \((\d+) timer interrupts\)", "uptime")
    return int(m.group(1)) if m else None


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


def case_panic(q, c, mode):
    start = len(q.text())
    q.send("crash\r")
    text = q.wait_for(lambda t: "system halted.\n" in t[start:], COMMAND_TIMEOUT, "the kernel to halt after 'crash'")
    c.contains(text[start:], r"!!! KERNEL PANIC: unhandled exception: load_page_fault \(scause=13\), "
               r"sepc=0x[0-9a-f]+, stval=0x0\n", "crash")
    # 停机后 QEMU 应该几乎不占 CPU：时钟中断没人再预约，会一直挂着，wfi 如果还能被它唤醒就成了忙等
    before = q.cpu_seconds()
    time.sleep(HALT_SECONDS)
    used = (q.cpu_seconds() - before) / HALT_SECONDS
    c.expect(used <= MAX_HALT_CPU,
             f"crash: QEMU used {used:.0%} of a CPU during {HALT_SECONDS}s after the kernel halted (busy-waiting?)")


# 每个用例覆盖的文件。改了 CORE 里的文件（或者没列出的内核文件）就跑全部用例。
CORE = ["build.zig", "linker.ld", "src/main.zig", "src/riscv.zig", "src/trap.zig", "src/vm.zig", "src/page.zig",
        "src/dtb.zig", "src/uart.zig", "tools/qemu_test.py"]
NOT_KERNEL = ["src/tests.zig"]  # 只在单元测试里用
CASES = {
    # 名字: (函数, 覆盖的文件, 是否以内核停机结束)
    "shell": (case_shell, ["src/shell.zig"], False),
    "interrupts": (case_interrupts, ["src/timer.zig", "src/sbi.zig", "src/plic.zig", "src/proc.zig", "user/spin.zig"], False),
    "user": (case_user, ["src/proc.zig", "src/syscall.zig", "src/abi.zig", "user/start.zig", "user/sys.zig",
                         "user/linker.ld", "user/hello.zig", "user/fault.zig", "user/tests/t_panic.zig",
                         "user/tests/t_time.zig"], False),
    "syscall": (case_syscall, ["src/syscall.zig", "src/abi.zig", "user/sys.zig", "user/tests/t_sys.zig"], False),
    "protection": (case_protection, ["src/proc.zig", "user/linker.ld", "user/tests/t_wx.zig", "user/tests/t_stack.zig",
                                     "user/tests/t_priv.zig", "user/tests/t_fp.zig", "user/tests/t_noperm.zig",
                                     "user/tests/noperm.ld"], False),
    # 要测的 kernelPanic 在 src/main.zig 里，属于 CORE
    "panic": (case_panic, [], True),
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
        hits = [name for name, (_, covers, _) in CASES.items() if f in covers]
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


def run_session(kernel, log_path, names, mode, halts):
    """启动一次 QEMU，依次运行 names 里的用例。返回 [(名字, Checks)]，第一项是启动和收尾的检查。"""
    session = Checks()
    results = [("boot", session)]
    current = session  # 出错时，错误记在正在跑的那一项上
    q = Qemu(kernel)
    try:
        check_boot(q, session)
        before = None if halts else free_pages(q.command("mem"))
        for name in names:
            current = Checks()
            results.append((name, current))
            CASES[name][0](q, current, mode)
        current = session  # 收尾的检查也记在 boot 上
        if not halts:
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
    if not halts and "KERNEL PANIC" in q.text():
        session.failures.append("KERNEL PANIC in the serial output")
    return results


def run_mode(mode, names):
    prefix = os.path.join(ROOT, "zig-out", "qemu-test", mode)
    try:
        build(mode, prefix)
    except Failure as e:
        return [("build", Checks(), str(e), None)]
    kernel = os.path.join(prefix, "bin", "kernel")
    results = []
    normal = [n for n in names if not CASES[n][2]]
    if normal:
        log = os.path.join(prefix, "serial.log")
        results += [(n, c, None, log) for n, c in run_session(kernel, log, normal, mode, False)]
    for n in names:
        if CASES[n][2]:  # 以停机结束的用例各自启动一次，启动检查算在这个用例里
            log = os.path.join(prefix, f"{n}.log")
            session = run_session(kernel, log, [n], mode, True)
            c = Checks()
            for _, sc in session:
                c.count += sc.count
                c.failures += sc.failures
            results.append((n, c, None, log))
    return results


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
        for name, (_, covers, _) in CASES.items():
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
