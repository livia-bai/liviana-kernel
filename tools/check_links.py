#!/usr/bin/env python3
"""检查仓库里 Markdown 文档的相对链接和 #锚点。

检查 README.md、AGENTS.md 和 docs/ 下的所有 .md 文件：
- 相对链接指向的文件或目录必须存在；
- 带 #锚点 的链接，锚点必须是目标文件里某个标题按 GitHub 规则生成的 id。
http(s) 等外部链接不检查。

用法：python3 tools/check_links.py [仓库根目录]
不给参数时用脚本所在目录的上一级。全部有效时退出码为 0，否则为 1。
"""

import os
import re
import sys
import unicodedata


def github_slug(text):
    """按 GitHub 的规则把标题文字转成锚点：转小写，去掉标点和符号，空格换成 -。

    字母（包括汉字）、数字、组合符号、空格、- 和 _ 保留，其余（。（）`.:/ 等）都去掉。
    """
    kept = []
    for ch in text.strip().lower():
        if ch in " -_" or unicodedata.category(ch)[0] in "LNM":
            kept.append(ch)
    return "".join(kept).replace(" ", "-")


def strip_code_blocks(markdown):
    """去掉 ``` 围起来的代码块，代码里的 # 和 [](...) 不是标题和链接。"""
    return re.sub(r"```.*?```", "", markdown, flags=re.S)


_anchor_cache = {}


def anchors_of(path):
    """文件里所有标题生成的锚点。同名标题从第二个起依次加 -1、-2……"""
    if path not in _anchor_cache:
        with open(path, encoding="utf-8") as f:
            text = strip_code_blocks(f.read())
        counts = {}
        result = set()
        for line in text.splitlines():
            m = re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
            if not m:
                continue
            # 标题里的链接只保留文字部分
            title = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", m.group(1))
            slug = github_slug(title)
            n = counts.get(slug, 0)
            counts[slug] = n + 1
            result.add(slug if n == 0 else f"{slug}-{n}")
        _anchor_cache[path] = result
    return _anchor_cache[path]


def markdown_files(root):
    files = [os.path.join(root, name) for name in ("README.md", "AGENTS.md")]
    for directory, _, names in os.walk(os.path.join(root, "docs")):
        files += [os.path.join(directory, n) for n in names if n.endswith(".md")]
    return sorted(f for f in files if os.path.isfile(f))


def check_file(path, root):
    """返回 (检查的链接数, 错误列表)。"""
    with open(path, encoding="utf-8") as f:
        text = strip_code_blocks(f.read())
    # 行内代码里的方括号、圆括号也不是链接
    text = re.sub(r"`[^`\n]*`", "", text)
    errors = []
    count = 0
    for target in re.findall(r"\]\(([^)\s]+)\)", text):
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target):  # http:、mailto: 等
            continue
        count += 1
        file_part, _, anchor = target.partition("#")
        if file_part:
            dest = os.path.normpath(os.path.join(os.path.dirname(path), file_part))
        else:
            dest = path  # 只有 #锚点：指向本文件
        rel = os.path.relpath(path, root)
        if not os.path.exists(dest):
            errors.append(f"{rel}: missing file: {target}")
        elif anchor:
            if not dest.endswith(".md") or os.path.isdir(dest):
                errors.append(f"{rel}: anchor on a non-markdown target: {target}")
            elif anchor not in anchors_of(dest):
                errors.append(f"{rel}: missing anchor: {target}")
    return count, errors


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    root = os.path.abspath(root)
    total = 0
    errors = []
    for path in markdown_files(root):
        n, errs = check_file(path, root)
        total += n
        errors += errs
    for e in errors:
        print(e)
    print(f"checked {total} links, {len(errors)} broken")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
