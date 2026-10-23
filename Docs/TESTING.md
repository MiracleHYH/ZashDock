# 实际构建与测试记录

执行日期：2026-10-23，Asia/Shanghai。设备：Apple Silicon arm64；运行系统 macOS 27.0.1（26A434）；完整 Xcode 27.1（27A9275）。工程最低部署版本为 macOS 26.0，架构固定 arm64。另用 Command Line Tools 的 macOS 26.5 SDK 编译通过；未在独立 macOS 26.0 机器上运行。

## 构建产物

### GitHub 更新通道接入后的复验

本次首次推送前，已固定 Sparkle 2.10.0 并重新构建实际 arm64 App。`github-final-build.log` 结果为 `BUILD SUCCEEDED`；`codesign --verify --deep --strict` 成功，沙盒权限中的两条安装服务名称已展开为稳定 Bundle ID。完整 App 包含 Sparkle Framework 和其安装服务，没有 Zashboard `dist`。

Core 测试汇总 **36 项通过，4.648 秒**，记录为 `build/verification/github-core-tests.log`。实际 `xcodebuild test` 汇总 **24 项、7 个 Suite 通过，22.308 秒**，记录为 `build/verification/github-final-tests.log` 与 `github-final-tests.xcresult`。真实官方 ZIP 的两个测试均启用并通过；用户后端网络测试本轮明确跳过，不重复访问个人后端。新增安全配置检查验证了真实 Bundle 的签名 Feed、公钥、解压前验签、沙盒安装服务以及测试进程不启动自更新。

两个工作流通过 Actionlint；发布脚本通过 Bash 语法与内嵌 Swift 验证器编译。专用签名私钥与 App 公钥的匹配、初始空 Feed 验签和篡改拒绝均已本地验证。未运行 Release 工作流，未执行 Developer ID 签名、公证或真实 Sparkle 应用替换；这些端到端步骤仍待正式发布凭据配置后验收。

首次依赖解析曾停在官方二进制下载，已中止；随后通过官方 HTTPS 下载相同资产，SHA-256 与固定 SPM 清单一致，使用依赖缓存重跑成功。中间失败构建及修复记录保留在本地 `build/verification/github-*.log`。下述较早的构建体积和测试数是接入 Sparkle 前的阶段记录。

### 接入前的阶段构建

```sh
xcodebuild -project ZashDock.xcodeproj -scheme ZashDock \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Xcode CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

结果：`BUILD SUCCEEDED`。产物 `build/Xcode/Build/Products/Debug/ZashDock.app`；`file` 确认为 Mach-O arm64；`codesign --verify --strict` 成功。Info.plist 和工程 plist 校验成功。最终 App Bundle 只有原生可执行文件、Debug 动态库和签名元数据，没有 Zashboard ZIP、dist 或静态网页资源。

最终构建日志：`build/verification/final-xcodebuild.log`。这是本机可运行的 ad hoc Debug 签名，不是发行签名或公证包；Xcode 对 ad hoc 签名不启用 hardened runtime，但 App Sandbox 及网络 entitlements 已在实际测试宿主中运行。

最终交付副本为 `build/Debug/ZashDock.app`（约 2.1 MiB），由 `Scripts/build-debug.sh` 从实际 Xcode 产物复制并重新验证，未修改签名。`vtool` 确认最低系统版本 26.0；实际签名权限导出见 `build/verification/delivery-entitlements.txt`，包含 sandbox、network client/server 和用户选择文件只读权限。打包日志为 `build/verification/delivery-build.log`。

开发最初只有 Command Line Tools，`xcodebuild` 无法运行；用户安装、初始化 Xcode 后已补跑真实构建和宿主测试。工具自身文件系统沙盒会阻挡 Xcode 缓存、WebKit 子进程或 LaunchServices，相关命令在获准后于工具沙盒外执行；应用自己的 App Sandbox 未关闭。

## 自动测试

| 阶段 | 实际结果 | 记录 |
| --- | --- | --- |
| 1 原生窗口 / Settings | arm64 SwiftPM 编译、签名构建成功；原生未安装窗口实际打开 | `build/verification/phase1.log`、`phase1-bundle.log` |
| 2 官方安装与目录管理 | 14 项初始 Core 测试通过；真实官方下载、摘要、安全解压和激活成功 | `build/stage2-tests.log`、`stage2-live-retry.log` |
| 3 本地服务 / WebPage | 实际绑定和安全边界通过；原生 WebPage 真正加载 loopback 页面 | `build/stage3-tests.log`、`build/verification/phase3-web-tests-unsandboxed.log` |
| 4 加密 Remote 桥接 | 9 项实际 Xcode 集成测试通过 | `build/verification/phase4-xcode-tests.log`、`phase4-tests.xcresult` |
| 5 应用级端口事务 | 16 项实际 Xcode 集成测试通过，含两 Remote、重启、占用失败和原端口不可访问 | `build/verification/phase5-xcode-tests.log`、`phase5-tests.xcresult` |
| 6 更新 / 回滚 / 缓存 | 22 项实际 Xcode 集成测试全部通过，21.521 秒；含真实官方网页及 N 参数化 | `build/verification/phase6-retry-xcode-tests.log`、`phase6-retry-tests.xcresult` |
| 7 最终 Core | 36 项测试汇总通过，4.695 秒；可选 live 默认跳过，live 已独立执行成功 | `build/verification/final-core-tests.log` |
| 7 最终完整 App 宿主 | 23 项全部通过，22.459 秒；真实官方首次离线安装取消后重试、官方双 Remote 重启迁移、真实 HTTP 可达性均启用 | `build/verification/final-xcode-tests.log`、`final-tests.xcresult` |

运行 Core 测试：

```sh
Scripts/test-core.sh
```

普通 Xcode 集成测试不需要联网或真实后端。启用官方资源和用户指定后端的只读网络测试时，使用测试运行器专用环境变量：

```sh
TEST_RUNNER_ZASHDOCK_OFFICIAL_ZIP=/absolute/path/to/official/dist.zip \
TEST_RUNNER_ZASHDOCK_MIHOMO_URL=http://your-mihomo-host:9090 \
xcodebuild -project ZashDock.xcodeproj -scheme ZashDock \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Xcode CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

