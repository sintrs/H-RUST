#!/usr/bin/env python3
"""取指定版本的 Sunrise native mod 源码包（.smod），校验后解开。

`sunrise-launcher mods install <slug>` 取的是**最新** release，而 native mod 只能
在编译时 pin 的那个 build 上跑（`[native] sunrise = <commit>`）。要复现一个已知能用
的组合，就得钉住 `slug@version`，所以这里直接读注册表索引、按版本取。

索引是 minisign 签名过的 JSON（`index.signed`），签名块在前面，正文从第一个 `{`
开始。我们不解签名（没有公钥，也不打算在这里自建信任根），但会把索引声明的
sha256 和下载到的文件逐字节对上 —— 这一条挡住的是传输损坏和错版本，不是上游作恶。

用法:
    python3 sunrise/fetch-sunrise-mods.py --out mods-src \\
        frontier@1.0.3 supercam@1.0.2 dynamic-fps@0.5.1

输出：<out>/<slug>/ 里是解开的源码（sunrise-mod.toml + Cargo.toml + src/ + assets），
可以直接当 `sunrise-launcher native-build <out>` 的参数。加 --manifest 时另写一份
JSON，打包脚本把它放进 BUILD-INFO 里。
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

DEFAULT_INDEX = "https://sunrise-org.github.io/sunrise-mods/v2/index.signed"


def fetch_bytes(url, attempts=3, timeout=180):
    last = None
    for _ in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "h-rust-native-pack"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except (urllib.error.URLError, TimeoutError) as exc:
            last = exc
    raise SystemExit(f"失败：下载不了 {url}（{last}）")


def load_index(url):
    raw = fetch_bytes(url).decode("utf-8", errors="replace")
    # 签名块是文本，正文才是 JSON。
    start = raw.find("{")
    if start < 0:
        raise SystemExit(f"失败：{url} 里找不到 JSON 正文")
    try:
        return json.loads(raw[start:])
    except json.JSONDecodeError as exc:
        raise SystemExit(f"失败：索引不是合法 JSON（{exc}）")


def find_release(projects, slug, version):
    for project in projects:
        if project.get("slug") != slug:
            continue
        for release in project.get("releases") or []:
            if release.get("version") == version:
                return project, release
        known = ", ".join(r.get("version", "?") for r in project.get("releases") or [])
        raise SystemExit(f"失败：{slug} 没有 {version} 这个版本（有：{known}）")
    known = ", ".join(sorted(p.get("slug", "?") for p in projects))
    raise SystemExit(f"失败：注册表里没有 {slug}（有：{known}）")


def unpack(smod_path, dest):
    """解开 .smod（zip，扁平结构）。拒绝任何跳出目标目录的条目。"""
    dest = pathlib.Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    root = dest.resolve()
    with zipfile.ZipFile(smod_path) as zf:
        for name in zf.namelist():
            target = (dest / name).resolve()
            if not str(target).startswith(str(root) + "/") and target != root:
                raise SystemExit(f"失败：{smod_path} 里有越界条目 {name!r}")
        zf.extractall(dest)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("specs", nargs="+", metavar="SLUG@VERSION")
    ap.add_argument("--out", required=True, help="解开到哪个目录（每个 mod 一个子目录）")
    ap.add_argument("--index", default=DEFAULT_INDEX, help="注册表索引地址")
    ap.add_argument("--manifest", help="把取到的东西写成 JSON 放到这里")
    ap.add_argument("--strict-fit", action="store_true",
                    help="build 不在 release 声明的 fits 里就失败（默认只警告）")
    ap.add_argument("--builds", default="",
                    help="要编的目标 build tag，逗号分隔；用来对照每个 release 的 fits")
    args = ap.parse_args()

    builds = [b.strip() for b in args.builds.replace(" ", ",").split(",") if b.strip()]

    index = load_index(args.index)
    projects = index.get("projects") or []
    if not projects:
        raise SystemExit("失败：索引里没有 projects")

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    manifest = []

    for spec in args.specs:
        if "@" not in spec:
            raise SystemExit(f"失败：{spec!r} 不是 slug@version")
        slug, version = spec.rsplit("@", 1)
        project, release = find_release(projects, slug, version)
        info = release.get("file") or {}
        url, want = info.get("url"), info.get("sha256")
        if not url or not want:
            raise SystemExit(f"失败：{slug} {version} 没有下载地址或 sha256")

        if builds:
            fits = release.get("fits") or []
            missing = [b for b in builds if b not in fits]
            if missing:
                msg = (f"{slug} {version} 没有声明支持 {', '.join(missing)}"
                       f"（fits: {', '.join(fits) or '无'}）")
                if args.strict_fit:
                    raise SystemExit("失败：" + msg)
                print(f"警告：{msg} —— 照样编，能不能成看 mixin 目标还在不在", file=sys.stderr)

        with tempfile.TemporaryDirectory() as tmp:
            smod = pathlib.Path(tmp) / f"{slug}-{version}.smod"
            smod.write_bytes(fetch_bytes(url))
            got = hashlib.sha256(smod.read_bytes()).hexdigest()
            if got != want:
                raise SystemExit(f"失败：{slug} {version} 的 sha256 不对\n  期望 {want}\n  实际 {got}")
            target = out / slug
            if target.exists():
                shutil.rmtree(target)
            unpack(smod, target)
            if not (target / "sunrise-mod.toml").is_file():
                raise SystemExit(f"失败：{slug} {version} 解出来没有 sunrise-mod.toml")

        entry = {
            "slug": slug,
            "version": version,
            "sha256": want,
            "url": url,
            "license": project.get("license"),
            "authors": project.get("authors") or [],
            "declared_fits": release.get("fits") or [],
            "declared_sunrise": release.get("sunrise"),
        }
        manifest.append(entry)
        print(f"{slug} {version}  ->  {target}  ({project.get('license')})")

    if args.manifest:
        pathlib.Path(args.manifest).write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"清单写到 {args.manifest}")


if __name__ == "__main__":
    main()
