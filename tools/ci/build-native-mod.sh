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
#   PIN_COMMIT       给了就把 mod 的 pin 改到这个上游 commit，再照它编
#                    （例：f1bb66f353cf67f2aa4665293fc75c8d91186fc7）
#   PIN_NIGHTLY      配合 PIN_COMMIT：该 commit 的安装版本名，同时作为 native 版本的 base
#                    （例：nightly-2026-11-22-f1bb66f）
#   INSTALL_TAG      装哪个 release tag；默认 NIGHTLY_TAG。比带日期的 tag 更新的构建
#                    只在滚动 tag `nightly` 里，会随时被顶掉
#   EXPECTED_SHA256  给了就报告与本机那版的字节差异（仅供参考，不作为失败条件：
#                   .so 里嵌了构建哈希目录名，换机器必然不同）
#
# 不需要 Minecraft、不需要 Java、不需要账号：native-build 要的“已准备”只是一个清单文件，
# 见第 5 步。编译只读 SDK 的 rmeta 与 mod 源码，818 MB 的游戏资源只供运行游戏用。
#
# 产物（<输出目录>，顶层平铺，不套目录）：
#   libminimap_worldmap_waypoints_reworked.so   2.9 M  mod 本体
#   libhorizon_patch.so                         5.2 M  打了 mixins 的游戏补丁
#   native-mods.json                            启动器自己写的清单（sha256 / identity）
#   BUILD.txt                                   这一包对应的 pin 与校验和
# 以及同名 .tar.gz。放进已有的 native-<commit>-<hash>/ 即可替换，无需重编。
set -euo pipefail

MOD_REPO=${MOD_REPO:-Gurov08ruS/Minimap-Worldmap-and-waypoints-reworked}
MOD_REF=${MOD_REF:-v0.7.9}
NIGHTLY_TAG=${NIGHTLY_TAG:-nightly-2026-11-20}
LAUNCHER_TAG=${LAUNCHER_TAG:-launcher@0.2.107}
WORK=${WORK:-build/native-mod}
EXPECTED_SHA256=${EXPECTED_SHA256:-}

OUT=${1:-dist-native}
mkdir -p "$WORK" "$OUT"
WORK=$(cd "$WORK" && pwd)
OUT=$(cd "$OUT" && pwd)

step() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

step "1/9 官方 launcher（native-build 在它里面）"
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

step "2/9 mod 源（${MOD_REPO}@${MOD_REF}）"
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

step "3/9 读 pin（commit / mixins / 版本名）"
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
ORIG_COMMIT=$COMMIT
SHORT=${COMMIT:0:7}
# tomllib 要 python 3.11+；Ubuntu 22.04 自带的 3.10 没有它，workflow 里用 setup-python 指定 3.12。
[ -n "$COMMIT" ] && [ -n "$SHORT" ] || die "读不到 pin（python3 需要 3.11+，tomllib）"
printf '  commit   %s\n  mixins   %s\n  版本      %s\n  mod      %s\n' \
  "$COMMIT" "$MIXINS" "$NIGHTLY_VERSION" "$MOD_VERSION"

# 换一个 nightly 编：mod 的 [native] 写死了 commit，native-build 遇到别的 revision 会直接
# 拒绝（"Made for other Horizon versions"）。这里就地改掉两份 pin，源码一行不动——上游
# 从 0a875da 到 f1bb66f 的 API surface 在 sdk.json 里一路标 additive（只加不删），所以老源码
# 能对着新 SDK 编。compatibility.json 的 source_sha256 是上游源文件哈希，只有 mod 自己的
# audit 用，启动器一个字节都不读，这里保持原值并在 BUILD.txt 里记一笔。
INSTALL_TAG=${INSTALL_TAG:-$NIGHTLY_TAG}
if [ -n "${PIN_COMMIT:-}" ] && [ "$PIN_COMMIT" != "$COMMIT" ]; then
  PIN_NIGHTLY=${PIN_NIGHTLY:-$NIGHTLY_VERSION}
  echo "  改 pin：$COMMIT → $PIN_COMMIT（$PIN_NIGHTLY）"
  python3 - "$MODDIR" "$PIN_COMMIT" "$MIXINS" "$PIN_NIGHTLY" <<'PY' || die "改 pin 失败"
import json, pathlib, re, sys
root, commit, mixins, nightly = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
toml = root / 'horizon-mod.toml'
text = toml.read_text()
block = text.split('\n[native]\n', 1)
if len(block) != 2:
    raise SystemExit('horizon-mod.toml 里没有 [native] 段')
body = block[1]
for key, value in (('horizon', commit), ('mixins', mixins)):
    body, count = re.subn(rf'(?m)^{key}\s*=\s*"[^"]*"', f'{key} = "{value}"', body, count=1)
    if not count:
        raise SystemExit(f'[native] 段里没有 {key}')
toml.write_text(block[0] + '\n[native]\n' + body)
compat = json.loads((root / 'compatibility.json').read_text())
compat['horizon_revision'] = commit
compat['horizon_mixins_revision'] = mixins
compat['nightly_version'] = nightly
(root / 'compatibility.json').write_text(json.dumps(compat, indent=2) + '\n')
print(f'  pin 已改为 {commit[:7]} / {mixins[:7]} / {nightly}')
PY
  COMMIT=$PIN_COMMIT
  SHORT=${COMMIT:0:7}
  NIGHTLY_VERSION=$PIN_NIGHTLY
fi
INSTALLED=$NIGHTLY_VERSION

