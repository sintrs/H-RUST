#!/usr/bin/env bash
# 组装离线包：自编的离线启动器 + 官方 nightly 游戏包（原样复制，不编译）。
#
# 与 gerdaroot 那套同源：离线账号体系（离线名、无拥有者可玩）是**源码级移植**的，
# 补丁见 tools/ci/offline-port.patch，不是靠环境变量或开发者版目录名。
# 因此版本目录就是普通名字（nightly-<date>-<sha>），启动器按正常版本对待它。
#
# 包里没有任何脚本：解压后直接打开 horizon-launcher，它自己把随包的 data/versions
# 装进启动器数据目录并选中（launcher/src/horizon_bundle.rs）。离线名在启动器的
# 设置 → 账号页里改，也可以 `horizon-launcher account offline NAME`。
#
# 用法:
#   bash make-offline-package.sh <launcher.tar.gz|-> <game.tar.gz|-> <commit> <输出目录> <自编 launcher> <版本 tag>
#
# <launcher.tar.gz> 只用来取随包的图标 / desktop 文件（里面的 horizon-launcher 一定会被
# 自编的那个覆盖，data/ 一律不收），所以传官方启动器包或已有的离线包都行；传 `-` 就纯不带图标。
#
# 两种取游戏的方式：
#   默认            解开 <game.tar.gz>（上游 nightly 原样包）当版本目录
#   NATIVE_DIR=…    直接用一个已装好的版本目录（native 版：loader + SDK 库 + mod .so）。
#                   此时 <game.tar.gz> 传 `-`，tag 传该目录的目录名。`.local`（资源缓存，
#                   首启会重建）与 `.last-used` 不打包。
set -euo pipefail

LAUNCHER_TGZ=${1:?用法: make-offline-package.sh <launcher.tar.gz> <game.tar.gz> <commit> <输出目录> <launcher 二进制> <版本 tag>}
GAME_TGZ=${2:?}
COMMIT=${3:?}
OUT=${4:-package}
LAUNCHER_BIN=${5:?}
TAG=${6:?}
NATIVE_DIR=${NATIVE_DIR:-}

if [[ "$LAUNCHER_TGZ" != "-" ]]; then
  [[ -f "$LAUNCHER_TGZ" ]] || { echo "错误：找不到启动器包 $LAUNCHER_TGZ" >&2; exit 1; }
fi
if [[ -n "$NATIVE_DIR" ]]; then
  [[ -d "$NATIVE_DIR" ]] || { echo "错误：NATIVE_DIR 不是目录 $NATIVE_DIR" >&2; exit 1; }
else
  [[ -f "$GAME_TGZ" ]] || { echo "错误：找不到游戏包 $GAME_TGZ" >&2; exit 1; }
fi
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "错误：commit 必须是 40 位十六进制" >&2; exit 1; }
[[ -x "$LAUNCHER_BIN" ]] || { echo "错误：找不到自编的启动器 $LAUNCHER_BIN" >&2; exit 1; }
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "错误：版本 tag 含非法字符：$TAG" >&2; exit 1; }

SHORT=${COMMIT:0:7}
# 附件名带构建时刻，和 game 那边带版本号的命名对位：
#   horizon-linux-x86_64-nightly-2026-11-20-0a875da.tar.gz   （game，上游原名）
#   horizon-linux-x86_64-offline-2026-11-21-1643.tar.gz      （这个，日期-时分）
# 时间取北京时间（UTC+8），可用 STAMP 覆盖（测试用）。
# 用 POSIX TZ 写法而不是 Asia/Shanghai：不依赖机器上装没装 tzdata。
# 缺 tzdata 时 TZ=Asia/Shanghai 会静默退回 UTC，包名就差 8 小时且看不出来。
STAMP=${STAMP:-$(TZ=CST-8 date +%Y-%m-%d-%H%M)}
NAME=horizon-linux-x86_64

WORK=$(mktemp -d "${TMPDIR:-/tmp}/h-offline.XXXXXX")
# KEEP_WORK=1 保留临时目录（本地排查用；CI 里不要设，否则盘子会涨）
if [[ "${KEEP_WORK:-0}" != "1" ]]; then
  trap 'rm -rf "$WORK"' EXIT
else
  trap 'echo "临时目录保留在 $WORK"' EXIT
fi
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# 包内**不再套一层同名的目录**：解开就是 horizon-launcher 和 data/ 直接落在当前目录。
# 以前套的那层 wrapper 目录只是让 tar 有个根，玩家却要多 cd 一次。
ROOT="$WORK/root"
VERSIONS="$ROOT/data/versions/$TAG"
mkdir -p "$VERSIONS"

if [[ "$LAUNCHER_TGZ" != "-" ]]; then
  echo "==> 解开官方启动器包（只取随包的图标与 LICENSE）"
  mkdir -p "$WORK/launcher-pkg"
  tar -xzf "$LAUNCHER_TGZ" -C "$WORK/launcher-pkg" --touch --no-same-owner
  # 只搬非二进制资源：horizon-launcher 一定换成自编的，data/ 绝不能从这儿混进来
  (cd "$WORK/launcher-pkg" && tar -cf - --exclude=./horizon-launcher --exclude=./data .) \
    | (cd "$ROOT" && tar -xmf -)
fi
install -Dm755 "$LAUNCHER_BIN" "$ROOT/horizon-launcher"
echo "==> 已放入自编的离线启动器"

