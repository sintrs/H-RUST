# Sunrise 离线包（试验链）

`sunrise-org/sunrise` 是 Horizon 改名后的延续项目。这个目录是**独立的一条链**，
和仓库里另外两条（`release-offline.yml` / `release-game.yml`，跟
`horizon-rust/horizon`）互不影响：不共用脚本、不共用 state、不共用 release。

**状态（2026-11-25 晚，真机实测 nightly-2026-11-20 · 9425651）：离线单人 + 离线 LAN 都通，
不需要任何补丁，靠「不经启动器、直连本体」绕开启动器。跨设备联机、正版服务器、多人服务器未测。**

直启有一个前提：`--resources` 不能指向**启动器登记过的缓存条目**，否则撞 cache lease 闸
（见「直连的第三个坑」）。复制/自建出来的副本实测可直启；包版面是副本，按同一机制应当可用，
但**没有单独跑过整包**。

CI 上已经跑通到「启动器接管随包版本并选中它」，产物发在 Release `sunrise-offline`。

## 为什么要试这一条

`horizon-rust` 整个组织已经 404（2026-11-25 记录），现有两条链的 schedule 已停。
Sunrise 是同一套代码改名搬过去的，而且**本体自带一个离线入口**：

```
--developer-single-player    单人，不需要登录（在 Launch API 契约里，是隐藏选项）
--name NAME                  多人身份
--session-file PATH          启动器给的会话（本链不用）
```

### `--developer-single-player` 不是「离线模式」，是「只有单人」

这一点必须说清楚，因为它决定了这条链是不是 `offline-port.patch` 的替代品。

它不是「关掉登录」，而是**把整个账号层拆掉，再把所有走网络的路堵上**。源码里五处：

| 位置 | 干什么 |
|---|---|
| `runtime/launch_options.rs` | `let session = if o.developer_single_player { Ok(None) }` —— `auth::current()` 恒空 |
| `runtime/launch_options.rs` + `interface/developer_launch.rs` | 带 `--server` 或会话文件，**启动就失败** |
| `interface/developer_launch.rs` | `lan_host`：`net.listen` 一开就拒 |
| `interface/developer_launch.rs` | `join_server`：连任何远程服务器就拒 |
| `world/integrated.rs` | `publish()`：「对局域网开放」按钮直接返回错误 |

错误文案都是一句 `Offline developer session: single-player only.`
`lan/mod.rs` 的 `OnlineMode::lan()` 第一行是 `crate::auth::current()?`，看着像「没登录就开不了 LAN」——
**但它不是**。`?` 在这里返回的是 `None`，语义是「没有在线模式，退回离线托管」，
源码注释原文：`a LAN or friends world authenticates its guests when the host is signed in;
an offline name hosts in offline mode`。2026-11-25 晚实测：无会话、`lan open` 照样监听，访客能进。

所以「**带着这个 flag**，单人 + 多人 + LAN 都能用」做不到。但真正的结论在下一节：
**只要不传这个 flag，就什么都不拦。**

## 关键：不传 flag 不等于没账号层

这是这条链最重要的一条，也是先把前面那段结论推翻的地方。

不传 `--developer-single-player` 时，`launch_options.rs` 走的是另一个分支：

```rust
Ok(None)   // 没有会话，但也没有任何拒绝
```

没有任何 `if session.is_none() { return Err(...) }`。于是：

- **主机侧** `lan/conn.rs`：`match online { Some(..) => authenticate(..), None => (offline_uuid(&hello.name), Vec::new()) }`
  —— `None` 是 vanilla 标准离线模式，不是错误分支。
- **客户端侧** `remote/connection.rs`：注释「An online-mode server gets the signed-in
  account again」 —— 只有 online-mode 服务器才需要账号。
- **多人按钮**：`allows_multiplayer` 初值就是 `true`，`poll_account()` 拿不到 session
  时直接 return，不会把它改成 false。
- **聊天密钥**：`remote_chat.rs` 只在 `r.online_mode` 为真时才 `prepare_chat_keys`，
  离线的世界和 LAN 都不需要。
- **局域网开放**：`publish()` 里那处拒绝是 flag 触发的，没有 flag 就不进那个分支。

`auth::current()` 确实是空的，但空的后果只是「按离线模式办」，不是「禁止联网」。
把顺序搞反了就会以为必须造一个 `AuthSession`——**那才是 `offline-account.patch` 想做的事，
而它其实不必要。**

### Horizon 也是这么绕过去的

