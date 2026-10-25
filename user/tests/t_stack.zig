//! 回归测试：无限递归，栈溢出撞到用户栈下面的保护页，
//! 应该触发 store_page_fault，stval 落在 0x7fffb000..0x7fffc000。

fn recurse(n: usize) usize {
    var buf: [256]u8 = undefined;
    buf[n % buf.len] = @truncate(n);
    const v: *volatile u8 = &buf[0];
    return recurse(n + 1) + v.*;
}

pub fn main() u8 {
    return @truncate(recurse(0));
}
