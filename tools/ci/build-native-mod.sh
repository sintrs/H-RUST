#!/usr/bin/env bash
# 编 minimap 的 native mod，不需要桌面、不需要本机那 1.6 G 的 native/ 缓存。
#
# 不复刻 rustc 调用：走上游官方 launcher 的 `native-build` 子命令。上游 mod 仓库
# 自己的 .github/workflows/validate.yml（tools/horizon.py build）就是这么编的，
# 所以这里的产物与启动器在本机编出来的是同一条代码路径，不是"照抄参数"的仿制。
#
# 用法（仓库根目录执行）：
#   bash tools/ci/build-native-mod.sh [输出目录，默认 dist-native]
#
# 环境变量（默认值 = 本机现在跑着的那一版）：
#   MOD_REPO         Gurov08ruS/Minimap-Worldmap-and-waypoints-reworked
#   MOD_REF          v0.7.9   mod 的 [native] 已经 pin horizon=0a875da / mixins=e59da90
#   NIGHTLY_TAG      nightly-2026-11-20   install 用的 release tag
#   LAUNCHER_TAG     launcher@0.2.107     提供 native-build 的官方 AppImage
#   WORK             build/native-mod     下载、解包、临时家目录都在这
#   EXPECTED_SHA256  给了就比对 libminimap_*.so；默认不因此失败（STRICT=1 才失败）
#
# 产物（<输出目录>，顶层平铺，不套目录）：
#   libminimap_worldmap_waypoints_reworked.so   2.9 M  mod 本体
#   libhorizon_patch.so                         5.2 M  打了 mixins 的游戏补丁
#   native-mods.json                            清单，sha256 / identity 都是现算的
#   BUILD.txt                                   这一包对应的 pin 与校验和
# 以及同名 .tar.gz。放进已有的 native-<commit>-<hash>/ 即可替换，无需重编。
set -euo pipefail

MOD_REPO=${MOD_REPO:-Gurov08ruS/Minimap-Worldmap-and-waypoints-reworked}
MOD_REF=${MOD_REF:-v0.7.9}
NIGHTLY_TAG=${NIGHTLY_TAG:-nightly-2026-11-20}
LAUNCHER_TAG=${LAUNCHER_TAG:-launcher@0.2.107}
WORK=${WORK:-build/native-mod}
EXPECTED_SHA256=${EXPECTED_SHA256:-}
STRICT=${STRICT:-0}

OUT=${1:-dist-native}
mkdir -p "$WORK" "$OUT"
WORK=$(cd "$WORK" && pwd)
OUT=$(cd "$OUT" && pwd)

step() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

step "1/8 官方 launcher（native-build 在它里面）"
APP=$WORK/launcher/horizon-launcher-linux-x86_64.AppImage
if [ ! -s "$APP" ]; then
  mkdir -p "$WORK/launcher"
  curl -fsSL --retry 3 -o "$APP" \
    "https://github.com/horizon-rust/horizon/releases/download/${LAUNCHER_TAG}/horizon-launcher-linux-x86_64.AppImage"
  chmod +x "$APP"
fi
if [ ! -x "$WORK/launcher/squashfs-root/usr/bin/horizon-launcher" ]; then
  ( cd "$WORK/launcher" && "$APP" --appimage-extract >/dev/null )
fi
L=$WORK/launcher/squashfs-root/usr/bin/horizon-launcher
"$L" --version 2>/dev/null || true

step "2/8 mod 源（${MOD_REPO}@${MOD_REF}）"
MODDIR=$WORK/mod
if [ ! -f "$MODDIR/horizon-mod.toml" ]; then
  rm -rf "$MODDIR"; mkdir -p "$MODDIR"
  curl -fsSL --retry 3 -o "$WORK/mod.tar.gz" \
    "https://codeload.github.com/${MOD_REPO}/tar.gz/refs/tags/${MOD_REF}"
  # --touch：不还原 tarball 里的 mtime，省掉一批 "无法 utime"（无权设备上会因此退出 2）。
  tar -xzf "$WORK/mod.tar.gz" -C "$MODDIR" --strip-components=1 --no-same-owner --touch || \
    [ -f "$MODDIR/horizon-mod.toml" ] || die "解包 mod 源失败"
