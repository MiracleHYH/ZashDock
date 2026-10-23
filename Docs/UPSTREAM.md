# Zashboard 上游核验记录

核验日期：2026-10-23（Asia/Shanghai）。本文记录官方上游行为及其对 ZashDock 的约束，不替代本地构建和运行测试。以下源码链接固定在 `v3.29.1`，升级上游时应重新核验。

## 官方发行来源和 ZIP

- 官方仓库：[Zephyruso/zashboard](https://github.com/Zephyruso/zashboard)。
- 稳定版查询：[GitHub Releases latest API](https://api.github.com/repos/Zephyruso/zashboard/releases/latest)。检查响应的仓库归属、`draft == false`、`prerelease == false`，精确选择名为 `dist.zip` 的资产。
- 本次版本：[v3.29.1](https://github.com/Zephyruso/zashboard/releases/tag/v3.29.1)，发布时间为 `2026-09-23T08:17:27Z`。
- 固定版本元数据：[v3.29.1 API](https://api.github.com/repos/Zephyruso/zashboard/releases/tags/v3.29.1)。资产 ID 为 `583318399`。
- 固定下载地址：[v3.29.1/dist.zip](https://github.com/Zephyruso/zashboard/releases/download/v3.29.1/dist.zip)。下载大小为 **9,570,334 字节**。
- API 提供的 digest 为 `sha256:4f16cce229e223bd07b5a3daccfbfb8bf349d7335572d412959284ab6c9bab50`；本次通过 HTTPS 下载后，实际 SHA-256 与之相符。

官方[发布流水线](https://github.com/Zephyruso/zashboard/blob/v3.29.1/.github/workflows/deploy.yml#L84)执行 `zip -r dist.zip dist`。实测归档有 **324 个条目**，声明的解压总大小为 **12,140,880 字节**，使用单一顶层目录 `dist/`。必要文件包括 `dist/index.html`、`dist/assets/`；另有 `sw.js`、`registerSW.js`、`manifest.webmanifest`、图标和字体。ZashDock 应将 `dist/` 内容作为静态站点根目录，不能把 GitHub 自动生成的源码 ZIP 当作发行资产。

ZIP 的目录约定、大小和摘要都是本次发行的观测结果，不能代替对每个安装包的独立验证。验证应覆盖路径规范化、绝对路径和 `..`、符号链接、重复及大小写冲突路径、文件数量、累计解压字节、压缩比和必要文件；在验证完成前不能切换当前版本。临时下载和解压目录不属于已启用资源；当前页面验证成功后仅保留当前资源，不提供历史保留或回滚。

下载入口和每一次重定向均须使用 HTTPS。允许列表应只覆盖官方 GitHub API、发行下载入口及 GitHub 实际使用的发行资产 CDN，不能因为入口来自 GitHub 就放行任意重定向目标。资产摘要提供内容完整性校验，信任根仍是通过 HTTPS 获取的官方发行元数据。

## 本地导入的来源边界

按用户选择，本地 ZIP 导入接受用户选定的任意有效静态归档，完全离线执行，不验证官方身份、不匹配官方已知摘要，也不查询或缓存 GitHub 发行目录。生产代码不内置离线官方摘要 seed。文件名、页面标题和 ZIP 内容不能据此识别为某个官方版本；本地包统一记录为 `localArchive`，显示“本地导入（版本未知）”。

归档仍须通过路径、ZIP 结构、条目数、解压总量、压缩比、CRC、必要静态资源等安全检查，并在隔离 WebKit profile 中实际渲染验证后才可激活。复制后的 ZIP 自算 SHA-256 用于内部完整性校验，不作为官方来源证明。失败或取消时现有当前资源与日常 WebKit 配置保留。

在线下载安装继续只使用官方 GitHub Releases 的指定 `dist.zip`，验证 HTTPS、重定向来源、大小和官方摘要。本文前述 v3.29.1 摘要是研究时的实际观测，测试代码也用它确认指定样本；它不再构成生产本地导入的准入条件。

## Remote 和 LocalStorage

官方[后端存储实现](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/store/setup.ts#L18)使用以下键：

| LocalStorage 键 | 内容 |
| --- | --- |
| `setup/api-list` | 序列化的 `Backend[]`，保存多个 Remote |
| `setup/active-uuid` | 当前选中 Remote 的 UUID 字符串 |
| `config/*` | 主题、语言、布局等网页设置 |
| `cache/*` 及其他键 | 网页自身管理的缓存和状态 |

[`Backend` 类型](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/types/index.d.ts#L6)包括 `type`、`protocol`、`host`、`port`、`secondaryPath`、`password`、`uuid`，以及可选标签和控制开关。`password` 包含敏感凭据；不得将存储内容、凭据或完整请求 URL 写入日志。本文不包含任何实际 Remote 或凭据。

官方 [`useStorage` 包装](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/composables/use-storage.ts#L5)采用 VueUse，配置 `writeDefaults: false`。网页初始化时会立即读取存储并执行旧数据迁移。切换端口时必须在官方应用脚本执行之前完成存储恢复，不能在网页完成加载后再恢复。

官方[设置导出](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/helper/utils.ts#L41)仅处理 `config/`，不包含 `setup/`，因此不能将其当作 Remote 备份接口。文件导入同样只合并 `config/` 后 reload。端口转移应保留所有 LocalStorage 键和原始字符串值，不推测或重写上游数据结构。

端口属于 Origin 的组成部分。当前生产实现以默认持久 WebKit DataStore 保存日常数据；只在修改端口时，通过可信 `WebPage.load(simulatedRequest:responseHTML:)` 空文档读旧 Origin、恢复并核验新 Origin，然后加载官方网页、提交端口。旧端口被其他程序占用时不需要向它发出连接。原生不再常驻同步 Remote 或保存新加密快照；旧密文仅用于一次性只读兼容。实现和回归边界见 [STORAGE-DESIGN.md](STORAGE-DESIGN.md)。

## IndexedDB 限制

LocalStorage 并非上游全部网页数据。官方还使用 IndexedDB：

- [`base64`](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/helper/indexeddb.ts#L102) 保存本地上传背景图，键为 `background-image`。
- [`connection-history`](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/helper/indexeddb.ts#L214) 保存按 Remote UUID 和聚合类型区分的连接历史。

这两个数据库在 v3.29.1 均为 version 1，同名 objectStore、keyPath 为 `key`，没有 autoIncrement 或索引，记录为 `{key,value:string}`。背景图是 DataURL 字符串，历史是 JSON 字符串；官方设置导出均不包含。当前 `OriginStorageTransfer` 按这两种实际业务结构读取和恢复，并等待数据库事务完成；不实现任意 IndexedDB 迁移框架。

当前端口转移保留完整 LocalStorage、背景 DataURL 和连接历史，不能宣称已迁移全部 Origin 数据。Cookie、凭据、sessionStorage、通用 Blob/索引或未知数据库不在承诺范围。发现未知数据库、版本、schema、记录类型或超限输入时，提交前停止并保留源数据，不跳过未知内容后清理源。清理只清空已支持业务 objectStore 的记录，保留空 schema。

## PWA、缓存与版本切换

官方 [Vite PWA 配置](https://github.com/Zephyruso/zashboard/blob/v3.29.1/vite.config.ts#L36)使用相对路径 `base: './'` 和 `registerType: 'autoUpdate'`，预缓存 HTML、JavaScript、CSS、字体、图像等内容。发行包中的 `registerSW.js` 在 `load` 事件注册 `./sw.js`，作用域为 `./`。本次实际检查的生成 `sw.js` 包含：

- `self.skipWaiting()` 和 `clientsClaim()`；
- `precacheAndRoute(...)`，清单包含 `index.html`；
- `cleanupOutdatedCaches()`；
- 以 `index.html` 为响应的导航路由。

因此静态服务器设置 `Cache-Control: no-store` 仍不能单独保证网页显示当前安装版本。当前实现卸载旧 JavaScript 上下文，按明确类型清理应用 DataStore 中 loopback 记录的 Service Worker 注册、Fetch Cache、磁盘/内存缓存，并拒绝新的 Service Worker 脚本请求。新页面必须通过实际渲染和服务版本/nonce 验证；只调用 `unregister()` 或只等 HTTP 完成不构成版本验收。

清理不调用全类型 WebsiteDataStore 删除，不包含 LocalStorage、IndexedDB、Cookie 或凭据。WebKit 站点记录粒度不等于精确单端口，不能宣称只清理一个端口缓存。Apple 提供独立的 [Service Worker 注册数据类型](https://developer.apple.com/documentation/webkit/wkwebsitedatatypeserviceworkerregistrations)和 [Fetch Cache 数据类型](https://developer.apple.com/documentation/webkit/wkwebsitedatatypefetchcache)，用于选择性处理。

资源版本与用户数据没有一一对应的快照。更新或本地导入先将已支持业务数据复制到 `.nonPersistent()` DataStore，验证候选网页，再提交当前资源指针；持久 live 页面验证成功后删除非当前资源，只保留当前版本。旧安装的历史目录也在当前页面成功启动后清理。指针提交后 live 失败会保留新指针和旧资源并提示重载，不提前清理。产品不再提供回滚，也不创建用户数据的版本快照；资源替换不能撤销上游已执行的数据迁移。

## HTTP、WebSocket 和 CORS

官方 [HTTP 拦截器](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/api/http.ts#L7)将 REST 请求发往选中 Remote，并在需要时附加 Bearer 认证。[URL 构造函数](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/helper/utils.ts#L81)由协议、主机、端口和可选 `secondaryPath` 组成。原版网页直接访问远程后端，ZashDock 的本地静态服务器不需要也不应提供远程 HTTP 代理 API。

官方 [WebSocket 实现](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/api/clash.ts#L129)将 `http`/`https` 转为 `ws`/`wss`，并通过 `token` 查询参数传递认证信息；使用的流端点包括 `connections`、`traffic`、`memory`、`logs`。测试应分别验证 REST 请求与 WebSocket 握手及消息接收，不能用 REST 成功推断 WebSocket 可用。记录失败时须移除认证头和敏感查询参数。

面板的 `http://127.0.0.1:<port>` 与 Mihomo 地址属于不同 Origin。远程 Mihomo 必须允许实际面板 Origin；原生壳不能绕过浏览器 CORS。Mihomo 官方[外部控制配置文档](https://github.com/MetaCubeX/Meta-Docs/blob/main/docs/config/general.en.md#external-control-api)提供 `external-controller-cors.allow-origins` 和 `allow-private-network` 配置。采用精确 Origin 白名单时，修改本地端口后用户也需更新远程允许列表。应用不能自动修改 Surge、系统代理或远程内核配置。

LAN/VPN 连通性还取决于用户网络路由、Surge 运行模式、服务绑定地址和防火墙。必须在实际环境中记录结果；源码研究和本地模拟后端测试不构成 Surge/LAN/VPN 环境验收证据。

## 原生更新与网页内核更新的区别

官方 [`upgradeUIAPI`](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/api/clash.ts#L236)调用所选远程 Mihomo 的 `POST /upgrade/ui`；网页[自动更新逻辑](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/assembly/version.ts#L147)也可能触发它。该接口不管理 ZashDock 的本地发行目录。`ZashboardUpdateManager` 直接使用官方 GitHub Releases 和本地版本事务，不调用 Mihomo `/upgrade/ui`，也不把该接口的成功误报成本地升级。官方网页资源保持原样，不能把原生导航策略描述成拦截全部远程子资源请求。

ZashDock Wrapper 自身的 Sparkle 更新来自 [MiracleHYH/ZashDock](https://github.com/MiracleHYH/ZashDock)，与 Zashboard 网页更新分开；仓库配置与签名流程见 [RELEASING.md](RELEASING.md)。上游核验与首次源码推送阶段没有创建 Release。随后准备的 `v1.0.0` 为通过 GitHub 直接分发的正式版，无需上架 App Store；使用显式 ad hoc 模式，未经过 Developer ID 签名和 Apple 公证。正式版的更新包及稳定 Sparkle Feed 仍须通过专用密钥签名和验证，不能用 ad hoc 模式跳过更新完整性检查。Apple 分发身份及 Gatekeeper 限制独立于产品版本成熟度；功能与边界见 [v1.0.0 发行说明](https://github.com/MiracleHYH/ZashDock/blob/main/Docs/RELEASE-NOTES-1.0.0.md)。

## 研究方法与实际执行记录

本次通过 `curl` 请求官方 GitHub API，下载固定标签源码归档和官方 `dist.zip`，使用系统 `shasum -a 256`、`unzip -l`、`unzip -p` 检查摘要、结构和生成文件，再对照固定标签 TypeScript/Vue 源码。未运行上游构建脚本，未安装依赖，未向上游发送本地配置或日志。此次研究文件位于 `/tmp/zashdock-research`，不属于 App Bundle 资源。
