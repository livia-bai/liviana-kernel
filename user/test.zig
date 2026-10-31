//! 检查条件，用退出码回答：成立是 0，不成立是 1，写错了是 2（和 Unix 的 test 一样）。
//! shell 没有 if，配合 `&&`、`||` 用：`test -f /a && cat /a || echo no file`。
//!
//!   -e PATH   存在              -f PATH  是普通文件      -d PATH  是目录
//!   -L PATH   是符号链接（不跟着走）  -s PATH  存在并且不是空的
//!   -z STR    是空串            -n STR   不是空串        STR      不是空串
//!   S1 = S2、S1 != S2           字符串相等、不相等
//!   N1 -eq N2（还有 -ne -lt -le -gt -ge）  整数比较，可以是负数
//!   ! E       E 不成立          E1 -a E2  都成立          E1 -o E2  有一个成立（-a 先算）
//!   ( E )     括号（shell 不把括号当运算符，直接写就行，前后要有空格）
//! 没有参数时不成立。和 Unix 一样，一元运算符后面没有东西时（`test -f`）当成普通的字符串。

const std = @import("std");
const sys = @import("sys");

/// NotInteger 的时候已经说明过原因了
const Error = error{ Syntax, NotInteger };

var args: []const sys.abi.Arg = &.{};
var pos: usize = 0;

pub fn main() u8 {
    args = sys.argv[@min(1, sys.argv.len)..];
    if (args.len == 0) return 1;
    const ok = orExpr() catch |err| return if (err == error.NotInteger) 2 else syntax();
    if (pos != args.len) return syntax();
    return if (ok) 0 else 1;
}

fn syntax() u8 {
    if (pos < args.len) {
        sys.fprint(sys.stderr, "test: unexpected '{s}'\n", .{args[pos].slice()});
    } else {
        sys.fprint(sys.stderr, "test: missing argument\n", .{});
    }
    return 2;
}

fn peek(offset: usize) ?[]const u8 {
    return if (pos + offset < args.len) args[pos + offset].slice() else null;
}

fn take() Error![]const u8 {
    const a = peek(0) orelse return error.Syntax;
    pos += 1;
    return a;
}

fn isOp(a: ?[]const u8, op: []const u8) bool {
    return if (a) |s| std.mem.eql(u8, s, op) else false;
}

fn orExpr() Error!bool {
    var v = try andExpr();
    while (isOp(peek(0), "-o")) {
        pos += 1;
        v = try andExpr() or v;
    }
    return v;
}

fn andExpr() Error!bool {
    var v = try notExpr();
    while (isOp(peek(0), "-a")) {
        pos += 1;
        v = try notExpr() and v;
    }
    return v;
}

fn notExpr() Error!bool {
    // `! X` 是取反，但 `! = X` 是在比较字符串 "!"
    if (isOp(peek(0), "!") and !isBinary(peek(1))) {
        pos += 1;
        return !try notExpr();
    }
    return primary();
}

const binary_ops = [_][]const u8{ "=", "!=", "-eq", "-ne", "-lt", "-le", "-gt", "-ge" };

fn isBinary(a: ?[]const u8) bool {
    for (binary_ops) |op| if (isOp(a, op)) return true;
    return false;
}

fn primary() Error!bool {
    if (isOp(peek(0), "(") and peek(1) != null) {
        pos += 1;
        const v = try orExpr();
        if (!isOp(try take(), ")")) return error.Syntax;
        return v;
    }
    // 两个参数以上、第二个是二元运算符：比较
    if (isBinary(peek(1)) and peek(2) != null) {
        const a = try take();
        const op = try take();
        const b = try take();
        return compare(a, op, b);
    }
    const a = try take();
    // 一元运算符后面跟着东西：`-f x`；单独一个 `-f` 是普通的字符串（非空，成立）
    if (a.len == 2 and a[0] == '-' and peek(0) != null and !isOp(peek(0), "-a") and !isOp(peek(0), "-o")) {
        switch (a[1]) {
            'z' => return (try take()).len == 0,
            'n' => return (try take()).len != 0,
            'e', 'f', 'd', 'L', 's' => return fileTest(a[1], try take()),
            else => {},
        }
    }
    return a.len != 0;
}

fn compare(a: []const u8, op: []const u8, b: []const u8) Error!bool {
    if (std.mem.eql(u8, op, "=")) return std.mem.eql(u8, a, b);
    if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, a, b);
    const x = integer(a) orelse return error.NotInteger;
    const y = integer(b) orelse return error.NotInteger;
    if (std.mem.eql(u8, op, "-eq")) return x == y;
    if (std.mem.eql(u8, op, "-ne")) return x != y;
    if (std.mem.eql(u8, op, "-lt")) return x < y;
    if (std.mem.eql(u8, op, "-le")) return x <= y;
    if (std.mem.eql(u8, op, "-gt")) return x > y;
    return x >= y;
}

fn integer(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch {
        sys.fprint(sys.stderr, "test: not an integer: '{s}'\n", .{s});
        return null;
    };
}

fn fileTest(op: u8, path: []const u8) bool {
    if (op == 'L') {
        const st = sys.lstat(path) catch return false;
        return st.kind == .symlink;
    }
    // 别的都跟着符号链接走：打开它再 fstat
    const fd = sys.open(path, .{}) catch return false;
    defer sys.close(fd) catch {};
    const st = sys.fstat(fd) catch return false;
    return switch (op) {
        'e' => true,
        'f' => st.kind == .file,
        'd' => st.kind == .dir,
        's' => st.size > 0,
        else => unreachable,
    };
}
