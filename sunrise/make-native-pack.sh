#!/usr/bin/env bash
# 把 native-build 的产物打成一个离线包：官方启动器 + 编好的版本 + 直连入口。
#
# 和 make-sunrise-package.sh 是同一套版面（包根就是启动器的数据目录），区别只在
# 版本目录里放的是 `native-<base>-<hash>` 而不是官方 dev/nightly —— 那个目录由
# native-build 生成，自带 `.installed` / `.downloaded-build` / `native-mods.json`，
# 对启动器来说就是一个完整的已装版本。所以这里不"造"版本，只搬运 + 校验。
#
# 三件事在发货前必须成立，任何一条不过就红，不发坏包：
#   1. native-mods.json 里每个库的 sha256 和盘上的文件对得上
#   2. 每个 .so 要求的 GLIBC 不高于 MAX_GLIBC（默认 2.35 = ubuntu-22.04 / 官方本体）
#   3. native-mods.json 记的 sunrise commit 和本体的 commit 是同一个
# 第 2 条是这条链存在的理由：在 24.04 上编，frontier 会把 atan2f 绑到 GLIBC_2.43，
# 整包在别人的机器上直接起不来。
#
# 用法:
#   bash sunrise/make-native-pack.sh <native_dir> <launcher.tar.gz> <out_dir>
#
# 环境变量:
#   MAX_GLIBC   允许的最高 glibc（默认 2.35，给 0 关闭检查）
#   MODS_LABEL  包内 BUILD-INFO.txt / PLAY-OFFLINE.txt 里的 mod 短标签（默认从 native-mods.json 拼）
#   MODS_BRIEF  附件名里的 mod 摘要，默认 `4mods`（逐个拼名会让附件名过百字符）
#   STAMP       附件名里的时间戳（默认北京时间）
#   KEEP_WORK=1 保留临时目录
set -euo pipefail

NATIVE_DIR=${1:?用法: make-native-pack.sh <native_dir> <launcher.tar.gz> <out_dir>}
LAUNCHER_TGZ=${2:?}
OUT=${3:-package}

MAX_GLIBC=${MAX_GLIBC:-2.35}
STAMP=${STAMP:-$(TZ=CST-8 date +%Y-%m-%d-%H%M)}

[[ -d "$NATIVE_DIR" ]] || { echo "错误：找不到 $NATIVE_DIR" >&2; exit 1; }
[[ -f "$LAUNCHER_TGZ" ]] || { echo "错误：找不到 $LAUNCHER_TGZ" >&2; exit 1; }
NATIVE_DIR=$(cd "$NATIVE_DIR" && pwd)
TAG=$(basename "$NATIVE_DIR")
MANIFEST=$NATIVE_DIR/native-mods.json
[[ -f "$MANIFEST" ]] || { echo "错误：$NATIVE_DIR 里没有 native-mods.json（不是 native-build 的产物？）" >&2; exit 1; }
[[ -x "$NATIVE_DIR/sunrise-client" ]] || { echo "错误：$NATIVE_DIR 里没有可执行的 sunrise-client" >&2; exit 1; }

echo "==> 校验 $TAG"

# 1) sha256 与 manifest 对账
python3 - "$NATIVE_DIR" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
man = json.loads((root / "native-mods.json").read_text())
libs = man.get("libraries") or []
if not libs:
    raise SystemExit("错误：native-mods.json 里没有 libraries")
bad = []
for lib in libs:
    f = root / lib["file"]
    if not f.is_file():
        bad.append(f"{lib['file']}: 文件不存在")
        continue
    got = hashlib.sha256(f.read_bytes()).hexdigest()
    if got != lib.get("sha256"):
        bad.append(f"{lib['file']}: sha256 {got[:16]} != {str(lib.get('sha256'))[:16]}")
    print(f"    {lib.get('kind','?'):6} {lib.get('mod','?'):16} {lib['file']}")
if bad:
    raise SystemExit("错误：\n  " + "\n  ".join(bad))
