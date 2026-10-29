//! 把标准输入原样复制到标准输出，直到读到结尾。没有文件系统，所以不接受文件名参数。
//! 一般放在管道中间：`run echo hi | cat | wc`。直接从键盘读时输入不回显，按 Ctrl-D 结束。

const sys = @import("sys");

pub fn main() u8 {
    var buf: [512]u8 = undefined;
    while (true) {
        const n = sys.read(sys.stdin, &buf) catch return 1;
        if (n == 0) return 0;
        sys.writeAll(sys.stdout, buf[0..n]) catch return 1;
    }
}