未提供可选变量时，对应用例明确跳过。官方 ZIP 测试按内置可信元数据校验 v3.29.1，不接受任意同名压缩包。测试文件只使用虚构 Remote 凭据。Keychain 测试为每轮创建独立 UUID service，并仅清理该轮测试条目，不访问或删除生产密钥。

## 验收映射

| 项目 | 已执行的覆盖和边界 |
| --- | --- |
| A 首次启动 | 实际 AppModel 无安装状态和无 WebPage；原生安装界面已观察 |
| B 取消 / 失败 / 重试 / ZIP | Core 覆盖下载任务取消、解压取消、未知 ZIP 拒绝、本地导入失败后重试；真实官方 ZIP 经 AppModel 首次安装取消、无激活残留、同 ZIP 重试、加密快照首次落盘和官方页面渲染均通过 |
| C 两个 Remote 重启保留 | 官方 setup/api-list + setup/active-uuid 的双 Remote，经加密快照、真实 WebPage 和真实官方网页重启验证 |
| D HTTP REST / WebSocket | 原生 WebPage 跨 Origin Authorization 预检和 REST 200；真实 WebSocket 握手与 JSON 帧，未关闭 WebKit 同源或 CORS |
| E 端口占用 | 实际 NWListener 占用；失败不写配置、不替换原监听器；可手动或显式自动选择新端口 |
| F 端口迁移 | 真实 AppModel 事务；初始化第一次读取已包含两 Remote、选中项和主题；失败保持配置字节、版本与快照 |
| G 启动前原端口被占用 | 先退出、另一个服务占据原端口、重启进入原生错误状态，再从原生快照迁移成功 |
| H 更新后保留 | 同一 Origin 切换不同版本，检查 DOM、JS 版本、两个 Remote 与快照 |
| I N=0/1/3 | 多次实际网页切换后检查 current/history 和物理版本目录总数；Core 另测激活顺序 |
| J 回滚 | 回滚后的实际 DOM / JS、服务版本、两个 Remote 及顺序均检查 |
| K 损坏 ZIP | CRC、摘要、截断、路径、ZIP Slip、符号链接、压缩比、配额、有界复制、源文件替换；失败不修改当前指针 |
| L SW / 缓存 | SW script 请求真实 403；真实 WebKit 注册失败；清理 CacheStorage 后 LocalStorage 保留；同 Origin 版本替换验证 |
| M 原生生命周期 | 见 UI-VERIFICATION.md 的实际窗口、Settings、菜单和退出观察 |
| N Surge / LAN / VPN | 下面记录真实环境；认证后的实际 Kernel WebSocket 尚需用户 Secret |

## Surge 环境中的真实后端测试

用户提供并授权只读测试了一个真实 HTTP Mihomo 后端。公开记录不包含其主机名、地址、凭据或本机路由细节。

- Surge 6.10.0 正在运行；确认该域名经 Surge 的虚拟地址和隧道路由可达。
- 原生终端 GET `/version` 返回 HTTP 401，包含 `Access-Control-Allow-Origin: *`。
- `/traffic` WebSocket Upgrade 请求返回 HTTP 401，未绕过认证。
- 带应用实际 ATS 配置的沙盒 WebPage 也成功读取 HTTP 401 响应，说明 HTTP / CORS 可达；记录于阶段 4 和阶段 6 的实际宿主测试。
- REST 认证和成功 WebSocket 数据帧使用本机测试专用后端验证。没有用户 Secret，因此不能声称真实远端的认证、订阅、节点或业务数据已经验收。
- 没有更改 Surge、系统代理、VPN 或远端 Mihomo 配置；没有在日志写入真实 Secret。

原始响应头保存在本地忽略的 `build/verification/` 目录，不随源码提交。响应只包含 Unauthorized，不含敏感配置。

## 已发现并修正的问题

独立审查和实际测试修正了：损坏官方目录阻断离线 seed、外部 ZIP 无界复制、静态大文件的整块内存占用、空 #app 被误判安装成功、迁回旧 Origin 的缓存清理、取消操作继承到旧版恢复、异步操作句柄覆盖、后台 WebKit timer 节流导致超时不准确，以及 __proto__ / 特殊字符串恢复边界。

保留失败记录：一次 GitHub CDN 超时（重试成功）；阶段 6 早期测试中，ad hoc 重签名读取先前测试误用的生产 service 触发钥匙串确认，以及背景计时器造成测试超时。修复后整轮 22 项重跑成功。没有通过放宽钥匙串 ACL、关闭 App Sandbox 或清空 WebsiteDataStore 来消除失败。

## 明确范围

跨端口迁移保证完整 LocalStorage，包括所有 Remote、选中后端及存在其中的设置。官方本地背景图和连接历史存于 IndexedDB，当前不跨 Origin 迁移；版本清理和缓存清理不会删除它们，旧 Origin 中的数据仍保留。此实现不能描述成迁移所有 WebsiteDataStore 数据。

发布签名 / 公证、独立 macOS 26.0 设备、真实后端提供 Secret 后的认证 REST / WebSocket 属于尚未执行的环境验收。ad hoc 重新签名可能要求用户重新确认钥匙串访问；应使用稳定证书，不能删除生产密钥来规避系统保护。