PY

# 2) glibc 门槛
#
# 注意 grep 一定要容错：有的 .so（libcrc_fast）是纯静态的，objdump -T 一行都不出，
# 在 pipefail 下 grep 的退出码会让整个脚本静默退出，而且什么都不打印 —— 比红还难查。
if [[ "$MAX_GLIBC" != "0" ]]; then
    command -v objdump >/dev/null || { echo "错误：缺 objdump，装 binutils，或用 MAX_GLIBC=0 关掉这项检查" >&2; exit 1; }
    echo "    最高允许 GLIBC_$MAX_GLIBC"
    over=""
    for so in "$NATIVE_DIR"/*.so; do
        [[ -e "$so" ]] || continue
        top=$(objdump -T "$so" 2>/dev/null | { grep -o 'GLIBC_[0-9.]*' || true; } | sort -V -u | tail -1)
        if [[ -z "$top" ]]; then
            printf '    %-32s %s\n' "$(basename "$so")" "(无 glibc 依赖)"
            continue
        fi
        printf '    %-32s %s\n' "$(basename "$so")" "$top"
        highest=$(printf '%s\n%s\n' "$MAX_GLIBC" "${top#GLIBC_}" | sort -V | tail -1)
        if [[ "$highest" != "$MAX_GLIBC" ]]; then
            over="${over}  $(basename "$so"): $top"$'\n'
        fi
    done
    if [[ -n "$over" ]]; then
        echo "错误：以下文件要求比 GLIBC_$MAX_GLIBC 更高的版本，换到更老的发行版（ubuntu-22.04）重新编译：" >&2
        printf '%s' "$over" >&2
        exit 1
    fi
fi

# 3) commit 自洽：manifest 记的 sunrise 必须等于 base 版本目录的 commit
BASE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("base",""))' "$MANIFEST")
WANT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("sunrise",""))' "$MANIFEST")
[[ -n "$WANT" ]] || { echo "错误：native-mods.json 里没有 sunrise commit" >&2; exit 1; }
echo "    base=$BASE  sunrise=$WANT"
SIBLING="$(dirname "$NATIVE_DIR")/$BASE"
if [[ -d "$SIBLING" ]]; then
    HAVE=""
    for f in sunrise-release.json research-lock.json; do
        if [[ -f "$SIBLING/$f" ]]; then
            HAVE=$(python3 - "$SIBLING/$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for key in ("commit", "sunrise", "revision"):
    if isinstance(d.get(key), str) and len(d[key]) >= 7:
        print(d[key]); raise SystemExit
mc = d.get("minecraft") or {}
for key in ("commit", "sunrise", "revision"):
    if isinstance(mc.get(key), str) and len(mc[key]) >= 7:
        print(mc[key]); raise SystemExit
PY
)
            [[ -n "$HAVE" ]] && break
        fi
    done
    if [[ -n "$HAVE" && "$HAVE" != "$WANT" ]]; then
        echo "错误：base $BASE 的 commit 是 $HAVE，但 mod 是按 $WANT 编的" >&2
        exit 1
    fi
    [[ -z "$HAVE" ]] && echo "    （base 目录里没记 commit，跳过这项对照）"
else
    echo "    （base 目录 $BASE 不在旁边，跳过这项对照）"
fi

# 附件名里的 mod 短标签（只进包内说明文件，不进附件名）
if [[ -z "${MODS_LABEL:-}" ]]; then
    MODS_LABEL=$(python3 - "$MANIFEST" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ids = [l.get("mod") for l in d.get("libraries", []) if l.get("kind") == "mod"]
label = "-".join(ids) if ids else "nomods"
if len(label) > 48:
    label = f"{ids[0]}-and-{len(ids) - 1}-more"
print(label)
PY
)
fi

# 附件名里的 mod 摘要：个数就够区分了，逐个拼名会让附件名过百字符
if [[ -z "${MODS_BRIEF:-}" ]]; then
    MODS_BRIEF=$(python3 - "$MANIFEST" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
n = sum(1 for l in d.get("libraries", []) if l.get("kind") == "mod")
print(f"{n}mods" if n else "nomods")
PY
)
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nat-pkg.XXXXXX")
if [[ "${KEEP_WORK:-0}" != "1" ]]; then
  trap 'rm -rf "$WORK"' EXIT
else
  trap 'echo "临时目录保留在 $WORK"' EXIT
fi
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

ROOT="$WORK/root"
LAUNCHER_HOME="$ROOT/data"
VERSIONS="$LAUNCHER_HOME/versions/$TAG"
mkdir -p "$VERSIONS"

echo "==> 解开官方启动器包"
mkdir -p "$WORK/launcher-pkg"
tar -xzf "$LAUNCHER_TGZ" -C "$WORK/launcher-pkg" --touch --no-same-owner
LAUNCHER_BIN=$(find "$WORK/launcher-pkg" -maxdepth 2 -type f -name 'sunrise-launcher' -perm -u+x | head -1)
[[ -n "$LAUNCHER_BIN" ]] || { echo "错误：启动器包里没有可执行的 sunrise-launcher" >&2; exit 1; }
LAUNCHER_DIR=$(dirname "$LAUNCHER_BIN")
# 整层搬过去（图标、desktop、LICENSE 都在里面），但排除官方包自带的 data/：
# 那是个空壳，会盖住随包版本。
(cd "$LAUNCHER_DIR" && tar -cf - --exclude=./data .) | (cd "$ROOT" && tar -xmf -)

echo "==> 搬运编好的版本（不含 .local/ 资源）"
# .local/sunrise-client/<mc> 是 prepare 出来的 694 MB 游戏资源，由使用者自己的
# Minecraft 生成，不进包。.preparing.lock 是运行时锁，留着会让对方以为有进程在写。
(cd "$NATIVE_DIR" && tar -cf - --exclude=./.local --exclude=./.preparing.lock .) | (cd "$VERSIONS" && tar -xmf -)
: > "$VERSIONS/.installed"
for exe in sunrise-client sunrise-ctl sunrise-prepare sunrise-server sunrise-perf sunrise-port-pack; do
  [[ -f "$VERSIONS/$exe" ]] && chmod +x "$VERSIONS/$exe"
done
[[ -x "$VERSIONS/sunrise-client" ]] || { echo "错误：版本目录里没有可执行的 sunrise-client" >&2; exit 1; }

# 再补一份以 base 命名的版本目录。
# 文档原话：「Client builds share their base version's prepared resources」。启动器
# 认标签用的是版本目录里 sunrise-release.json 的 build 字段，也就是 base 名，于是
# prepare 要写 versions/<base>/.local/，目录不在就直接死在
# 「.preparing.lock: No such file or directory」—— 资源一根都没导出来。
# 内容全部硬链接到上面那份，tar 只多存硬链接条目，包不会变大。
if [[ "$BASE" != "$TAG" ]]; then
    BASE_DIR_PKG="$LAUNCHER_HOME/versions/$BASE"
    if [[ -e "$BASE_DIR_PKG" ]]; then
        echo "错误：包里已经有 $BASE 了，不该出现两个" >&2; exit 1
    fi
    mkdir -p "$BASE_DIR_PKG"
    (cd "$VERSIONS" && find . -mindepth 1 -maxdepth 1 -exec cp -al {} "$BASE_DIR_PKG/" \;)
    echo "    另存为 $BASE（硬链接，不额外占空间）"
fi

cat > "$ROOT/run-offline.sh" <<'LAUNCH'
#!/bin/sh
# Start the Sunrise launcher with this folder as its data folder.
#
# The launcher keeps installed builds under <data_dir>/versions/ and follows only
# SUNRISE_LAUNCHER_HOME (default ~/.local/share/sunrise/launcher). Both variables
# are set here: with only one set it reads ~/.config/sunrise/launcher/location.json
# and can pick up whatever the player already had.
set -eu
self=$0
while [ -L "$self" ]; do
  link=$(readlink "$self")
  case $link in
    /*) self=$link ;;
    *) self=$(dirname "$self")/$link ;;
  esac
done
here=$(cd "$(dirname "$self")" && pwd)
SUNRISE_LAUNCHER_HOME="$here/data"
SUNRISE_HOME="$here/data"
export SUNRISE_LAUNCHER_HOME SUNRISE_HOME
exec "$here/sunrise-launcher" "$@"
LAUNCH
chmod +x "$ROOT/run-offline.sh"

cat > "$ROOT/play-offline.sh" <<LAUNCH
#!/bin/sh
# Start the bundled Sunrise client straight from its folder, no launcher.
#
# No account is used: the client runs as the classic offline player, so single
# player, LAN hosting and joining an offline-mode server all work. The launcher's
# single-player-only flag is never passed, because the launcher is never involved.
#
#   ./PLAY-OFFLINE.sh                        play offline
#   ./PLAY-OFFLINE.sh --name YourName        play as YourName
#   ./PLAY-OFFLINE.sh --server 192.168.1.9   join an offline-mode server
set -eu
self=\$0
while [ -L "\$self" ]; do
  link=\$(readlink "\$self")
  case \$link in
    /*) self=\$link ;;
    *) self=\$(dirname "\$self")/\$link ;;
  esac
done
here=\$(cd "\$(dirname "\$self")" && pwd)

GAME="\$here/data/versions/${TAG}"
BASE_DIR="\$here/data/versions/${BASE}"
MIRROR="\$here/resources"
CLIENT="\$GAME/sunrise-client"
if [ ! -x "\$CLIENT" ]; then
  echo "PLAY-OFFLINE.sh: \$CLIENT is missing" >&2
  exit 1
fi

# Where the launcher runs the game: saves, options.txt, logs, mods.
SUNRISE_HOME="\$here/data"
export SUNRISE_HOME

# The game files can be next to the native build, next to the base build it was
# compiled for (client native builds share the base's prepared resources), or
# already mirrored into ./resources.
MANIFEST=
for candidate in \\
  "\$MIRROR"/*/sunrise-resources.json \\
  "\$GAME/.local/sunrise-client"/*/sunrise-resources.json \\
  "\$BASE_DIR/.local/sunrise-client"/*/sunrise-resources.json
