# ZashDock 架构

本文描述 2026-10-23 当前源码。日常网页数据由 WebKit 持久化；原生只保存应用设置、官方发行元数据及网页资源版本。旧审计中出现的常驻存储桥接、原生加密快照和退出前 flush 已移除，不是现有架构。存储细节见 [STORAGE-DESIGN.md](STORAGE-DESIGN.md)，实际构建和验收边界见 [TESTING.md](TESTING.md)。

## 组件与并发隔离

应用使用 SwiftUI `Window`、独立 `Settings` Scene、`WebView`/`WebPage`、Swift Concurrency 和 `@Observable`。目标为 macOS 26+、arm64。Core 以本地 Swift Package 接入 Xcode；ZIP 解压使用系统 zlib，Wrapper 更新通过 SwiftPM 接入 Sparkle。不引入 Node.js、Electron、Tauri、Docker 或 Mihomo Kernel。

| 组件 | 隔离方式 | 职责 |
| --- | --- | --- |
| `AppModel` | `@MainActor @Observable` | 启动状态、安装编排、端口与版本事务 |
| `WebSession` | `@MainActor @Observable` | 创建网页、渲染与服务身份验证、运行时错误处理 |
| `OriginStorageTransfer` | `@MainActor` | 可信空文档中的限额读取、恢复、核验和提交后清理 |
| `WebInteractionCoordinator` | `@MainActor` | 原生网页对话框、文件选择与受限导出 |
| `LegacyWebStorageReader` | `Sendable` 值类型 | 一次性只读兼容旧 AES-GCM LocalStorage 文件 |
| `ZashboardUpdateManager` | `@MainActor @Observable` | 官方网页版本检查、下载进度、取消、准备和清理 |
| `ReleaseClient` | `actor` | 官方 HTTPS 元数据、资产来源、大小与 SHA-256 验证 |
| `VersionStore` | `actor` | 版本目录、内容清单、当前指针、历史顺序和清理报告 |
| `LoopbackHTTPServer` | 主线程入口、内部串行队列 | loopback 绑定、受限静态文件读取与流式发送 |
| `SafeZIPExtractor` | 无共享可变状态的值类型 | ZIP 结构、路径、资源上限、解压和 CRC 校验 |
| `ConfigurationStore` / `AtomicFile` | 同步值类型和工具 | 普通配置验证、原子提交与小型恢复镜像 |
| `WrapperUpdateController` | `@MainActor @Observable` | ZashDock 自身的 Sparkle 签名更新入口 |

HTTP 服务内部对象由独立串行 DispatchQueue 管理，不是 Swift actor。其 `@unchecked Sendable` 依赖队列约束。AppModel 串行化安装、端口与版本操作；下载阶段可继续显示旧网页，替换网页前卸载旧 JavaScript 和连接，再停止旧监听器，任何时刻最多一个本地 HTTP 监听器。

主窗口按启动、未安装、安装中、就绪、安装损坏、服务不可用或配置恢复状态呈现原生内容。没有有效安装时不会进入空白 WebView。AppDelegate 处理 Dock 重开、关闭最后窗口后的行为以及退出时取消/等待当前操作、卸载页面和停止服务；没有原生 Remote 保存队列或保存失败退出选项。

## 持久化布局与权威来源

`AppPaths.application()` 取得 Application Support 后追加稳定标识 `app.zashdock.mac`。App Sandbox 下由系统映射到容器，代码不硬编码容器路径。

```text
<Application Support>/app.zashdock.mac/
  configuration.json                 # 普通设置，唯一端口提交点
  configuration.last-valid.json      # 已提交普通设置的小型恢复镜像
  configuration-recovery/...         # 用户显式恢复前保全的原设置文件
  official-releases.json             # 可信官方发行元数据缓存
  versions-state.json                # 当前资源指针、激活顺序、清理报告
  versions/<version-id>/
    manifest.json
    content/index.html
    content/assets/...
  staging/...                        # 未完成下载与解压
  storage.aesgcm[.backup]             # 仅已有旧安装可能存在，只读兼容

WebKit 默认持久 DataStore（位置由 WebKit 管理）
  http://127.0.0.1:<当前端口>
    LocalStorage
    IndexedDB: base64 / connection-history
    其他由 WebKit 管理的网站数据
```

`configuration.json` 仅包含端口、历史保留数、窗口行为、`pendingOriginCleanup` 和 `legacyStorageImported`，不含 Remote、Secret 或网页配置。正常加载只读主文件，不自动选择恢复镜像。镜像用于原生界面显式恢复原端口，不能成为另一份 Remote 数据源。

`save` 原子写入主文件后，尽力更新镜像；镜像失败不能把已经提交的端口报告为失败。清理旧 Origin 前必须先成功 `ensureRecoveryCopy`。因此镜像滞后时，它指向的旧业务数据仍保留。主文件损坏或丢失但有镜像时进入恢复界面；没有有效端口元数据时由用户指定原端口，不静默改用 9099。

