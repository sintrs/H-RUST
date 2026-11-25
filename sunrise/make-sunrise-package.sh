#!/usr/bin/env bash
# 组装 Sunrise 离线包：官方启动器 + 官方本体包（原样复制，不编译）。
#
# 和 Horizon 那条链的根本区别：**不打源码补丁**。Sunrise 本体自带离线入口
# （`sunrise-client --name NAME`），启动器也已经装好随包版本，两个官方产物拼起来
# 就是一个能玩的包。这条链只验证「拼起来能不能用」，不做任何源码级改动。
#
# 版面与 Horizon 包保持一致（解压不套目录，直接是 sunrise-launcher + data/），
# 这样两个包的操作习惯一样。
#
# 用法:
#   bash sunrise/make-sunrise-package.sh <launcher.tar.gz> <game.tar.gz> <commit> <输出目录> <版本 tag>
#
# <launcher.tar.gz> 用官方的 sunrise-launcher-linux-x86_64.tar.gz：既给启动器二进制，
# 也给随包的图标/desktop 文件。
set -euo pipefail

LAUNCHER_TGZ=${1:?用法: make-sunrise-package.sh <launcher.tar.gz> <game.tar.gz> <commit> <输出目录> <版本 tag>}
GAME_TGZ=${2:?}
COMMIT=${3:?}
OUT=${4:-package}
TAG=${5:?}

[[ -f "$LAUNCHER_TGZ" ]] || { echo "错误：找不到启动器包 $LAUNCHER_TGZ" >&2; exit 1; }
[[ -f "$GAME_TGZ" ]] || { echo "错误：找不到本体包 $GAME_TGZ" >&2; exit 1; }
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "错误：commit 必须是 40 位十六进制" >&2; exit 1; }
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "错误：版本 tag 含非法字符：$TAG" >&2; exit 1; }

SHORT=${COMMIT:0:7}
# 附件名带北京时间的构建时刻，与 Horizon 那两个 release 的命名对位。
# 用 POSIX TZ 写法而不是 Asia/Shanghai：不依赖机器上装没装 tzdata，
# 而 Asia/Shanghai 在缺 tzdata 时会静默退回 UTC，名字就差 8 小时且看不出来。
STAMP=${STAMP:-$(TZ=CST-8 date +%Y-%m-%d-%H%M)}
NAME=sunrise-linux-x86_64

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sun-pkg.XXXXXX")
if [[ "${KEEP_WORK:-0}" != "1" ]]; then
  trap 'rm -rf "$WORK"' EXIT
else
  trap 'echo "临时目录保留在 $WORK"' EXIT
fi
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# 与 Horizon 包同构：不解套一层目录，解压即得 sunrise-launcher 与 data/。
ROOT="$WORK/root"
VERSIONS="$ROOT/data/versions/$TAG"
mkdir -p "$VERSIONS"

echo "==> 解开官方启动器包"
mkdir -p "$WORK/launcher-pkg"
tar -xzf "$LAUNCHER_TGZ" -C "$WORK/launcher-pkg" --touch --no-same-owner
# 官方包可能套了一层目录，也可能没有；找到真正装着启动器的那个层。
LAUNCHER_BIN=$(find "$WORK/launcher-pkg" -maxdepth 2 -type f -name 'sunrise-launcher' -perm -u+x | head -1)
[[ -n "$LAUNCHER_BIN" ]] || { echo "错误：启动器包里没有可执行的 sunrise-launcher" >&2
  find "$WORK/launcher-pkg" -maxdepth 2 | head -20 >&2; exit 1; }
LAUNCHER_DIR=$(dirname "$LAUNCHER_BIN")
echo "    启动器在 $(realpath --relative-to="$WORK/launcher-pkg" "$LAUNCHER_DIR")"
# 整层搬过去（图标、desktop、LICENSE 都在里面），data/ 若存在也不收：
# 那是启动器自己的数据目录，绝不能让官方包里的空壳盖住随包版本。
(cd "$LAUNCHER_DIR" && tar -cf - --exclude=./data .) | (cd "$ROOT" && tar -xmf -)

echo "==> 解开官方本体包"
mkdir -p "$WORK/game"
tar -xzf "$GAME_TGZ" -C "$WORK/game" --touch --no-same-owner
CLIENT=$(find "$WORK/game" -maxdepth 3 -type f -name 'sunrise-client' | head -1)
[[ -n "$CLIENT" ]] || { echo "错误：本体包里没有 sunrise-client" >&2
  find "$WORK/game" -maxdepth 3 | head -20 >&2; exit 1; }
GAME_DIR=$(dirname "$CLIENT")

echo "==> 把本体装成 $TAG"
# tar 管道复制，解包带 -m（不还原 mtime）：有些文件系统不允许改时间戳。
(cd "$GAME_DIR" && tar -cf - .) | (cd "$VERSIONS" && tar -xmf -)

# Sunrise 用版本目录名当 build 名；Sunrise 启动器认出「已装」的标志还不确定是
# .installed 还是别的，两种都放上，冒烟测试会告诉我们哪个真正起作用。
: > "$VERSIONS/.installed"

for exe in sunrise-client sunrise-ctl sunrise-prepare sunrise-server sunrise-perf sunrise-port-pack; do
  [[ -f "$VERSIONS/$exe" ]] && chmod +x "$VERSIONS/$exe"
done
[[ -f "$VERSIONS/sunrise-client" ]] || { echo "错误：版本目录里没有 sunrise-client" >&2; exit 1; }

cat > "$ROOT/PLAY-OFFLINE.txt" <<EOF
Sunrise offline package (Linux x86_64)
======================================

Game build: ${TAG} (upstream release, copied verbatim, not rebuilt)
Launcher:   official Sunrise launcher, unmodified
Commit:     ${COMMIT}

Nothing here is compiled or patched: this is the official launcher and the official
game build, packaged together so the build is already installed on first start.

How to play
-----------
1. Open ./sunrise-launcher (double-click it).
2. Single player: the build is already installed, press Play. Sunrise prepares the
   resources from your own Minecraft: Java Edition 26.3 the first time.
3. Offline name, from a terminal:
       ./data/versions/${TAG}/sunrise-client --name YourName
   (or run the client directly from that folder.)

Sunrise needs your own copy of Minecraft: Java Edition. No account is used by the
steps above; servers with online-mode=true still reject offline identities.
EOF

ASSET="$OUT/$NAME-offline-$STAMP.tar.gz"
# `-C root .` so the archive has no wrapper directory: `tar -xzf` here yields
# ./sunrise-launcher and ./data directly.
tar -czf "$ASSET" -C "$ROOT" --sort=name .
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "PACKAGE_ASSET=$ASSET" >> "$GITHUB_ENV"
fi
echo "==> 打包完成：$ASSET（$(du -h "$ASSET" | cut -f1)）"
echo "    tag=$TAG  commit=$COMMIT"
