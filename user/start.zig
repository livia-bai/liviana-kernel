//! 每个用户程序的根文件，相当于 C 的 crt0：导出入口 _start、定义 panic 处理，
//! 然后调用程序本身（user/<名字>.zig，作为 program 模块导入）的 main。

const std = @import("std");
const sys = @import("sys");
const program = @import("program");

/// 内核跳到这里时 sp 已经指向用户栈顶，其他寄存器都是 0。main 的返回值就是退出码。
export fn _start() noreturn {
    sys.exit(program.main());
}

/// 用户程序 panic（包括 Debug 模式下的整数溢出、数组越界等）时打印原因，以退出码 255 结束。
pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    sys.print("panic: {s}\n", .{msg});
    sys.exit(255);
}
