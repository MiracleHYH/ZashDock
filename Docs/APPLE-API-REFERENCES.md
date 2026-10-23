# Apple API 核对记录

核对日期：2026-10-23（Asia/Shanghai）。目标系统为 macOS 26.0 及以上，目标架构为 arm64。

本文记录 Apple 官方文档与本机 SDK 中已经确认的声明。API 可用性核对不等同于实际运行验收；涉及 WebKit 网络行为、Service Worker 生命周期和签名沙盒的结论仍需在实际构建中验证。

## 核对依据

- [WebKit for SwiftUI / WebPage](https://developer.apple.com/documentation/webkit/webpage)
- [WebPage.Configuration](https://developer.apple.com/documentation/webkit/webpage/configuration)
- 本机 SDK 的 `WebKit.framework/Versions/A/Modules/WebKit.swiftmodule/arm64e-apple-macos.swiftinterface`，位于 `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/`。
- 同一 SDK 的 `WKUserScript.h`、`WKUserContentController.h`、`WKScriptMessageHandler.h`、`WKWebsiteDataStore.h` 和 `WKSecurityOrigin.h`。

本机 SDK 接口包含较新系统的声明，因此必须按每个成员的 `@available` 核对，不能因为 SDK 中存在某个成员就把它用于 macOS 26.0。

## WebPage 与持久化配置

`WebPage`、`WebPage.Configuration`、`WebPage.NavigationDeciding` 和 `WebPage.FrameInfo` 均自 macOS 26.0 可用。`WebPage` 与配置访问受 `MainActor` 隔离。

SDK 确认以下声明：

```swift
// WebPage 内的嵌套配置类型
@MainActor
public struct Configuration {
    public init()
    public var websiteDataStore: WKWebsiteDataStore
    public var userContentController: WKUserContentController
}

// WebPage 的初始化器
@MainActor
convenience init(
    configuration: WebPage.Configuration = Configuration(),
    navigationDecider: some WebPage.NavigationDeciding
)
```

以上分别摘录嵌套类型及初始化器声明，实际调用为：

```swift
var configuration = WebPage.Configuration()
configuration.websiteDataStore = .default()
configuration.userContentController = controller
let page = WebPage(configuration: configuration, navigationDecider: decider)
```

原生 `WebPage` 可直接配置 `WKUserContentController`，不需要通过 `NSViewRepresentable` 包装 `WKWebView` 来取得脚本桥接功能。[userContentController 官方声明](https://developer.apple.com/documentation/webkit/webpage/configuration/usercontentcontroller)。

`WKWebsiteDataStore.default()` 是持久化存储，可跨启动保存网站数据；不能使用 `.nonPersistent()`。[websiteDataStore](https://developer.apple.com/documentation/webkit/webpage/configuration/websitedatastore)、[default()](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/default())。

## 导航策略

协议要求的准确签名如下；提供默认实现的成员可以按需要实现：

```swift
@MainActor
mutating func decidePolicy(
    for action: WebPage.NavigationAction,
    preferences: inout WebPage.NavigationPreferences
) async -> WKNavigationActionPolicy

@MainActor
mutating func decidePolicy(
    for response: WebPage.NavigationResponse
) async -> WKNavigationResponsePolicy
```

[NavigationDeciding](https://developer.apple.com/documentation/webkit/webpage/navigationdeciding)、[动作策略方法](https://developer.apple.com/documentation/webkit/webpage/navigationdeciding/decidepolicy(for:preferences:))。

`NavigationAction` 的相关成员是：

```swift
var source: WebPage.FrameInfo { get }
var target: WebPage.FrameInfo? { get }
var request: URLRequest { get }
var navigationType: WKNavigationType { get }
```

不能把旧 `WKNavigationAction` 的 `sourceFrame` / `targetFrame` 名称用于这里。[NavigationAction](https://developer.apple.com/documentation/webkit/webpage/navigationaction)。

应仅允许本地服务的精确 Origin 在应用中作为页面导航；外部 HTTP/HTTPS 链接取消 WebKit 导航，并通过 `NSWorkspace.shared.open(_:)` 交给系统浏览器。`target == nil` 的新窗口导航也必须处理。禁止把 `javascript:`、`file:` 或任意自定义 scheme 作为外部 URL 打开。[NSWorkspace.open(_:)](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:))。

导航策略只处理页面导航，不能把它误当成 REST、WebSocket 或子资源请求的访问控制器。

## JavaScript 调用与文档开始注入

`WebPage` 在 macOS 26.0 提供以下异步方法：

```swift
@MainActor
@discardableResult
func callJavaScript(
    _ functionBody: String,
    arguments: [String: Any] = [:],
    in frame: WebPage.FrameInfo? = nil,
    contentWorld: WKContentWorld? = nil
) async throws -> sending Any?
```

传入的是异步函数体；`in: nil` 表示主框架。配置快照等动态值应通过 `arguments` 或安全的 JSON 编码传入，不能拼接未经编码的配置字符串。[callJavaScript](https://developer.apple.com/documentation/webkit/webpage/calljavascript(_:arguments:in:contentworld:))。

`WKUserScript` 和 `WKUserContentController` 是当前 `WebPage` 明确支持的配置对象。以下脚本初始化器及带内容世界的消息处理器自 macOS 11.0 可用，因此可用于本项目的 macOS 26.0 目标：

```swift
WKUserScript(
    source: script,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: true,
    in: .page
)

controller.add(handler, contentWorld: .page, name: "zashdockStorage")
```

[WKUserScript 初始化器](https://developer.apple.com/documentation/webkit/wkuserscript/init(source:injectiontime:formainframeonly:in:))、[add(_:contentWorld:name:)](https://developer.apple.com/documentation/webkit/wkusercontentcontroller/add(_:contentworld:name:))。

`.atDocumentStart` 在文档元素创建后、其他网页内容加载前注入。因此迁移快照应嵌入该脚本并同步写入 LocalStorage，不能等待 `.finished` 后才恢复，也不能在恢复前执行 `await`。[注入时机](https://developer.apple.com/documentation/webkit/wkuserscriptinjectiontime/atdocumentstart)。

需要包装网页实际使用的 `Storage.prototype` 方法时应在 `.page` 世界执行；隔离世界中的 JavaScript 全局对象修改不会自动影响网页自己的全局对象。[WKContentWorld](https://developer.apple.com/documentation/webkit/wkcontentworld)、[page](https://developer.apple.com/documentation/webkit/wkcontentworld/page)。

## 消息来源与能力边界

消息处理协议的方法为：

```swift
func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
)
```

[WKScriptMessageHandler](https://developer.apple.com/documentation/webkit/wkscriptmessagehandler)。

原生接收端需要独立验证：

1. `message.name` 是固定的存储通道名称，`message.world` 是预期内容世界。
2. `message.frameInfo.isMainFrame == true`。
3. `message.frameInfo.securityOrigin` 的协议、主机和端口与当前授权 Origin 完全一致，即 `http`、`127.0.0.1` 和当前运行端口。
4. 消息结构、协议版本、会话标识、键值类型、键数量和总字节数符合限制；不能信任消息正文自报的 Origin。

`WKScriptMessage.frameInfo` 返回 `WKFrameInfo`，不是 `WebPage.FrameInfo`。其 `securityOrigin` 返回 `WKSecurityOrigin`，提供 `protocol: String`、`host: String` 和 `port: Int`。[frameInfo](https://developer.apple.com/documentation/webkit/wkscriptmessage/frameinfo)、[WKFrameInfo.securityOrigin](https://developer.apple.com/documentation/webkit/wkframeinfo/securityorigin)。

消息处理器虽然会出现在所选内容世界的所有框架中，但 `forMainFrameOnly` 只约束用户脚本注入，不替代原生消息接收端的主框架和来源检查。桥接能力只应包含存储快照同步，不能提供路径、文件操作、命令执行或 HTTP 代理参数。

## Origin 迁移的实现约束

以下是基于已确认 API 的实现设计，并非 Apple 提供的自动 Origin 迁移功能：

- 原生持久化快照独立于 Origin，保存全部 LocalStorage 字符串键值；使用 CryptoKit AES-GCM 加密，密钥存储于 Keychain。密文与配置元数据采用原子写入。
- 在网页写入 LocalStorage 后发送完整快照；除包装 `setItem`、`removeItem` 和 `clear` 外，还需周期比较或主动刷新，以覆盖存储属性赋值等路径。
- 端口迁移前主动读取并持久化最新快照，然后实际绑定新端口。创建候选 `WebPage` 时预先配置文档开始脚本，同步恢复到新 Origin。
- 完成页面加载后读回存储进行验证，验证成功才提交端口配置；失败保留旧配置、旧快照和旧服务器。
- 若应用启动前旧端口已被其他程序占用，使用已经持久化的原生快照恢复，不能要求先打开旧 Origin 才允许迁移。

[CryptoKit AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm)、[Keychain Services](https://developer.apple.com/documentation/security/keychain-services)、[Data.write(to:options:)](https://developer.apple.com/documentation/foundation/data/write(to:options:))。

macOS 26.0 新增 `WKWebsiteDataStore.fetchData(of:completionHandler:)` 与 `restoreData(_:completionHandler:)`，可导出/恢复不透明数据。这些接口没有提供重写 Origin 的参数，不能据此声称已经实现端口迁移；本文采用可验证的 LocalStorage 快照方案。[WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)。

## Service Worker 与缓存

相关数据类型包括 `WKWebsiteDataTypeServiceWorkerRegistrations`、`WKWebsiteDataTypeFetchCache`、`WKWebsiteDataTypeDiskCache` 和 `WKWebsiteDataTypeMemoryCache`。应在版本切换时释放旧页面，再按明确的数据类型和本地站点记录清理，避免旧 Service Worker 或缓存继续提供旧版本。

读取记录的异步签名是：

```swift
func dataRecords(ofTypes dataTypes: Set<String>) async -> [WKWebsiteDataRecord]
```

它与回调式的 `fetchDataRecords(ofTypes:completionHandler:)` 对应；不要误写成不存在的异步 `fetchDataRecords(ofTypes:)`。[数据记录读取](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/fetchdatarecords(oftypes:completionhandler:))。

删除接口 `removeData(ofTypes:for:completionHandler:)` 可以按类型及数据记录清理。不能使用 `allWebsiteDataTypes()` 进行全量清空，不能删除 LocalStorage、Cookie 或其他用户设置。[按记录删除数据](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/removedata(oftypes:for:completionhandler:))、[Service Worker 类型](https://developer.apple.com/documentation/webkit/wkwebsitedatatypeserviceworkerregistrations)。

公开的站点数据记录不是任意精度的端口级选择器；优先使用应用专用数据存储并按本地站点记录清理，不能把其他网站的数据混入清理范围。是否已经解除旧页面的 Service Worker 控制、是否显示切换后的实际版本，需要运行测试验证。

## ATS 与任意 HTTP Remote 的取舍

当前 Apple 文档说明：macOS 14 起，IP 地址不再默认获得 ATS 豁免，可以在 `NSExceptionDomains` 中为单个 IP 或 CIDR 配置例外。旧资料中“IP 地址不能配置例外”的结论不适用于本项目。[NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)。

仅访问本地面板时，可以为 `127.0.0.1` 配置 `NSExceptionAllowsInsecureHTTPLoads`，并使用 `NSAllowsLocalNetworking` 表达本地网络访问意图。但 ZashDock 还要求官方网页直接连接用户配置的任意 HTTP 域名 Remote；这些域名不能在发布时穷举进固定 `Info.plist`。为满足该行为，采用以下 WebKit 专用例外：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoadsInWebContent</key>
    <true/>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

`NSAllowsArbitraryLoadsInWebContent` 允许网页内容进行 HTTP 连接，范围覆盖整个应用内 WebKit 网络请求，因此宽于只允许 loopback。它保留原生 `URLSession` 的 ATS 保护；不配置全局 `NSAllowsArbitraryLoads`。原生 GitHub API 与安装包下载还应主动校验 HTTPS、官方仓库/资产来源及重定向目标，不能仅依赖 ATS。[WebKit 专用 ATS 例外](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloadsinwebcontent)。

这项取舍使明文 HTTP Remote 可用，但 HTTP 上的 Secret 和流量仍会以明文传输；应用应允许用户自行选择 HTTPS Remote。ATS 例外不关闭 WebKit 的同源策略、CORS 或其他浏览器安全规则，也不保证远端 Mihomo 的 CORS 配置正确。若发布到 App Store，Apple 文档要求为该例外提供审核说明。

实际验收应分别覆盖本地 HTTP、远端 HTTP/HTTPS REST、`ws://` / `wss://`、LAN/VPN 和 Surge 环境，不能根据配置文件推断全部连接已经通过。

## 构建环境记录

2026-10-23 实际执行结果：

```text
$ xcrun --show-sdk-path
/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk

$ xcodebuild -version
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory
'/Library/Developer/CommandLineTools' is a command line tools instance
```

以上为开发最初的环境记录。用户随后安装并初始化了 Xcode 27.1（27A9275），已实际成功执行 arm64 Debug `xcodebuild build` 和带 App Sandbox 的 App 宿主集成测试。26.5 SDK 的 arm64 编译也已通过；本机运行系统为 macOS 27.0.1，尚未在单独的 macOS 26.0 机器上运行。最终命令、结果及 `.xcresult` 路径见 [TESTING.md](TESTING.md)。
