//! 演示抢占：进入死循环，不再做任何系统调用。即便如此，时钟和串口中断照样会让内核拿回 CPU，
//! 内核在中断里发现用户按了 Ctrl-C，就结束这个进程。

const sys = @import("sys");

pub fn main() u8 {
    sys.print("spinning in U-mode without making syscalls, press Ctrl-C to stop\n", .{});
    while (true) {}
}
