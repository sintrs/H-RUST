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
#   PORT_PATCH       LOD 移植补丁，默认 tools/ci/native-mod-lod-surface.patch
#                    只有 target 版本的 lod.rs 已经是 span 压缩的 TileColumns 时才打
#
# 不需要 Minecraft、不需要 Java、不需要账号：native-build 要的“已准备”只是一个清单文件，
# 见第 5 步。编译只读 SDK 的 rmeta 与 mod 源码，818 MB 的游戏资源只供运行游戏用。
#
# 产物（<输出目录>）：
#   horizon-native-full-<modver>-<short>.tar.gz   完整 native 版本增量，解压后：
#     install-native-build.sh   本机组装脚本（复制 base → 覆盖 → touch .installed）
#     manifest.json             版本目录名、base、commit、每个文件的 sha256
#     BUILD.txt                 这一包对应的 pin 与校验和
#     payload/                  相对 base nightly 的全部增量（13 项 / 约 336 MB）：
#       libhorizon_patch.so / libminimap_*.so   8 MB，这次真正编出来的
#       libhorizon_*.so / libmod_*.so / libstd  328 MB，该 commit 的 SDK 引擎库
#       horizon-native-mods/<id>/               1 MB，mod 源码副本
#       native-mods.json                        启动器写的清单
# 本机不需要下载 SDK、不需要编译：解开跑 install-native-build.sh 就有可玩的版本目录。
# 不带 .local/（693 MB 资源缓存，首次启动会自己重建）。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

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

step "4b/9 LOD 移植（只对 tile 已改成 span 压缩的 target 生效）"
# 上游把 LOD 的 tile 从 Arc<Vec<Column>> 换成了 span 压缩的 pub(crate) TileColumns：
# 字段还在（ready 能列出），但 len/spans/surface 全是 crate 私有的，mod 碰不到，
# 于是 lod_adapter 里 columns.len() / columns.iter() / Arc<Vec<Column>> 三处全废。
# 移植走 SDK 自己留的口子 `Lod::surface(x, z)`（文档写的就是"a client mod's map past
# the loaded chunks"），按块列取样，不再借 tile 内部的列。
# 判据用上游那一版的 lod.rs：有 TileColumns 才需要，没有就一个字不动，所以对着旧
# nightly 编出来和以前完全一样。
PORT_PATCH=${PORT_PATCH:-$ROOT/tools/ci/native-mod-lod-surface.patch}
curl -fsSL --retry 3 -o "$WORK/lod-$SHORT.rs" \
  "https://raw.githubusercontent.com/horizon-rust/horizon/${COMMIT}/crates/horizon-client-render/src/lod.rs" || \
  die "取不到 $SHORT 的 lod.rs，无法判断要不要移植"
if grep -q 'struct TileColumns' "$WORK/lod-$SHORT.rs"; then
  if [ ! -f "$MODDIR/.lod-surface-port" ]; then
    ( cd "$MODDIR" && patch -p1 --batch --forward -i "$PORT_PATCH" ) || die "LOD 移植补丁打不上"
    : > "$MODDIR/.lod-surface-port"
  fi
  LOD_PORTED=1
  echo "  已移植：lod_adapter 改走 Lod::surface，去重键换成 sample 指针"
else
  LOD_PORTED=0
  echo "  $SHORT 的 tile 还是 Arc<Vec<Column>>，不需要移植"
fi

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

step "9/9 收集、校验、打包（完整 native 版本，不只是那 2 个 .so）"
# 以前只收 native-mods.json 里列的 2 个 .so（8 MB），本机还得自己下 SDK 补齐 330 MB
# 引擎库、再复制 1 GB 骨架才能玩。现在把 built 目录相对 base 的**全部增量**都收进来：
# 下下来解开跑 install-native-build.sh，复制 base、覆盖、touch .installed，就完事，
# 本机既不下载 SDK 也不编译。.local/ 是首次启动可重建的资源缓存（693 MB），不带。
PKG=$OUT/pkg
BASE_DIR=$HORIZON_LAUNCHER_HOME/versions/$INSTALLED
[ -d "$BASE_DIR" ] || die "找不到 base 目录 $BASE_DIR，无法算增量"
rm -rf "$PKG"
mkdir -p "$PKG/payload"

BASE_DIR="$BASE_DIR" LOD_PORTED="${LOD_PORTED:-0}" python3 - \
  "$BUILT" "$PKG" "$COMMIT" "$MIXINS" "$SHORT" "$MOD_VERSION" \
  "$INSTALLED" "$MOD_REPO" "$MOD_REF" "$NIGHTLY_TAG" "$LAUNCHER_TAG" "$WORK" \
  "$EXPECTED_SHA256" "${PIN_COMMIT:-}" "$ORIG_COMMIT" "${INSTALL_TAG:-$NIGHTLY_TAG}" <<'PY'
