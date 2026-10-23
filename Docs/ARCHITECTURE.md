# ZashDock 架构

本文描述 2026-10-23 源码的职责和事务边界。原生更新、回滚及端口事务已经过实际 App 宿主测试；执行结果与剩余限制见 [TESTING.md](TESTING.md)。

## 组件与并发隔离

原生应用位于 `Sources/ZashDock`，可复用 Core 位于 `Packages/ZashDockCore`。本地 Core 通过 Swift Package Manager 接入 Xcode；`CZlib` 为系统 zlib 的 C 模块，不引入外部运行时或依赖安装脚本。

| 组件 | 隔离方式 | 职责 |
| --- | --- | --- |
| `AppModel` | `@MainActor @Observable` | 应用状态、安装编排、端口事务、退出前保存 |
| `WebSession` | `@MainActor @Observable` | 创建持久化 WebPage、加载与渲染验证、存储刷新 |
| `ZashboardStorageBridge` | `@MainActor` | 文档开始恢复、消息验证、快照顺序和持久化队列 |
| `ZashboardUpdateManager` | `@MainActor @Observable` | 下载进度、取消、发行检查、准备与显式提交 |
| `ReleaseClient` | `actor` | 官方元数据、受限 HTTPS 下载、大小与 SHA-256 验证 |
| `VersionStore` | `actor` | 版本目录、文件清单、当前指针、历史顺序与清理 |
| `StorageSnapshotVault` | `actor` | AES-GCM 快照、认证备份和失败恢复 |
| `LoopbackHTTPServer` | 主线程入口、内部串行队列 | 绑定、连接生命周期、受限静态文件读取与流式发送 |
| `SafeZIPExtractor` | 无共享可变状态的值类型 | ZIP 结构、路径、资源上限、解压和 CRC 校验 |
| `ConfigurationStore` / `AtomicFile` | 同步值类型和工具 | 配置验证、同目录临时文件、原子替换 |

服务内部 `StaticServerCore` 与连接对象通过独立串行 DispatchQueue 管理，不把它们称为 Swift actor。`@unchecked Sendable` 的正确性依赖该队列约束，跨队列入口通过排队或同步进入。

SwiftUI 使用独立 `Window` 和 `Settings` Scene。主窗口按 `starting`、`uninstalled`、`installing`、`ready`、`damaged`、`unavailable` 展示原生状态或 WebView。AppDelegate 处理 Dock 重开和退出前异步保存；用户可配置关闭最后窗口后退出。系统窗口恢复及菜单的人工验收与自动测试分开记录。

## 持久化布局

`AppPaths.application()` 使用系统 Application Support 目录，并追加稳定标识 `app.zashdock.mac`。启用 App Sandbox 时由系统映射到应用容器，不在代码中硬编码容器绝对路径。

```text
<Application Support>/app.zashdock.mac/
  configuration.json
  official-releases.json
  versions-state.json
  storage.aesgcm
  storage.aesgcm.backup
  versions/
    <tag>-<digest-prefix>[-<repair-id>]/
      manifest.json
      content/
        index.html
        assets/...
  staging/
    <temporary downloads and extraction directories>
```

`configuration.json` 保存端口、历史数量和窗口行为，不包含 Remote Secret。`official-releases.json` 缓存通过官方 API 获得的发行摘要元数据。版本内容、安装清单、版本指针和存储快照各自独立，HTTP 服务仅打开 `content/`，不会把配置或备份目录作为站点根目录。

`AtomicFile` 在目标同目录创建权限为 `0600` 的临时文件，写入并同步，随后通过 `rename` 原子替换目标，并同步父目录。受管目录使用 `0700`。版本状态和端口配置都使用此路径，不直接覆盖正式文件。

## 官方发行与安装事务

`ReleaseClient` 访问固定官方 GitHub API，排除 draft 和 prerelease，精确选择名为 `dist.zip` 且提供 SHA-256 的已上传资产。初始资产 URL 必须为官方仓库对应标签的 HTTPS 发行地址。API 与下载分别使用临时 URLSession，检查每次重定向和最终 URL；不接受第三方源，也不将 Remote 配置附加到请求。

下载流以小缓冲增量写入和计算 SHA-256，核对声明大小、实际大小和 digest，取消或失败删除未完成下载。离线导入以可信摘要目录识别文件；内置的 v3.29.1 seed 只有发行元数据，不包含 ZIP。损坏的缓存目录不会使内置 seed 失效。无法匹配可信摘要的 ZIP 会被拒绝。

