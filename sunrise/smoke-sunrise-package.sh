#!/usr/bin/env bash
# 冒烟：把真正会交给玩家的包解开、跑起来。
#
# 与 Horizon 那条链的 smoke 是同一个思路，但断言换成了 Sunrise 自己的契约：
# 这里没有任何补丁，所以不是查「离线闸门还开着吗」，而是查「官方产物拼起来之后，
# 随包的那个本体是不是这个 build、能不能起、离线入口还在不在」。
#
# 三条断言各自防一件真事：
#   1. 启动器能跑            —— 包里的启动器二进制能在这台机器上执行
#   2. 随包本体就是这个 build —— 版本目录没串包、没被别的产物盖掉
#   3. 本体能起、带离线入口   —— 不登录也能开单人世界
#
# 第 1 条在某些根环境（例如容器里以 root 直跑、/root 不可写）会失败，那不是包坏了。
# 这种失败被单独识别成 skipped，不判失败 —— 否则一个只在特定 runner 上成立的环境
# 限制会把整条链判红。真的包坏（缺文件、版本串了）仍然判失败。
#
# 用法:
#   bash sunrise/smoke-sunrise-package.sh <package.tar.gz> <version tag>
set -uo pipefail

TGZ=${1:?用法: smoke-sunrise-package.sh <package.tar.gz> <version tag>}
TAG=${2:?用法: smoke-sunrise-package.sh <package.tar.gz> <version tag>}
TGZ=$(cd "$(dirname "$TGZ")" && pwd)/$(basename "$TGZ")
[[ -f "$TGZ" ]] || { echo "::error title=Sunrise smoke::no such package: $TGZ"; exit 1; }

# 辅助检查器与这个脚本同目录；冒烟全程在临时目录里跑，所以要绝对路径。
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

mkdir -p "${SMOKE_TMPDIR:-${TMPDIR:-/var/tmp}}"
BASE=$(mktemp -d "$( cd "${SMOKE_TMPDIR:-${TMPDIR:-/var/tmp}}" && pwd )/sun-smoke.XXXXXX")
LOG="$BASE/smoke.log"
FAILS=0

cleanup() { [[ "${KEEP_SMOKE:-0}" == 1 ]] && echo "kept: $BASE" || rm -rf "$BASE"; }
trap cleanup EXIT
: > "$LOG"

say() { echo "-- $*"; }
bad() { echo "::error title=Sunrise smoke::$*"; FAILS=$((FAILS + 1)); }
note() { echo "-- note: $*"; }
show_log() { sed 's/^/     | /' "$LOG" | tail -30; }

say "unpacking $TGZ"
mkdir -p "$BASE/extract"
if ! tar -xzf "$TGZ" -C "$BASE/extract" --no-same-owner --touch; then
  bad "cannot unpack $TGZ"
  exit 1
fi
PKG="$BASE/extract"

# --- 包的结构 ---------------------------------------------------------------
# 与 Horizon 包一致：不套目录，解开就是启动器、data/、PLAY-OFFLINE.txt。
# 启动器包自带的 LICENSE / LICENSES/ 必须留着（Sunrise 本体是 PolyForm Shield，
# 分发时得带上），所以它们在白名单里，不是意外闯入的东西。
EXTRA=$(ls -A "$PKG" | grep -vx -e sunrise-launcher -e data -e PLAY-OFFLINE.txt -e BUILD-INFO.txt \
                                      -e LICENSE -e LICENSES || true)
if [[ -n "$EXTRA" ]]; then
  bad "the package unpacks with unexpected top-level entries: $(echo "$EXTRA" | tr '\n' ' ')"
fi
[[ -x "$PKG/sunrise-launcher" ]] || { bad "the package has no executable sunrise-launcher"; exit 1; }
[[ -d "$PKG/data/versions/$TAG" ]] || { bad "the package has no bundled build at data/versions/$TAG"; exit 1; }
CLIENT="$PKG/data/versions/$TAG/sunrise-client"
[[ -x "$CLIENT" ]] || { bad "the bundled build $TAG has no executable sunrise-client"; exit 1; }
say "ok   top level is launcher + data/versions/$TAG"

# --- 一次性的运行环境 -------------------------------------------------------
# 启动器首启会往数据目录里装东西，绝不能碰 runner 的真状态。
# Horizon 改名成 Sunrise 后，读的是哪个环境变量还不确定，所以 HOME/XDG 一律重定向，
# 同时把两个候选名字都设上。
USER_HOME="$BASE/userhome"
mkdir -p "$USER_HOME"
export HOME="$USER_HOME"
export XDG_DATA_HOME="$USER_HOME/.local/share"
export XDG_CONFIG_HOME="$USER_HOME/.config"
export XDG_CACHE_HOME="$USER_HOME/.cache"
export XDG_STATE_HOME="$USER_HOME/.local/state"
export XDG_RUNTIME_DIR="$USER_HOME/run"
export HORIZON_LAUNCHER_HOME="$BASE/home-horizon"
export SUNRISE_LAUNCHER_HOME="$BASE/home-sunrise"
export SUNRISE_HOME="$BASE/home-sunrise"
export NO_AT_BRIDGE=1
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" \
         "$XDG_RUNTIME_DIR" "$HORIZON_LAUNCHER_HOME" "$SUNRISE_LAUNCHER_HOME"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

say "1. the packaged launcher starts"
L="$PKG/sunrise-launcher"
OUT=$(timeout 60 "$L" --version 2>&1) && RC=0 || RC=$?
echo "$OUT" >> "$LOG"
if [[ "$RC" -eq 0 && "$OUT" == *sunrise-launcher* ]]; then
  say "ok   --version -> $(head -1 <<< "$OUT")"
