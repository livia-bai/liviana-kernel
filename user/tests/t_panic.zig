//! 回归测试：整数溢出。Debug/safe 模式下触发 panic，以退出码 255 结束；
//! fast/small 模式没有溢出检查，250 + 10 回绕成 4，以退出码 4 结束。

pub fn main() u8 {
    var x: u8 = 250;
    const p: *volatile u8 = &x;
    p.* += 10;
    return x;
}