`AtomicFile` 使用同目录、`0600` 临时文件，写入同步后 `rename` 替换并尝试同步父目录；受管目录使用 `0700`。HTTP 根目录仅为所选版本的 `content/`，不暴露配置、旧密文或恢复镜像。

## 安装与资源验证

Bundle 不包含 Zashboard dist。首次安装和手动更新使用 Zephyruso/zashboard 官方稳定 Release，排除 draft/prerelease，精确选择带可信 SHA-256 的 `dist.zip`。URLSession 为临时会话，入口、每次重定向和最终 URL 均验证 HTTPS 与官方 GitHub 资产来源。下载增量写入并计算摘要，核对声明及实际大小；取消和失败删除临时下载。

本地 ZIP 通过已缓存的可信官方摘要或内置 v3.29.1 发行摘要识别。内置内容只有元数据，没有网页资源。未知摘要的离线归档不能因名称或结构相同而获得官方身份。`BoundedZIPInput` 以 `O_NOFOLLOW` 打开普通文件、限额复制并检查身份/修改，再校验私有副本摘要。

`SafeZIPExtractor` 先验证记录，再写入新的私有 staging 目录：

| 项目 | 上限 |
| --- | --- |
| ZIP 大小 | 128 MiB |
| 累计展开大小 | 256 MiB |
| 单文件展开大小 | 64 MiB |
| 条目数 | 20,000 |
| 单条目压缩比 | 250 |

解析器验证中央目录、本地头、UTF-8 名称、数据描述符、记录边界及 CRC，拒绝 ZIP64、加密、特殊文件、符号链接、路径穿越、重复及大小写/Unicode 冲突。只有 `index.html` 与必要 JavaScript 资源有效，才生成含文件大小和 SHA-256 的 `manifest.json`。读取/激活已安装版本也验证实际文件；目录存在不等于安装有效。

校验后的候选移入版本目录，尚不改变当前指针。staging 和未激活候选不计入历史；失败不会预删旧版。网页代码预检和资源提交顺序见下文。

## 本地 HTTP 与 WebKit 边界

`NWListener` 仅绑定 `127.0.0.1:<port>`，关闭端点重用和点对点接口，收到 `.ready` 并核对端口后才算绑定成功。连接还验证 IPv4 loopback 对端。HTTP 只支持 GET/HEAD，要求精确 Host；存在 Origin 时须匹配当前站点。拒绝跨站请求、Service Worker 脚本请求、重复标头、请求体和 Transfer-Encoding。头部限 16 KiB、目标限 4096 字节、连接限 32，并设读写期限。

路径只解码一次；持有根目录描述符，通过逐级 `openat`/`O_NOFOLLOW` 访问目录与普通文件，复核身份、长度及修改，避免逃出受管目录。文件按 64 KiB 块发送，全局待发块预算 2 MiB。只有无扩展名路径可回退 `index.html`，资源缺失返回 404。响应包含明确 MIME、`nosniff`、`no-store` 和无 Referrer 策略。

唯一动态路由 `/__zashdock_health` 返回版本 ID 与启动 nonce，用于核验当前绑定实例。服务器没有命令执行、文件写入、配置修改、远程 HTTP 代理端点。

生产 `WebSession` 使用 `WKWebsiteDataStore.default()`。网页自己正常读写 LocalStorage/IndexedDB；原生不包装 Storage 方法、不周期轮询、不接收 Remote 快照、不在 reload 时回放 seed。加载验证等待 `#app` 实际内容并核验版本/nonce；持续观察 `WebPage.navigations`，运行时失败显示原生重新载入入口。

本地精确 Origin 的主框架导航可留在应用内，外部 HTTP/HTTPS 主框架导航交系统浏览器。该策略不是 REST/WebSocket 子资源过滤器。官方网页直接连接 Mihomo；连接的 CORS、认证、TLS 与网络路由仍由浏览器和远端约束。

`WebInteractionCoordinator` 保留有限的文件交互脚本，区别于已删除的存储桥接。消息验证内容世界、主框架、SecurityOrigin、格式、MIME、文件名及数据大小，导出需一次真实手势，位置仅由原生保存面板返回。文档切换/恢复撤销旧授权、取消面板，并在异步返回后验证文档代次；不提供任意路径写入或命令能力。

## 端口事务

默认 9099，用户可输入 1024–65535；自动选择仅由明确按钮触发，在 9099–9198 中实际尝试绑定，成功后持久保存。没有静默换端口。

`AppModel.changePort` 的顺序为：

1. 完成必要的一次性旧密文导入；若上次仍待清理旧 Origin，先完成该清理，避免覆盖标记。
2. 卸载网页、停止旧监听器。通过可信模拟响应读取旧 Origin 的完整 LocalStorage 及两种受支持业务 IndexedDB 到临时内存，不请求旧端口。
3. 实际绑定目标端口，在目标 Origin 恢复并读回核验；已有安装时加载官方页面，验证渲染及服务身份。
4. 原子保存新端口和 `pendingOriginCleanup=旧端口`，这是唯一持久提交点。
5. 采用新页面/服务。先确保当前普通配置恢复镜像可用，再清空旧 Origin 的 LocalStorage 和两个业务 objectStore，最后清除待清理标记。