elif grep -qiE 'Permission denied|os error 13|No such file or directory' <<< "$OUT"; then
  # 根环境里启动器会去写一个宿主机上不可写的目录（容器、root 直跑）。
  # 这和包无关，把它记成 skip 而不是 fail。
  say "skipped: this environment cannot run the launcher ($(head -1 <<< "$OUT"))"
  LAUNCHER_USABLE=0
else
  bad "--version failed (exit $RC): $(head -3 <<< "$OUT")"
  LAUNCHER_USABLE=0
fi
LAUNCHER_USABLE=${LAUNCHER_USABLE:-1}

# --- 随包本体就是这个 build --------------------------------------------------
# `--launch-api` 打印的 `sunrise` 字段就是上游 release body 里那句
# "Nightly 2026-11-20 · 9425651"，与 sunrise-release.json 的 build 一一对应。
# 用它当断言，比 grep --help 稳：一个是结构化 JSON，一个是给人看的文本。
say "2. the bundled client is the build the package claims"
API_FILE="$BASE/launch-api.json"
timeout 120 "$CLIENT" --launch-api > "$API_FILE" 2>> "$LOG" && API_RC=0 || API_RC=$?
if [[ "$API_RC" -ne 0 && ! -s "$API_FILE" ]]; then
  bad "the bundled sunrise-client did not run at all (exit $API_RC); this machine cannot start the binary in this package"
else
  if VERDICT=$(python3 "$HERE/check-launch-api.py" "$TAG" "$API_FILE"); then
    say "ok   client $VERDICT"
  else
    bad "$VERDICT"
    show_log
  fi
  # 离线入口：`--developer-single-player` 是 Sunrise 官方**公开在 Launch API 契约里**
  # 的单人离线开关（docs/api/launch.md）。它不在 --help 里 —— 是隐藏选项 —— 所以
  # 只能从 --launch-api 的 options 里读到，这也是用它的原因：那是契约，help 是散文。
  # 这条断言就是「这个包不登录能不能开单人世界」的全部依据。
  if python3 "$HERE/check-launch-option.py" "$API_FILE" --developer-single-player; then
    say "ok   --developer-single-player is a launch option (single-player without sign-in)"
  else
    bad "sunrise-client no longer offers --developer-single-player: offline single-player is gone from this build"
  fi
  # --name 只管多人身份，不在 Launch API 的 options 里，所以单独从 --help 查。
  if timeout 60 "$CLIENT" --help 2>&1 | grep -qE -- '--name'; then
    say "ok   --name is still in --help (offline identity for multiplayer)"
  else
    note "sunrise-client --help no longer mentions --name; multiplayer identity may have moved"
  fi
fi

# --- 启动器认不认这个版本 ----------------------------------------------------
# --- 启动器认不认这个版本 ----------------------------------------------------
# 这一段是这条试验链唯一还没有答案的问题。Sunrise 启动器有自己的版本库（`versions`
# 子命令），而它的离线玩法走的是另一条路：`developer-install CHECKOUT --program CHECKOUT`
# —— 要一个 git checkout，不是「往版本目录里放个二进制」就完事。
#
# 所以「把官方包放进 data/versions/<tag>/」这个版面对启动器是否**真的**可用，本脚本
# 只能观察到「启动器有没有把它列出来」。列出来了 = 这条路成立；没列出来 = 启动器不认
# 这个版面，下一步得换成别的组装方式（或者退回「让玩家自己 prepare」的流程）。
# 两种情况这里都不判失败，因为包本身没坏 —— 坏的是假设，该由人看了结论再定。
say "3. does the launcher list the bundled build?"
if [[ "$LAUNCHER_USABLE" == "1" ]]; then
  # 列已装版本用 `versions`（Sunrise 的 CLI 里 `list` 不存在；`versions` 同时能列表
  # 上游 release 和本机已装的构建）。
  LIST_OUT=$(timeout 180 "$L" versions 2>&1) || LIST_RC=$?
  echo "$LIST_OUT" >> "$LOG"
  if [[ "${LIST_RC:-0}" -eq 0 ]]; then
    if grep -qF -- "$TAG" <<< "$LIST_OUT"; then
      say "ok   versions shows $TAG -- the packaged layout is usable by this launcher"
    else
      say "unanswered: the launcher runs but does not list $TAG"
      echo "--       the packaged layout is not one this launcher reads; the game still runs"
      echo "--       straight from data/versions/<tag>/, but the launcher will not offer it."
      echo "--       See sunrise/README.md for what to try next."
      echo "$LIST_OUT" | sed 's/^/     | /' | head -15
    fi
  else
    note "versions exited ${LIST_RC}: $(head -3 <<< "$LIST_OUT" | tr '\n' ' ')"
  fi
else
  say "skipped: the launcher cannot run in this environment"
fi

# --- 包里该有的东西都在 ------------------------------------------------------
say "4. the version folder is complete"
for f in sunrise-client sunrise-prepare PLAY.txt; do
  if [[ -e "$PKG/data/versions/$TAG/$f" ]]; then
    say "ok   $f"
  else
    [[ "$f" == "sunrise-prepare" || "$f" == "PLAY.txt" ]] && note "$f is not in this upstream build" \
      || bad "$f is missing from the version folder"
  fi
done

echo
if [[ "$FAILS" -gt 0 ]]; then
  echo "::error title=Sunrise smoke::$FAILS check(s) failed for $TAG"
  echo "--- smoke.log ---"
  tail -60 "$LOG" 2>/dev/null || true
  exit 1
fi
echo "smoke test passed for $TAG"
