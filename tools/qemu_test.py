#!/usr/bin/env python3
"""在 QEMU 里自动测试内核，并判定是否通过。

对每种优化模式跑三轮：
  1. 标准测试：普通构建，执行 help、uptime、mem、ebreak、run hello/fault/spin（Ctrl-C）、mem、shutdown。
  2. 回归测试：加 -Dtest-programs=true 构建，运行 user/tests/ 里的各个测试程序。
  3. panic 测试：普通构建，执行 crash，检查 panic 信息，以及停机后 QEMU 不再占用 CPU。
每一轮都检查：构建成功且没有任何输出、启动日志完整、每条命令的输出符合预期。
前两轮还检查：前后两次 mem 的空闲页数相同、没有 KERNEL PANIC、shutdown 后 QEMU 的退出码为 0。
panic 测试读 /proc/<pid>/stat 统计 QEMU 的 CPU 时间，只能在 Linux 上运行。

构建产物装到 zig-out/qemu-test/<模式>-<轮次>/（用 zig build -p），不影响 zig-out/bin/kernel。
每一轮的完整串口输出保存在同一目录下的 serial.log，失败时可以打开看。

用法：python3 tools/qemu_test.py [--mode debug|safe|fast|small ...] [--no-regression]
全部通过时退出码为 0，否则为 1。
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
TIMEBASE_HZ = 10_000_000  # QEMU virt 的 time CSR 频率，启动日志里也会检查
CLOCK_TOLERANCE_MS = 20  # t_clock：uptime() 和 rdtime 走过的时间最多差多少（量化误差最多 10 ms）
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
        """发一条命令，等下一个提示符，返回这条命令产生的输出（不含回显那一行之前的内容）。"""
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

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


class Checks:
    """收集一轮测试里的所有检查结果。"""

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


def build(mode, prefix, test_programs):
    cmd = ["zig", "build", f"-Doptimize={mode}", "-p", prefix]
    if test_programs:
        cmd.append("-Dtest-programs=true")
    r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    # 链接器的警告会以 "error: warning(link)" 打印出来，但 zig build 仍然返回 0，所以输出必须为空
    if r.returncode != 0 or r.stdout.strip():
        raise Failure(f"`{' '.join(cmd)}` failed (exit {r.returncode}) or printed output:\n{indent(r.stdout)}")


def free_pages(output):
    m = re.search(r"(\d+) of (\d+) pages free", output)
    return (int(m.group(1)), int(m.group(2))) if m else None


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


def check_killed(c, out, name, exception, stval_range=None, stval=None, stval_mask=~0):
    m = c.contains(out, rf"\[proc\] pid \d+ \({name}\) killed: {exception} at 0x[0-9a-f]+, stval=0x([0-9a-f]+)", f"run {name}")
    if m:
        value = int(m.group(1), 16)
        if stval_range:
            lo, hi = stval_range
            c.expect(lo <= value < hi, f"run {name}: stval=0x{value:x} not in [0x{lo:x}, 0x{hi:x})")
        if stval is not None:
            c.expect(value & stval_mask == stval, f"run {name}: stval=0x{value:x}, expected 0x{stval:x}")


def standard_round(q, c, mode):
    check_boot(q, c)
    out = q.command("help")
    c.contains(out, r"run NAME", "help")
    uptime_ticks(q, c)
    before = free_pages(q.command("mem"))
    c.expect(before is not None, "mem: no 'N of M pages free' line")
    out = q.command("ebreak")
    c.contains(out, r"\[trap\] breakpoint at 0x[0-9a-f]+, skipping it", "ebreak")
    out = q.command("run hello")
    c.contains(out, r"Hello from U-mode! I am pid 1, the kernel has been up for \d+ ms\.", "run hello")
    c.contains(out, r"write\(\) refused a kernel pointer: BadAddress", "run hello")
    c.contains(out, r"\[proc\] pid 1 \(hello\) exited with code 0", "run hello")
    out = q.command("run fault")
    check_killed(c, out, "fault", "load_page_fault", stval=0x80200000)
    # spin 在 U 模式里死循环 SPIN_SECONDS 秒。这段时间里内核只能靠中断拿回 CPU，
    # 所以前后两次 uptime 的差说明时钟中断在 U 模式下照常发生（100 Hz，0.5 秒约 50 次）
    ticks_before = uptime_ticks(q, c)
    out = spin_and_interrupt(q)
    c.contains(out, r"\^C\n\[proc\] pid 3 \(spin\) killed: interrupted by Ctrl-C", "run spin + Ctrl-C")
    ticks_after = uptime_ticks(q, c)
    if ticks_before is not None and ticks_after is not None:
        c.expect(ticks_after - ticks_before >= MIN_SPIN_TICKS,
                 f"uptime: only {ticks_after - ticks_before} timer interrupts while spin ran for {SPIN_SECONDS}s")
    return before


def uptime_ticks(q, c):
    m = c.contains(q.command("uptime"), r"up \d+\.\d\ds \((\d+) timer interrupts\)", "uptime")
    return int(m.group(1)) if m else None


def spin_and_interrupt(q):
    """run spin，等它开始转，过 SPIN_SECONDS 秒再发 Ctrl-C，等提示符。"""
    start = len(q.text())
    prompts = q.text().count(PROMPT)
    q.send("run spin\r")
    q.wait_for(lambda t: "press Ctrl-C to stop" in t[start:], COMMAND_TIMEOUT, "spin to start")
    time.sleep(SPIN_SECONDS)
    q.send("\x03")
    text = q.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, "the prompt after Ctrl-C")
    return text[start:]


def regression_round(q, c, mode):
    check_boot(q, c)
    before = free_pages(q.command("mem"))
    c.expect(before is not None, "mem: no 'N of M pages free' line")

    # 在 shell 里按的 Ctrl-C 不应该影响之后运行的程序
    q.send("\x03")
    out = q.command("run hello")
    c.contains(out, r"\[proc\] pid \d+ \(hello\) exited with code 0", "Ctrl-C at the shell, then run hello")

    out = q.command("run t_sys")
    for pattern in [
        r"abcd\npartial write -> 4\n",
        r"abcdhuge write -> 4\n",
        r"empty write -> 0\n",
        r"\.{4191}\ncross-page write -> 4192\n",
        r"syscall 999 -> -38\n",
        r"\[proc\] pid \d+ \(t_sys\) exited with code 42",
    ]:
        c.contains(out, pattern, "run t_sys")

    check_killed(c, q.command("run t_wx"), "t_wx", "store_page_fault", stval_range=USER_SPACE)
    check_killed(c, q.command("run t_stack"), "t_stack", "store_page_fault", stval_range=GUARD_PAGE)
    # stval 是那条指令的编码：csrr rd, sstatus（= csrrs rd, sstatus, x0）。rd（第 7..11 位）随寄存器分配变化，不比较
    check_killed(c, q.command("run t_priv"), "t_priv", "illegal_instruction", stval=0x10002073, stval_mask=~(0x1F << 7))
    # sstatus.FS = Off，浮点指令是非法指令。stval 是 fmv.d.x f1, a0 的编码，寄存器是写死的，整个比较
    check_killed(c, q.command("run t_fp"), "t_fp", "illegal_instruction", stval=0xF20500D3)

    out = q.command("run t_panic")
    if mode in ("debug", "safe"):
        c.contains(out, r"panic: integer overflow", "run t_panic")
        c.contains(out, r"\[proc\] pid \d+ \(t_panic\) exited with code 255", "run t_panic")
    else:  # 没有溢出检查：250 + 10 回绕成 4
        c.contains(out, r"\[proc\] pid \d+ \(t_panic\) exited with code 4\b", "run t_panic")

    out = q.command("run t_time")
    m = c.contains(out, r"rdtime from U-mode = (\d+)", "run t_time")
    if m:
        c.expect(int(m.group(1)) > 0, "run t_time: time CSR read as 0")
    c.contains(out, r"\[proc\] pid \d+ \(t_time\) exited with code 0", "run t_time")

    # t_clock 忙等到 uptime() 走过 3 秒，打印 uptime() 和 rdtime 各走了多少
    out = q.command("run t_clock")
    m = c.contains(out, r"uptime\(\) advanced (\d+) ms, rdtime advanced (\d+)\n", "run t_clock")
    if m:
        uptime_ms = int(m.group(1))
        rdtime_ms = int(m.group(2)) * 1000 / TIMEBASE_HZ
        c.expect(abs(uptime_ms - rdtime_ms) <= CLOCK_TOLERANCE_MS,
                 f"run t_clock: uptime() advanced {uptime_ms} ms while rdtime advanced {rdtime_ms:.1f} ms "
                 f"(tolerance {CLOCK_TOLERANCE_MS} ms)")
    c.contains(out, r"\[proc\] pid \d+ \(t_clock\) exited with code 0", "run t_clock")

    out = q.command("run t_noperm")
    c.contains(out, r"run: cannot load t_noperm: BadElf", "run t_noperm")
    c.expect("should never run" not in out, "run t_noperm: the program ran")
    return before


def panic_round(q, c, mode):
    check_boot(q, c)
    start = len(q.text())
    q.send("crash\r")
    text = q.wait_for(lambda t: "system halted.\n" in t[start:], COMMAND_TIMEOUT, "the kernel to halt after 'crash'")
    c.contains(text[start:], r"!!! KERNEL PANIC: unhandled exception: load_page_fault \(scause=13\), "
               r"sepc=0x[0-9a-f]+, stval=0x0\n", "crash")
    # 停机后 QEMU 应该几乎不占 CPU。时钟中断没人再预约，会一直挂着；
    # 如果它在 sie 里还是使能的，wfi 每次都立刻返回，停机就成了忙等
    before = q.cpu_seconds()
    time.sleep(HALT_SECONDS)
    used = (q.cpu_seconds() - before) / HALT_SECONDS
    c.expect(used <= MAX_HALT_CPU,
             f"crash: QEMU used {used:.0%} of a CPU during {HALT_SECONDS}s after the kernel halted (busy-waiting?)")


def run_round(mode, name, test_programs, body, halts):
    """halts 为真的一轮以内核停机结束：不比较 mem、不 shutdown，也允许出现 KERNEL PANIC。"""
    prefix = os.path.join(ROOT, "zig-out", "qemu-test", f"{mode}-{name}")
    log_path = os.path.join(prefix, "serial.log")
    c = Checks()
    q = None
    try:
        build(mode, prefix, test_programs)
        q = Qemu(os.path.join(prefix, "bin", "kernel"))
        before = body(q, c, mode)
        if not halts:
            after = free_pages(q.command("mem"))
            c.expect(before is not None and before == after, f"mem: free pages changed from {before} to {after} (leak?)")
            q.send("shutdown\r")
            code = q.finish(COMMAND_TIMEOUT)
            c.contains(q.text(), r"bye!", "shutdown")
            c.expect(code == 0, f"shutdown: QEMU exit code {code}, expected 0")
    except Failure as e:
        c.failures.append(str(e))
    finally:
        if q is not None:
            q.kill()
            os.makedirs(prefix, exist_ok=True)
            with open(log_path, "w", encoding="utf-8") as f:
                f.write(q.text())
    if q is not None and not halts and "KERNEL PANIC" in q.text():
        c.failures.append("KERNEL PANIC in the serial output")
    return c, log_path


def main():
    parser = argparse.ArgumentParser(description="Run the kernel in QEMU and check the results.")
    parser.add_argument("--mode", action="append", choices=MODES, help="optimize mode to test (repeatable; default: all four)")
    parser.add_argument("--no-regression", action="store_true", help="skip the round with the test programs from user/tests/")
    args = parser.parse_args()

    rounds = [("standard", False, standard_round, False)]
    if not args.no_regression:
        rounds.append(("regression", True, regression_round, False))
    rounds.append(("panic", False, panic_round, True))

    failed = False
    for mode in args.mode or MODES:
        for name, test_programs, body, halts in rounds:
            started = time.monotonic()
            c, log_path = run_round(mode, name, test_programs, body, halts)
            elapsed = time.monotonic() - started
            status = "PASS" if not c.failures else "FAIL"
            print(f"{status}  {mode:<5}  {name:<10}  {c.count} checks  {elapsed:5.1f}s", flush=True)
            for f in c.failures:
                print(f"    - {f}")
            if c.failures:
                print(f"    serial log: {os.path.relpath(log_path, ROOT)}")
                failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