提交前失败关闭候选，尝试清空未提交目标并恢复旧服务；旧配置与源 Origin 不清除。提交后清理失败保留新配置及标记，下次启动重试，不把操作谎报为端口未改变。清空不删除 IndexedDB schema，也不删除 Cookie 等未迁移数据。WebKit 的这些多步写入不是跨数据库原子事务；安全性来自提交前保留源数据及提交后幂等清理。

旧端口被别的程序占用时，同一持久 DataStore 中的可信 `load(simulatedRequest:responseHTML:)` 文档仍可访问旧 Origin；实测路径不会向占用者发送请求。迁移仅覆盖当前已知官方业务格式，发现未知数据库/schema 或超限数据则提交前停止，详见存储文档。

## 更新、回滚与历史清理

资源版本与网页数据分离，更新/回滚保持同一端口和持久 DataStore。没有随版本保存或回放用户配置。

1. 下载、解压、清单及文件验证完成后卸载旧网页，停止旧监听器。
2. 读取当前业务数据到内存；候选服务绑定同一端口，将数据恢复到新建 `.nonPersistent()` DataStore，在其中执行候选官方网页并验证渲染及服务身份。
3. 预检成功、取消检查通过后，原子提交 `versions-state.json` 的当前资源指针。
4. 清理持久容器中的可丢弃缓存，启动当前版本的持久 live 页面。此时才允许新网页在真实数据上执行自身迁移。
5. live 页面验证成功后执行历史清理。

提交前失败不会让候选代码接触持久网页数据，恢复原服务/页面，保留原资源指针。指针提交后 live 失败则保留新指针和历史资源，显示重载入口，**不自动回退指针，也不清理历史**。因为新代码此时可能已修改持久数据，不能承诺资源回退等于网页数据回滚。手动回滚也需预检；上游数据 schema 的向后兼容性仍有实际边界。

历史按激活顺序维护，回滚也是一次激活。`maxRollbackVersions=N` 默认 1、范围 0–100，不含当前版本。清理先验证健康历史再保留最近 N 个；损坏历史不挤占名额，有明确清理/损坏报告。当前及显式保护的活跃版本不删除，短暂保护解除后再执行上限。权限、枚举错误或取消不能伪装成损坏并删除。清理仅作用于资源版本目录，不触及网页数据、旧密文或普通设置。

## 缓存、安全与发布边界

官方包包含 PWA 注册与 Workbox 缓存。`WebCacheController` 仅对本应用 DataStore 中 loopback 记录删除 Service Worker 注册、Fetch Cache、磁盘及内存缓存；不调用全类型清理，不删除 LocalStorage、IndexedDB、Cookie 或凭据。站点记录粒度不是精确端口选择器，因此不声称只清某个端口缓存。服务器同时拒绝新的 Service Worker 脚本加载。

Bundle ID 固定 `app.zashdock.mac`。Sandbox 允许 network.client/server 和用户选定文件读写；Sparkle 使用其所需的命名 Mach 服务例外。原生 GitHub 请求保持 ATS，并独立验证官方来源。Info.plist 有 loopback HTTP、本地网络及 WebKit 专用 `NSAllowsArbitraryLoadsInWebContent` 例外，以支持用户运行时配置的任意 HTTP Remote；该范围宽于 loopback，不等于全局关闭 ATS，也不绕过 CORS 或 TLS 验证。HTTP/WS 上的凭据仍是明文传输。

旧密文兼容器只读取已有 Keychain 密钥并认证旧文件，不生成密钥、写新密文、轮换或修复原文件。成功恢复并核验 WebKit 后才提交一次性标记；失败保留文件和标记，允许重试。新安装没有旧文件就不访问 Keychain。WebKit 自身数据不增加原生应用层加密。

Zashboard 网页更新来自 Zephyruso/zashboard；ZashDock 应用更新来自 MiracleHYH/ZashDock 的 Sparkle 签名发布包，两条流程分离。Mihomo `/upgrade/ui` 不管理本地资源，ZashDock 的更新流程不调用它。签名和发布要求见 [RELEASING.md](RELEASING.md)，本轮开发不创建 Release。

## 验证范围

Core 覆盖 ZIP、资源历史、普通元数据和只读旧文件兼容；App 宿主覆盖两个官方格式 Remote、选中项、业务 IndexedDB、旧端口被占、目标绑定/元数据失败、清理重试、更新回滚、缓存和原生交互。测试使用隔离临时目录及 DataStore，不操作生产 Remote 或 Keychain。

实际执行结果、跨进程证据及未执行项集中在 [TESTING.md](TESTING.md)。API 的 macOS 26 availability 和 SDK 编译不代表已在 macOS 26 实机或系统重启后验收；当前运行证据来自 macOS 27.0.1。历史 [AUDIT-2026-10-23.md](AUDIT-2026-10-23.md) 是问题发现时的记录，现状以当前源码和修复记录为准。