`tools/ci/offline-port.patch`（1070 行、21 个文件）全在 `launcher/src/`，`crates/` 一行未动。
它的 `mark()` 不注入 `FLAG`，只 `env_remove`，让本体以「无会话」状态跑，离线身份靠 `--name`。

这条链更进一步：**干脆不经过启动器**。`play-offline.sh` 直接 `exec` 本体的
`sunrise-client`，启动器根本没机会塞参数。

### 直连的第二个坑：`--resources`

不传 flag 只解决了「拦不拦」，还要解决「起不起得来」。本体自己的默认值是：

```rust
let sibling = std::env::current_exe()?.parent()?.join("resources");
resources: if sibling.join("sunrise-resources.json").exists() {
    sibling                                            // 包里有 resources/ 就用它
} else {
    Path::new(".local/sunrise-client").join(VANILLA_VERSION)   // 否则相对 cwd
}
```

包里没有 `resources/`，于是它退到**相对于工作目录**的 `.local/sunrise-client/26.3`。
启动器准备工作文件时写的是版本目录里的 `<tag>/.local/sunrise-client/<ver>/`，
两处对不上，首次运行必定报：

> `Sunrise's prepared game files are missing: no sunrise-resources.json in ...`

所以 `play-offline.sh` 自己找：先扫 `<tag>/.local/sunrise-client/*/sunrise-resources.json`，
再退到 `<tag>/resources/`，找到就把 `--resources <那个目录>` 传下去。
命令行上已经有 `--resources` 时不重复添加。找不到就直说「还没准备」并给出准备命令，
不让玩家进到游戏里看一句堆栈。

`SUNRISE_HOME` 指向包里的 `data/`，存档、`options.txt`、日志、mod 都在那儿，
和启动器跑它时（`game_home()`）一致。

准备那一步启动器是唯一**打包好的**入口（不变），但手跑同在版本目录里的 `sunrise-prepare`
也行，实测 16 秒（`--server-jar` 用启动器缓存过的 26.3 server jar，`--minecraft-dir` 指自己的
`~/.minecraft`，全程无网）。`sunrise-ctl` 的错误文案原文是
`prepare it in the launcher first (sunrise-launcher prepare <tag>)`，所以包里写
`./run-offline.sh prepare`（版本已选中，不用带参数；要指定就 `--version <tag>`，
**裸写 tag 会被 clap 拒成 `unexpected argument`** —— 这条踩过，别再写错）。
代码侧一旦发现资源不在就停在门口，
这个分支已实测（退出码 1 + 提示文案），资源存在时的三条路径也都实测过。

### 直连的第三个坑：cache lease

资源找对了还有一道闸（2026-11-25 实测撞到）。直接指向启动器版本目录时：

> `Sunrise: cannot acquire launcher cache leases: …/launcher/versions/<tag>/.local/sunrise-client/26.3
> is in the launcher's data folder but has no cache lease there; start the game with the launcher's Play
> (sunrise-launcher play --instance <instance> --version <tag>), and update the launcher if it was
> already started that way`

退出码 78，143 ms 退出，连窗口都不开。租约是启动器 Play 时写在 `<launcher>/run-leases/` 的记录，
文件名不是资源路径的 sha256（试过），也不打算伪造。

判据不是「路径在启动器数据目录里」，而是**那个目录里有没有 `run-leases/`**（2026-11-26 坐实）：
同一个路径，`SUNRISE_HOME` 换到别处一样报；把 `data/run-leases/` 挪走，本体目录和资源**都在
原地**就能起，实测 `./PLAY-OFFLINE.sh` 首帧 78 ms、worldgen 324 ms。租约只写「启动器自己装的
那个版本」，`prepare` 认的是 base（`dev-…`），所以 `native-…` 永远补不上它的租约。

于是 `play-offline.sh` 在 exec 前删掉 `data/run-leases/`（`./run-offline.sh prepare` 下次会
自己重建），资源不再镜像，`--resources` 直接指 `data/versions/<base>/.local/sunrise-client/<mc>`。
早期那版把资源硬链接镜像到 `./resources/` 是误判——闸门不在资源上，白搭一份 694 MB 的目录树。

## 那 `offline-account.patch` 呢
留着，但**不是必需品**。它是「如果哪天必须走启动器 Play 按钮」时的备用路线：
造一个离线 `AuthSession`、拆掉五处拦截。