`BoundedZIPInput` 在复制前以 `O_NOFOLLOW` 打开源文件并确认是大小匹配的普通文件，限制复制字节数，检查文件身份、增长和修改。随后再次校验私有副本摘要，避免识别与复制之间替换外部文件导致无界复制。

`SafeZIPExtractor` 先验证归档记录，再写入新的私有 staging 目录。当前限制如下：

| 项目 | 上限 |
| --- | --- |
| ZIP 大小 | 128 MiB |
| 累计展开大小 | 256 MiB |
| 单文件展开大小 | 64 MiB |
| 条目数 | 20,000 |
| 单条目压缩比 | 250 |

解析器核对中央目录、本地头、UTF-8 名称、数据描述符、连续且无重叠的文件记录和 CRC；拒绝 ZIP64、加密归档、特殊文件、符号链接、绝对路径、`..`、反斜杠、含糊编码、Unicode/大小写冲突和父文件路径冲突。只有必需入口和 JavaScript 资源有效，才会生成候选安装清单。

`manifest.json` 记录 schema、版本 ID、官方发行元数据、安装时间，以及每个内容文件的相对路径、大小和 SHA-256。`VersionStore` 在激活和读取时验证清单与文件内容；损坏的已安装版本不能仅凭目录存在进入 WebView。

候选完成校验后移入独立版本目录，但此时仍不是当前版本。`versions-state.json` 中的 `currentID` 是原子提交点；准备失败不修改指针，也不预先删除旧版。启动时清理 staging 的中断任务，未激活候选不进入历史列表。

## 本地 HTTP 服务

`NWListener` 明确绑定 `127.0.0.1:<port>`，不绑定通配地址或 IPv6 外部接口，禁用端点重用和点对点接口。只有监听器报告 `.ready` 且端口匹配，`start()` 才返回。接受连接时再次验证 IPv4 loopback 对端。

HTTP 层只支持 GET/HEAD，要求精确 `Host: 127.0.0.1:<port>`；出现 Origin 时必须与当前站点完全一致，拒绝 `Sec-Fetch-Site: cross-site`、Service Worker 脚本请求、重复标头、请求体和 Transfer-Encoding。请求头限制 16 KiB，目标限制 4096 字节，连接数限制 32，并设置读取及发送期限。

路径只解码一次，拒绝目录穿越和含糊分隔符。根目录被打开为持有的文件描述符；后续通过逐级 `openat` 和 `O_NOFOLLOW` 查找文件，中间组件要求目录，最终组件要求普通文件。文件身份、长度和修改时间在读取期间复核，避免符号链接替换或文件变化被当作正常静态响应。

静态文件使用每连接最多一个 64 KiB 块的流式发送，全局待发送文件块预算为 2 MiB；发送完成后才读取下一块。HEAD 只取元数据，不读取整个文件。所有响应带明确 MIME、`nosniff`、`no-store`、无 Referrer 和同源资源策略。只有不含扩展名的缺失路径可回退到 `index.html`，资源缺失返回 404。

唯一内置动态路由 `/__zashdock_health` 返回当前服务的版本 ID 和本次启动 nonce，供原生验证实例。该 nonce 用于识别绑定实例，不是对外的通用授权或远程管理接口。服务没有命令执行、文件写入、配置修改或远程 HTTP 代理端点。

## WebKit 页面与导航

`WebSession` 使用 macOS 26 的 `WebPage` 和 SwiftUI `WebView`，配置 `WKWebsiteDataStore.default()` 持久保存网页数据。它通过 `WebPage.Configuration.userContentController` 直接接入存储脚本，无需包装旧式 NSView WebView。

页面导航只允许本地精确 Origin；外部用户点击的 HTTP/HTTPS 链接交给 `NSWorkspace` 打开。子框架导航不获得原生桥接信任。网页导出使用的 Blob 下载是独立处理边界，不允许把任意 `file:`、自定义 scheme 或本地文件路径交给网页。

加载验证不仅等待主文档完成，还等待 `#app` 出现实际内容，检查健康路由返回的版本和 nonce，并核验文档开始阶段的存储恢复确认。网络完成不等于 Vue 初始化完成；错误或空白候选不能仅凭空 `#app` 被激活。