import hashlib, json, os, pathlib, shutil, sys, time
built, pkg, commit, mixins, short, modver, version, repo, ref, nightly, launcher, work = sys.argv[1:13]
built, pkg = pathlib.Path(built), pathlib.Path(pkg)
payload = pkg / 'payload'
base = pathlib.Path(os.environ['BASE_DIR'])
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
    shutil.copy2(src, payload / lib['file'])
    lines.append(f"{lib['kind']:6s} {lib['file']:44s} {digest}")
    print(f"  {lib['kind']:6s} {lib['file']:44s} {src.stat().st_size / 1e6:6.1f} MB  {digest[:12]}")
shutil.copy2(built / 'native-mods.json', payload / 'native-mods.json')

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

# 相对 base 的增量：9 个引擎 / 运行时 .so（330 MB，SDK 预先构建的，不是这次编的）、
# horizon-native-mods/<id>/ 源码副本，都在这。.local/ 是首次启动会自己重建的资源缓存
# （693 MB），.installed / .last-used 是本地标记，三者都不带。
#
# 判据是「base 没有 或 内容变了」，不能只比名字 —— native-build 会把 horizon-client
# 从 nightly 那份 166 MB 原版二进制换成 7.5 KB 的 horizon_native_game 入口（内嵌
# HOLDER_CAPABILITY，NEEDED $ORIGIN/libhorizon_mod_host.so，游戏本体在 mod_host.so 里）。
# 两边同名，只比名字就会漏掉这个替换：装出来跑的是没打补丁的原版，mod 静默不生效。
skip = {'.local', '.installed', '.last-used'}

def listing(root):
    """相对路径 → 字节数。目录递归，给一次快速判等用。"""
    out = {}
    for dirpath, _, filenames in os.walk(root):
        for f in filenames:
            p = pathlib.Path(dirpath) / f
            out[str(p.relative_to(root)).replace(os.sep, '/')] = p.stat().st_size
    return out

def same_file(a, b):
    if a.stat().st_size != b.stat().st_size:
        return False
    return hashlib.sha256(a.read_bytes()).digest() == hashlib.sha256(b.read_bytes()).digest()

base_names = set(os.listdir(base))
added, replaced = [], []
for name in sorted(set(os.listdir(built)) - skip):
    src, dst = built / name, base / name
    if name not in base_names:
        added.append(name)
    elif src.is_dir() != dst.is_dir():
        replaced.append(name)
    elif src.is_file():
        if not same_file(src, dst):
            replaced.append(name)
    else:
        mine, theirs = listing(src), listing(dst)
        if mine != theirs:
            replaced.append(name)
        else:
            # 清单（路径+大小）一致再逐个比内容，防止同大小不同内容
            for rel in mine:
                if not same_file(src / rel, dst / rel):
                    replaced.append(name)
                    break
extra = added + replaced
for name in extra:
    src = built / name
    if src.is_dir():
        shutil.copytree(src, payload / name, dirs_exist_ok=True)
    else:
        shutil.copy2(src, payload / name)
if replaced:
    print(f'  同名替换 {len(replaced)} 项：{", ".join(replaced)}')
    for name in replaced:
        a, b = base / name, built / name
        if a.is_file() and b.is_file():
            print(f'    {name:14s} {a.stat().st_size:>12,} → {b.stat().st_size:>10,} B')
        else:
            print(f'    {name:14s} 目录内容有变化')

# 逐文件清单：安装脚本按它校验覆盖结果，缺一个或哈希不符就报错。
entries = []
for path in sorted(payload.rglob('*')):
    if not path.is_file():
        continue
    entries.append({
        'name': str(path.relative_to(payload)).replace(os.sep, '/'),
        'size': path.stat().st_size,
        'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
    })
total = sum(e['size'] for e in entries)
print(f'  增量 {len(extra)} 项（新增 {len(added)}、同名替换 {len(replaced)}）'
      f' / {len(entries)} 个文件 / {total / 1e6:.0f} MB')

manifest = {
    'native_version': built.name,
    'base': version,
    'horizon': commit,
    'horizon_mixins': mixins,
    'rust': record.get('rust'),
    'profile': record.get('profile'),
    'mod': {
        'repo': repo,
        'ref': ref,
        'version': record['mods'][0]['version'] if record.get('mods') else modver,
    },
    'lod_port': os.environ.get('LOD_PORTED') == '1',
    'replaced': replaced,
    'built_by': f'launcher {launcher}',
    'built_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'payload': entries,
}
(pkg / 'manifest.json').write_text(json.dumps(manifest, indent=1) + '\n')
lines.append(f"payload    {len(entries)} 个文件 / {total / 1e6:.0f} MB"
             f"（含 SDK 的引擎 .so，不带 .local 资源缓存）")
