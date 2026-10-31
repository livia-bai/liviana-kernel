//! 整数运算：`expr 1 + 2` 打印 `3`。shell 没有算术（也没有 `$(...)`），脚本里用它算，结果打印出来，
//! 或者只看退出码：`expr $# '>' 1 > /dev/null && echo many`。
//! 每个数、每个运算符都是单独的参数（要用空格隔开）。`*` 在 shell 里会被当成文件名匹配，要写成 '*' 或者 \*。
//!
//! 运算符（优先级从低到高）：`|`（左边不是 0 就是左边，否则是右边）、`&`（两边都不是 0 就是左边，否则是 0）、
//! `= != < <= > >=`（成立是 1，否则是 0）、`+ -`、`* / %`，同一级从左到右；括号 `(` `)`。
//! 数是 64 位有符号整数，溢出、除以 0 都是错误。
//! 退出码和 Unix 的 expr 一样：结果不是 0 是 0，结果是 0 是 1，写错了是 2。

const std = @import("std");
const sys = @import("sys");

const Error = error{ Syntax, NotANumber, Overflow, DivisionByZero };

var args: []const sys.abi.Arg = &.{};
var pos: usize = 0;

pub fn main() u8 {
    args = sys.argv[@min(1, sys.argv.len)..];
    const v = parse() catch |err| {
        switch (err) {
            error.Syntax => if (pos < args.len)
                sys.fprint(sys.stderr, "expr: syntax error at '{s}'\n", .{args[pos].slice()})
            else
                sys.fprint(sys.stderr, "expr: syntax error\n", .{}),
            error.NotANumber => sys.fprint(sys.stderr, "expr: not a number: '{s}'\n", .{args[pos - 1].slice()}),
            error.Overflow => sys.fprint(sys.stderr, "expr: overflow\n", .{}),
            error.DivisionByZero => sys.fprint(sys.stderr, "expr: division by zero\n", .{}),
        }
        return 2;
    };
    sys.print("{d}\n", .{v});
    return if (v != 0) 0 else 1;
}

fn parse() Error!i64 {
    if (args.len == 0) return error.Syntax;
    const v = try orExpr();
    if (pos != args.len) return error.Syntax;
    return v;
}

fn peek() ?[]const u8 {
    return if (pos < args.len) args[pos].slice() else null;
}

/// 下一个参数是 ops 里的哪个运算符（是的话吃掉它），不是返回 null。
fn op(comptime ops: []const []const u8) ?usize {
    const a = peek() orelse return null;
    for (ops, 0..) |o, i| {
        if (std.mem.eql(u8, a, o)) {
            pos += 1;
            return i;
        }
    }
    return null;
}

fn orExpr() Error!i64 {
    var v = try andExpr();
    while (op(&.{"|"}) != null) {
        const r = try andExpr();
        if (v == 0) v = r;
    }
    return v;
}

fn andExpr() Error!i64 {
    var v = try cmpExpr();
    while (op(&.{"&"}) != null) {
        const r = try cmpExpr();
        if (r == 0) v = 0;
    }
    return v;
}

fn cmpExpr() Error!i64 {
    var v = try addExpr();
    while (op(&.{ "=", "!=", "<", "<=", ">", ">=" })) |i| {
        const r = try addExpr();
        const t = switch (i) {
            0 => v == r,
            1 => v != r,
            2 => v < r,
            3 => v <= r,
            4 => v > r,
            else => v >= r,
        };
        v = @intFromBool(t);
    }
    return v;
}

fn addExpr() Error!i64 {
    var v = try mulExpr();
    while (op(&.{ "+", "-" })) |i| {
        const r = try mulExpr();
        v = if (i == 0) try std.math.add(i64, v, r) else try std.math.sub(i64, v, r);
    }
    return v;
}

fn mulExpr() Error!i64 {
    var v = try primary();
    while (op(&.{ "*", "/", "%" })) |i| {
        const r = try primary();
        if (i == 0) {
            v = try std.math.mul(i64, v, r);
        } else {
            if (r == 0) return error.DivisionByZero;
            if (v == std.math.minInt(i64) and r == -1) return error.Overflow;
            v = if (i == 1) @divTrunc(v, r) else @rem(v, r);
        }
    }
    return v;
}

fn primary() Error!i64 {
    if (op(&.{"("}) != null) {
        const v = try orExpr();
        if (op(&.{")"}) == null) return error.Syntax;
        return v;
    }
    const a = peek() orelse return error.Syntax;
    pos += 1;
    return std.fmt.parseInt(i64, a, 10) catch |err| switch (err) {
        error.Overflow => error.Overflow,
        error.InvalidCharacter => error.NotANumber,
    };
}
