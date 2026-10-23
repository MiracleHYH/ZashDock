# ZashDock

ZashDock 是仅面向 Apple Silicon 的 macOS 原生 Zashboard 容器：从 [Zephyruso/zashboard 官方 Releases](https://github.com/Zephyruso/zashboard/releases) 安装网页资源，通过 `http://127.0.0.1:<port>` 展示原版界面，并由 Zashboard 直接连接用户配置的多个远程 Mihomo Kernel。

应用采用 SwiftUI、macOS 26 的 WebKit `WebView` / `WebPage`、Swift Concurrency 和 Observation。Swift Package Manager 管理本地 Core 包和 Sparkle，系统 zlib 用于解压。没有 Electron、Tauri、Node.js、Docker 或内置 Mihomo Kernel，也不修改 Surge 或系统代理设置。App Bundle 不包含 Zashboard `dist` 静态资源。

原生安装、版本管理、静态服务、WebKit 持久化、端口事务、更新及回滚界面均已实现。已执行真实 `xcodebuild` 和 Swift Testing；逐项结果及实际限制见 [测试说明](Docs/TESTING.md)。

2026-10-23 审计修复已通过 P1、P2 阶段编译与回归，详情见 [修复记录](Docs/REMEDIATION.md)。现已采用“WebKit 日常持久化＋改端口时一次性转移完整业务数据”，移除了持续同步的原生配置副本和相关恢复界面；未发布 Release。

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

产物位于 `build/Xcode/Build/Products/Debug/ZashDock.app`。上述签名是供本机开发使用的 ad hoc 签名，发布签名和公证需要自己的开发者身份。

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

没有有效安装时，主窗口显示原生安装页面。点击“安装最新稳定版”后，应用从官方 GitHub API 获取稳定发行信息，下载精确的 `dist.zip` 资产，显示进度并支持取消。通过 HTTPS 来源、资产大小、SHA-256 和 ZIP 安全检查后，候选版本还须在 WebKit 中正常加载，才会成为当前版本。失败可重试；安装损坏时提供修复入口。

无法在线下载时，可通过“从本地官方 ZIP 导入…”选择已下载的官方资产。首次完全离线导入支持 [v3.29.1 的官方 dist.zip](https://github.com/Zephyruso/zashboard/releases/download/v3.29.1/dist.zip)：

```text
大小：9,570,334 字节
SHA-256：4f16cce229e223bd07b5a3daccfbfb8bf349d7335572d412959284ab6c9bab50
```

应用只内置上述发行的来源、大小及摘要元数据，不捆绑 ZIP 或网页资源。联网获取过可信发行元数据后，也可离线导入与缓存摘要匹配的版本。未知 ZIP 不会仅凭文件名或目录结构被视为官方安装包。完整上游核验记录见 [UPSTREAM.md](Docs/UPSTREAM.md)。

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

原生设置文件只记录端口、历史版本数量、窗口行为及清理标记。端口提交成功后才清理旧 Origin；若中断，重启会根据已提交端口继续工作并重试旧数据清理。普通设置损坏时先保全原文件，再显式恢复原端口，避免误把其他 Origin 当成空配置。

从早期开发版升级时，`LegacyWebStorageReader` 可只读认证原密文并完成一次导入。成功标记后不再读取旧密文或访问其 Keychain 项；原文件不会被修改或删除。旧密钥暂不可读时保留文件并允许重试，不生成替代密钥。全新安装不使用此兼容路径。Bundle ID 固定为 `app.zashdock.mac`，请保持应用身份稳定。

## 更新与回滚契约

在原生 **设置 → 更新** 中检查稳定版、安装最新或历史稳定版、导入官方 ZIP、查看本地历史并手动回滚。`ZashboardUpdateManager` 独立处理官方来源和下载；候选先使用临时 WebKit 存储验证实际网页及本地服务版本，通过后才提交版本指针，再加载日常持久 profile。候选失败或取消不会清空当前配置。若提交后的持久页面加载失败，保留已提交版本与历史资源，显示重新载入入口；只有持久页面成功加载后才执行历史清理。

保留参数 `maxRollbackVersions = N` 默认 **1**，允许 **0**；N 仅计算历史版本，不包含当前版本。成功操作完成后的版本数量上限为 **N + 1**。首次安装只有当前版本，失败或未激活候选不属于历史。历史按最近激活顺序保留；回滚目标成为当前版本，原当前版本进入历史，同样应用上限。清理只在候选验证与提交成功后执行，不删除正在使用的版本或网页业务数据。

本地面板更新由原生安装器直接处理官方 Releases，不能通过 Mihomo `/upgrade/ui` 更新 ZashDock 的网页目录。版本切换处理 loopback 的 Service Worker 和可丢弃缓存，不全量清空 WebsiteDataStore，不删除 LocalStorage 或 IndexedDB。

## ZashDock 应用的发布与更新

项目仓库为 [MiracleHYH/ZashDock](https://github.com/MiracleHYH/ZashDock)。ZashDock 自身通过固定版本的 **Sparkle 2.10.0** 接入此仓库的 GitHub Releases；原生应用菜单和“设置 → 更新”提供检查入口，自动检查默认关闭，可由用户开启。Zashboard 网页仍从上游官方仓库独立安装和更新。

ZashDock 使用 MIT License；App 资源内保留本项目及 Sparkle 的完整许可文本，包含 Sparkle 所用组件的通知，“关于”页也提供许可链接。

应用固定使用 `main/appcast.xml` 的 HTTPS 更新源，并要求更新源及更新包的 Ed25519 签名有效。公钥随应用发布，专用私钥不提交源码；签名失败不会在一段时间后自动回退为无签名 Feed。首次推送只提供签名的空更新源，不包含发布包或虚构版本。

推送和 Pull Request 只触发构建、测试和 Debug 工件上传。正式发布须手动运行 `Publish signed ZashDock` 工作流并输入 `PUBLISH`，经过 Developer ID 签名、Apple 公证、装订和 Sparkle 签名后，才创建 GitHub Release 并更新 Feed。所需证书、仓库配置和失败恢复步骤见 [发布说明](Docs/RELEASING.md)。首次源码推送不会创建 Tag 或 Release。

## 进一步阅读

- [架构与事务边界](Docs/ARCHITECTURE.md)
- [实际测试记录与验收限制](Docs/TESTING.md)
- [Apple API 核对](Docs/APPLE-API-REFERENCES.md)
- [上游发行、存储与 PWA 核验](Docs/UPSTREAM.md)
- [签名发布与应用更新通道](Docs/RELEASING.md)
- [Zashboard 官方项目](https://github.com/Zephyruso/zashboard) 与 [官方 MIT License](https://github.com/Zephyruso/zashboard/blob/v3.29.1/LICENSE)