do
  if [ -f "\$candidate" ]; then
    MANIFEST=\$candidate
    break
  fi
done

if [ -z "\$MANIFEST" ]; then
  cat >&2 <<MISSING
PLAY-OFFLINE.sh: the game files are not prepared yet.

They are built from your own Minecraft: Java Edition, and that step lives in the
launcher. Run this once and let it finish:

    ./run-offline.sh prepare

The first run also takes the 26.3 version file and server jar from Mojang (about
250 MB), so it needs a network connection once.

Then run ./PLAY-OFFLINE.sh again.
MISSING
  exit 1
fi
RESOURCES=\$(dirname "\$MANIFEST")

# The launcher marks its data folder with ./data/run-leases/, and the client
# refuses any build that lives inside such a folder without a lease written for
# it (exit 78, before a window appears):
#   "cannot acquire launcher cache leases: ... is in the launcher's data folder
#    but has no cache lease there"
# A lease only exists for builds the launcher installed itself. This native
# build was compiled outside the launcher, so it has none and can never get one.
# Without the marker the folder counts as an ordinary one, and then both the
# build and the files prepared next to it start in place (measured: first frame
# 79 ms), so nothing has to be copied anywhere. ./run-offline.sh prepare puts the
# marker back every time it runs, which is why this is not a one-off.
if [ -d "\$here/data/run-leases" ]; then
  rm -rf "\$here/data/run-leases"
