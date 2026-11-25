# Sunrise 离线包（试验链）

`sunrise-org/sunrise` 是 Horizon 改名后的延续项目。这个目录是**独立的一条试验链**，
和仓库里另外两条（`release-offline.yml` / `release-game.yml`，跟
`horizon-rust/horizon`）互不影响：不共用脚本、不共用 state、不共用 release。

## 为什么要试这一条

`horizon-rust` 整个组织已经 404（2026-11-25 记录），现有两条链的 schedule 每半小时
失败一次。Sunrise 是同一套代码改名搬过去的，而且**本体自带离线入口**：

```
--developer-single-player    单人，不需要登录（在 Launch API 契约里，是隐藏选项）
--name NAME                  多人身份
--session-file PATH          启动器给的会话（本链不用）
```

这意味着一个关键差别：

| | Horizon（现有链） | Sunrise（本链） |
|---|---|---|
| 源码补丁 | `offline-port.patch`，1070 行、21 个文件 | **不需要** |
| 编译 | Rust 工具链 + 图形库，~90 min | 不编译，纯下载组装 |
| 产物来源 | 上游源码 + 官方包 | 两个官方包，原样复制 |
| 版本判定 | 解析 release body 正则 | `sunrise-release.json` 里的 `commit` |

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

解压不套目录，直接是：

```
sunrise-launcher          官方启动器，未做任何修改
data/versions/<build>/    官方 sunrise-linux-x86_64.tar.gz 原样解开
  sunrise-client          170 MB，本体
  sunrise-prepare         准备资源（从你自己的 Minecraft 26.3）
  sunrise-ctl             终端/脚本控制，也带 MCP server
  sunrise-server          服务端
  PLAY.txt                上游的说明
LICENSE / LICENSES/       启动器包的许可文件（Sunrise 本体是 PolyForm Shield，必须带）
PLAY-OFFLINE.txt          这份包怎么用
```

## 已经验证过的

- 上游资产能取、`SHA256SUMS` 校验一致（`sunrise-linux-x86_64.tar.gz` 与
  `sunrise-launcher-linux-x86_64.tar.gz` 都核对过）。
- `sunrise-release.json` 可直接读 `commit` / `build`，不必解析 release body。
- 组装出来的包 109 MB，结构正确，解压不套目录。
- 随包本体的 `--launch-api` 报 `"Nightly 2026-11-20 · 9425651"`，与版本目录名一致
  —— 说明版本没串包。
- `--developer-single-player` 在 Launch API 的 options 里 —— 离线单人的入口在。
- 本体二进制在本机能跑（`--help`、`--launch-api` 都有正常输出）。

## 还没答案的

**启动器认不认这个版面。** Sunrise 启动器有自己的版本库，而它的离线玩法官方走的是
另一条路：

```
sunrise-launcher developer-install CHECKOUT --program CHECKOUT
```

`CHECKOUT` 是一个 git 检出，不是「往版本目录里放个二进制」。所以「把官方包塞进
`data/versions/<tag>/`」这个版面，启动器是不是真的会列出来，只能在 CI 上跑出来看：

- 冒烟第 3 步跑 `sunrise-launcher list`。列出来了 → 这条路成立。
- 没列出来 → 包还是能玩（直接跑 `data/versions/<tag>/sunrise-client`），但启动器
  不会提供它。那种情况下下一步要么换成启动器认的版面，要么在包里放一个启动脚本。

冒烟脚本**不把这一条判失败**，因为包没坏，坏的是假设 —— 该由人看了结论再定。

## 本机为什么验不了启动器

容器里 `/root` 的 owner 是 `nobody`、权限 `drwx------`，而我们以 uid 0 跑。Sunrise
启动器启动前先写 `/root/.local/state/sunrise-launcher-root-leases`，直接
`Permission denied (os error 13)`。这是本机环境的限制，不是包的问题，也不是
Sunrise 的 bug。冒烟脚本把这类失败识别成 `skipped`，不判失败。

本体 `sunrise-client` 不受影响，所以上面那几条断言本机能验。

## 文件

| 文件 | 作用 |
|---|---|
| `probe-sunrise.py` | 读两个仓库当前发布什么，输出 `build`/`commit`/`launcher_tag` |
| `fetch-sunrise-asset.sh` | 下资产，对 `SHA256SUMS` + GitHub digest 双重校验 |
| `check-downloaded-build.py` | 下载到的 `sunrise-release.json` 与探测到的 commit 对账 |
| `make-sunrise-package.sh` | 拼包 |
| `smoke-sunrise-package.sh` | 解开、跑、断言 |
| `check-launch-api.py` | 断版本目录名与本体自报的 build 一致 |
| `check-launch-option.py` | 断某个选项还在 Launch API 里 |
| `probe-cli.sh` | 打印启动器/本体的命令行形状（排查用） |

## 许可

Sunrise 本体是 **PolyForm Shield + Additional Terms**，不是 Horizon 那个 MIT。
它的附加条款要求分发 fork 时必须继续免费开源，所以这条链：

- 不修改任何二进制，只做复制作业；
- 包里带上 `LICENSE` 与 `LICENSES/`（包含 `MIT-Horizon.txt` —— 血统保留）；
- 产物标 `--prerelease`，不当正式版发布。

如果这条链最后要变成正式产物，许可这块得再看一遍。
