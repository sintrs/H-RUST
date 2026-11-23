#!/usr/bin/env bash
# 把 CI 打出来的完整 native 包在本机组装成可玩的版本目录。
#
# 背景：native 版本目录 = 一个 nightly 的全套文件 + 该 commit 编出来的引擎 .so 与
# mod .so，共 1 GB 上下。CI 编的只是其中 8 MB（libhorizon_patch + libminimap），
# 剩下 330 MB 是 SDK 预先构建的引擎库。这个包把"相对 base nightly 的全部增量"
# 一起带下来了，所以本机既不用下 SDK 也不用编译。
#
# 用法：
#   bash install-native-build.sh [--force] [launcher 数据目录]
#
#   launcher 数据目录默认 $HORIZON_LAUNCHER_HOME，否则 ~/.local/share/horizon-launcher。
#   --force：目标版本目录已存在时，先改名成 .bak-<时间戳> 再重建（不删除任何东西）。
#
# 做的事只有四步：确认 base 在本地 → 复制 base 成新版本目录 → 覆盖包里的 payload
# → touch 一个 .installed。启动器见到 .installed 就认定该版本已构建，不会再下载
# SDK 或重新编译（launcher/src/native_mods.rs 里 `exists` 只检查这个文件）。
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi
ROOT=${1:-${HORIZON_LAUNCHER_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/horizon-launcher}}

step() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

step "1/4 读包里的清单"
[ -f "$HERE/manifest.json" ] || \
  die "缺 manifest.json。这个脚本要跟 horizon-native-full-*.tar.gz 一起解开才有用。"
eval "$(python3 - "$HERE/manifest.json" <<'PY'
import json, shlex, sys
m = json.load(open(sys.argv[1]))
for key, out in (('native_version', 'NATIVE'), ('base', 'BASE'), ('horizon', 'COMMIT')):
    print(f'{out}={shlex.quote(m[key])}')
PY
)"
[ -d "$HERE/payload" ] || die "缺 payload/ 目录，包不完整"
printf '  native  %s\n  base    %s\n  commit  %s\n  launcher 数据目录 %s\n' \
  "$NATIVE" "$BASE" "$COMMIT" "$ROOT"

step "2/4 确认 base nightly 在本地"
[ -d "$ROOT/versions" ] || die "$ROOT/versions 不存在，检查路径或先装并启动一次启动器"
[ -d "$ROOT/versions/$BASE" ] || die "本机没有 $BASE。
   先把它装上（GUI 版本页，或 horizon-launcher install nightly 后确认名字对得上），
   再回来跑本脚本。base 就是这套引擎 .so 与游戏本体对齐的那一版，不能拿别的凑。"

step "3/4 复制 base 并覆盖 payload"
DEST=$ROOT/versions/$NATIVE
if [ -e "$DEST" ]; then
  [ "$FORCE" = 1 ] || die "$DEST 已存在。
   它可能正被某个实例使用。确认没问题后加 --force 重跑：旧目录会改名成
   $(basename "$DEST").bak-<时间戳>，不会删除。"
  KEEP=$DEST.bak-$(date +%Y%m%d-%H%M%S)
  mv "$DEST" "$KEEP"
  echo "  旧目录已改名：$KEEP"
fi
echo "  复制 $(du -sh "$ROOT/versions/$BASE" | cut -f1) → $DEST"
# 不用裸 cp -a：-a 会尝试保留属主/时间戳，在容器或 root 沙箱里那两步必然失败，
# cp 返回非零，配合 set -e 会让脚本在复制到一半时静默中止（payload 根本没铺上）。
cp -a --no-preserve=ownership,timestamps "$ROOT/versions/$BASE" "$DEST"
cp -a --no-preserve=ownership,timestamps "$HERE/payload/." "$DEST/"
: > "$DEST/.installed"

step "4/4 校验"
python3 - "$DEST" "$HERE/manifest.json" <<'PY'
import hashlib, json, pathlib, sys
dest, manifest = pathlib.Path(sys.argv[1]), json.load(open(sys.argv[2]))
bad = []
for entry in manifest['payload']:
    path = dest / entry['name']
    if path.is_dir():
        continue
    if not path.is_file():
        bad.append(f"缺 {entry['name']}")
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != entry['sha256']:
        bad.append(f"{entry['name']} sha256 不符：{digest[:12]} != {entry['sha256'][:12]}")
if bad:
    print('\n'.join('!! ' + b for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"  {len(manifest['payload'])} 项，sha256 全部对上")
PY

printf '\n组装完成：%s\n' "$DEST"
printf '\n切换实例到这个版本（GUI 的版本页里选同名项也一样）：\n'
printf '  horizon-launcher instance version <实例名> %s\n' "$NATIVE"
printf '\n想切回去，把实例指回原来的版本名即可；本脚本没有改动任何已有版本。\n'
