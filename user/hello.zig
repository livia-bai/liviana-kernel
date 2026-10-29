//! 第一个用户程序：在 U 模式下打招呼，顺便试一试几个系统调用。

const sys = @import("sys");

pub fn main() u8 {
    sys.print("Hello from U-mode! I am pid {d}, the kernel has been up for {d} ms.\n", .{
        sys.getpid(), sys.uptime(),
    });

    // 内核会检查 write 收到的指针：传一个内核地址进去，只会得到错误，不会把内核的内存打印出来
    const kernel_text: [*]const u8 = @ptrFromInt(0x8020_0000);
    if (sys.write(sys.stdout, kernel_text[0..16])) |_| {
        sys.print("the kernel leaked its own memory!\n", .{});
    } else |err| {
        sys.print("write() refused a kernel pointer: {s}\n", .{@errorName(err)});
    }
    return 0;
}
