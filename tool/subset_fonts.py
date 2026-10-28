#!/usr/bin/env python3
"""把仓库里打包的 Maple Mono NF CN 字体做 CJK 子集化。

为什么：完整字体两个分字重合计 ~39 MB，UI 启动时要在 `runApp` 之前同步加载，
导致冷启动多出秒级等待。子集方案（GB2312 全量 + App UI 实际用到的字符 + 基础
拉丁/标点）把两份降到 ~10 MB，常用汉字零回退；GB2312 之外的生僻字/繁体由系统
字体逐字回退（可读，只是字形不同）。

依赖：Python 3 + fonttools（`python -m pip install fonttools`）。

用法（需要**完整原始字体**；仓库里现在是子集版本，可从 git 历史取回，例如：
`git show <old-commit>:assets/fonts/MapleMono-NF-CN-Regular.ttf > ...`）：

    python tool/subset_fonts.py --source-dir <含完整字体的目录>

输出覆盖 assets/fonts/ 下的两个文件名；脚本会打印体积与覆盖率。
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

BASE_RANGES = [
    (0x20, 0x7E),      # ASCII
    (0xA0, 0xFF),      # Latin-1
    (0x2000, 0x206F),  # 通用标点
    (0x20A0, 0x20BF),  # 货币
    (0x2100, 0x214F),  # 字母式符号
    (0x2190, 0x21FF),  # 箭头
    (0x2200, 0x22FF),  # 数学运算符
    (0x2500, 0x257F),  # 制表符
    (0x25A0, 0x25FF),  # 几何图形
    (0x3000, 0x303F),  # CJK 标点
    (0xFF00, 0xFFEF),  # 全角字符
]

FONTS = ["MapleMono-NF-CN-Regular.ttf", "MapleMono-NF-CN-Bold.ttf"]
REQUIRED_FAMILY = "Maple Mono NF CN"


def base_codepoints() -> set[int]:
    cps: set[int] = set()
    for lo, hi in BASE_RANGES:
        cps.update(range(lo, hi + 1))
    return cps


def app_codepoints() -> set[int]:
    """所有 l10n ARB 的字符串值（UI 固定文案），确保文案不触发回退。"""
    cps: set[int] = set()
    l10n_dir = os.path.join(os.path.dirname(__file__), "..", "lib", "l10n")
    for name in sorted(os.listdir(l10n_dir)):
        if not name.endswith(".arb"):
            continue
        with open(os.path.join(l10n_dir, name), encoding="utf-8") as fh:
            data = json.load(fh)
        for key, value in data.items():
            if key.startswith("@") or not isinstance(value, str):
                continue
            cps.update(ord(ch) for ch in value)
    return cps


def gb2312_codepoints() -> set[int]:
    """GB2312 全量（6763 汉字 + 682 符号），覆盖常用/次常用简体中文。"""
    cps: set[int] = set()
    for lead in range(0xA1, 0xF8):
        for trail in range(0xA1, 0xFF):
            try:
                cps.add(ord(bytes([lead, trail]).decode("gb2312")))
            except UnicodeDecodeError:
                continue
    return cps


def build_charset() -> set[int]:
    return base_codepoints() | app_codepoints() | gb2312_codepoints()


def subset(source: str, target: str, codepoints: set[int], charset_file: str) -> None:    # Windows 命令行上限 ~32K：8k+ 个码点必须走 --unicodes-file，不能拼进参数。
    with open(charset_file, "w", encoding="utf-8") as fh:
        for cp in sorted(codepoints):
            fh.write(f"U+{cp:04X}\n")
    cmd = [
        sys.executable,
        "-m",
        "fontTools.subset",
        source,
        f"--output-file={target}",
        f"--unicodes-file={charset_file}",
        "--layout-features=*",
        "--name-IDs=*",
        "--name-legacy",
        "--name-languages=*",
        "--notdef-glyph",
        "--notdef-outline",
    ]
    subprocess.run(cmd, check=True)


def source_cmap(path: str) -> set[int]:
    from fontTools.ttLib import TTFont

    font = TTFont(path)
    try:
        return set(font.getBestCmap() or {})
    finally:
        font.close()


def verify(path: str, required: set[int]) -> None:
    from fontTools.ttLib import TTFont  # imported lazily so --help works without fonttools

    font = TTFont(path)
    family = {str(n) for n in font["name"].names if n.nameID == 1}
    cmap = set(font.getBestCmap() or {})
    missing = required - cmap
    print(
        f"  {os.path.basename(path)}: {os.path.getsize(path) / 1024 / 1024:.2f} MB, "
        f"{len(font.getGlyphOrder())} glyphs, cmap {len(cmap)}, "
        f"family={sorted(family)}"
    )
    if REQUIRED_FAMILY not in family:
        raise SystemExit(f"字族名丢了：{family}")
    if missing:
        raise SystemExit(f"缺 {len(missing)} 个原字体本应覆盖的字符，例如 {sorted(missing)[:5]}")
    font.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", required=True, help="完整原始字体所在目录")
    parser.add_argument(
        "--out-dir",
        default=os.path.join(os.path.dirname(__file__), "..", "assets", "fonts"),
        help="输出目录（默认 assets/fonts）",
    )
    args = parser.parse_args()

    codepoints = build_charset()
    print(
        f"目标字符集：{len(codepoints)} 个码点（GB2312 + l10n 文案 + 基础拉丁/标点）"
    )
    os.makedirs(args.out_dir, exist_ok=True)
    charset_file = os.path.join(args.out_dir, ".font-subset-charset.txt")
    try:
        for name in FONTS:
            source = os.path.join(args.source_dir, name)
            if not os.path.exists(source):
                raise SystemExit(f"找不到原始字体：{source}")
            target = os.path.join(args.out_dir, name)
            # 只要求"原字体本来就有"的字符：控制字符/原字体缺失的字符不参与校验。
            required = codepoints & source_cmap(source)
            subset(source, target, codepoints, charset_file)
            verify(target, required)
    finally:
        if os.path.exists(charset_file):
            os.remove(charset_file)


if __name__ == "__main__":
    main()