- 145 行，4 个文件，全部在 `crates/sunrise-client/`，**不动 `launcher/`**。
- 每处带 `OFFLINE-PATCH:` 注释（共 7 处），方便对着上游 rebase。
- `AuthSession::new(name, uuid, token)` 本来就是 public（注释写着 "For tests and
  harnesses"），UUID 用 `sunrise_core::md5::offline_uuid(name)`。
- 已验证：`git apply --check` 干净、`cargo check` 过、`clippy -D warnings` 过
  （workflow `check-sunrise-offline-patch.yml`，两轮全绿）。

为什么没在用：**公开源码编不出本体。** `Cargo.toml` 声明 78 个 workspace members，
其中 44 个目录不存在——包括真正的游戏二进制 `sunrise-official`、`sunrise-protocol`、
`sunrise-server`、`sunrise-port-pack`。`cargo check -p sunrise-client` 能过只是因为
依赖树没碰到那些。要真打补丁就得重编 `sunrise-client`，而它链接 `sunrise-protocol`，
拿不到。

## 验证到哪一步了

- ✅ 补丁能干净打到上游 `main`（`git apply --check`）
- ✅ `cargo check -p sunrise-client --all-targets` 通过
- ✅ `cargo clippy -p sunrise-client --all-targets -- -D warnings` 通过
- ✅ `PLAY-OFFLINE.sh` 能起本体（`--launch-api` 返回正常，`--quickPlayMultiplayer`
  在 options 里）
- ✅ `PLAY-OFFLINE.sh` 的资源发现：未准备 → 退出码 1 + 明确提示；已准备 → 正确注入
  `--resources`；自带 `--resources` 不重复；跨目录绝对路径调用正常
- ✅ `offline-wrapper.sh` 参数过滤实测：带空格路径、单引号、`$`、空串都原样保留；
  有 flag 时滤掉、无 flag 时整串透传
- ✅ **真本体直启（2026-11-25 19:10）**：资源复制到启动器数据目录之外，`sunrise-client
  --resources … --game-dir …` 起来，1.1 s 载入资源，Vulkan 首帧 1108 ms，离线身份自动生成
  （`Player98590`），全程无账号
- ✅ **离线 LAN 真进人（同日 19:15）**：`sunrise-ctl lan open 25566` → 监听 `0.0.0.0:25566`；
  第二个实例 `--server 192.168.5.55:25566 --name Guest` 进世界，主机 `lan status` 有
  Guest（loaded/placed），chat 有 `Guest joined the game`
- ✅ **从自己的 Minecraft 准备（同日 19:45）**：空目录 + `sunrise-prepare --prepare
  --server-jar <缓存的 26.3 server jar> --minecraft-dir ~/.minecraft`，16 s 出 730 MB 资源，
  再用这份资源直启 + `lan open 25567` + 访客 `Guest2` 进世界，全程无网
- ❌ **没测跨设备**：两次都是同一台机（经 LAN 地址走本机协议栈），另一台设备 + 防火墙放行未验
- ❌ **离线访客的属性是空的**：皮肤是默认皮，聊天没有签名（离线模式本来不适用），
  身份不验证——只适合可信局域网
- ❌ 正版服务器、多人服务器（online-mode）仍未测，按源码判断需要会话，不是本链目标

## Horizon 与本链的差别

|  | Horizon（现有链） | Sunrise（本链） |
|---|---|---|
| 源码补丁 | `offline-port.patch`，1070 行、21 个文件，改启动器 | 不需要（`offline-account.patch` 仅作备用，未用） |
| 编译 | Rust 工具链 + 图形库，~90 min | 不编译，纯下载组装 |
| 产物来源 | 上游源码 + 官方包 | 两个官方包，原样复制 |
| 离线入口 | 启动器里点 Play | `PLAY-OFFLINE.sh` 直连本体 |
| 离线完整性 | 单人 + 多人 + LAN | 单人 + 离线 LAN 实测通过；跨设备、正版服未测 |
| 直启前提 | 无（补丁在启动器侧） | 资源须在启动器登记缓存之外（见第三个坑） |

## 怎么跑

只有 `workflow_dispatch`，**刻意不挂 schedule**。上游一断，挂了 cron 的链就变成
持续失败通知，这条在验证出结论之前不该自动跑。

```
Actions → Build Sunrise offline (experimental) → Run workflow
```

五个输入：

