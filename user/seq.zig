//! 打印一串整数，一行一个：`seq LAST`（从 1 到 LAST）、`seq FIRST LAST`、`seq FIRST STEP LAST`（STEP 可以是负数）。
//! 配合 xargs 当循环用：`seq 3 | xargs -n 1 echo hi`。

const std = @import("std");
const sys = @import("sys");

pub fn main() u8 {
    const n = sys.argv.len - 1;
    if (n < 1 or n > 3) return usage();
    var nums: [3]i64 = undefined;
    for (sys.argv[1..], nums[0..n]) |a, *x| {
        x.* = std.fmt.parseInt(i64, a.slice(), 10) catch {
            sys.fprint(sys.stderr, "seq: not an integer: '{s}'\n", .{a.slice()});
            return 2;
        };
    }
    const first: i64 = if (n >= 2) nums[0] else 1;
    const step: i64 = if (n == 3) nums[1] else 1;
    const last = nums[n - 1];
    if (step == 0) {
        sys.fprint(sys.stderr, "seq: the step must not be 0\n", .{});
        return 2;
    }
    var i = first;
    while (if (step > 0) i <= last else i >= last) {
        sys.print("{d}\n", .{i});
        i = std.math.add(i64, i, step) catch break;
    }
    return 0;
}

fn usage() u8 {
    sys.fprint(sys.stderr, "usage: seq [FIRST [STEP]] LAST\n", .{});
    return 2;
}