if replaced:
    lines.append(f"replaced   {' '.join(replaced)}（与 base 同名但内容不同，已在 payload 里）")

(pkg / 'BUILD.txt').write_text('\n'.join(lines) + '\n')
if problems:
    print('\n'.join('!! ' + p for p in problems), file=sys.stderr)
    sys.exit(1)
PY

if [ "${LOD_PORTED:-0}" = 1 ]; then
  printf 'lod-port   lod_adapter 改走 Lod::surface（%s 的 tile 是 span 压缩的 TileColumns）\n' \
    "$SHORT" >> "$PKG/BUILD.txt"
fi

# 安装脚本随包发：本机解开就能组装，不用记 base 目录、目录名哈希、.installed 这些约定。
install -m 755 "$ROOT/tools/ci/install-native-build.sh" "$PKG/install-native-build.sh"

TARBALL=$OUT/horizon-native-full-${MOD_VERSION}-${SHORT}.tar.gz
tar -czf "$TARBALL" -C "$PKG" .
( cd "$OUT" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )

printf '\n完成：%s（%.1f MB）\n' "$TARBALL" "$(stat -c %s "$TARBALL" | awk '{print $1/1e6}')"
printf '用法：mkdir /tmp/nf && tar -xf %s -C /tmp/nf && bash /tmp/nf/install-native-build.sh\n' \
  "$(basename "$TARBALL")"

# 附：native 离线包（解压即用）
#
# 增量包要底座 + 脚本，玩家用不了。这里再组一个「解压 → 打开」的包：自编离线启动器
# + 整个 native 版本目录（$BUILT，含 loader、SDK 库、mod .so，不带可重建的 .local）。
# 启动器不在这里编（要 30+ 分钟），取滚动 Release 里那份：它带 offline 账号补丁，
# 只在启动器自身升级时才变。
if [ "${SKIP_OFFLINE_PKG:-0}" != 1 ]; then
  step "附：native 离线包（解压即用，不用脚本、不用底座）"
  REPO=${GITHUB_REPOSITORY:-sintrs/H-RUST}
  OFFLINE_TAG=${OFFLINE_TAG:-nightly-offline}
  SRC=$WORK/offline-src
  LBIN=$WORK/offline-lbin
  LAUNCHER_PKG=""
  mkdir -p "$SRC" "$LBIN"
  if command -v gh >/dev/null 2>&1 && gh release view "$OFFLINE_TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release download "$OFFLINE_TAG" --repo "$REPO" \
      --pattern 'horizon-linux-x86_64-offline-*.tar.gz' --dir "$SRC" --clobber >/dev/null 2>&1 || true
    LAUNCHER_PKG=$(ls "$SRC"/*.tar.gz 2>/dev/null | head -1 || true)
  fi
  if [ -n "${LAUNCHER_PKG:-}" ] && [ -s "$LAUNCHER_PKG" ]; then
    # 只抽那一个二进制；图标等资源仍从整包里取（make-offline-package.sh 会排除二进制与 data/）
    tar -xzf "$LAUNCHER_PKG" -C "$LBIN" ./horizon-launcher 2>/dev/null || \
      tar -xzf "$LAUNCHER_PKG" -C "$LBIN" horizon-launcher
    [ -x "$LBIN/horizon-launcher" ] || die "离线包里没有 horizon-launcher"
    cp -f "$LAUNCHER_PKG" "$WORK/launcher-assets.tar.gz"
    NATIVE_DIR=$BUILT bash "$ROOT/tools/ci/make-offline-package.sh" \
      "$WORK/launcher-assets.tar.gz" - "$COMMIT" "$OUT" \
      "$LBIN/horizon-launcher" "$(basename "$BUILT")"
    OFFLINE_TARBALL=$(ls -t "$OUT"/horizon-linux-x86_64-native-offline-*.tar.gz 2>/dev/null | head -1 || true)
    if [ -n "${OFFLINE_TARBALL:-}" ]; then
      ( cd "$OUT" && sha256sum "$(basename "$OFFLINE_TARBALL")" > "$(basename "$OFFLINE_TARBALL").sha256" )
      printf '\n离线包：%s（%.1f MB）\n解压后直接 ./horizon-launcher\n' \
        "$OFFLINE_TARBALL" "$(stat -c %s "$OFFLINE_TARBALL" | awk '{print $1/1e6}')"
    else
      echo "!! 离线包没有生成（make-offline-package.sh 未产出附件），增量包不受影响" >&2
    fi
  else
    echo "!! 取不到 $OFFLINE_TAG 的离线包，跳过 native 离线包；增量包已正常产出" >&2
  fi
fi