## LocalStorage 桥接与消息协议

`ZashboardStorageBridge` 只处理当前 `http://127.0.0.1:<port>` 的主框架。`WKUserScript` 在 `.atDocumentStart`、`.page` 世界注入；有快照时同步清空并恢复 LocalStorage，之后才允许官方应用脚本读取。`nil` seed 表示尚无原生快照，保留现有 Origin 数据；空字典表示真实的已保存空配置，两者不能混同。

脚本保存初始恢复确认，包装 `Storage.prototype.setItem`、`removeItem`、`clear`，监听 storage/pagehide，并每 250 ms 比较完整键值，以覆盖属性赋值等写入路径。网页只提交完整字符串字典，不能选择原生路径、调用系统命令或请求任意网络转发。

原生消息必须同时满足固定通道、`.page` 世界、主框架、精确 SecurityOrigin，以及严格字段集合：

```text
schema = 1
token = 当前桥接会话标识
kind = restoreAck | snapshot
sequence = 非负、JavaScript 安全范围内的整数
snapshot = [String: String]
```

拒绝布尔值冒充 schema/sequence、额外字段、错误会话、非字符串键值、过期序号和超限消息。限制为最多 4096 个键、单键 16 KiB、单值 4 MiB、序列化数据及消息最多 8 MiB。会话 token 用于关联消息，不能当作对受信同源网页隐藏的秘密；真正的边界是受控来源、主框架和有限能力。

消息按顺序排队交给 Vault。显式 `flush` 主动捕获最新状态，等待先前保存，持续排空写入期间到达的新修订，完成后才能报告最新快照已持久化。错误只报告分类信息，不输出 LocalStorage 内容、后端 URL 或 Secret。

## AES-GCM 与 Keychain

Vault 将全部 LocalStorage 字符串字典序列化，以随机 256 位密钥使用 AES-GCM 加密。固定头 `ZASHDOCK-SNAPSHOT-1` 同时作为认证附加数据；密文保存 nonce 和认证 tag。主密文及 backup 通过原子文件写入，轮换前必须先成功认证旧快照。

生产密钥由 Keychain 保存，service 为 `app.zashdock.mac.storage`，account 为 `primary`，不启用同步或共享 access group，访问属性为 `AfterFirstUnlockThisDeviceOnly`。已有密文但取不到密钥时，不能创建新密钥覆盖，也不能回退到明文。

读取主快照失败时只尝试经过认证的备份；恢复成功返回明确状态，提示最近一次更改可能需要重新输入。主备份都无效时抛出错误，保留原数据。测试通过可注入密钥提供者覆盖 AES 完整性、错误密钥、轮换和恢复；这与生产 Keychain 权限的实际运行验收分别记录。

加密覆盖的是原生独立快照和备份。WebKit 自己的 LocalStorage/IndexedDB 仍由系统持久化；本文不声称对整个 WebsiteDataStore 提供额外的应用层加密。

## 端口迁移事务

`AppModel.changePort` 以 `configuration.json` 的原子写入作为提交点：

1. 刷新旧页面，持久保存最新完整 LocalStorage；暂停旧桥接的自动保存。
2. 加载独立快照，在保留旧监听器的同时实际绑定候选端口。
3. 创建默认不自动持久化的候选桥接，在文档开始阶段恢复到新 Origin。
4. 验证页面渲染、服务版本/nonce、初始恢复确认，并捕获候选最新状态。
5. 原子保存候选端口；至此事务提交。
6. 停止旧页面和服务，采用候选页面，启用其保存并刷新快照。

提交前失败会关闭候选并恢复旧桥接，原端口配置和独立快照保持不变。提交后的快照写入失败显示错误，不把已经保存的端口谎报为未提交。自动选择只由明确按钮触发，探测成功并验证后同样保存配置。

当应用刚启动、旧端口已被其他程序占用时，没有可读取的旧 WebPage 也能迁移：原生 Vault 在启动时独立加载，事务使用该快照恢复到新 Origin，而不连接占用旧端口的其他程序。

**当前限制：没有实现 IndexedDB 跨端口迁移。** 官方的本地背景图数据库 `base64` 和连接历史数据库 `connection-history` 留在旧 Origin。LocalStorage 中的相关设置值会迁移，不能据此声称背景图二进制数据或完整 Origin 也已迁移。单纯重写 WebKit 导出数据中的 Origin 不属于本实现。