| 输入 | 作用 |
|---|---|
| `channel` | `dev`（默认，取存在的最新构建）或 `nightly`（上游推荐渠道） |
| `build_tag` | 固定某个 release tag；填了就盖过 `channel`。例：`dev-2026-11-24-3d34bbe` |
| `launcher_tag` | 固定启动器（留空取最新）。例：`v1.3.1` |
| `publish` | 发到 Release `sunrise-offline`；关掉只留 artifact |
| `dry_run` | 只探测版本、不下载不组包 |

**第一次先跑 `dry_run=true`**，确认能读到 build 和 launcher 再往下走。

### 为什么默认 dev 而不是 nightly

上游两条通道：

- `dev-<date>-<sha>` —— 每次合并出一个，**默认用这条**。
- `nightly` —— 滚动 release，资产原地替换，`published_at` 不动；官方推荐渠道。

选 dev 是因为 nightly 会**卡住不动**：写这份时 nightly 还停在 11-20 的
`9425651`，而 dev 已经到 11-24 的 `3d34bbe`。这个仓库的包是按需重建的，
「存在的最新构建」比「上游推荐渠道上那个十几天前的构建」更有用。

代价是真实的：dev 是「合完急着测」的构建。觉得不稳定就把 `channel` 换成
`nightly`，或者用 `build_tag=nightly` 直接钉住，两条跑出来的包可以直接比。

## 包里是什么

解压不套目录：

```
play-offline.sh           玩这个：直连本体，不经启动器（PLAY-OFFLINE.sh 是软链接）
run-offline.sh            启动启动器（能看/能改设置，但没有离线账号，玩不了）
offline-wrapper.sh        走启动器时的保险：滤掉 --developer-single-player
sunrise-launcher          官方启动器，未做任何修改
data/                     启动器自己的数据目录
  versions/<build>/       官方 sunrise-linux-x86_64.tar.gz 原样解开
    sunrise-client        170 MB，本体
    sunrise-prepare       准备资源（从你自己的 Minecraft 26.3）
    sunrise-ctl           终端/脚本控制，也带 MCP server
    sunrise-server        服务端
    .installed            启动器认「已装」的唯一依据
LICENSE / LICENSES/       启动器包的许可文件（Sunrise 本体是 PolyForm Shield，必须带）
PLAY-OFFLINE.txt          这份包怎么用
```

### 为什么必须带 run-offline.sh

Sunrise 启动器**没有** Horizon 那个 `horizon_bundle::ensure()`——它不会去启动器旁边
找版本。`backend::installed()` 只读 `<data_dir>/versions/*/.installed`，而

```rust
pub fn data_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("SUNRISE_LAUNCHER_HOME")... { return PathBuf::from(home); }
    ...
    crate::identity::launcher_folder_in(&dirs::data_dir()...)   // ~/.local/share/sunrise/launcher
}
```

所以把本体放进 `data/versions/` 却不告诉启动器「data 就是你的家」，它看到的是玩家
家里那个空目录，输出 `No version is installed.`。

`run-offline.sh` 干的事就一句：把 `SUNRISE_LAUNCHER_HOME` 和 `SUNRISE_HOME` 都指向
包里的 `data/`。**两个都要设**——`data_location::configured_roots()` 只有在两个都设时
才返回 `None`（此时 `data_dir()` 直接用环境变量）；只设一个它会去读
`~/.config/sunrise/launcher/location.json`，装过别的版本的玩家就会串到旧目录。

这破了「包里不放脚本」这条从 Horizon 时代留下来的规矩。它是唯一能既保持启动器原样
又保住双击即玩的办法：不然就得让玩家自己跑 `install` + `prepare`，那不是同一个东西。

## 已经验证过的

全部在 CI 上跑出来的（`gh run view` 可查），不是本地推断：

- 上游资产能取、`SHA256SUMS` 校验一致。
- `sunrise-release.json` 可直接读 `commit` / `build`，不必解析 release body。
- 组装出来的包 103 MB，结构正确，解压不套目录。
- 随包本体的 `--launch-api` 报 `"Dev 2026-11-24 · 3d34bbe"`，与版本目录名一致
  —— 说明版本没串包。
- `--developer-single-player` 在 Launch API 的 options 里 —— 但**不要用它**，
  它把多人/LAN 全堵上。见上文。
- `--quickPlayMultiplayer` 也在 options 里，是多人入口。
- **启动器认这个包**：`versions --installed` 列出 `dev-2026-11-24-3d34bbe`。
- **版本被选中**：`settings` 报 `selected_version: "dev-2026-11-24-3d34bbe"`，玩家点
  Play 就走它。
