#!/usr/bin/env python3
"""把一个 Minecraft: Java Edition 版本完整拉到本地，供 `sunrise-prepare` 使用。

`sunrise-prepare` 要的是完整安装：版本 json、client jar、每一个 library、asset
index 和它引用的全部 objects。Mojang 对这些都不需要账号，所以 CI 可以直接备一份。

已经存在的文件跳过不重下 —— 缓存恢复回来的目录靠这条省掉几乎全部流量。

用法:
    python3 sunrise/fetch-minecraft.py --version 26.3 --root ~/.minecraft
"""
import argparse
import concurrent.futures as futures
import hashlib
import json
import pathlib
import shutil
import sys
import urllib.request

MANIFEST = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
OBJECTS = "https://resources.download.minecraft.net/"
# Mojang 的 Maven，旧版库文件长期留在上面 —— 版本重新发布后 prepare 的 sha1
# 清单还指着旧路径，靠这里取回来。
LIBRARIES = "https://libraries.minecraft.net/"


def get(url, attempts=3, timeout=180):
    last = None
    for _ in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "h-rust-native-pack"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except Exception as exc:  # noqa: BLE001 - 重试覆盖所有传输层错误
            last = exc
    raise SystemExit(f"失败：{url}（{last}）")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--version", required=True, help="Minecraft 版本号，例 26.3")
    ap.add_argument("--root", default="~/.minecraft", help="安装到哪个目录（默认 ~/.minecraft）")
    args = ap.parse_args()

    root = pathlib.Path(args.root).expanduser()

    def save(item):
        url, rel = item
        path = root / rel
        if path.exists() and path.stat().st_size > 0:
            return 0
        path.parent.mkdir(parents=True, exist_ok=True)
        data = get(url)
        tmp = path.with_suffix(path.suffix + ".part")
        tmp.write_bytes(data)
        tmp.replace(path)
        return 1

    manifest = json.loads(get(MANIFEST))
    entry = next((v for v in manifest["versions"] if v["id"] == args.version), None)
    if entry is None:
        known = ", ".join(v["id"] for v in manifest["versions"][:10])
        raise SystemExit(f"失败：Mojang 没有 {args.version}（最近的有：{known} …）")

    data = json.loads(get(entry["url"]))
    vdir = root / "versions" / args.version
    vdir.mkdir(parents=True, exist_ok=True)
    (vdir / f"{args.version}.json").write_text(json.dumps(data))

    pairs = [(data["downloads"]["client"]["url"], f"versions/{args.version}/{args.version}.jar")]

    for lib in data.get("libraries", []):
        downloads = lib.get("downloads") or {}
        arts = [downloads.get("artifact")] + list((downloads.get("classifiers") or {}).values())
        for art in arts:
            if art and art.get("path"):
                pairs.append((art["url"], "libraries/" + art["path"]))
    ai = data["assetIndex"]
    index_path = root / "assets" / "indexes" / f"{ai['id']}.json"
    index_path.parent.mkdir(parents=True, exist_ok=True)
    if not index_path.exists():
        index_path.write_bytes(get(ai["url"]))
    index = json.loads(index_path.read_text())
    for _name, obj in index["objects"].items():
        h = obj["hash"]
        pairs.append((OBJECTS + h[:2] + "/" + h, "assets/objects/" + h[:2] + "/" + h))

    with futures.ThreadPoolExecutor(max_workers=24) as ex:
        saved = sum(ex.map(save, pairs))

    # Mojang 重新发布过 26.3：lwjgl-freetype 的版本从 3.4.3 变成 3.4.3-mojang-2.15.0，
    # 而 sunrise-prepare 带着自己发布时的 sha1 清单去找 libraries/.../3.4.3/...jar。
    # 光把新文件复制过去不行 —— prepare 会算 sha1 并拒绝（两个 jar 内容不同）。
    # 正确做法是从 Mojang 的 Maven 取回旧路径那份，它还在，sha1 也正是 pin 的值。
    aliased = 0
    for lib in data.get("libraries", []):
        name = lib.get("name", "")
        path = (lib.get("downloads") or {}).get("artifact", {}).get("path")
        if not path or name.count(":") < 2:
            continue
        _group, _artifact, version = name.split(":")[:3]
        if "-mojang-" not in version:
            continue
        base = version.split("-mojang-")[0]
        parts = path.split("/")
        # 用原文件名替换版本段，而不是拿 artifact 名硬拼：natives 条目的文件名是
        # lwjgl-freetype-<ver>-natives-linux.jar，硬拼会把 -natives-linux 丢掉。
        rel = "/".join(parts[:-2] + [base, parts[-1].replace(version, base)])
        target = root / "libraries" / rel
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)

        data_old = None
        try:
            req = urllib.request.Request(LIBRARIES + rel, headers={"User-Agent": "h-rust-native-pack"})
            with urllib.request.urlopen(req, timeout=120) as r:
                data_old = r.read()
        except Exception:  # noqa: BLE001 - Maven 上没有就退回新版，不是致命错误
            data_old = None

        if data_old:
            target.write_bytes(data_old)
            print(f"兼容副本：{rel}（Maven 上的旧版，sha1 {hashlib.sha1(data_old).hexdigest()[:12]}）")
        else:
            src = root / "libraries" / path
            if not src.is_file():
                continue
            try:
                target.hardlink_to(src)
            except OSError:
                shutil.copy2(src, target)
            print(f"兼容副本：{rel}（Maven 没有旧版，用新版顶替）")
        aliased += 1
    if aliased:
        print(f"（Mojang 重发过这个版本的元数据，补了 {aliased} 个旧路径）")

    total = sum(f.stat().st_size for f in root.rglob("*") if f.is_file())
    print(f"版本 {args.version}：{len(pairs)} 个文件，新下载 {saved} 个，"
          f"目录共 {total / 1048576:.0f} MB")


if __name__ == "__main__":
    main()