fi

given=0
for arg in "\$@"; do
  [ "\$arg" = "--resources" ] && given=1
done
if [ "\$given" -eq 1 ]; then
  exec "\$CLIENT" "\$@"
fi
exec "\$CLIENT" --resources "\$RESOURCES" "\$@"
LAUNCH
chmod +x "$ROOT/play-offline.sh"
ln -sf play-offline.sh "$ROOT/PLAY-OFFLINE.sh"

# 走启动器路线时的保险：滤掉启动器给本体加上的 --developer-single-player。
install -m 755 "$(dirname "${BASH_SOURCE[0]}")/offline-wrapper.sh" "$ROOT/offline-wrapper.sh"

echo "==> 写 BUILD-INFO"
python3 - "$MANIFEST" "$ROOT/BUILD-INFO.txt" "$TAG" "$BASE" "$MODS_LABEL" <<'PY'
import json, sys, datetime
manifest, out, tag, base, label = sys.argv[1:6]
d = json.load(open(manifest))
lines = [
    "Sunrise native mod pack (Linux x86_64)",
    "=" * 40,
    "",
    f"Version:    {tag}",
    f"Base build: {base}",
    f"Sunrise:    {d.get('sunrise')}",
    f"Mixins:     {d.get('horizon_mixins')}",
    f"Rust:       {d.get('rust')}   profile: {d.get('profile')}   route: {d.get('route')}",
    "",
    "Compiled in GitHub Actions (ubuntu-22.04) by the official launcher's own",
    "native-build; nothing here is patched. Libraries:",
    "",
]
for lib in d.get("libraries", []):
    lines.append(f"  {lib.get('kind','?'):6} {lib.get('mod','?'):16} {lib['file']}")
    lines.append(f"        {lib.get('identity')}")