fi
[ -f "$MODDIR/horizon-mod.toml" ] || die "mod 源不完整：$MODDIR"

step "3/8 读 pin（commit / mixins / 版本名）"
read -r COMMIT MIXINS NIGHTLY_VERSION MOD_VERSION <<EOF
$(python3 - "$MODDIR" <<'PY'
import json, sys, tomllib
root = sys.argv[1]
compat = json.load(open(f'{root}/compatibility.json'))
manifest = tomllib.load(open(f'{root}/horizon-mod.toml', 'rb'))
native = manifest['native']
if (native['horizon'], native['mixins']) != (compat['horizon_revision'], compat['horizon_mixins_revision']):
    raise SystemExit('horizon-mod.toml 与 compatibility.json 的 pin 不一致')
print(compat['horizon_revision'], compat['horizon_mixins_revision'],
      compat['nightly_version'], manifest['version'])
PY
)
EOF
SHORT=${COMMIT:0:7}
# tomllib 要 python 3.11+；Ubuntu 22.04 自带的 3.10 没有它，workflow 里用 setup-python 指定 3.12。
[ -n "$COMMIT" ] && [ -n "$SHORT" ] || die "读不到 pin（python3 需要 3.11+，tomllib）"
printf '  commit   %s\n  mixins   %s\n  版本      %s\n  mod      %s\n' \
  "$COMMIT" "$MIXINS" "$NIGHTLY_VERSION" "$MOD_VERSION"

step "4/8 装 pinned nightly（隔离家目录，不碰已有的）"
export HORIZON_LAUNCHER_HOME=$WORK/home-launcher
export HORIZON_HOME=$WORK/home-game
mkdir -p "$HORIZON_LAUNCHER_HOME" "$HORIZON_HOME"
INSTALLED=${NIGHTLY_VERSION}
if [ ! -d "$HORIZON_LAUNCHER_HOME/versions/$INSTALLED" ]; then
  "$L" install "$NIGHTLY_TAG"
fi
[ -d "$HORIZON_LAUNCHER_HOME/versions/$INSTALLED" ] || \
  die "装出来的版本不是 $INSTALLED：$(ls "$HORIZON_LAUNCHER_HOME/versions" 2>/dev/null | tr '\n' ' ')"
case "$INSTALLED" in
  *"$SHORT"*) ;;
  *) die "装到的 $INSTALLED 与 pin 的 $SHORT 不符" ;;
esac

step "5/8 建实例（native-build 挂在实例上）"
# 注意 `|| true`：instances/ 还不存在时 find 返回 1，set -e + pipefail 会整步退出。
INSTANCE=$(find "$HORIZON_HOME/instances" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | head -1 || true)
if [ -z "$INSTANCE" ]; then
  "$L" instance create 'Mod build' >/dev/null
  INSTANCE=$(find "$HORIZON_HOME/instances" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | head -1 || true)
fi
[ -n "$INSTANCE" ] || die "没建出实例：$HORIZON_HOME/instances"
echo "  实例 $INSTANCE"

step "6/8 生成扁平工程（mod 仓库自己的 package.py，不是我们猜的布局）"
( cd "$MODDIR" && python3 tools/package.py --project target/ci-project > "$WORK/package.json" )
PROJECT=$MODDIR/target/ci-project
[ -f "$PROJECT/src/lib.rs" ] || die "扁平工程没生成：$PROJECT"

step "7/8 编译（启动器自己的 Rust 与 SDK，profile=optimized）"
"$L" native-build "$PROJECT" \
  --instance "$INSTANCE" \
  --version "$INSTALLED" \
  --profile optimized \
  --trust-native-code 2>&1 | tee "$WORK/native-build.log" || die "native-build 失败，见上面的日志"

