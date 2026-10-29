//! 把命令行参数用空格连起来，加上换行，写到标准输出。和 Unix 的 echo 一样，用来演示命令行参数和管道：
//! `run echo hello world | wc`。

const sys = @import("sys");

pub fn main() u8 {
    for (sys.argv[@min(1, sys.argv.len)..], 1..) |a, i| {
        if (i > 1) sys.writeAll(sys.stdout, " ") catch return 1;
        sys.writeAll(sys.stdout, a.slice()) catch return 1;
    }
    sys.writeAll(sys.stdout, "\n") catch return 1;
    return 0;
}
