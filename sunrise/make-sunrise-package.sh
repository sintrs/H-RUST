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

# 版面：包根目录就是启动器的**数据目录**，不是游戏目录。
#
# 这是和 Horizon 包最大的不同，也是实测出来的：Sunrise 启动器认已装版本的唯一依据是
# `<data_dir>/versions/<tag>/.installed`（backend::installed() 读它），而 data_dir()
# 默认是 `~/.local/share/sunrise/launcher`，**不看包旁边放什么**。所以把本体放
# `data/versions/` 再指望启动器自己发现，是行不通的 —— CI 上跑出来就是
# "No version is installed."。
#
# 因此 data/ 直接做成启动器数据目录，并用 run-offline.sh 把 SUNRISE_LAUNCHER_HOME
# 指过来（两个变量都要设：只设一个时启动器会去读 location.json，可能被旧记录干扰）。
ROOT="$WORK/root"
LAUNCHER_HOME="$ROOT/data"
VERSIONS="$LAUNCHER_HOME/versions/$TAG"
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

# 这个标记就是启动器认「已装」的全部依据：backend::installed() 只收
# `versions/*/.installed` 存在的目录，内容不看。空文件即可。
: > "$VERSIONS/.installed"

for exe in sunrise-client sunrise-ctl sunrise-prepare sunrise-server sunrise-perf sunrise-port-pack; do
  [[ -f "$VERSIONS/$exe" ]] && chmod +x "$VERSIONS/$exe"
done
[[ -f "$VERSIONS/sunrise-client" ]] || { echo "错误：版本目录里没有 sunrise-client" >&2; exit 1; }

# 启动脚本：Sunrise 启动器只认自己的数据目录，而那个目录由 SUNRISE_LAUNCHER_HOME
# 决定，不是「启动器旁边」。没有这个脚本，包解开后启动器看到的是玩家家里那个空目录，
# 随包版本相当于不存在。
#
# 两个变量都设：data_location::configured_roots() 只在 **两个都设** 时返回 None，
# 这时 data_dir() 直接用 SUNRISE_LAUNCHER_HOME；只设一个它会去读
# ~/.config/sunrise/launcher/location.json，玩家之前装过别的版本就会串。
cat > "$ROOT/run-offline.sh" <<'LAUNCH'
#!/bin/sh
# Start the Sunrise launcher with this folder as its data folder.
#
# The launcher keeps its installed builds under <data_dir>/versions/, and data_dir()
# only follows SUNRISE_LAUNCHER_HOME (default ~/.local/share/sunrise/launcher).
# Pointing both that and SUNRISE_HOME here is what makes the bundled build visible
# instead of whatever the player's home already had.
set -eu

# Resolve our own folder, following symlinks, so the script works when linked elsewhere.
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

# 直连本体的入口：不经启动器，因此也不受 `--developer-single-player` 的任何限制。
#
# 为什么需要它：启动器调 client 时若带上 `--developer-single-player`，本体就把
# 账号层拆掉并把所有网络路径堵死（`--server` 拒绝、开放局域网拒绝、LAN 监听拒绝、
# 连远程服拒绝），只剩单人。不传这个 flag 时本体走「无会话」分支，什么都不拦：
# 自己用 `--name` 算离线 UUID，能开 LAN、能进离线服务器。Horizon 的启动器补丁
# 做的就是「别传这个 flag」，这里换成「干脆不经启动器」。
#
# First run needs the game files prepared from your own Minecraft, which the
# launcher does through its own UI, so the script finds whatever the launcher
# prepared and passes it on with --resources.
cat > "$ROOT/play-offline.sh" <<LAUNCH
#!/bin/sh
# Start the bundled Sunrise client straight from its folder, no launcher.
#
# No account is used. Started with no session at all, the client runs as the
# classic Minecraft offline player, so single-player, LAN hosting and joining an
# offline-mode server all work -- the launcher's single-player-only flag is
# never passed, because the launcher is never involved.
#
# Usage:
#   ./PLAY-OFFLINE.sh                  play offline
#   ./PLAY-OFFLINE.sh --name YourName  play as YourName
#   ./PLAY-OFFLINE.sh --server HOST    join an offline-mode server
#
# Anything else is passed straight to sunrise-client (sunrise-client --help).
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
CLIENT="\$GAME/sunrise-client"
if [ ! -x "\$CLIENT" ]; then
  echo "PLAY-OFFLINE.sh: \$CLIENT is missing" >&2
  exit 1
fi

# Where the launcher runs the game: saves, options.txt, logs, mods.
SUNRISE_HOME="\$here/data"
export SUNRISE_HOME

