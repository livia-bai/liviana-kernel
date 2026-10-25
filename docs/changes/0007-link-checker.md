# 0007 文档链接检查脚本加进仓库；删除会话分支

- 日期：2026-10-25
- 提交：`e947307` Add a link checker for the documentation
- 涉及文件：`tools/check_links.py`（新）、`docs/testing.md`、`docs/README.md`、`AGENTS.md`、`README.md`、`docs/changes/0006-docs.md`、`docs/changes/README.md`

## 目标

维护者的要求：“删掉分支，脚本也加进仓库吧”。对应 [0006](0006-docs.md#遗留问题) 遗留的两件事：

1. 删除远端的会话分支 `claude/focused-pascal-bc28g3`。
2. 把写文档时用的链接检查脚本加进仓库。

## 改动

- `tools/check_links.py`：检查 README.md、AGENTS.md 和 `docs/` 下所有 Markdown 文件的相对链接和 `#锚点`。在 0006 的临时版本基础上整理：
  - 不给参数时以脚本所在目录的上一级作为仓库根，从任何目录运行都可以；
  - 去掉了临时版本里一段调试残留（错误信息后面多打印的 `(have: [])`）；
  - 跳过所有带协议头的链接（`http:`、`https:`、`mailto:` 等），临时版本只认 `xxx://` 形式；
  - 错误信息格式统一为 `<文件>: missing file|missing anchor|anchor on a non-markdown target: <链接>`，有错误时退出码为 1。
- `docs/testing.md`：“必做的检查”加第 5 条：改了 Markdown 就运行它，必须 `0 broken`；说明它检查什么、锚点规则，附实际的错误输出。
- `AGENTS.md`：“常用命令”和“文档”两节加上这条命令。
- `docs/README.md`：文件对照表加上 `tools/check_links.py`，“维护文档”加一句。
- `README.md`：目录加上 `tools/`。
- `docs/changes/0006-docs.md`：补上提交哈希 `d8ec2a6`；“遗留问题”里这两条后面加注，指向本记录（按 AGENTS.md 的规则，不改原来的内容）。
- `docs/changes/README.md`：索引补上 0006 的哈希，加上本记录。

## 设计决策

- **用 Python，不做成 `zig build` 步骤**：脚本只处理文本，Python 标准库就够用，环境里本来就有（Python 3.13）。做成构建步骤需要用 Zig 重写，或者让 `build.zig` 依赖 Python，都不值得。
- **锚点规则是对 GitHub 的近似**：转小写，保留字母（包括汉字）、数字、组合符号、空格、`-`、`_`，其他字符去掉，空格换成 `-`，同名标题依次加 `-1`、`-2`。仓库里现有的中文标题、带反引号和全角括号的标题都符合这个规则；遇到少见的符号时可能和 GitHub 有出入，到时候再调整。
- **只检查仓库内的链接**：外部链接要联网，结果也不稳定。
- 放在 `tools/` 下，以后有其他开发用的脚本也放这里。

## 验证

### 环境

Python 3.13.17；Zig 0.17.0、QEMU 8.2.2、OpenSBI v1.3（同前）。

### 删除分支

先确认分支的内容和 `main` 上对应的提交一致，再删除：

```sh
git fetch origin
git diff --stat origin/claude/focused-pascal-bc28g3 0752ca1     # 空：内容相同
git push origin --delete claude/focused-pascal-bc28g3
git branch -D claude/focused-pascal-bc28g3
git fetch --prune origin
git ls-remote --heads origin                                    # 只剩 refs/heads/main
```

`git push --delete` 返回 `remote ref does not exist`：远端分支在这之前就已经不在了（`git fetch` 默认不清理已删除分支的跟踪引用，所以本地还显示着 `origin/claude/focused-pascal-bc28g3`）。`git ls-remote` 确认远端只剩 `main`。本地分支（指向改写作者之前的 `0011a29`）和过期的跟踪引用已经清理。

### 脚本

**正常情况**：从根目录以外的地方运行（`cd / && python3 /home/user/liviana-kernel/tools/check_links.py`），结果和 0006 的临时版本相同：`checked 211 links, 0 broken`，退出码 0。本次改完文档后是 `checked 213 links, 0 broken`。

**故意放进错误**：把 README.md、AGENTS.md、`docs/` 复制到一个临时目录，在副本的 `docs/testing.md` 末尾加上：

```markdown
[不存在的文件](nope.md)、[不存在的锚点](trap.md#没有这个标题)、[本文件的坏锚点](#也没有)、[目录加锚点](changes/#x)、[外部](https://example.com/a#b)、`[行内代码](ignored.md)`、[好的同名第二个标题](devices.md#寄存器-1)、[好的本文件锚点](#gdb)
```

结果：

```
docs/testing.md: missing file: nope.md
docs/testing.md: missing anchor: trap.md#没有这个标题
docs/testing.md: missing anchor: #也没有
docs/testing.md: anchor on a non-markdown target: changes/#x
checked 217 links, 4 broken
```

退出码 1。4 个坏链接都报出来了；外部链接和行内代码里的“链接”被跳过（检查数 211 + 6，而不是 + 8）；`devices.md` 里第二个“寄存器”标题的锚点 `#寄存器-1` 和本文件的 `#gdb` 被正确接受。

testing.md 里引用的错误输出示例，是在副本里只加 `[a](nope.md) [b](trap.md#没有这个标题)` 两个链接时的实际输出（`checked 215 links, 2 broken`）。

### 其他

- 只改了文档和 Python 脚本，按规则跑了 Debug 模式：`zig fmt --check` 通过，构建输出为空，标准测试脚本全部正常（`hello` 退出、`fault` 和 `spin` 被杀，前后两次 `mem` 都是 `32052 of 32057`，退出码 0）。

## 发现的问题

### 问题 1：testing.md 里的示例输出是编的

- 现象：给 testing.md 写“有错误时的输出”时，先按脚本的格式手写了一段，其中的链接数（213）不是真实运行出来的。
- 原因：违反了“文档里的输出必须实测”的规则。
- 修复：在临时副本里放两个坏链接实际运行，用真实输出替换，并在文档里写明是在什么条件下得到的。
- 确认：输出逐字来自运行结果。

## 遗留问题

- 锚点规则是近似，遇到 GitHub 处理方式不同的符号时需要调整。
- 没有检查“每个源码文件都出现在 `docs/README.md` 的对照表里”，这条规则目前靠人工遵守。
