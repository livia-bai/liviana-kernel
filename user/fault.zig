//! 演示内存保护：在 U 模式下直接读内核的内存。内核页表项没有 U 位，这次读会触发缺页异常，
//! 内核杀掉这个进程后照常运行。

const sys = @import("sys");

pub fn main() u8 {
    const kernel_text: *const volatile u32 = @ptrFromInt(0x8020_0000);
    sys.print("reading kernel memory at 0x{x} from U-mode...\n", .{@intFromPtr(kernel_text)});
    const value = kernel_text.*;
    sys.print("read 0x{x}, memory protection is broken!\n", .{value});
    return 1;
}
