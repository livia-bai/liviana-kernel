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

    // 用户程序：每个程序以 user/start.zig 为根文件、user/<名字>.zig 作为 program 模块，
    // 各自编译成一个 ELF，链接到用户地址空间（user/linker.ld）。ELF 再作为匿名模块交给内核，
    // 内核用 @embedFile(名字) 拿到它的字节，运行时自己加载。程序名列表通过 build_options 传给内核。
    const user_programs = [_][]const u8{ "hello", "fault", "spin" };
    const abi = b.createModule(.{ .root_source_file = b.path("src/abi.zig") });
    const sys = b.createModule(.{
        .root_source_file = b.path("user/sys.zig"),
        .imports = &.{.{ .name = "abi", .module = abi }},
    });
    const options = b.addOptions();
    options.addOption([]const []const u8, "user_programs", &user_programs);
    kernel.root_module.addOptions("build_options", options);
    for (user_programs) |name| {
        const program = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("user/start.zig"),
                .target = target,
                .optimize = optimize,
                .code_model = .medany,
                // 调试信息和栈回溯用的 unwind 表对用户程序都没用，去掉之后嵌进内核的 ELF 小很多
                .strip = true,
                .unwind_tables = .none,
                .imports = &.{
                    .{ .name = "sys", .module = sys },
                    .{ .name = "program", .module = b.createModule(.{
                        .root_source_file = b.path(b.fmt("user/{s}.zig", .{name})),
                        .imports = &.{.{ .name = "sys", .module = sys }},
                    }) },
                },
            }),
        });
        program.setLinkerScript(b.path("user/linker.ld"));
        // Debug 模式默认不回收没用到的段，会把整个 compiler_rt 带进来，体积大两倍多
        program.link_gc_sections = true;
        kernel.root_module.addAnonymousImport(name, .{ .root_source_file = program.getEmittedBin() });
        // 另外安装一份到 zig-out/user/，方便用 llvm-readelf 等工具查看（内核用的是上面嵌进去的那份）
        const install = b.addInstallArtifact(program, .{ .dest_dir = .{ .override = .{ .custom = "user" } } });
        b.getInstallStep().dependOn(&install.step);
    }

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
