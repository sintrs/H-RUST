#!/usr/bin/env python3
"""挑一个「列出的 mod 全都能同时用」的最新 build，并给出各 mod 在该 build 上的最高版本。

为什么不是「取最新版本再看配不配」：native mod 的 `fits` 是作者按 build 逐个声明的，
各作者跟进速度不同，最新版本经常分散在不同 build 上。2026-11-26 实测：frontier 和
supercam 各自只有一个版本、只认 `dev-2026-11-24-3d34bbe`，而 dynamic-fps 的最新版只认
`dev-2026-11-26-ba1f24e` —— 按「取最新 + 全部 fits」写，永远凑不齐，一次都编不出来。

所以反过来解：
  1. 对每个 mod，收集它所有版本 `fits` 的并集
  2. 取交集 —— 这就是「每个 mod 都至少有一个可用版本」的 build 集合
  3. 按 build 名取最大（名字里带日期，字典序即日期序）
  4. 每个 mod 在那个 build 上挑版本号最高的

用法:
    python3 sunrise/plan-native-pack.py \\
        frontier supercam dynamic-fps wayfarer-stones

输出（stdout，同时追加到 GITHUB_OUTPUT）:
    builds=dev-2026-11-24-3d34bbe
    mods=frontier@1.0.3 supercam@1.0.2 dynamic-fps@0.5.1 wayfarer-stones@0.9.2

退出码：0 有解；2 没有任何 build 能让这些 mod 凑齐（不是脚本出错）。
"""
import argparse
import importlib.util
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent


def load_fetch_module():
    """复用 fetch-sunrise-mods.py 的索引加载和版本比较。

    那个文件名带连字符，不能直接 import；但它顶层只有常量和函数定义，加载无副作用，
    所以用 importlib 从同目录取。好处是两个脚本对「哪个版本更大」的判定永远一致。
    """
    path = HERE / "fetch-sunrise-mods.py"
    spec = importlib.util.spec_from_file_location("sunrise_fetch_mods", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("slugs", nargs="+", metavar="SLUG", help="要一起带的 mod slug")
    ap.add_argument("--index", help="覆盖注册表索引地址")
    args = ap.parse_args()

    fetch = load_fetch_module()
    index = fetch.load_index(args.index or fetch.DEFAULT_INDEX)
    projects = {p.get("slug"): p for p in (index.get("projects") or [])}

    usable = {}
    for slug in args.slugs:
        project = projects.get(slug)
        if project is None:
            raise SystemExit(f"失败：注册表里没有 {slug}")
        table = {}
        for release in project.get("releases") or []:
            version = release.get("version")
            if not version:
                continue
            for build in release.get("fits") or []:
                current = table.get(build)
                if current is None or fetch.version_key(version) > fetch.version_key(current):
                    table[build] = version
        if not table:
            raise SystemExit(f"失败：{slug} 没有任何 release 声明 fits，无从判断")
        usable[slug] = table
        print(f"{slug:16} 覆盖 {len(table)} 个 build，最新那个上可用 {table[max(table)]}",
              file=sys.stderr)

    common = set.intersection(*(set(t) for t in usable.values()))
    if not common:
        print("没有能让这些 mod 同时使用的 build：", file=sys.stderr)
        for slug, table in usable.items():
            print(f"  {slug}: {', '.join(sorted(table)) or '无'}", file=sys.stderr)
        return 2

    build = max(common)
    mods = " ".join(f"{slug}@{usable[slug][build]}" for slug in args.slugs)
    lines = [f"builds={build}", f"mods={mods}"]

    for slug in args.slugs:
        others = sorted(set(usable[slug]) - {build})
        if others:
            print(f"  {slug} 在别的 build 上还有：{', '.join(others)}", file=sys.stderr)

    print("\n".join(lines))
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
