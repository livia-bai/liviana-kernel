//! 把命令行参数用空格连起来，加上换行，写到标准输出。和 Unix 的 echo 一样，用来演示命令行参数和管道：
//! `run echo hello world | wc`。
//! 整行拼好了一次写出去（参数最多 abi.max_arg_bytes 字节，放得下），不会和别的进程的输出交错在一行中间。

const sys = @import("sys");
const abi = sys.abi;

var line: [abi.max_arg_bytes + abi.max_args + 1]u8 = undefined;

pub fn main() u8 {
    var n: usize = 0;
    for (sys.argv[@min(1, sys.argv.len)..], 1..) |a, i| {
        if (i > 1) {
            line[n] = ' ';
            n += 1;
        }
        @memcpy(line[n..][0..a.len], a.slice());
        n += a.len;
    }
    line[n] = '\n';
    sys.writeAll(sys.stdout, line[0 .. n + 1]) catch return 1;
    return 0;
}