step "4/9 装 pinned nightly（隔离家目录，不碰已有的）"
export HORIZON_LAUNCHER_HOME=$WORK/home-launcher
export HORIZON_HOME=$WORK/home-game
mkdir -p "$HORIZON_LAUNCHER_HOME" "$HORIZON_HOME"
if [ ! -d "$HORIZON_LAUNCHER_HOME/versions/$INSTALLED" ]; then
  # 带日期的 release tag 只能指到一个 commit（nightly-2026-11-22 是 2b77287）；
  # 比它更新的构建（f1bb66f）只在滚动 tag `nightly` 里，会随时被下一版顶掉。
  "$L" install "$INSTALL_TAG"
fi
[ -d "$HORIZON_LAUNCHER_HOME/versions/$INSTALLED" ] || \
  die "装出来的版本不是 $INSTALLED：$(ls "$HORIZON_LAUNCHER_HOME/versions" 2>/dev/null | tr '\n' ' ')"
case "$INSTALLED" in
  *"$SHORT"*) ;;
  *) die "装到的 $INSTALLED 与 pin 的 $SHORT 不符" ;;
esac

step "5/9 满足 prepared 前置条件（只要一个清单文件）"
# native-build 进 pipeline 第一件事是 backend::ready() -> check_prepared() -> prepared_at()，
# 而 prepared_at() 只做两件事：资源目录里有能解析的 horizon-resources.json，且顶层没有
# 0 字节的 .json。编译本身只读 SDK 的 rmeta 和 mod 源码，一个字都不读游戏资源——所以这里
# 写个空清单就够了，不必准备那 818 MB（省掉 Mojang jar 下载、Java 25 和几分钟反编译）。
VDIR=$HORIZON_LAUNCHER_HOME/versions/$INSTALLED
MC_VERSION=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['minecraft']['version'])" \
  "$VDIR/research-lock.json" 2>/dev/null || echo 26.3)
RES=$VDIR/.local/horizon-client/$MC_VERSION
mkdir -p "$RES"
printf '{}\n' > "$RES/horizon-resources.json"
echo "  $RES/horizon-resources.json（$(stat -c %s "$RES/horizon-resources.json") B，版本 $MC_VERSION 取自 research-lock.json）"

step "6/9 建实例（native-build 挂在实例上）"
# 注意 `|| true`：instances/ 还不存在时 find 返回 1，set -e + pipefail 会整步退出。
INSTANCE=$(find "$HORIZON_HOME/instances" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | head -1 || true)
if [ -z "$INSTANCE" ]; then
  "$L" instance create 'Mod build' >/dev/null
  INSTANCE=$(find "$HORIZON_HOME/instances" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | head -1 || true)
fi
[ -n "$INSTANCE" ] || die "没建出实例：$HORIZON_HOME/instances"
echo "  实例 $INSTANCE"

step "7/9 生成扁平工程（mod 仓库自己的 package.py，不是我们猜的布局）"
( cd "$MODDIR" && python3 tools/package.py --project target/ci-project > "$WORK/package.json" )
PROJECT=$MODDIR/target/ci-project
[ -f "$PROJECT/src/lib.rs" ] || die "扁平工程没生成：$PROJECT"

step "8/9 编译（启动器自己的 Rust 与 SDK，profile=optimized）"
"$L" native-build "$PROJECT" \
  --instance "$INSTANCE" \
  --version "$INSTALLED" \
  --profile optimized \
  --trust-native-code 2>&1 | tee "$WORK/native-build.log" || die "native-build 失败，见上面的日志"

BUILT=$(ls -td "$HORIZON_LAUNCHER_HOME"/versions/native-* 2>/dev/null | head -1 || true)
[ -n "$BUILT" ] || die "没找到 native-* 产物目录"

step "9/9 收集与校验"
python3 - "$BUILT" "$OUT" "$COMMIT" "$MIXINS" "$SHORT" "$MOD_VERSION" \
  "$INSTALLED" "$MOD_REPO" "$MOD_REF" "$NIGHTLY_TAG" "$LAUNCHER_TAG" "$WORK" \
  "$EXPECTED_SHA256" "${PIN_COMMIT:-}" "$ORIG_COMMIT" "${INSTALL_TAG:-$NIGHTLY_TAG}" <<'PY'
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
repin, original, install_tag = sys.argv[14], sys.argv[15], sys.argv[16]
if repin and repin != original:
    lines.append(f"repin      mod 的 pin 从 {original} 改到 {repin}")
    lines.append("           源码一行未动；compatibility.json 的 source_sha256 未重算"
                 "（启动器不读，只有 mod 自己的 audit 用）")
lines.append(f"installed  from release tag {install_tag}")

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

# 与本机那一版比对。注意**字节不会相同**：.so 里嵌了构建哈希目录名
# （native/prebuilt-build/rustc-<commit>-<hash>/），换台机器这个 hash 就变，
# 实测同一份源码本机编出来 3013560 B，隔离环境重编 3014088 B，identity 一致。
# 所以这里只报告，判合格靠上面那些 identity / 清单校验。
expected = sys.argv[13]
mod = next((l for l in record['libraries'] if l['kind'] == 'mod'), None)
if expected and mod:
    same = mod['sha256'] == expected
    lines.append(f"reference {expected}  byte-identical={same}")
    print('  与本机旧产物逐字节相同' if same
          else '  与本机旧产物字节不同（正常：.so 内嵌构建哈希目录名，identity 已校验一致）')

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
