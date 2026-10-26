//! RISC-V 特权架构相关的辅助函数：读写 CSR、开关中断、刷新 TLB。

/// 内核会用到的 S 模式 CSR。枚举名就是汇编里的寄存器名。
pub const Csr = enum {
    sstatus,
    sie,
    sip,
    stvec,
    sscratch,
    sepc,
    scause,
    stval,
    satp,
    time,
};

// sstatus 中的位
pub const sstatus_sie: usize = 1 << 1; // S 模式全局中断使能
pub const sstatus_spie: usize = 1 << 5; // 陷入前的 SIE，sret 时恢复到 SIE
pub const sstatus_spp: usize = 1 << 8; // 陷入前的特权级：0 = U，1 = S；sret 回到这个特权级
pub const sstatus_fs: usize = 3 << 13; // 浮点单元状态（2 位）：0 = Off，这时浮点指令都是非法指令

// sie 中的位：分别使能三类 S 模式中断
pub const sie_ssie: usize = 1 << 1; // 软件中断
pub const sie_stie: usize = 1 << 5; // 时钟中断
pub const sie_seie: usize = 1 << 9; // 外部中断（来自 PLIC）

/// satp 的 MODE 字段（最高 4 位）为 8 表示 Sv39，低 44 位是根页表的物理页号。
pub const satp_sv39: usize = 8 << 60;

pub inline fn read(comptime csr: Csr) usize {
    return asm volatile ("csrr %[ret], " ++ @tagName(csr)
        : [ret] "=r" (-> usize),
    );
}

pub inline fn write(comptime csr: Csr, value: usize) void {
    asm volatile ("csrw " ++ @tagName(csr) ++ ", %[value]"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

/// 把 mask 中为 1 的位置 1。
pub inline fn set(comptime csr: Csr, mask: usize) void {
    asm volatile ("csrs " ++ @tagName(csr) ++ ", %[mask]"
        :
        : [mask] "r" (mask),
        : .{ .memory = true });
}

/// 把 mask 中为 1 的位清 0。
pub inline fn clear(comptime csr: Csr, mask: usize) void {
    asm volatile ("csrc " ++ @tagName(csr) ++ ", %[mask]"
        :
        : [mask] "r" (mask),
        : .{ .memory = true });
}

pub inline fn enableInterrupts() void {
    set(.sstatus, sstatus_sie);
}

pub inline fn disableInterrupts() void {
    clear(.sstatus, sstatus_sie);
}

/// 让 CPU 休眠直到有中断待处理。
/// 只要中断在 sie 里被使能，即使 sstatus.SIE 为 0，wfi 也会被唤醒。
pub inline fn wfi() void {
    asm volatile ("wfi" ::: .{ .memory = true });
}

/// 清空整个 TLB（页表缓存）。改了正在使用的页表、或者切换 satp 之后都要执行，
/// 否则 CPU 可能还在用旧的地址翻译结果。
pub inline fn sfenceVma() void {
    asm volatile ("sfence.vma zero, zero" ::: .{ .memory = true });
}
