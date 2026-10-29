//! 数标准输入里的行数、单词数、字节数，读到结尾后打印出来，和 Unix 的 wc 一样：`run echo a b | wc` 打印 `1 2 4`。

const sys = @import("sys");

pub fn main() u8 {
    var lines: usize = 0;
    var words: usize = 0;
    var bytes: usize = 0;
    var in_word = false;
    var buf: [512]u8 = undefined;
    while (true) {
        const n = sys.read(sys.stdin, &buf) catch return 1;
        if (n == 0) break;
        bytes += n;
        for (buf[0..n]) |c| {
            const space = c == ' ' or c == '\n' or c == '\r' or c == '\t';
            if (c == '\n') lines += 1;
            if (!space and !in_word) words += 1;
            in_word = !space;
        }
    }
    sys.print("{d} {d} {d}\n", .{ lines, words, bytes });
    return 0;
}
