# ZashDock

ZashDock 是仅面向 Apple Silicon 的 macOS 原生 Zashboard 容器：从 [Zephyruso/zashboard 官方 Releases](https://github.com/Zephyruso/zashboard/releases) 安装网页资源，通过 `http://127.0.0.1:<port>` 展示原版界面，并由 Zashboard 直接连接用户配置的多个远程 Mihomo Kernel。

应用采用 SwiftUI、macOS 26 的 WebKit `WebView` / `WebPage`、Swift Concurrency 和 Observation。Swift Package Manager 管理本地 Core 包和 Sparkle，系统 zlib 用于解压。没有 Electron、Tauri、Node.js、Docker 或内置 Mihomo Kernel，也不修改 Surge 或系统代理设置。App Bundle 不包含 Zashboard `dist` 静态资源。

原生安装、静态服务、WebKit 持久化、端口事务和更新界面均已实现。已执行真实 `xcodebuild` 和 Swift Testing；逐项结果及实际限制见 [测试说明](Docs/TESTING.md)。

2026-10-23 审计修复已通过 P1、P2 阶段编译与回归，详情见 [修复记录](Docs/REMEDIATION.md)。现已采用“WebKit 日常持久化＋改端口时一次性转移完整业务数据”，移除了持续同步的原生配置副本和相关恢复界面。

## 首个正式版准备

计划通过 GitHub Releases 直接分发正式版 **`v1.0.0`**，应用内版本为 **`1.0.0 (2)`**，要求 Apple Silicon、macOS 26.0+，不需要上架 App Store。产品版本和 Apple 分发身份分别记录：本次选择正式版发行，使用实际 Release 构建和 **ad hoc 签名**；维护者目前没有 Apple Developer Program 会员，没有 Developer ID 签名、Apple 公证或装订。**Gatekeeper 可能阻止下载后的应用启动**；ad hoc 签名不提供 Apple 验证的开发者身份，也不能保证每台 Mac 上的首次启动体验。相关要求见 [Apple 软件分发说明](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)。

此正式版计划进入稳定 Sparkle Feed，更新包与 Feed 均使用专用 Ed25519 密钥签名；该更新完整性验证独立于 Apple 的 Developer ID 和公证。发行同时提供应用 ZIP、SHA-256、匹配 dSYM 与白名单构建信息；归档检查和对应源码提交的 CI 通过后才发布。功能与验证边界见 [v1.0.0 发行说明](https://github.com/MiracleHYH/ZashDock/blob/main/Docs/RELEASE-NOTES-1.0.0.md)。实际可用版本以仓库 [Releases](https://github.com/MiracleHYH/ZashDock/releases) 为准。

## 构建与运行

要求 Apple Silicon Mac、macOS 26.0 或更新版本，以及支持相应 SDK 的完整 Xcode。2026-10-23 已使用 **Xcode 27.1（27A9275）实际成功构建 arm64 Debug 应用**；构建记录保存在 `build/verification/`，不是仅通过源码或 SDK 检查推断可构建。

在 Xcode 中打开工程，选择 `ZashDock` Scheme 和本机 Mac 后运行：

```sh
open ZashDock.xcodeproj
```

对应的命令行构建命令为：

```sh
xcodebuild -project ZashDock.xcodeproj \
  -scheme ZashDock -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Xcode \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

产物位于 `build/Xcode/Build/Products/Debug/ZashDock.app`。上述命令生成供本机开发使用的 ad hoc Debug 构建。GitHub 正式版可显式选择 ad hoc Release 模式；Developer ID 签名与 Apple 公证另需相应开发者身份。

仓库也提供 SwiftPM 辅助命令：

```sh
Scripts/swift-build.sh       # 编译原生应用和本地 Core 包
Scripts/build-debug.sh       # 生成 build/Debug/ZashDock.app 并进行本机签名
Scripts/test-core.sh         # Core 单元测试
Scripts/test-integration.sh  # WebKit 集成测试
Scripts/test-storage-processes.sh # 隔离 WebKit profile 的真实跨进程持久化与强退测试
Scripts/test-appmodel-processes.sh # 正式 AppModel 端口提交后强退与冷启动
```

WebKit、沙盒和 App 生命周期的验收应使用 Xcode 的实际 App 测试宿主。运行工程测试：

```sh
xcodebuild -project ZashDock.xcodeproj \
  -scheme ZashDock -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Xcode \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

各命令的最新结果、可选网络测试和未完成的人工检查见 [测试说明](Docs/TESTING.md)。

## 首次安装

没有有效安装时，主窗口显示原生安装页面。“下载并安装”从官方 GitHub API 获取最新稳定发行信息，下载精确的 `dist.zip` 资产，显示进度并支持取消。在线下载仍核验 HTTPS 来源、资产大小及官方 SHA-256。候选网页正常加载后才成为当前安装；失败可重试，安装损坏时提供修复入口。

右侧导入图标可选择本地 ZIP，适用于离线或 GitHub 受限环境。导入不联网、不验证官方身份、不要求匹配已知版本或官方摘要，来源由用户自行判断。应用保留 ZIP 路径、结构、解压限额和必要文件检查，并确认页面能够加载；本地计算的摘要仅用于安装后的内部完整性记录。导入安装在 Settings 显示为“本地导入（版本未知）”，不从文件名猜测 Zashboard 版本。

GitHub 匿名 API 的额度按网络出口共享，使用同一代理出口的其他请求也会占用额度。出现限流时，应用显示 HTTP 状态及响应中可用的重试时间；可以等待后重试，或使用右侧图标导入本地 ZIP。

## 连接 Remote 与端口设置

原版 Zashboard 负责 Remote 的添加、编辑、切换、节点管理和统计。ZashDock 不另做一套 Remote 编辑器，也不在本地提供转发远程请求的代理 API。

本地服务默认端口为 **9099**。在原生 **设置 → 通用** 中可以指定 **1024–65535**，或主动点击“自动选择并保存可用端口”。自动选择只在用户显式触发后进行，当前探测范围为 9099–9198；应用不会在启动失败时静默修改端口。

端口切换执行“暂停网页并停止旧服务 → 一次性读取当前 WebKit 数据到内存 → 实际绑定新端口 → 在网页初始化前写入并核验数据 → 验证真实网页 → 原子保存端口 → 清理旧 Origin”。始终只运行一个 HTTP 监听器；提交前失败会保留原端口和原数据，并尝试重新启动旧服务。旧端口在启动前已被占用时，仍可通过可信模拟文档直接读取该 Origin 的 WebKit 存储，不会请求占用端口的程序。

远程 Mihomo 需要允许实际面板 Origin。使用精确白名单时，可按远端版本配置：

```yaml
external-controller-cors:
  allow-origins:
    - 'http://127.0.0.1:9099'
  allow-private-network: true
```

修改本地端口后，须相应检查远端白名单。具体配置见 [Mihomo 官方文档](https://github.com/MetaCubeX/Meta-Docs/blob/main/docs/config/general.en.md#external-control-api)。应用不会替用户修改远端、Surge 或系统代理配置；LAN/VPN 连通性还取决于实际路由、权限和防火墙。HTTP Remote 支持明文连接，凭据保护需要后端提供 HTTPS；浏览器 CORS 仍然生效。

## 网页数据持久化

日常配置只保存在固定的持久 `WKWebsiteDataStore.default()` 中，由原版 Zashboard 正常读写 LocalStorage 和 IndexedDB。普通重载、退出和重启不导出配置、不重新注入旧值，也不增加原生 Remote 文件、定时同步或 Keychain 密钥。用户主动清空网页设置后，应用不会回放旧配置。

改端口时，`OriginStorageTransfer` 一次性转移完整 LocalStorage，以及已核验的官方 `base64`、`connection-history` 两个 IndexedDB，包含 Remote、选中后端、设置、本地背景图和连接历史。数据只暂存在内存；目标数据在官方网页初始化前已写入。未知数据库或结构、超限、取消和验证失败都会中止提交并保留源数据。这里的“完整”指当前官方版本的业务数据，不包含 Cookie、sessionStorage、Service Worker 和可重新生成的缓存。

原生设置文件只记录端口、窗口行为及兼容和清理标记。端口提交成功后才清理旧 Origin；若中断，重启会根据已提交端口继续工作并重试旧数据清理。普通设置损坏时先保全原文件，再显式恢复原端口，避免误把其他 Origin 当成空配置。

从早期开发版升级时，`LegacyWebStorageReader` 可只读认证原密文并完成一次导入。成功标记后不再读取旧密文或访问其 Keychain 项；原文件不会被修改或删除。旧密钥暂不可读时保留文件并允许重试，不生成替代密钥。全新安装不使用此兼容路径。Bundle ID 固定为 `app.zashdock.mac`，请保持应用身份稳定。

## 更新与当前安装

从系统菜单栏 **ZashDock → 设置…** 或 **⌘,** 打开原生设置窗口。主窗口不放右上角设置或版本控件。**设置 → 更新** 和 **关于** 页均同时显示明确标注的 ZashDock 完整版本（含构建号）与 Zashboard 版本；系统菜单 **关于 ZashDock** 的原生面板也同时显示两者。更新页另提供 Zashboard 最新稳定版和安装入口。

应用只保留当前安装，不提供 Zashboard 回滚、历史下载列表或历史保留数。候选先使用临时 WebKit 存储验证实际网页及本地服务版本，通过后才提交当前指针，再加载日常持久 profile。候选失败或取消时原安装和网页数据保留；成功加载后清理旧资源。旧版已有历史目录在当前安装确认可用后清理，用户的 Remote、设置及背景/历史数据库独立保留。

若指针提交后的持久页面加载失败，保留已提交安装与暂未清理的原资源，显示重载入口。这是失败恢复的临时资源保全，未向用户提供版本回滚功能。

本地面板更新由原生安装器直接处理官方 Releases，不能通过 Mihomo `/upgrade/ui` 更新 ZashDock 的网页目录。版本切换处理 loopback 的 Service Worker 和可丢弃缓存，不全量清空 WebsiteDataStore，不删除 LocalStorage 或 IndexedDB。

## ZashDock 应用的发布与更新

项目仓库为 [MiracleHYH/ZashDock](https://github.com/MiracleHYH/ZashDock)。ZashDock 自身通过固定版本的 **Sparkle 2.10.0** 接入此仓库的 GitHub Releases；原生应用菜单和“设置 → 更新”提供检查入口，自动检查默认关闭，可由用户开启。Zashboard 网页仍从上游官方仓库独立安装和更新。

ZashDock 使用 MIT License；App 资源内保留本项目及 Sparkle 的完整许可文本，包含 Sparkle 所用组件的通知，“关于”页也提供许可链接。

应用固定使用 `main/appcast.xml` 的 HTTPS 更新源，并要求更新源及更新包的 Ed25519 签名有效。公钥随应用发布，专用私钥不提交源码；签名失败不会在一段时间后自动回退为无签名 Feed。首次源码推送提供了签名的空更新源；`v1.0.0` 正式版计划在发行验证完成后将签名条目写入稳定 Feed。

推送和 Pull Request 只触发构建、测试和 Debug 工件上传。正式发布须手动运行 `Publish signed ZashDock` 工作流并输入 `PUBLISH`，通过 `signing_mode` 显式选择 Apple 分发模式：默认 `developer-id` 要求 Developer ID 签名、公证和装订；本次选择 `adhoc`，明确保留未公证限制。两种模式均要求 Sparkle 对更新包和 Feed 签名并独立验证，成功后才创建正式 GitHub Release 并更新 Feed；缺少所选模式的必需凭据时停止，不隐式切换模式。正式版使用 Build `2`，供此前 Build `1` 的试用安装识别更新；后续发行 Build 必须大于 `2` 并持续递增。所需配置和失败恢复步骤见 [发布说明](Docs/RELEASING.md)。

## 进一步阅读

- [架构与事务边界](Docs/ARCHITECTURE.md)
- [实际测试记录与验收限制](Docs/TESTING.md)
- [Apple API 核对](Docs/APPLE-API-REFERENCES.md)
- [上游发行、存储与 PWA 核验](Docs/UPSTREAM.md)
- [签名发布与应用更新通道](Docs/RELEASING.md)
- [Zashboard 官方项目](https://github.com/Zephyruso/zashboard) 与 [官方 MIT License](https://github.com/Zephyruso/zashboard/blob/v3.29.1/LICENSE)