# The client defaults --resources to \`.local/sunrise-client/<version>\` relative to
# the working directory, so it has to be told where the prepared files are. The
# launcher prepares them inside the version folder; the version too is read from
# research-lock.json, the same rule sunrise-ctl uses.
MANIFEST=
for candidate in \\
  "\$GAME/.local/sunrise-client"/*/sunrise-resources.json \\
  "\$GAME/resources/sunrise-resources.json"
do
  if [ -f "\$candidate" ]; then
    MANIFEST=\$candidate
    break
  fi
done

if [ -z "\$MANIFEST" ]; then
  cat >&2 <<MISSING
PLAY-OFFLINE.sh: the game files are not prepared yet.

Sunrise builds them from your own Minecraft: Java Edition, and that step lives in
the launcher. Run ./run-offline.sh once, pick the build, press Play, and wait for
the first start to finish -- or in a terminal:

    ./run-offline.sh prepare

(the build is already selected, so no arguments are needed; add
--version ${TAG} if you want to name it -- a bare tag is rejected)

Then run ./PLAY-OFFLINE.sh again. Nothing is downloaded from our side: the files
come from the copy of Minecraft you own.
MISSING
  exit 1
fi
RESOURCES=\$(dirname "\$MANIFEST")

# --resources is filled in here, but an explicit one on the command line wins.
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

# 走启动器路线时的保险：启动器若给本体传了 --developer-single-player，这个脚本
# 把它滤掉。用启动器的 profile 钩子挂上（Settings → 该 profile 的 launch 命令，
# 或 `sunrise-launcher launch --wrapper ...`）；不挂也不影响 play-offline.sh。
install -m 755 "$(dirname "${BASH_SOURCE[0]}")/offline-wrapper.sh" "$ROOT/offline-wrapper.sh"

cat > "$ROOT/PLAY-OFFLINE.txt" <<EOF
Sunrise offline package (Linux x86_64)
======================================

Game build: ${TAG} (upstream release, copied verbatim, not rebuilt)
Launcher:   official Sunrise launcher, unmodified
Commit:     ${COMMIT}

Nothing here is compiled or patched: this is the official launcher and the official
game build, with the build already installed so the launcher offers it on first start.

Two ways to play
----------------
A. ./PLAY-OFFLINE.sh   <-- use this one for offline play

   Starts the game build directly, no launcher involved, no account. Single player,
   LAN and a private offline-mode server all work from here.

       ./PLAY-OFFLINE.sh                        play offline
       ./PLAY-OFFLINE.sh --name YourName        play as YourName
       ./PLAY-OFFLINE.sh --server 192.168.1.9   join an offline-mode server

   From a menu or from a terminal somewhere else, use the full path:
       /full/path/to/PLAY-OFFLINE.sh

B. ./run-offline.sh    <-- the launcher

   Starts the official launcher with the build already installed and selected.
   It has no offline account entry, so it cannot sign in -- but it is where the
   game files get prepared from your own Minecraft the first time, and where you
   change Java settings or pick another build.

   Do not run ./sunrise-launcher by itself -- it only looks for installed builds in
   its own data folder, so you would see whatever your home folder already had
   instead of the build shipped here.

First run
---------
The first start has to prepare the game files, and that step lives in the launcher.
So once:

       ./run-offline.sh              then press Play and let it finish

   or, in a terminal:
       ./run-offline.sh prepare

   The build is already selected, so that is all it needs. To name it, use the
   --version option: ./run-offline.sh prepare --version ${TAG}
   (a bare tag is rejected -- "unexpected argument").

After that ./PLAY-OFFLINE.sh goes straight in. It finds the prepared files by
itself and passes them along; if they are not there yet it says so instead of
failing inside the game. Nothing is downloaded from our side -- the files come
from the copy of Minecraft you own.

Why A does not go through the launcher
--------------------------------------
The launcher was built for online accounts and has no offline mode. The build
itself does: started with no session at all, it runs as the classic Minecraft
offline player, with the identity taken from --name. That is exactly what A does.
If you do go through the launcher, ./offline-wrapper.sh is included as a safety
net -- point the launcher's launch command at it and it strips the account-only
flags the launcher likes to add.

What does not work offline
--------------------------
- Servers with online-mode=true still reject offline identities. Set
  online-mode=false in a private server you control.
- Skins and cape come from the account server, so you get the default skin.
- The launcher's own account pages do nothing without a login.

Sunrise needs your own copy of Minecraft: Java Edition.
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
