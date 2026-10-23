# ZashDock 1.0.0

ZashDock 的首个正式版本，为 Apple Silicon Mac 提供原生 Zashboard 容器。通过 GitHub Releases 直接分发，无需上架 App Store。

## 平台与分发说明

- **Apple Silicon（arm64）、macOS 26.0+**；应用内版本为 **ZashDock 1.0.0 (2)**。Build 递增使此前 Build `1` 的试用安装能够识别本次更新。
- 使用实际 Release 构建和 **ad hoc 签名**。此版本没有 Developer ID 签名、Apple 公证或装订，**Gatekeeper 可能阻止网络下载后的应用启动**。Apple 分发身份影响系统信任与首次启动体验，和本版本的正式版定位分别记录；ad hoc 签名不提供 Apple 验证的开发者身份。相关要求见 [Apple 软件分发说明](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)。
- 应用 ZIP 和稳定 Sparkle Feed 均使用专用 Ed25519 密钥签名，并使用应用内公钥验证。该机制保护更新完整性，不等同于 Developer ID 或 Apple 公证。
- 开发者也可依据 [源码构建说明](https://github.com/MiracleHYH/ZashDock/blob/main/README.md#构建与运行) 自行构建。

## 功能

- 原生 SwiftUI 首次安装页，从 Zashboard 官方 GitHub Releases 下载最新稳定版，支持进度、取消、失败重试和损坏安装修复。
- 完全离线导入本地 ZIP，不验证官方身份或匹配已知摘要，由用户负责来源；保留 ZIP 路径、结构、CRC 和解压限额检查，通过实际页面验证后启用。
- 仅监听 `127.0.0.1` 的静态服务，默认端口 `9099`；原版 Zashboard 直接管理多个远程 Mihomo，支持 HTTP REST 与 WebSocket。远端须允许实际面板 Origin，路由、权限、防火墙和 CORS 继续生效。
- WebKit 日常持久化 Remote 和网页设置；改端口时一次性转移完整 LocalStorage 及已核验的背景图、连接历史 IndexedDB。未知数据库结构或迁移失败时保留源数据。
- Zashboard 更新先验证页面再切换资源指针，成功后仅保留当前安装；不提供回滚或历史保留设置。选择性处理 Service Worker 与可丢弃缓存，不清空网页配置。
- 原生设置通过系统应用菜单或 **⌘,** 打开；设置与原生关于面板同时展示 ZashDock 完整版本和 Zashboard 版本。主窗口保持简洁，不添加右上角设置或版本组件。
- App Sandbox、稳定 Bundle ID、应用图标与许可信息。应用包不包含 Zashboard dist 或 Mihomo，不修改 Surge 或系统代理。

## 下载与更新

应用包为 `ZashDock-1.0.0-arm64.zip`，摘要见 `SHA256SUMS.txt`。另附 `ZashDock-1.0.0-build2-arm64-` 前缀的独立 dSYM、白名单构建元数据与诊断摘要，匹配归档程序 UUID，用于追溯构建和分析崩溃。资产不包含用户 Remote、Secret、WebKit 数据、完整 Archive 或签名密钥。

ZashDock 应用更新使用稳定 Sparkle Feed，自动检查默认关闭，可在设置中开启或手动检查。Zashboard 网页继续通过原生安装器从上游独立更新。

## 验证边界

已执行实际 Xcode 构建、Swift Testing、沙盒 App 测试，以及隔离 WebKit 和生产 AppModel 的跨进程持久化、端口占用和强退恢复测试。详细覆盖与结果见 [测试记录](https://github.com/MiracleHYH/ZashDock/blob/main/Docs/TESTING.md)；源码与构建信息随发行附后。

实际运行环境为 Apple Silicon、macOS 27.0.1、Xcode 27.1。尚未在独立 macOS 26.0 设备上运行，也未完成全新独立 Mac 的下载与 Gatekeeper 首次启动验收。个人远端的认证访问、各种 Surge/LAN/VPN 拓扑、所有辅助功能和长时间运行情况未全部覆盖。Developer ID、公证及 Sparkle 真实安装升级仍需各自单独验证。
