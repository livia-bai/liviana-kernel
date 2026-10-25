//! 系统调用。用户程序执行 ecall 陷入内核后，handleTrap 把它交给 dispatch。
//! 调用约定见 abi.zig。处理期间中断是关着的，系统调用都很短，不会长时间占着 CPU。

const abi = @import("abi.zig");
const uart = @import("uart.zig");
const timer = @import("timer.zig");
const vm = @import("vm.zig");
const page = @import("page.zig");
const proc = @import("proc.zig");
const TrapFrame = @import("trap.zig").TrapFrame;

/// 返回值会写回用户程序的 a0。
pub fn dispatch(frame: *TrapFrame) usize {
    const args = frame.regs[10..16]; // a0..a5
    const number: abi.Syscall = @fromBackingInt(frame.regs[17]); // a7
    return switch (number) {
        .exit => proc.exit(@truncate(args[0])),
        .write => write(args[0], args[1]),
        .getpid => proc.current.?.pid,
        .uptime => timer.uptimeMs(),
        _ => abi.fail(.nosys),
    };
}

/// 用户内存先分块复制到内核缓冲区再输出，每块都经过 vm.copyFromUser 检查。
/// 中途遇到坏地址就停下，返回已经写出的字节数；一个字节都没写出才返回错误。
fn write(ptr: usize, len: usize) usize {
    var buf: [128]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        // 每块都不跨页：一块失败就说明这一页整个不能读，前面的字节都已经写出去了
        const va = ptr + done;
        const chunk = buf[0..@min(buf.len, len - done, page.size - va % page.size)];
        vm.copyFromUser(proc.current.?.space, chunk, va) catch {
            return if (done == 0) abi.fail(.fault) else done;
        };
        uart.write(chunk);
        done += chunk.len;
    }
    return done;
}
