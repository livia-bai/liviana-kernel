//! 回归测试：往自己的代码段写。代码段只读，应该触发 store_page_fault 被结束。

pub fn main() u8 {
    const code: *volatile u16 = @ptrFromInt(@intFromPtr(&main) & ~@as(usize, 1));
    code.* = 0;
    return 0;
}
