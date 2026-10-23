# Apple API 核对记录

核对日期：2026-10-23（Asia/Shanghai）。目标 macOS 26.0+、arm64。本文件记录当前实现使用的公开接口与边界，不把 API availability 当作运行验收。架构见 [ARCHITECTURE.md](ARCHITECTURE.md)，实际命令和结果见 [TESTING.md](TESTING.md)。

## 核对方法与环境

优先查阅下列 Apple 官方文档，动态页面另读取同地址 `.md` 内容及其 availability 元数据，并对照本机 Xcode SDK 的公开 Swift interface/头文件。不能因较新 SDK 包含某个成员，就忽略成员的最低系统版本。

当前实际运行环境为 macOS 27.0.1、Xcode 27.1。已有 arm64 Debug 和 macOS 26.5 SDK 编译证据；这不代表已在 macOS 26.0 实机运行，也不代表系统重启或断电恢复已经测试。完整执行范围由测试记录限定。

## 系统应用菜单与关于面板

`Settings` Scene 自带 macOS 应用菜单“设置…”与 ⌘,，无需在主窗口重复添加齿轮或创建 MenuBarExtra。`CommandGroup(replacing: .appInfo)` 用于提供“关于 ZashDock”命令。[Settings](https://developer.apple.com/documentation/swiftui/settings)、[appInfo](https://developer.apple.com/documentation/swiftui/commandgroupplacement/appinfo)。

关于命令调用 `NSApplication.orderFrontStandardAboutPanel(options:)`。`.applicationVersion` 对应应用营销版本，`.version` 对应应用构建号，不能将 Zashboard 版本作为 ZashDock 构建号。当前显式清空默认版本项，通过 `.credits` 的 `NSAttributedString` 同时写出两个名称和完整版本，使用系统字体与自动文本颜色。SDK 头文件明确说明空 `.version` 留空；显式空 `.applicationVersion` 对默认值的覆盖另由实际原生界面验证。[标准关于面板](https://developer.apple.com/documentation/appkit/nsapplication/orderfrontstandardaboutpanel(options:))、[version](https://developer.apple.com/documentation/appkit/nsapplication/aboutpaneloptionkey/version)、[credits](https://developer.apple.com/documentation/appkit/nsapplication/aboutpaneloptionkey/credits)。

## WebKit for SwiftUI 与数据容器

`WebPage`、`WebView` 和 `WebPage.Configuration` 是 macOS 26 的公开 API，页面及配置在 MainActor 上使用。配置直接提供 `websiteDataStore` 和 `userContentController`，不需要用 `NSViewRepresentable` 包装旧式 `WKWebView` 获得这两项能力。[WebPage](https://developer.apple.com/documentation/webkit/webpage)、[WebView](https://developer.apple.com/documentation/webkit/webview-swift.struct)、[Configuration](https://developer.apple.com/documentation/webkit/webpage/configuration)。

| 使用位置 | DataStore | 目的 |
| --- | --- | --- |
| 日常官方网页 | `.default()` | 由 WebKit 将网站数据持久保存到磁盘 |
| 按需端口转移的可信文档 | 同一 `.default()` | 读取旧 Origin、恢复并核验目标 Origin |
| 新安装/更新候选预检 | 新建 `.nonPersistent()` | 隔离候选代码，仅使用内存，不写真实用户容器 |
| 自动测试 | 注入隔离容器 | 避免访问生产配置、网站数据和 Keychain |

Apple 明确区分默认持久容器与不写盘的内存容器。使用 `.nonPersistent()` 预检不改变生产持久化选择；它不是日常页面的数据源。[default()](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/default())、[nonPersistent()](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/nonpersistent())。

当前不再用用户脚本持续镜像 Remote；WebKit 日常写入不经原生 flush 或 seed 回放。公开接口没有提供本项目需要的 Origin 重命名参数；`fetchData`/`restoreData` 的不透明容器数据也没有 Origin 重映射参数。本实现不编辑 WebKit 内部文件或依赖私有 SPI。[fetchData](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/fetchdata(of:completionhandler:))、[restoreData](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/restoredata(_:completionhandler:))。

## 可信模拟响应与按需脚本

macOS 26 提供 `WebPage.load(simulatedRequest:responseHTML:)`，将应用传入的 HTML 解释为指定请求的响应，并返回可观察加载进度的异步序列。[官方声明](https://developer.apple.com/documentation/webkit/webpage/load(simulatedrequest:responsehtml:))。

`OriginStorageTransfer` 以精确 `http://127.0.0.1:<port>/__zashdock_origin_transfer` 创建可信空文档，不加载官方脚本或外部资源。CSP 禁止连接、资源、worker、frame 和表单，导航策略只允许这一次初始导航。随后固定脚本检查主框架和预期 Origin，再读写已支持的存储。旧端口被其他监听器占用且无网络请求的行为由实际测试证明，不能仅从 API 名称推断。

`callJavaScript(_:arguments:in:contentWorld:)` 接受异步函数体和独立参数，`in:nil` 指向主框架。生产实现用 JSON 字符串参数承载数据，避免将 Remote 内容拼成代码或把特殊键转换成 JavaScript 对象字面量。数据库事务必须完成并核验后才提交端口。[callJavaScript](https://developer.apple.com/documentation/webkit/webpage/calljavascript(_:arguments:in:contentworld:))。

该流程是应用实现的有限业务迁移，不是 Apple 自动迁移全部 Origin 的承诺。仅支持完整 LocalStorage 和官方两个指定 schema 的 IndexedDB；Cookie、凭据、任意 Blob/索引和所有 WebsiteData 不在迁移声明中。

## 导航、加载与原生对话框

`WebPage.NavigationDeciding` 提供 action/response 导航决策；当前本地网页只允许精确 Origin 的主框架导航。`WebPage.NavigationAction` 使用 `source`、`target` 和 `request`，不能照搬旧 `WKNavigationAction` 的属性名。[NavigationDeciding](https://developer.apple.com/documentation/webkit/webpage/navigationdeciding)、[NavigationAction](https://developer.apple.com/documentation/webkit/webpage/navigationaction)。

外部 HTTP/HTTPS 主框架导航经 `NSWorkspace.open(_:)` 交给系统浏览器，不放行任意 `file:`、`javascript:` 或自定义 scheme。导航策略不等于 REST、WebSocket 或子资源过滤器。[NSWorkspace.open](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:))。

`WebSession` 持续观察公开 `WebPage.navigations`，对后续主文档重新执行渲染及服务身份验证；区分取消、外部策略交接和真正导航/网页进程失败。失败显示原生重载入口；没有需要暂停的原生 Remote 保存队列。[navigations](https://developer.apple.com/documentation/webkit/webpage/navigations)、[NavigationError](https://developer.apple.com/documentation/webkit/webpage/navigationerror)。

`WebPage.DialogPresenting` 接入原生 alert/confirm/prompt/文件选择。`WebInteractionCoordinator` 对来自授权页面的请求使用系统面板；文档切换会取消面板，异步返回仍检查文档 generation，避免把旧文档结果交给新文档。[DialogPresenting](https://developer.apple.com/documentation/webkit/webpage/dialogpresenting)。

## 受限文件交互脚本

`WebPage.Configuration.userContentController` 可直接配置 `WKUserScript` 与消息处理器。文档开始注入和隔离内容世界仅用于当前文件交互：跟踪官方 Blob 导出、真实用户手势及文档生命周期，不用于 Remote 持久化。[userContentController](https://developer.apple.com/documentation/webkit/webpage/configuration/usercontentcontroller)、[WKUserScript](https://developer.apple.com/documentation/webkit/wkuserscript/init(source:injectiontime:formainframeonly:in:))、[内容世界消息处理器](https://developer.apple.com/documentation/webkit/wkusercontentcontroller/add(_:contentworld:name:))。

`.atDocumentStart` 是文档开始的脚本时机，`.page` 与隔离 `WKContentWorld` 拥有不同 JavaScript 命名空间。当前代码在隔离世界捕获可信手势，在页面世界处理上游实际使用的导出对象；不把网页可见 token 当成隐蔽密钥。[注入时机](https://developer.apple.com/documentation/webkit/wkuserscriptinjectiontime/atdocumentstart)、[WKContentWorld](https://developer.apple.com/documentation/webkit/wkcontentworld)。

接收端独立核对固定通道、内容世界、主框架、精确 `securityOrigin` 与 frame URL，再验证消息格式、MIME、文件名、数据上限和一次性手势。`forMainFrameOnly` 只限制脚本注入，不能代替接收端校验。`WKScriptMessage.frameInfo` 是 `WKFrameInfo`，区别于 `WebPage.FrameInfo`。[frameInfo](https://developer.apple.com/documentation/webkit/wkscriptmessage/frameinfo)、[WKFrameInfo.securityOrigin](https://developer.apple.com/documentation/webkit/wkframeinfo/securityorigin)。

保存地址只能由原生保存面板返回，网页不能提供原生绝对路径。pagehide 和 BFCache persisted pageshow 撤销手势、取消未完成面板；异步返回后仍检查文档代次。生产没有通用文件写入、命令执行或远程 HTTP 代理桥接。

## 选择性缓存清理

`WKWebsiteDataStore.dataRecords(ofTypes:)` 是 `fetchDataRecords(ofTypes:completionHandler:)` 的异步形式；不能误写成不存在的异步 `fetchDataRecords(ofTypes:)`。`removeData(ofTypes:for:)` 只删除指定数据类型和记录。[读取记录](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/fetchdatarecords(oftypes:completionhandler:))、[按记录删除](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/removedata(oftypes:for:completionhandler:))。

`WebCacheController` 选择本应用 DataStore 的 loopback 记录，仅包含以下可丢弃类型：

- [Service Worker 注册](https://developer.apple.com/documentation/webkit/wkwebsitedatatypeserviceworkerregistrations)
- [Fetch Cache](https://developer.apple.com/documentation/webkit/wkwebsitedatatypefetchcache)
- [磁盘缓存](https://developer.apple.com/documentation/webkit/wkwebsitedatatypediskcache)
- [内存缓存](https://developer.apple.com/documentation/webkit/wkwebsitedatatypememorycache)

不调用 `allWebsiteDataTypes()`，不清 LocalStorage、IndexedDB、Cookie 或凭据。记录粒度不是任意精度的端口筛选；该实现只能称为本应用的 loopback 缓存处理。停止旧上下文、拒绝新 SW 注册、清缓存和验证实际页面共同约束版本显示，不能用 `no-store` 单独替代。

## 旧密文只读兼容

`KeychainLegacyStorageKeyReader` 只通过 `SecItemCopyMatching` 查询已有密钥，没有 SecItemAdd/Update/Delete。没有旧文件时不查询。`LegacyWebStorageReader` 使用 CryptoKit AES-GCM 认证 v1 密文和附加头，主文件失败才尝试同一密钥下的备份；不生成密钥、修复或写新文件。[SecItemCopyMatching](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))、[AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm)。

认证字典在官方网页初始化前恢复并验证，普通配置提交一次性标记后不再重放。此处加密只是读取旧格式的兼容能力，不能描述成对整个 WebKit DataStore 的应用层加密。

## 网络、ATS 与 Sandbox

本地服务使用 `NWListener`、`NWParameters.requiredLocalEndpoint` 明确指定 `127.0.0.1:<port>`。有效性以实际 `.ready` 及端口校验为准，不根据提前探测或配置值宣布可用。[NWListener](https://developer.apple.com/documentation/network/nwlistener)、[requiredLocalEndpoint](https://developer.apple.com/documentation/network/nwparameters/requiredlocalendpoint)。

Info.plist 配置 `127.0.0.1` 的 HTTP 例外、`NSAllowsLocalNetworking`，以及 WebKit 专用 `NSAllowsArbitraryLoadsInWebContent`，用于官方网页直接访问用户运行时配置的任意 HTTP Remote。macOS 14 起，Apple 允许通过异常域配置单个 IP/CIDR；不能沿用旧系统的“IP 不可配置例外”结论。[本地网络 ATS 文档](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)。

WebKit 例外宽于 loopback，Apple 明确说明它不影响原生 URLSession 的 ATS；项目未配置全局 `NSAllowsArbitraryLoads`。原生下载仍主动校验 HTTPS、官方仓库和全部重定向。该例外不关闭 CORS/同源策略，也不代表明文 HTTP/WS 具有 TLS 保护；App Store 审核需说明例外用途。[WebKit 专用 ATS 例外](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloadsinwebcontent)。

entitlements 启用 App Sandbox、网络 client/server 和用户选择文件的读写范围；ZIP/网页文件选择在安全作用域中访问。应用不修改系统代理、Surge 或远端 Mihomo 配置。LAN/VPN、Surge、REST 与 WebSocket 必须分别记录实际结果，不能从 entitlements 或编译成功推断连通。
