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

ZIP 的目录约定、大小和摘要都是本次发行的观测结果，不能代替对每个安装包的独立验证。验证应覆盖路径规范化、绝对路径和 `..`、符号链接、重复及大小写冲突路径、文件数量、累计解压字节、压缩比和必要文件；在验证完成前不能切换当前版本。临时下载和解压目录不应计入历史版本。

下载入口和每一次重定向均须使用 HTTPS。允许列表应只覆盖官方 GitHub API、发行下载入口及 GitHub 实际使用的发行资产 CDN，不能因为入口来自 GitHub 就放行任意重定向目标。资产摘要提供内容完整性校验，信任根仍是通过 HTTPS 获取的官方发行元数据。

## 离线导入的信任边界

ZIP 结构正确、文件名叫 `dist.zip`、页面标题相同，都不能证明归档来自官方。离线导入需要将实际 SHA-256 与此前可信取得并保存的官方 `dist.zip` digest 比较，或者与应用明确内置的官方发行摘要比较。匹配成功后，仍须完成完整 ZIP 安全验证。

若完全离线且没有该资产的可信摘要，不能将未知归档标记为“已验证官方发行”；应保留现有版本，说明无法验证来源，并允许用户联网取得官方元数据后重试。不得为了离线备用功能信任任意用户输入的摘要、第三方下载站或仅有版本名称的 ZIP。

## Remote 和 LocalStorage

