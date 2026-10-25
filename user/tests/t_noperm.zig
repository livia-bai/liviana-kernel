//! 回归测试：用 user/tests/noperm.ld 链接，数据段的权限是 FLAGS(0)。
//! 内核的 ELF 加载器必须拒绝它：run 应该打印 `cannot load t_noperm: BadElf`，程序根本不会运行。

const sys = @import("sys");

// 保证数据段不是空的：可写的全局变量，并且真的写过（否则可能被优化进只读数据或者删掉）
var counter: u32 = 1;

pub fn main() u8 {
    const p: *volatile u32 = &counter;
    p.* += 1;
    sys.print("t_noperm should never run (counter = {d})\n", .{p.*});
    return 1;
}
