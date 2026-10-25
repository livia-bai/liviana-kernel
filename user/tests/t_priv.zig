//! 回归测试：在 U 模式读 S 模式的 CSR，应该触发 illegal_instruction 被结束。

pub fn main() u8 {
    const s = asm volatile ("csrr %[r], sstatus"
        : [r] "=r" (-> usize),
    );
    return @truncate(s);
}