echo "==> 解开官方游戏包"
if [[ -n "$NATIVE_DIR" ]]; then
  echo "==> 改用现成的 native 版本目录：$NATIVE_DIR"
  [[ -f "$NATIVE_DIR/.installed" ]] || { echo "错误：native 目录没有 .installed（启动器不会认）" >&2; exit 1; }
  [[ -f "$NATIVE_DIR/native-mods.json" ]] || echo "    警告：没有 native-mods.json，启动器可能会就地重编 mod"
  GAME_DIR=$NATIVE_DIR
else
  mkdir -p "$WORK/game"
  tar -xzf "$GAME_TGZ" -C "$WORK/game" --touch --no-same-owner 2>/dev/null || true
  GAME_DIR=$(find "$WORK/game" -maxdepth 2 -type f -name 'horizon-client' | head -1)
  [[ -n "$GAME_DIR" ]] || { echo "错误：游戏包里没有 horizon-client" >&2; exit 1; }
  GAME_DIR=$(dirname "$GAME_DIR")
fi

echo "==> 把游戏装成 $TAG"
# tar 管道复制，解包带 -m（不还原 mtime）：有些文件系统不允许改时间戳。
# native 版不带走 .local（811 MB 资源缓存，首次启动重建）与 .last-used。
if [[ -n "$NATIVE_DIR" ]]; then
  (cd "$GAME_DIR" && tar -cf - --exclude=./.local --exclude=./.last-used .) | (cd "$VERSIONS" && tar -xmf -)
else
  (cd "$GAME_DIR" && tar -cf - .) | (cd "$VERSIONS" && tar -xmf -)
fi

# 普通版本目录：启动器靠 .installed 认出"已安装"，靠目录名当 tag。
: > "$VERSIONS/.installed"

CLIENT="$VERSIONS/horizon-client"
[[ -f "$CLIENT" ]] || { echo "错误：版本目录里没有 horizon-client" >&2; exit 1; }
chmod +x "$CLIENT"
for extra in horizon-ctl horizon-prepare horizon-server; do
  [[ -f "$VERSIONS/$extra" ]] && chmod +x "$VERSIONS/$extra"
done

if [[ -n "$NATIVE_DIR" ]]; then
cat > "$ROOT/PLAY-OFFLINE.txt" <<EOF
Horizon offline package (native mods included)
=============================================

Game build: nightly $SHORT, with the minimap native mod already compiled for it
Launcher:   built from the same upstream source with the offline account patch
            (offline names, no account needed, multiplayer and LAN work, no self-update)

Nothing is compiled on your side: the mod ships as a .so built against this exact
build ($SHORT), so the launcher takes it as-is instead of rebuilding it.

How to play
-----------
1. Open ./horizon-launcher (double-click it).
   The first start copies the bundled build into the launcher data folder and
   selects it -- after that just click the launcher's icon. The first start also
   rebuilds the ~800 MB asset cache, so give it a minute.
2. Your offline name: Settings -> Account -> "Play offline", type a name (3 to 16
   letters, digits or _) and press Enter. From a terminal, the same:
       ./horizon-launcher account offline YourName
3. The minimap is part of the build; its key bindings are in Settings -> Mods.

No Microsoft account is needed and no account session is read.
Single-player, multiplayer and LAN all work. Servers that require a real
Minecraft account (online-mode=true) will still reject offline identities.
EOF
else
cat > "$ROOT/PLAY-OFFLINE.txt" <<EOF
Horizon offline package
=======================

Game build: upstream nightly $SHORT (copied verbatim, not rebuilt)
Launcher:   built from the same upstream source with the offline account patch
            (offline names, no account needed, multiplayer and LAN work, no self-update)

How to play
-----------
1. Open ./horizon-launcher (double-click it).
   The first start copies the bundled game build into the launcher data folder and
   selects it -- after that just click the launcher's icon.
2. Your offline name: Settings -> Account -> "Play offline", type a name (3 to 16
   letters, digits or _) and press Enter. The game then plays as that name's
   offline UUID. From a terminal, the same:
       ./horizon-launcher account offline YourName
3. First time only, it needs Minecraft 26.3 assets: an installed Minecraft 26.3
   is found automatically (official / Prism / MultiMC / Modrinth / ATLauncher),
   or run
       ./horizon-launcher prepare --version $TAG

No Microsoft account is needed and no account session is read.
Single-player, multiplayer and LAN all work. Servers that require a real
Minecraft account (online-mode=true) will still reject offline identities.
EOF
fi

if [[ -n "$NATIVE_DIR" ]]; then
  ASSET="$OUT/$NAME-native-offline-$STAMP.tar.gz"
else
  ASSET="$OUT/$NAME-offline-$STAMP.tar.gz"
fi
# `-C root .` so the archive has no wrapper directory: `tar -xzf` here yields
# ./horizon-launcher and ./data directly. Sorting keeps runs comparable.
tar -czf "$ASSET" -C "$ROOT" --sort=name .
# The file name carries the build time, so the caller has to learn it from us rather
# than globbing for it. GITHUB_ENV covers later steps; the stdout line is for a human.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "PACKAGE_ASSET=$ASSET" >> "$GITHUB_ENV"
fi
echo "==> 打包完成：$ASSET（$(du -h "$ASSET" | cut -f1)）"
echo "    tag=$TAG  commit=$COMMIT"