BUILT=$(ls -td "$HORIZON_LAUNCHER_HOME"/versions/native-* 2>/dev/null | head -1 || true)
[ -n "$BUILT" ] || die "没找到 native-* 产物目录"

step "8/8 收集与校验"
python3 - "$BUILT" "$OUT" "$COMMIT" "$MIXINS" "$SHORT" "$MOD_VERSION" \
  "$INSTALLED" "$MOD_REPO" "$MOD_REF" "$NIGHTLY_TAG" "$LAUNCHER_TAG" "$WORK" \
  "$EXPECTED_SHA256" "$STRICT" <<'PY'
import hashlib, json, pathlib, shutil, sys, time
built, out, commit, mixins, short, modver, version, repo, ref, nightly, launcher, work = sys.argv[1:13]
built, out = pathlib.Path(built), pathlib.Path(out)
record = json.loads((built / 'native-mods.json').read_text())

problems = []
if record.get('horizon') != commit:
    problems.append(f"native-mods.json horizon={record.get('horizon')} != {commit}")
if record.get('horizon_mixins') != mixins:
    problems.append(f"horizon_mixins={record.get('horizon_mixins')} != {mixins}")

lines = [f"built by launcher {launcher} on {time.strftime('%Y-%m-%d %H:%M:%S %Z')}",
         f"mod        {repo}@{ref} ({record['mods'][0]['version'] if record.get('mods') else modver})",
         f"horizon    {commit}", f"mixins     {mixins}",
         f"nightly    {version}", f"base       {record.get('base')}",
         f"rust       {record.get('rust')}  route={record.get('route')}  secs={record.get('secs')}", ""]
for lib in record['libraries']:
    src = built / lib['file']
    if not src.is_file():
        problems.append(f"清单里的 {lib['file']} 不在产物目录")
        continue
    digest = hashlib.sha256(src.read_bytes()).hexdigest()
    if digest != lib['sha256']:
        problems.append(f"{lib['file']} sha256 与清单不符：{digest}")
    if not lib.get('identity', '').startswith(commit):
        problems.append(f"{lib['file']} identity 不是这个 commit：{lib.get('identity')}")
    shutil.copy2(src, out / lib['file'])
    lines.append(f"{lib['kind']:6s} {lib['file']:44s} {digest}")
    print(f"  {lib['kind']:6s} {lib['file']:44s} {src.stat().st_size / 1e6:6.1f} MB  {digest[:12]}")
shutil.copy2(built / 'native-mods.json', out / 'native-mods.json')

# 与已知可用的那一版比对（informational；STRICT=1 才算失败）
expected, strict = sys.argv[13], sys.argv[14] == '1'
mod = next((l for l in record['libraries'] if l['kind'] == 'mod'), None)
if expected and mod:
    same = mod['sha256'] == expected
    lines.append(f"expected {expected}  match={same}")
    print(('  相符 ' if same else '  不一致 ') + f"本机旧产物 {expected[:12]} vs 这次 {mod['sha256'][:12]}")
    if not same and strict:
        problems.append("sha256 与本机那一版不一致（STRICT=1）")

(out / 'BUILD.txt').write_text('\n'.join(lines) + '\n')
if problems:
    print('\n'.join('!! ' + p for p in problems), file=sys.stderr)
    sys.exit(1)
PY

# 上面 python 的 EXPECTED_SHA256 / STRICT 来自环境变量，随参数传入
TARBALL=$OUT/horizon-native-mod-${MOD_VERSION}-${SHORT}.tar.gz
tar -czf "$TARBALL" -C "$OUT" $(cd "$OUT" && ls lib*.so native-mods.json BUILD.txt)
( cd "$OUT" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )

printf '\n完成：%s（%.1f MB）\n' "$TARBALL" "$(stat -c %s "$TARBALL" | awk '{print $1/1e6}')"
