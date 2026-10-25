const std = @import("std");

pub fn build(b: *std.Build) void {
    // rv64imac：不启用 F/D 浮点扩展（和 Linux 内核一样），
    // 这样编译器保证不会生成浮点指令，陷阱处理时也就不用保存浮点寄存器。
    // zicsr 是读写 CSR 的 csrr/csrw 指令，zifencei 是 fence.i，LLVM 里需要单独打开。
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv64 },
        .cpu_features_add = std.Target.riscv.featureSet(&.{ .m, .a, .c, .zicsr, .zifencei }),
    });
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // 内核链接在 0x80200000，超出了默认 medlow 模型能寻址的 ±2GiB 范围，
            // medany 改用 PC 相对寻址，代码放在哪都能访问到。
            .code_model = .medany,
        }),
    });
    kernel.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel);

    // zig build run：用 QEMU 的 virt 机器启动内核。
    // -bios default 使用 QEMU 自带的 OpenSBI 固件，它在 M 模式完成初始化后
    // 以 S 模式跳到 0x80200000 执行内核。按 Ctrl-A 再按 X 退出 QEMU。
    const qemu = b.addSystemCommand(&.{
        "qemu-system-riscv64",
        "-machine",
        "virt",
        "-smp",
        "1",
        "-m",
        "128M",
        "-nographic",
        "-bios",
        "default",
        "-kernel",
    });
    qemu.addArtifactArg2(kernel, .{});
    qemu.addPassthruArgs();

    const run_step = b.step("run", "Run the kernel in QEMU");
    run_step.dependOn(&qemu.step);
}
