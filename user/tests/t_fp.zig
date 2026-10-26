//! 回归测试：执行一条浮点指令。内核启动时把 sstatus.FS 清成 Off，浮点指令都是非法指令，
//! 应该触发 illegal_instruction 被结束，stval 是这条指令的编码 0xf20500d3。
//! FS 不是 Off 的话，这条指令会成功，f1 里的值还会留给下一个进程（见 docs/changes/0010）。

pub fn main() u8 {
    // fmv.d.x f1, a0：把 a0 的位原样放进 f1。目标是 rv64imac，汇编器不认浮点指令，只能手工编码
    asm volatile (".word 0xf20500d3"
        :
        : [value] "{a0}" (@as(usize, 0x1234_5678_9abc_def0)),
        : .{ .memory = true });
    return 0;
}
