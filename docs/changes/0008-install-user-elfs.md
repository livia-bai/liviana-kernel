# 0008 用户程序的 ELF 安装到 zig-out/user/

- 日期：2026-10-25
- 提交：本记录对应的提交（Install user program ELFs to zig-out/user）
- 涉及文件：`build.zig`、`docs/build.md`、`docs/testing.md`

## 目标

维护者从改进建议里选了这一条：用户程序的 ELF 只在 `.zig-cache` 里，文档只好写 `llvm-readelf -l $(ls -t .zig-cache/o/*/hello | head -1)` 这种绕法去找。在构建里把它们装到 `zig-out/user/`。

## 改动

- `build.zig`：每个用户程序额外加一个安装步骤：

  ```zig
  const install = b.addInstallArtifact(program, .{ .dest_dir = .{ .override = .{ .custom = "user" } } });
  b.getInstallStep().dependOn(&install.step);
  ```

  `zig build` 之后得到 `zig-out/user/hello`、`fault`、`spin`。内核仍然嵌入同一个构建产物，这一步对内核镜像没有影响。
- `docs/build.md`：代码片段和要点里加上这一步；“产物和缓存”改成指向 `zig-out/user/`，并说明为什么不要去 `.zig-cache` 里找。
- `docs/testing.md`：查看用户程序 ELF 的命令改成 `llvm-readelf -hl zig-out/user/hello`。

## 设计决策

- 装到单独的 `zig-out/user/`，不和内核混在 `zig-out/bin/` 里：用户程序不是能在宿主机上直接运行的东西。
- 只是安装一份副本，不改内核嵌入用户程序的方式（仍然是 `addAnonymousImport` + `@embedFile`）。

## 验证

### 环境

Zig 0.17.0、QEMU 8.2.2、OpenSBI v1.3（同前）。

### 步骤和结果

- `rm -rf zig-out && zig build`：构建输出为空，`zig-out` 下是 `bin/kernel`、`user/fault`、`user/hello`、`user/spin`。
- **安装的就是嵌进内核的那份**：在内核 ELF 里原样查找每个用户程序文件的全部字节：

  ```python
  kernel = open('zig-out/bin/kernel','rb').read()
  for name in ('hello','fault','spin'):
      data = open(f'zig-out/user/{name}','rb').read()
      print(name, len(data), 'bytes, embedded in kernel:', kernel.find(data) >= 0)
  ```

  三个都是 `True`（Debug 下各 98960 字节）。
- **四种模式**：每种模式构建输出都为空，装出来的 `hello` 随模式变化，说明装的是当前模式的版本：

  | 模式 | `zig-out/user/hello` 大小 | 入口 |
  | --- | --- | --- |
  | debug | 98960 | `0x40011426` |
  | safe | 17040 | `0x40000824` |
  | fast | 12944 | `0x40000000` |
  | small | 12944 | `0x40000000` |

- **QEMU**（Debug，标准测试脚本）：全部正常，前后两次 `mem` 都是 `32052 of 32057`，退出码 0。启动时的空闲页数和改动前一样（32057），内核镜像没有变化。

## 发现的问题

### 问题 1：文档里原来找用户程序 ELF 的办法会挑错文件

- 现象：验证时想用 `cmp zig-out/user/hello $(ls -t .zig-cache/o/*/hello | head -1)` 确认两者相同，结果报 `differ: char 25`。
- 原因：缓存里同时留着 14 个 `hello`（各个优化模式、各个历史版本），这次构建没有重新编译用户程序（命中缓存），按修改时间排第一的是之前另一次构建的产物。这正是文档原来推荐的办法，它并不可靠。
- 修复：这次的改动本身就是修复：文档改成直接用 `zig-out/user/`，并写明不要去缓存里找。验证改用“在内核 ELF 里找这份文件的字节”。
- 确认：见上面的验证。

## 遗留问题

没有。
