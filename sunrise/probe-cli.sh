#!/usr/bin/env bash
# 打印 Sunrise 启动器 / 本体的命令行形状，供上面那条链对账。
#
# 这条试验链的每一个假设都建立在「启动器认什么」上，而启动器是 GUI 程序，在很多环境里
# 起不来。这个脚本只碰那些能拿到输出的入口（--version / --help / list / 本体的
# --launch-api），起不来就如实说，不猜。
#
# 用法:
#   bash sunrise/probe-cli.sh <解开后的包目录>
set -uo pipefail

PKG=${1:?用法: probe-cli.sh <解开后的包目录>}
[[ -d "$PKG" ]] || { echo "错误：不是目录 $PKG" >&2; exit 1; }

BASE=$(mktemp -d "${TMPDIR:-/var/tmp}/sun-cli.XXXXXX")
trap 'rm -rf "$BASE" 2>/dev/null || true' EXIT
export HOME="$BASE/home"
export XDG_DATA_HOME="$HOME/.local/share" XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state"
export XDG_RUNTIME_DIR="$BASE/run"
export SUNRISE_HOME="$BASE/sunrise-home" SUNRISE_LAUNCHER_HOME="$BASE/launcher-home"
export HORIZON_LAUNCHER_HOME="$BASE/horizon-home"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" \
         "$XDG_RUNTIME_DIR" "$SUNRISE_HOME" "$SUNRISE_LAUNCHER_HOME" "$HORIZON_LAUNCHER_HOME"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

section() { echo; echo "=== $* ==="; }

L="$PKG/sunrise-launcher"
if [[ -x "$L" ]]; then
  section "launcher --version"
  timeout 60 "$L" --version 2>&1 | head -5 || echo "(exit $?)"
  section "launcher --help"
  timeout 60 "$L" --help 2>&1 | head -40 || echo "(exit $?)"
  section "launcher list"
  timeout 90 "$L" list 2>&1 | head -20 || echo "(exit $?)"
else
  echo "no sunrise-launcher in $PKG"
fi

CLIENT=$(find "$PKG" -maxdepth 4 -type f -name 'sunrise-client' | head -1)
if [[ -n "$CLIENT" ]]; then
  section "client --launch-api (options only)"
  timeout 120 "$CLIENT" --launch-api 2>&1 \
    | python3 -c '
import json, sys
text = sys.stdin.read()
start = text.find("{")
while start != -1:
    try:
        data, _ = json.JSONDecoder().raw_decode(text[start:])
        break
    except ValueError:
        start = text.find("{", start + 1)
else:
    sys.exit("no JSON object in --launch-api output")
print("launch_api:", data.get("launch_api"))
print("minecraft: ", data.get("minecraft"))
print("sunrise:   ", data.get("sunrise"))
print("options:")
for entry in data.get("options") or []:
    name = entry.get("name") if isinstance(entry, dict) else entry
    print("  ", name)
' || echo "(client did not report)"
else
  echo "no sunrise-client in $PKG"
fi