官方[后端存储实现](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/store/setup.ts#L18)使用以下键：

| LocalStorage 键 | 内容 |
| --- | --- |
| `setup/api-list` | 序列化的 `Backend[]`，保存多个 Remote |
| `setup/active-uuid` | 当前选中 Remote 的 UUID 字符串 |
| `config/*` | 主题、语言、布局等网页设置 |
| `cache/*` 及其他键 | 网页自身管理的缓存和状态 |

[`Backend` 类型](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/types/index.d.ts#L6)包括 `type`、`protocol`、`host`、`port`、`secondaryPath`、`password`、`uuid`，以及可选标签和控制开关。`password` 包含敏感凭据；不得将存储内容、凭据或完整请求 URL 写入日志。本文不包含任何实际 Remote 或凭据。

官方 [`useStorage` 包装](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/composables/use-storage.ts#L5)采用 VueUse，配置 `writeDefaults: false`。网页初始化时会立即读取存储并执行旧数据迁移。ZashDock 必须在官方应用脚本执行之前恢复完整键值快照，不能在网页完成加载后再恢复。

官方[设置导出](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/helper/utils.ts#L41)仅处理 `config/`，不包含 `setup/`，因此不能将其当作 Remote 备份接口。原生快照应保留所有 LocalStorage 键和原始字符串值，不推测或重写上游数据结构；快照需加密，密钥存入 Keychain。

端口属于 Origin 的组成部分。跨端口恢复不能依赖旧端口仍能绑定，也不能依赖从旧网页临时读取配置；应用运行期间持续保存的独立快照是启动时旧端口被占用情形的恢复依据。

## IndexedDB 限制

LocalStorage 并非上游全部网页数据。官方还使用 IndexedDB：

- [`base64`](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/helper/indexeddb.ts#L102) 保存本地上传背景图，键为 `background-image`。
- [`connection-history`](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/helper/indexeddb.ts#L214) 保存按 Remote UUID 和聚合类型区分的连接历史。

仅迁移 LocalStorage 可以覆盖 Remote 及存于 LocalStorage 的设置，**不能宣称已迁移完整 Origin 数据**。背景图的设置值可能成功迁移，而其 IndexedDB 图像数据仍留在旧 Origin。若实现未迁移 IndexedDB，须在测试与用户说明中明确这一限制；缓存处理也不能删除这些数据库。

## PWA、缓存与版本切换

官方 [Vite PWA 配置](https://github.com/Zephyruso/zashboard/blob/v3.29.1/vite.config.ts#L36)使用相对路径 `base: './'` 和 `registerType: 'autoUpdate'`，预缓存 HTML、JavaScript、CSS、字体、图像等内容。发行包中的 `registerSW.js` 在 `load` 事件注册 `./sw.js`，作用域为 `./`。本次实际检查的生成 `sw.js` 包含：

- `self.skipWaiting()` 和 `clientsClaim()`；
- `precacheAndRoute(...)`，清单包含 `index.html`；
- `cleanupOutdatedCaches()`；
- 以 `index.html` 为响应的导航路由。

因此静态服务器设置 `Cache-Control: no-store` 仍不能单独保证网页显示当前安装版本。更新和回滚需要处理当前 Origin 的 Service Worker 注册、CacheStorage 以及 HTTP 资源缓存，并等待操作完成后重新创建或加载页面；只调用 `unregister()` 而继续使用原有受控页面，也不足以证明控制器已经退出。验证应确认页面实际加载当前版本资源，包含回滚至旧版和重启后加载场景。

清理范围必须限于受管面板的缓存数据类型。不能调用全类型 WebsiteDataStore 清理，不能删除 LocalStorage、IndexedDB、Remote 快照或 Keychain 密钥。Apple 提供独立的 [Service Worker 注册数据类型](https://developer.apple.com/documentation/webkit/wkwebsitedatatypeserviceworkerregistrations)和 [Fetch Cache 数据类型](https://developer.apple.com/documentation/webkit/wkwebsitedatatypefetchcache)，可作为选择性处理的依据。

## HTTP、WebSocket 和 CORS

官方 [HTTP 拦截器](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/api/http.ts#L7)将 REST 请求发往选中 Remote，并在需要时附加 Bearer 认证。[URL 构造函数](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/helper/utils.ts#L81)由协议、主机、端口和可选 `secondaryPath` 组成。原版网页直接访问远程后端，ZashDock 的本地静态服务器不需要也不应提供远程 HTTP 代理 API。

官方 [WebSocket 实现](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/api/clash.ts#L129)将 `http`/`https` 转为 `ws`/`wss`，并通过 `token` 查询参数传递认证信息；使用的流端点包括 `connections`、`traffic`、`memory`、`logs`。测试应分别验证 REST 请求与 WebSocket 握手及消息接收，不能用 REST 成功推断 WebSocket 可用。记录失败时须移除认证头和敏感查询参数。

面板的 `http://127.0.0.1:<port>` 与 Mihomo 地址属于不同 Origin。远程 Mihomo 必须允许实际面板 Origin；原生壳不能绕过浏览器 CORS。Mihomo 官方[外部控制配置文档](https://github.com/MetaCubeX/Meta-Docs/blob/main/docs/config/general.en.md#external-control-api)提供 `external-controller-cors.allow-origins` 和 `allow-private-network` 配置。采用精确 Origin 白名单时，修改本地端口后用户也需更新远程允许列表。应用不能自动修改 Surge、系统代理或远程内核配置。

LAN/VPN 连通性还取决于用户网络路由、Surge 运行模式、服务绑定地址和防火墙。必须在实际环境中记录结果；源码研究和本地模拟后端测试不构成 Surge/LAN/VPN 环境验收证据。

## 原生更新与网页内核更新的区别

官方 [`upgradeUIAPI`](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/api/clash.ts#L236)调用所选远程 Mihomo 的 `POST /upgrade/ui`；网页[自动更新逻辑](https://github.com/Zephyruso/zashboard/blob/v3.29.1/src/assembly/version.ts#L147)也可能触发它。该接口不管理 ZashDock 的本地发行目录。ZashboardUpdateManager 必须直接使用官方 GitHub Releases 及本地原子版本切换，不能借用 Mihomo `/upgrade/ui`。若产品禁止网页触发该路径，限制必须覆盖真实网络请求，并清楚提示原生更新入口，不能返回伪造的成功结果。

## 研究方法与实际执行记录

本次通过 `curl` 请求官方 GitHub API，下载固定标签源码归档和官方 `dist.zip`，使用系统 `shasum -a 256`、`unzip -l`、`unzip -p` 检查摘要、结构和生成文件，再对照固定标签 TypeScript/Vue 源码。未运行上游构建脚本，未安装依赖，未向上游发送本地配置或日志。此次研究文件位于 `/tmp/zashdock-research`，不属于 App Bundle 资源。
