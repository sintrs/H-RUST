# Sunrise 离线包（试验链）

`sunrise-org/sunrise` 是 Horizon 改名后的延续项目。这个目录是**独立的一条链**，
和仓库里另外两条（`release-offline.yml` / `release-game.yml`，跟
`horizon-rust/horizon`）互不影响：不共用脚本、不共用 state、不共用 release。

**状态：单人可用，多人/LAN 需要补丁（`offline-account.patch`，已能编译，未实机验证）。**
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
连锁反应更麻烦：`lan/mod.rs` 的 `OnlineMode::lan()` 第一行是
`crate::auth::current()?`，**没登录就生成不出 LAN 密钥对**。

所以「单人 + 多人 + LAN 都能用」这个目标，Sunrise 原样**做不到**。和 Horizon 当年
必须打 `offline-port.patch` 是同一件事：`--name` 只改显示名和离线 UUID，
变不出一个 `AuthSession`。

## 补丁：`offline-account.patch`

145 行，4 个文件，全部在 `crates/sunrise-client/`，**不动 `launcher/`**。每处带
`OFFLINE-PATCH:` 注释（共 7 处），方便对着上游 rebase。

干两件事：

1. **造一个离线账号。** `AuthSession::new(name, uuid, token)` 本来就是 public
   （注释写着 "For tests and harnesses"），UUID 用现成的
   `sunrise_core::md5::offline_uuid(name)`（标准 Java `OfflinePlayer:<name>`）。
   token 是占位的，只在连 online-mode 服务器时才会被拿去问 Mojang——而离线客户端
   本来就过不了那道验证。装上它的位置在 `game_dir` 切换**之后**，因为离线名要从
   游戏目录里的 `sunrise-player.txt` 读。
2. **拆掉那五处拦截。** `OnlineMode::lan()` 不再要求已登录——它自己的注释原本就写着
   "an offline name hosts in offline mode"，是那行 `?` 把路堵了。

为什么这样能通（上游本来就有这条路，只是被拦在外面）：

- **主机侧** `lan/conn.rs`：`match online { Some(..) => authenticate(..), None => (offline_uuid(&hello.name), Vec::new()) }`
  —— `None` 是 vanilla 标准离线模式，不是错误分支。
- **客户端侧** `remote/connection.rs`：注释「An online-mode server gets the signed-in
  account again」 —— 只有 online-mode 服务器才需要账号。
- **多人按钮**：`allows_multiplayer` 初值就是 `true`，`poll_account()` 拿不到 session
  时直接 return，不会把它改成 false。

### 验证到哪一步了

- ✅ 补丁能干净打到上游 `main`（`git apply --check`）
- ✅ `cargo check -p sunrise-client --all-targets` 通过
- ✅ `cargo clippy -p sunrise-client --all-targets -- -D warnings` 通过
- ❌ **没有实机验证 LAN 能不能真进人** —— 这是最大的未知数，见下

跑这几条的 workflow 是 `check-sunrise-offline-patch.yml`，只编译、不建包、
不碰 `sunrise-offline` release。

**还没验的**：一个离线主机的世界，另一台机器能不能连进来、能不能正常玩。
上游代码路径是通的，但「代码路径通」和「真能玩」之间还有距离——
尤其是玩家列表、皮肤、聊天这些依赖账号属性的地方，离线访客的 properties 是空的。

## Horizon 与本链的差别

|  | Horizon（现有链） | Sunrise（本链） |
|---|---|---|
| 源码补丁 | `offline-port.patch`，1070 行、21 个文件 | `offline-account.patch`，145 行、4 个文件 |
| 编译 | Rust 工具链 + 图形库，~90 min | 不编译，纯下载组装（补丁另需一次编译验证） |
| 产物来源 | 上游源码 + 官方包 | 两个官方包，原样复制 |
| 离线完整性 | 单人 + 多人 + LAN | 单人有；多人/LAN 待验证 |

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
run-offline.sh            启动入口（PLAY.sh 是它的软链接）
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
- `--developer-single-player` 在 Launch API 的 options 里 —— 离线单人的入口在。
  **注意它只管单人**，多人/LAN 见上文补丁那节。
- **启动器认这个包**：`versions --installed` 列出 `dev-2026-11-24-3d34bbe`。
- **版本被选中**：`settings` 报 `selected_version: "dev-2026-11-24-3d34bbe"`，玩家点
  Play 就走它。

最后两条是这条链存在的意义，也是唯一不能靠读代码确认的。

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
| `make-sunrise-package.sh` | 拼包（含 `run-offline.sh`） |
| `smoke-sunrise-package.sh` | 解开、跑、断言 |
| `check-launch-api.py` | 断版本目录名与本体自报的 build 一致 |
| `check-launch-option.py` | 断某个选项还在 Launch API 里 |
| `probe-cli.sh` | 打印启动器/本体的命令行形状（排查用） |
| `offline-account.patch` | 离线账号 + 拆掉多人/LAN 的五处拦截（编译已验证，未实机玩过） |

## 用法

Release 页的 `sunrise-offline` 附件，解开：

```sh
tar -xzf sunrise-linux-x86_64-offline-*.tar.gz
./run-offline.sh
```

想直接起本体、完全不碰启动器：

```sh
./data/versions/<tag>/sunrise-client --developer-single-player
```

**注意**：现在 Release 里那个包**没打补丁**，所以只有单人。要多人/LAN 得自己套
`offline-account.patch` 重编 `sunrise-client`，而重编需要 Rust 工具链——本机没有，
只能走 CI。

## 许可

Sunrise 本体是 **PolyForm Shield + Additional Terms**，不是 Horizon 那个 MIT。
它的附加条款要求分发 fork 时必须继续免费开源，所以这条链：

- 不修改任何二进制，只做复制作业；
- 包里带上 `LICENSE` 与 `LICENSES/`（包含 `MIT-Horizon.txt` —— 血统保留）；
- 产物标 `--prerelease`，不当正式版发布。

如果这条链最后要变成正式产物，许可这块得再看一遍。
