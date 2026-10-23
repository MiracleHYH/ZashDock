# ZashDock

ZashDock 是仅面向 Apple Silicon 的 macOS 原生 Zashboard 容器：从 [Zephyruso/zashboard 官方 Releases](https://github.com/Zephyruso/zashboard/releases) 安装网页资源，通过 `http://127.0.0.1:<port>` 展示原版界面，并由 Zashboard 直接连接用户配置的多个远程 Mihomo Kernel。

应用采用 SwiftUI、macOS 26 的 WebKit `WebView` / `WebPage`、Swift Concurrency 和 Observation。Swift Package Manager 管理本地 Core 包和 Sparkle，系统 zlib 用于解压。没有 Electron、Tauri、Node.js、Docker 或内置 Mihomo Kernel，也不修改 Surge 或系统代理设置。App Bundle 不包含 Zashboard `dist` 静态资源。

原生安装、版本管理、静态服务、加密存储桥接、端口事务、更新及回滚界面均已实现。已执行真实 `xcodebuild` 和 Swift Testing；逐项结果及实际限制见 [测试说明](Docs/TESTING.md)。

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

端口切换执行“保存最新快照 → 实际绑定候选端口 → 在网页初始化前恢复存储 → 验证页面和恢复结果 → 原子保存端口配置”。提交前保留旧监听器；失败时仍使用原配置和快照。即使启动前原端口已被其他程序占用，也能从独立原生快照迁移到新端口。

远程 Mihomo 需要允许实际面板 Origin。使用精确白名单时，可按远端版本配置：

```yaml
external-controller-cors:
  allow-origins:
    - 'http://127.0.0.1:9099'
  allow-private-network: true
```

修改本地端口后，须相应检查远端白名单。具体配置见 [Mihomo 官方文档](https://github.com/MetaCubeX/Meta-Docs/blob/main/docs/config/general.en.md#external-control-api)。应用不会替用户修改远端、Surge 或系统代理配置；LAN/VPN 连通性还取决于实际路由、权限和防火墙。HTTP Remote 支持明文连接，凭据保护需要后端提供 HTTPS；浏览器 CORS 仍然生效。

## 存储与恢复

`ZashboardStorageBridge` 持续同步完整 LocalStorage 字符串键值，包括多个 Remote 的 `setup/api-list` 和当前选择的 `setup/active-uuid`。修改端口、切换页面和退出前会主动读取最新数据。恢复脚本在官方网页脚本执行前同步写入存储，并核验初始恢复结果。

独立原生快照和上一次有效备份采用 **AES-256-GCM** 加密，密钥保存在系统 **Keychain**。密钥不可用或密文损坏时不降级写入明文，也不把失败解释为“空配置”；有效备份恢复会明确提示。网页 LocalStorage 本身仍使用 WebKit 的持久化存储，快照加密不代表整个 WebsiteDataStore 被应用另行加密。

当前跨端口迁移的范围是 **LocalStorage**。官方自定义本地背景图和连接历史保存在 IndexedDB，**尚不跨端口迁移**；这不是完整 Origin 数据迁移。原 Origin 中的 IndexedDB 数据不会被版本清理删除。测试代码覆盖两个 Remote、文档开始恢复、写入捕获、重新创建 Vault、损坏备份恢复、错误密钥和桥接来源限制；通过情况见 [测试说明](Docs/TESTING.md)。

Bundle ID 固定为 `app.zashdock.mac`，Keychain 使用稳定的 service/account。不要为了重置调试界面随意更改这些身份或删除 Keychain 项，否则已有加密快照可能无法解密。

ad hoc Debug 构建重签名后代码身份会变化，系统可能要求重新确认钥匙串访问。持续开发和发布建议使用稳定的开发或发布证书；不要放宽钥匙串 ACL 或删除生产密钥来规避提示。自动测试使用独立的测试钥匙串条目，并只清理自己创建的测试条目。

## 更新与回滚契约

在原生 **设置 → 更新** 中检查稳定版、安装最新或历史稳定版、导入官方 ZIP、查看本地历史并手动回滚。`ZashboardUpdateManager` 独立处理官方来源和下载；实际网页渲染、存储恢复及本地服务版本验证成功后才提交版本指针。已执行更新、回滚、无效候选和取消恢复的实际 WebKit 测试。

保留参数 `maxRollbackVersions = N` 默认 **1**，允许 **0**；N 仅计算历史版本，不包含当前版本。成功操作完成后的版本数量上限为 **N + 1**。首次安装只有当前版本，失败或未激活候选不属于历史。历史按最近激活顺序保留；回滚目标成为当前版本，原当前版本进入历史，同样应用上限。清理只在候选验证与提交成功后执行，不删除正在使用的版本或用户快照。

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
