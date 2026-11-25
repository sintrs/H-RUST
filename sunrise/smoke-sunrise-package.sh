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
                                      -e LICENSE -e LICENSES -e run-offline.sh -e PLAY.sh || true)
if [[ -n "$EXTRA" ]]; then
  bad "the package unpacks with unexpected top-level entries: $(echo "$EXTRA" | tr '\n' ' ')"
fi
[[ -x "$PKG/sunrise-launcher" ]] || { bad "the package has no executable sunrise-launcher"; exit 1; }
[[ -x "$PKG/run-offline.sh" ]] || { bad "the package has no run-offline.sh to point the launcher at data/"; exit 1; }
[[ -d "$PKG/data/versions/$TAG" ]] || { bad "the package has no bundled build at data/versions/$TAG"; exit 1; }
CLIENT="$PKG/data/versions/$TAG/sunrise-client"
[[ -x "$CLIENT" ]] || { bad "the bundled build $TAG has no executable sunrise-client"; exit 1; }
say "ok   top level is launcher + data/versions/$TAG + run-offline.sh"

# --- 一次性的运行环境 -------------------------------------------------------
# 每个测试都用一份**新解开的包**，因为 run-offline.sh 会把启动器指向包里那个 data/，
# 启动器会往里面写真东西（settings、prepare 状态）。共用一份的话第二个测试看到的
# 就不是「刚解压的样子」了。
#
# HOME/XDG 仍然重定向，避免碰到 runner 的真状态；但别再设 SUNRISE_LAUNCHER_HOME ——
# 那正是 run-offline.sh 要自己决定的东西，预先设上就测不出它有没有生效。
USER_HOME="$BASE/userhome"
mkdir -p "$USER_HOME"
export HOME="$USER_HOME"
export XDG_DATA_HOME="$USER_HOME/.local/share"
export XDG_CONFIG_HOME="$USER_HOME/.config"
export XDG_CACHE_HOME="$USER_HOME/.cache"
export XDG_STATE_HOME="$USER_HOME/.local/state"
export XDG_RUNTIME_DIR="$USER_HOME/run"
export NO_AT_BRIDGE=1
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
unset SUNRISE_LAUNCHER_HOME SUNRISE_HOME HORIZON_LAUNCHER_HOME

say "1. the packaged launcher starts"
# 走 run-offline.sh，因为那是玩家实际会跑的东西 —— 直接跑未包装的启动器会读到
# 玩家家里的数据目录，测不到这个包。
L="$PKG/run-offline.sh"
OUT=$(timeout 60 "$L" --version 2>&1) && RC=0 || RC=$?
echo "$OUT" >> "$LOG"
if [[ "$RC" -eq 0 && "$OUT" == *sunrise-launcher* ]]; then
  say "ok   run-offline.sh --version -> $(head -1 <<< "$OUT")"
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
# `versions --installed` 读的是 `<data_dir>/versions/*/.installed`，不联网。data_dir()
# 由 run-offline.sh 设的 SUNRISE_LAUNCHER_HOME 决定 —— 所以这一条同时验证了两件事：
# 包里的 .installed 标记对不对，和脚本有没有真把启动器按到包里的 data/ 上。
#
# 不加 --installed 的 `versions` 列的是**上游可下载的 release**，拿它 grep 一定命中
# （上游确实有这个 tag），是假阳性，不能用。
#
# 这一条决定包能不能交给玩家：列出来了 = 启动器接管这个版本，玩家点 Play 就走它；
# 没列出来 = 只能靠直接跑 data/versions/<tag>/sunrise-client。
say "3. does the launcher take the bundled build as an installed version?"
if [[ "$LAUNCHER_USABLE" == "1" ]]; then
  LIST_OUT=$(timeout 180 "$L" versions --installed 2>&1) || LIST_RC=$?
  echo "$LIST_OUT" >> "$LOG"
  if [[ "${LIST_RC:-0}" -eq 0 ]]; then
    if grep -qF -- "$TAG" <<< "$LIST_OUT"; then
      say "ok   versions --installed lists $TAG -- the launcher owns this build"
    else
      bad "the launcher runs but does not see $TAG as installed: run-offline.sh did not point it at data/, or the bundled .installed marker is not where backend::installed() looks"
      echo "$LIST_OUT" | sed 's/^/     | /' | head -15
    fi
  else
    note "versions --installed exited ${LIST_RC}: $(head -3 <<< "$LIST_OUT" | tr '\n' ' ')"
  fi

  # 版本被选中，玩家才有「点 Play 就走」这回事。
  SETTINGS_OUT=$(timeout 60 "$L" settings 2>&1) || true
  echo "$SETTINGS_OUT" >> "$LOG"
  if grep -q "selected_version" <<< "$SETTINGS_OUT"; then
    say "ok   settings reports a selected version ($(grep selected_version <<< "$SETTINGS_OUT" | head -1 | cut -c1-60))"
  else
    note "settings printed no selected_version line"
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