lines += ["", "Mods (all MIT unless noted; taken from the Sunrise registry by exact version):", ""]
for m in d.get("mods", []):
    lines.append(f"  {m.get('id')} {m.get('version')}")
lines += [
    "",
    "How to play",
    "-----------",
    "Once, to build the game files from your own Minecraft 26.3:",
    "",
    "    ./run-offline.sh prepare",
    "",
    "That first run also takes the 26.3 version file and server jar from Mojang",
    "(about 250 MB), so it needs a network connection once. Everything after that",
    "works offline.",
    "",
    "Then, to play offline (single player, LAN, private offline-mode servers):",
    "",
    "    ./PLAY-OFFLINE.sh",
    "    ./PLAY-OFFLINE.sh --name YourName",
    "    ./PLAY-OFFLINE.sh --server 192.168.1.9",
    "",
    "Do not run ./sunrise-launcher by itself: it only looks in its own data folder,",
    "so start it through ./run-offline.sh, which points it at ./data.",
    "",
    "Native mods only load on the build they were compiled against. This pack is",
    f"built for {base}; installing it on another build makes the mods unloadable",
    "and the pack useless. Use ./run-offline.sh to install a matching build.",
    "",
    f"Built: {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
    f"Mods: {label}",
    "",
    "Sunrise needs your own copy of Minecraft: Java Edition.",
    "",
]
open(out, "w").write("\n".join(lines))
PY

cat > "$ROOT/PLAY-OFFLINE.txt" <<EOF
Sunrise native mod pack (Linux x86_64)
======================================

Version:  ${TAG}
Base:     ${BASE}
Mods:     ${MODS_LABEL}

First run, once:   ./run-offline.sh prepare
                   needs Minecraft 26.3 of your own, plus about 250 MB taken
                   from Mojang, so it has to be online that once
Then to play:      ./PLAY-OFFLINE.sh

See BUILD-INFO.txt for the build identity and the mod list.
EOF

ASSET="$OUT/${BASE}-${MODS_BRIEF}-${STAMP}.tar.gz"
echo "==> 打包"
tar -czf "$ASSET" -C "$ROOT" --sort=name .
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "PACKAGE_ASSET=$ASSET" >> "$GITHUB_ENV"
  echo "PACKAGE_TAG=$TAG" >> "$GITHUB_ENV"
fi
echo "==> 完成：$ASSET（$(du -h "$ASSET" | cut -f1)）"