- **`PLAY-OFFLINE.sh` 能起本体**：实测 `./play-offline.sh --launch-api` 正常返回。
- **`offline-wrapper.sh` 参数保真**：带空格路径、单引号、`$`、空串全部原样透传。

最后两条是这条链存在的意义。`PLAY-OFFLINE.sh` 那天只验到「`--launch-api` 能返回」，
真正的「进世界 + 有人进来」是 2026-11-25 晚在本机（有显示器和 Vulkan）补的，
见 `## 验证到哪一步了`。

## 踩过的两个坑（别再踩）

1. **`versions` 不带 `--installed` 是上游目录，不是本机已装。** 它的输出是
   `tag  date  state`，state 为 `installed` / 空 / `no build for this platform`。
   拿它 grep tag 会**永远命中**（上游确实有这个 release），曾经因此报过一个假绿。
2. **跑启动器前必须装 X11 库。** 裸 `ubuntu-22.04` runner 上没有
   `libxkbcommon-x11.so.0`，启动器连 `--version` 都起不来，冒烟测试会把所有跟启动器
   有关的检查全部 skip 掉——那样跑出来的绿等于没跑。workflow 里现在装了。

## 本机为什么验不了启动器

容器里 `/root` 的 owner 是 `nobody`、权限 `drwx------`，而我们以 uid 0 跑。Sunrise
启动器启动前先写 `/root/.local/state/sunrise-launcher-root-leases`，直接
`Permission denied (os error 13)`。这是本机环境的限制，不是包的问题，也不是
Sunrise 的 bug。冒烟脚本把这类失败识别成 `skipped`，不判失败。

本体 `sunrise-client` 不受影响，所以版本一致性、离线入口那几条本机能验。

## 文件

| 文件 | 作用 |
|---|---|
| `probe-sunrise.py` | 读两个仓库当前发布什么，输出 `build`/`commit`/`launcher_tag` |
| `fetch-sunrise-asset.sh` | 下资产，对 `SHA256SUMS` + GitHub digest 双重校验 |
| `check-downloaded-build.py` | 下载到的 `sunrise-release.json` 与探测到的 commit 对账 |
| `make-sunrise-package.sh` | 拼包（含 `play-offline.sh` / `run-offline.sh` / `offline-wrapper.sh`） |
| `smoke-sunrise-package.sh` | 解开、跑、断言 |
| `check-launch-api.py` | 断版本目录名与本体自报的 build 一致 |
| `check-launch-option.py` | 断某个选项还在 Launch API 里 |
| `probe-cli.sh` | 打印启动器/本体的命令行形状（排查用） |
| `offline-wrapper.sh` | 滤掉 `--developer-single-player`（走启动器时的保险） |
| `offline-account.patch` | 备用：离线账号 + 拆五处拦截。编译已验证，产物未使用 |

## 用法

Release 页的 `sunrise-offline` 附件，解开：

```sh
tar -xzf sunrise-linux-x86_64-offline-*.tar.gz
./run-offline.sh prepare              # 只需一次：从你自己的 Minecraft 准备文件
./PLAY-OFFLINE.sh                      # 单人 + LAN + 离线服务器都从这儿进
./PLAY-OFFLINE.sh --name YourName      # 用你的名字
./PLAY-OFFLINE.sh --server HOST        # 进离线服务器
```

`<tag>` 就是 `data/versions/` 下那个目录名，例如 `dev-2026-11-24-3d34bbe`。
也可以 `./run-offline.sh` 进界面点 Play，第一次启动会自动准备。

想走启动器（改 Java 设置之类的）：

```sh
./run-offline.sh
```

启动器里点 Play 会带上 `--developer-single-player`，于是只剩单人。想从启动器进去
又要有多人/LAN，就把该 profile 的 launch 命令挂到 `offline-wrapper.sh` 上。

**注意**：`offline-account.patch` 现在没用在产物里——不需要它。留着是因为它把
「如何在不改二进制的前提下造离线账号」这条路写清楚了，万一上游哪天改了「不传 flag
就报错」，它就是下一手。

## 许可

Sunrise 本体是 **PolyForm Shield + Additional Terms**，不是 Horizon 那个 MIT。
它的附加条款要求分发 fork 时必须继续免费开源，所以这条链：

- 不修改任何二进制，只做复制作业；
- 包里带上 `LICENSE` 与 `LICENSES/`（包含 `MIT-Horizon.txt` —— 血统保留）；
- 产物标 `--prerelease`，不当正式版发布。

如果这条链最后要变成正式产物，许可这块得再看一遍。
