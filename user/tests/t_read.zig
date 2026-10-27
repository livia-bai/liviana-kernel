//! 回归测试：read。读到回车为止，每次最多读 3 个字节（所以一行要分几次读完），然后把这一行打印出来。
//! qemu_test.py 等它打印 "reading" 之后再输入。

const sys = @import("sys");

pub fn main() u8 {
    sys.print("reading\n", .{});
    var line: [64]u8 = undefined;
    var len: usize = 0;
    var calls: usize = 0;
    while (true) {
        const n = sys.read(line[len..@min(len + 3, line.len)]) catch return 1;
        calls += 1;
        len += n;
        if (n == 0 or line[len - 1] == '\r' or len == line.len) break;
    }
    sys.print("got \"{s}\" in {d} reads\n", .{ line[0 .. len - 1], calls });
    return 0;
}