## 版本历史与切换事务

Core 的版本激活和清理已分离。历史列表按最近激活顺序排列，不按标签字符串或目录修改时间猜测。激活时将目标移到激活序列末尾；回滚仍是一次经过文件验证和网页验证的显式激活。

`maxRollbackVersions = N` 默认 1，配置范围 0–100，N 不包括当前版本。成功操作完成后保留当前及最近 N 个历史版本，总数不超过 N + 1。`protecting` 集合用于短暂保护仍被服务引用的目录；引用释放后必须再次清理，不能让暂时保护永久突破上限。清理范围仅限 versions，不触及 Vault、配置或 WebKit 用户数据。

下载和解压期间旧网页继续工作。在停用旧网页前刷新快照、卸载旧 JavaScript 上下文，再绑定同一端口并验证候选。验证完成才提交当前指针并清理历史。失败会在独立于取消状态的新任务中恢复旧服务与旧页面，保留原快照和版本指针。实际测试同时检查 DOM、初始化首读、服务 nonce、版本指针字节和历史顺序。

Mihomo `/upgrade/ui` 修改的是远程内核的面板，与本地版本目录没有关系；ZashDock 更新流程不调用该接口。

## PWA 与缓存边界

官方发行包含自动注册的 Service Worker 和缓存 `index.html` 的 Workbox 预缓存。`Cache-Control: no-store` 不能单独证明已显示新版。

`WebCacheController` 在创建替代页面前，仅选择 displayName 为 loopback 的 WebsiteDataRecord，并清除 Service Worker 注册、Fetch Cache、磁盘缓存和内存缓存。不会调用 `allWebsiteDataTypes()`，也不会删除 LocalStorage、IndexedDB、Cookie 或凭据。HTTP 服务同时拒绝新的 Service Worker 脚本加载。

WebKit 的站点记录不提供任意精度的端口级筛选，因此该处理范围是此应用数据存储中的 loopback 缓存记录，而非声称只删除某个单独端口。实际版本显示、回滚、重启和旧控制器退出需要运行用例验证。

## Sandbox、ATS 与 Remote 网络

Bundle ID 固定 `app.zashdock.mac`。entitlements 启用 App Sandbox、network.client、network.server，以及用户选择文件的只读访问。ZIP 导入只在选定文件作用域有效期间读取，不授予网页文件系统能力。

Info.plist 包含 loopback HTTP 例外和 `NSAllowsLocalNetworking`。由于原版网页必须直接连接用户运行时配置的任意 HTTP Remote，固定域名例外无法穷举这些后端；因此还配置 WebKit 专用的 `NSAllowsArbitraryLoadsInWebContent`。这项例外覆盖应用内 WebKit 请求，范围宽于 loopback，必须明确说明，而不能称为仅允许本地 HTTP。

没有配置全局 `NSAllowsArbitraryLoads`。原生 GitHub URLSession 保留 ATS，并主动执行 HTTPS、官方仓库、资产和重定向校验。WebKit 例外不关闭 CORS、同源策略或 TLS 认证；明文 HTTP/WS 的凭据仍是明文传输，HTTPS/WSS 的保护需要远程服务支持。分发到 App Store 时还需按 Apple 文档说明该例外的用途。

远程 REST 和 WebSocket 由官方网页直接发出。REST 认证头触发正常 CORS 预检；WebSocket 使用远端 URL 上的 token 查询参数。应用不记录这些完整请求，不进行远程代理转发，也不修改 Surge、VPN 或系统路由。公开端点返回 401 只能证明连通性，不能记为认证或订阅成功。

## 验证入口

Core 测试位于 `Packages/ZashDockCore/Tests`，WebKit 与原生事务集成测试位于 `Tests/ZashDockIntegrationTests`。用例包含 ZIP/历史/快照安全边界、两个 Remote 的恢复、跨 Origin HTTP 预检和真实 WebSocket 握手。测试 fixture 的键、Remote 和 token 都是虚构数据。

构建采用实际 Xcode 工程和本地 SwiftPM Core。Xcode 27.1 的 arm64 Debug 构建已经成功；每阶段运行结果、未执行项及真实网络记录集中在 [TESTING.md](TESTING.md)，不以测试函数存在或 mock 通过代替全部验收。
