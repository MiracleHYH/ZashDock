# 实际构建与测试记录

执行日期：2026-10-23，Asia/Shanghai。设备为 Apple Silicon arm64，运行 macOS 27.0.1（26A434），完整 Xcode 27.1（27A9275）。最低部署版本为 macOS 26.0，架构固定 arm64；未在独立 macOS 26.0 设备上运行。

## 首个 GitHub 正式版的发布候选验证

用户已选择通过 GitHub 直接发布正式版 `v1.0.0`，应用版本为 `1.0.0 (2)`，不涉及 App Store。Build 递增供此前试用 Build 1 识别更新。首次发行显式选择 ad hoc 签名，没有 Developer ID 签名、Apple 公证或装订，首次从互联网下载后可能被 Gatekeeper 阻止。未公证描述分发信任状态，不表示它是测试版；应用 ZIP 和稳定 Sparkle Feed 仍须通过 EdDSA 签名验证。

实际 `xcodebuild archive` 的 Release 优化预检构建通过，架构 arm64，保留 Hardened Runtime 和 App Sandbox，未注入调试用 `get-task-allow`。预检使用开发 Build 1，日志为 `build/verification/release-candidate-1.0.0-archive.log`。`Scripts/test-release-diagnostics.sh` 对该真实归档的 7 项检查通过，包含符号 UUID、摘要与来源、白名单内容，以及凭据 canary、符号缺失、符号链接和 UUID 不匹配的拒绝用例；日志为 `release-candidate-1.0.0-diagnostics-tests.log`。

正式 `adhoc` 模式的 Build 2 另已实际归档成功，日志 `adhoc-release-1.0.0-build2-archive.log`。签名显示 `adhoc,runtime`、无 Team ID，保留四项必需沙箱权限且无 `get-task-allow`；仅临时 entitlements 添加加载 Sparkle 所需的库验证例外，共享 entitlements 保持不变。新增 `Scripts/test-release-profiles.sh` 的 14 项无凭据检查通过，验证显式模式、默认模式不降级、缺失凭据拒绝、非法输入/本地发布拒绝及工作流 Apple 凭据隔离；它不认证凭据或执行发布。普通 CI 与发布工作流均执行这些检查。

已用该实际 Release 程序创建随机独立 Bundle ID 的沙箱副本，仅修改测试副本的 Info 与对应 Mach 服务名并以相同运行时权限重新签名，程序 UUID 保持相同。CUA 确认安装页面正常、Sparkle“检查 ZashDock 更新…”菜单可用，原生关于面板显示 `1.0.0 (2)`；最后正常退出。它验证优化程序和 Sparkle 的实际加载，不代表互联网下载后的 Gatekeeper 首次许可或完整更新安装已验收；生产安装和 Remote 数据未改动。准备记录 `build/verification/adhoc-runtime-smoke-preparation.log`，临时程序在本地忽略目录。

本节记录发布前验证，不表示此时已经公开发行。最终包需从已提交、通过 CI 的源码归档，并附 SHA-256、匹配 dSYM 与白名单构建元数据；实际发布状态及对应源码提交以 GitHub Release 为准。

## 系统菜单与双版本展示验证（最新）

主窗口移除了右上角原生控件；设置由 SwiftUI Settings Scene 提供系统应用菜单入口及 ⌘,。关于命令调用标准 AppKit About 面板，同时显示 ZashDock 完整版本（含构建号）与 Zashboard 版本；设置的更新和关于页也同时显示两者。

- 实际 Xcode App Sandbox 全量 **61 项通过、1 项可选个人后端测试跳过，0 失败**；汇总 62 项 / 16 suites，25.099 秒。真实官方 ZIP 两项启用。证据：`build/verification/native-menu-complete.xcresult`、同名 `.log` 和 `-summary.json`。
- 两个隔离原生 UI fixture 从当前生产源码提取，包含相同的 `ZashDockCommands`，实际编译、签名及源码一致性检查通过。CUA 实际验证应用菜单 Settings、⌘,、主窗口无右上角控件、设置双版本、标准 About 面板双版本及无重复默认版本行。过程与边界见 [UI 记录](UI-VERIFICATION.md)。
- `Scripts/build-debug.sh` 实际成功，日志 `build/verification/native-menu-debug.log`；`build/Debug/ZashDock.app` 为 arm64，`codesign --verify --deep --strict` 通过，最终副本定向图标登记成功。`git diff --check` 通过，未提交、推送或发布 Release。
- 本轮没有修改 Core、安装、存储或端口逻辑；未重复访问个人后端，未操作用户日常 WebKit 数据。以下保留前一阶段的业务回归与资源清理证据，不将其描述成重新执行。

## 当前版本与本地导入策略

本轮按用户要求移除了回滚、历史版本列表和保留数量设置。成功安装或更新并完成持久页面验证后，仅保留当前资源；旧安装留下的历史资源也在当前页面成功启动后清理。候选验证失败或取消时，现有资源指针、当前资源和 WebKit 业务数据保留；当前安装损坏时不先清理其他资源。

本地 ZIP 导入完全离线，不验证官方身份，不匹配已知发行摘要，也不从文件名猜版本。任意满足结构、路径、大小和必要资源校验并通过实际页面验证的本地包均可导入；来源标记为 `localArchive`，界面显示“本地导入（版本未知）”。自算 SHA-256 用于内部完整性校验。在线更新继续校验官方 GitHub HTTPS 发行资产和官方摘要。

### 本轮定向验证

| 验证 | 实际结果 | 本地证据 |
| --- | --- | --- |
| 实际 Xcode Sandbox App | **23/23 项通过，5 suites，23.038 秒，无跳过**；启用真实官方 v3.29.1 ZIP 样本 | `build/verification/no-rollback-app-stage2.log`、`no-rollback-app-stage2.xcresult` |
| 隔离 WebKit / Transfer 跨进程 | **19 个不同 PID 通过**；正常重启、3 个 SIGKILL 边界、清旧 Origin、旧端口 TCP 连接数 0 | `build/verification/no-rollback-origin-processes.log`、`storage-processes.5ZyC8E/` |
| 正式 AppModel 跨进程 | **7 个不同 PID 通过**；正常重启、旧端口占用迁移、观察正式端口提交后 SIGKILL、两次冷启动与清理，sentinel 连接数 0 | `build/verification/no-rollback-appmodel-processes.log`、`appmodel-processes.KWPMdn/` |

23 项覆盖首次任意本地包导入、未知摘要包离线更新、连续成功后只留当前、候选失败/取消保全两个 Remote 与两个 IndexedDB、坏 ZIP 重试、旧官方 manifest 兼容、旧历史资源清理、普通配置恢复和端口迁移。真实官方 ZIP 两项分别验证首次取消后离线重试，以及双 Remote 的重启和端口迁移。首次定向执行发现取消候选会留下错误提示，修复后重新执行上述 23 项全部通过；失败记录保留为 `no-rollback-app-stage1.log`。

两个进程工具均使用独立 UUID profile 和虚构数据，不启用 App Sandbox；实际沙盒由 Xcode App 宿主覆盖。19 PID 工具的提交边界使用最小端口元数据模型，7 PID 工具直接编译正式 AppModel；二者都不代表操作系统重启。

### 本轮最终统一验证

- **Core：78 项通过、1 项可选在线下载测试跳过，0 失败**；汇总 79 项 / 5 suites，4.661 秒。日志：`build/verification/local-single-current-core-complete.log`。本地导入、来源标记、旧清单兼容、单当前资源及清理保护定向 32 项通过。
- **实际 Xcode Sandbox App：61 项通过、1 项可选个人后端测试跳过，0 失败**；汇总 62 项 / 16 suites，26.817 秒。动态参数展开为 65 个通过的 test runs；按唯一测试项计数。真实官方 ZIP 两项启用。结果：`build/verification/local-single-current-complete.xcresult`、同名 `.log` 和 `-summary.json`。
- **arm64 Debug 构建通过**：`build/verification/local-single-current-debug.log`；产物为 `build/Debug/ZashDock.app`。`codesign --verify --deep --strict` 通过，Bundle ID 仍为 `app.zashdock.mac`，最低系统版本 26.0。包内含 AppIcon 和 Assets.car，无 Zashboard dist、ZIP、index.html 或 XCTest 插件；最终副本的定向 Launch Services 登记成功。
- **原生界面实际观察通过**：在 `build/ui-simplification/` 中编译直接复用生产视图和按钮逻辑的隔离 App，使用独立临时配置、非持久 WebKit 和 Bundle ID。CUA 确认首次页无副标题或导入说明，“下载并安装”和图标导入并排，Toolbar 仅设置图标；图标能打开原生 ZIP 选择器，取消后无错误弹窗。原生 Settings 可打开；更新和关于页明确区分 ZashDock 与 Zashboard 版本，v3.29.1 无截断，没有回滚列表或保留数量。两个隔离 App 已正常退出；未清理或重置用户正在试用的网页数据。
- `git diff --check` 通过。本轮未提交、推送或发布 Release；以上本地结果不等同于新提交的 GitHub CI 结果。以下上一轮汇总均为历史记录。

## 当前存储实现

当前生产代码采用 WebKit 日常持久化。改端口才读取完整 LocalStorage 和官方 `base64`、`connection-history` 两个业务 IndexedDB 到内存，目标写入和核验均发生在官方页面初始化之前；端口提交后清理旧 Origin 业务记录。没有持续原生配置副本、写入捕获桥接或退出时导出配置。旧版密文只保留一次性只读兼容。

“完整数据”限定为已核验的官方业务存储，不能解释成复制任意 WebsiteDataStore。未知数据库、数据库版本或 schema 会拒绝迁移，保留源数据。Cookie、sessionStorage、Service Worker 和可丢弃缓存不属于配置迁移范围。

## 上一轮 WebKit 存储重构验证（历史）

以下为移除回滚和放宽本地导入之前的实际验证记录，反映各阶段当时的实现，包含现已删除的历史保留与回滚测试；计数和证据保持原样。

| 阶段 | 实际结果 | 本地证据 |
| --- | --- | --- |
| 可信旧 Origin 访问原型 | 真实 Xcode App Sandbox 1 项通过；旧端口被占用，TCP 连接数 0；读取 LocalStorage 和 IndexedDB | `build/verification/origin-storage-access.xcresult`（早期原型） |
| 转移组件 | SwiftPM 7 项、实际 Xcode App Sandbox 7 项通过；含多种 schema 参数反例、配额、取消与超时 | `origin-transfer-stage1.log`、`origin-transfer-stage1-xcode.xcresult` |
| 普通配置与只读兼容 | Core 汇总 57 项，在线下载 1 项按条件跳过，其余通过 | `build/legacy-reader-core-complete.log` |
| 端口 / 更新 / 坏历史 | 实际 Xcode 14 项通过；补未提交目标清理断言后端口 8 项再次通过 | `webkit-model-stage2.xcresult`、`webkit-port-stage2-final.xcresult` |
| 启动恢复 / 旧版一次导入 / 生命周期 / 运行故障 | 实际 Xcode 4 suites、17 项通过 | `recovery-webkit.xcresult` |
| 真实官方 ZIP 与日常持久化 | 实际 Xcode 4 项通过；官方 v3.29.1 ZIP 两项启用 | `webkit-storage-official.xcresult` |
| 取消停用页面 | 正常 / 预取消两种参数均通过；旧 JS 上下文消失、计时器停止、WebSocket 断开、原生面板取消 | `webkit-suspension-cancellation-fixed.xcresult` |
| Unicode 等价键 | 转移组件8项通过；原始 JS 中可区分而 Swift 字典不能区分的键会在写入前拒绝，源数据保持原字节 | `webkit-transfer-unicode-keys.xcresult` |
| 隔离跨进程 WebKit / Transfer | 最终源码19个独立 App PID、正常退出重启、3个真实 SIGKILL 边界，旧端口 TCP连接数0，清理成功 | `storage-processes-final.log`、`storage-processes.vKEDKt/` |
| 正式 AppModel 跨进程 | 最终源码7个独立 PID；正常重启、旧端口占用迁移、正式端口提交后 SIGKILL、两次冷启动及清理通过；sentinel连接数0 | `appmodel-processes-final.log`、`appmodel-processes.Q0xybg/` |

除 Core 日志的特别注明路径外，表中证据位于本地忽略目录 `build/verification/`。跨进程 Transfer 工具的提交中断用例使用最小端口元数据模型；正式 AppModel 的独立工具则直接编译生产源码，没有产品测试 hook，并从外部观察真实配置提交后发送 SIGKILL。本轮确实捕获了 `pendingOriginCleanup` 尚存在的提交状态，后续冷启动完成清理。边界见 [Transfer harness](../Tests/OriginStorageProcessHarness/README.md) 和 [AppModel harness](../Tests/AppModelProcessHarness/README.md)。两个进程工具不启用 App Sandbox，实际 Sandbox 另由 Xcode 宿主覆盖；进程重启不代表操作系统重启。

该轮统一验证结果（历史）：

- **Core：56项通过、1项可选官方在线下载测试跳过，0失败**；Swift Testing汇总57项/4 suites，4.773秒，`webkit-storage-core-final.log`。
- **实际 Xcode Sandbox App：58项通过、1项可选个人后端测试跳过，0失败**；汇总59项/16 suites，31.825秒，`webkit-storage-verified.log`、`webkit-storage-verified.xcresult`、`webkit-storage-verified-summary.json`。参数化执行另展开为64个通过的 test runs，文档按唯一测试项计数。真实官方 ZIP 两项均启用。
- **arm64 Debug构建和签名验证通过**：`webkit-storage-debug-delivery.log`，产物 `build/Debug/ZashDock.app`；`codesign --verify --deep --strict`成功。独立构建目录不包含 XCTest插件，Bundle中无Zashboard dist、ZIP或index.html。
- 真实签名entitlements包含App Sandbox、network client/server、用户选择文件读写和Sparkle限定安装服务；记录为 `webkit-storage-debug-entitlements.plist`。最低系统版本26.0，实际可执行架构arm64。
- 两个进程脚本已接入CI；Actionlint、Bash语法及`git diff --check`通过。以上是源码推送前的本地结果，GitHub CI须按对应提交的实际运行结果单独确认；不发布Release。

## 运行自动测试

```sh
Scripts/test-core.sh
Scripts/test-storage-processes.sh
Scripts/test-appmodel-processes.sh
xcodebuild -project ZashDock.xcodeproj -scheme ZashDock \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Xcode CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
Scripts/build-debug.sh
```

WebKit、沙盒、原生文件交互和 App 生命周期以实际 Xcode App 测试宿主为准。工具自身的文件系统沙盒会阻挡 Xcode 缓存、WebKit 子进程或 LaunchServices，相关命令在获准后于工具沙盒外执行；应用自己的 App Sandbox 未关闭。

普通集成测试不需要联网或真实后端。启用官方资源或用户授权后端的只读网络测试：

```sh
TEST_RUNNER_ZASHDOCK_OFFICIAL_ZIP=/absolute/path/to/official/dist.zip \
TEST_RUNNER_ZASHDOCK_MIHOMO_URL=http://your-mihomo-host:9090 \
xcodebuild -project ZashDock.xcodeproj -scheme ZashDock \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Xcode CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

未提供变量的可选测试明确跳过。`ZASHDOCK_OFFICIAL_ZIP` 指向已知的 v3.29.1 测试样本，测试代码用独立常量核对样本摘要，确保跑到指定上游网页；这不属于生产本地导入的官方身份验证。生产本地导入接受任意通过安全和页面验证的 ZIP，不依赖内置 seed、发行目录或联网。ZIP 不进入 App Bundle；本轮定向验证未访问个人后端。

新存储测试使用随机 UUID 的独立持久 WebsiteDataStore、临时目录和虚构凭据；只清理本轮 fixture。旧版兼容测试通过假只读 Keychain reader 和手工生成的测试密文验证，不创建、读取或删除生产密钥，不操作生产 default DataStore。测试代码中的同一个 AppModel 重新创建和真实不同 PID 的进程测试分别记录，不混为一谈。

## 当前验收映射

| 项目 | 已执行的覆盖和边界 |
| --- | --- |
| A 首次启动 | AppModel 无安装时没有 WebSession；原生安装界面已有历史人工观察 |
| B 取消 / 失败 / 重试 / ZIP | 任意有效本地 ZIP 首次离线导入、自算摘要与本地来源；损坏 ZIP 拒绝及重试；真实官方样本首次取消后离线重试及渲染；没有原生配置密文落盘 |
| C 两个 Remote 重启保留 | 官方 setup/api-list + setup/active-uuid；普通重载、同源导航、会话重建，独立进程读回持久 WebKit 数据；主动 clear 后不回放旧值 |
| D HTTP REST / WebSocket | 真实 WebPage Authorization 预检、REST 200、WebSocket 握手与 JSON 帧；未关闭同源、CORS 或 App Sandbox |
| E 端口占用 | 实际监听器占用；失败不提交新端口，原服务重建；显式手动或自动选择 |
| F 端口迁移 | 真实 AppModel：首读即含两个 Remote、选中项、主题、两 IDB；源数据只在提交后清理；失败保留原配置字节与数据，未提交目标记录清理 |
| G 启动前旧端口被占 | 旧 Origin 通过可信模拟文档直接读写，不请求占用者；新端口加载成功；不依赖原生 Remote 文件 |
| H 更新后保留 | 同一 Origin 的不同 fixture 版本；候选在 nonPersistent store 中验证，即使候选清空自己存储后失败或取消，活跃 profile 仍保留 |
| I 仅保留当前资源 | 连续成功导入后检查物理目录仅一个当前版本；当前页面成功启动后清理旧安装历史，包括损坏的非当前资源；N 保留规则已移除 |
| J 旧安装兼容与失败保全 | 回滚功能已移除；旧官方 manifest 继续可读，候选失败或取消时资源指针、工作页面、两个 Remote 和两 IDB 保留；当前安装损坏时不先删旧资源 |
| K 损坏 ZIP | CRC、截断、路径、ZIP Slip、符号链接、压缩比、配额、有界复制和源文件替换；在线资产校验官方摘要，本地包自算摘要只作内部完整性；失败不改当前版本 |
| L SW / 缓存 | SW script 请求 403，真实 WebKit 注册失败；选择性缓存清理后业务数据保留，同 Origin 版本替换验证；已有旧 SW 的专门反例仍待补 |
| M 原生生命周期 | 宿主覆盖退出、取消任务、旧会话晚回调与重载；人工窗口、Settings、菜单观察见历史 [UI 记录](UI-VERIFICATION.md) |
| N Surge / LAN / VPN | 下节记录历史真实环境；认证后的个人 Kernel WebSocket 尚需用户 Secret |

## Surge 环境中的真实后端测试

用户曾提供并授权只读测试一个真实 HTTP Mihomo 后端。公开记录不包含其主机名、地址、凭据或本机路由细节。

- Surge 6.10.0 运行中，确认该域名经 Surge 虚拟地址和隧道路由可达。
- 原生终端 GET `/version` 返回 HTTP 401，包含 `Access-Control-Allow-Origin: *`。
- `/traffic` WebSocket Upgrade 返回 HTTP 401，未绕过认证。
- 带应用实际 ATS 配置的沙盒 WebPage 成功读取 HTTP 401，代表 HTTP / CORS 可达。
- 已用本机测试后端验证认证 REST 和成功 WebSocket 帧。没有用户 Secret，不能声称真实远端的认证、订阅、节点和业务数据已验收。
- 没有更改 Surge、系统代理、VPN 或远端配置，没有记录真实 Secret。

这是先前阶段的实际记录；本次存储重构未再次请求个人后端。原始响应保存在本地忽略的 `build/verification/`。

## 历史：应用图标与本机试用

2026-10-23 新增 macOS AppIcon 资源，10个槽位的实际PNG尺寸、透明通道及工程设置已核验。Debug/Release 均关联 `AppIcon`；实际 `Scripts/build-debug.sh` 成功，日志为 `build/verification/icon-debug-build.log`。产物包含 `AppIcon.icns` 和 `Assets.car`，编译后的 Info.plist 图标关联正确；arm64 与 `codesign --verify --deep --strict` 通过，没有 XCTest 插件。

首次用精确路径打开 `build/Debug/ZashDock.app` 时确认进程启动，但因当时 Mac 锁屏未能查看界面；解锁后通过 CUA 确认原生安装窗口。用户随后报告 Dock 仍为默认图标：读取运行实例路径与包内图标确认是新副本，正常退出、用公开 `LSRegisterURL` 定向登记最终副本并按精确路径重开后，用户明确确认 Dock 已显示蓝色 Z。没有清空全局缓存、重启 Dock 或改动网页数据。本轮未发布 Release。

Debug 打包脚本已补最终复制副本的定向注册步骤，独立 Swift 工具仅接受本项目 Bundle ID；该工具已在实际试用产物上执行成功。注册 API 不保证强制刷新所有系统缓存，已运行会话仍可能需要正常退出再重开。

图标源文件、生成提示和重建命令见 [图标说明](../Design/AppIcon/README.md)。本轮仅修改图标资源和工程关联，未改业务逻辑，验证范围为实际图标编译、签名、资源与启动检查。

## 历史：首次在线试用的 GitHub API 限流

2026-10-23 首次在线安装实测遇到 HTTP403，官方响应头为 `X-RateLimit-Limit: 60`、`X-RateLimit-Remaining: 0`，确认是网络出口共享的匿名 API 额度耗尽。此前文案把非200响应合并为“可能离线或达到 API 速率限制”，不能据此辨别原因。

按服务端 reset 等待后，匿名请求返回 HTTP200，官方稳定版仍为 v3.29.1，dist.zip 的大小和 SHA-256 与既有可信元数据一致。随后通过真实试用 App 点击重试，完成官方 HTTPS 下载、摘要验证、解压、网页验证及激活；CUA 截图确认进入原版 Zashboard 后端配置页。没有改动网络、Surge 或系统代理设置，也没有使用 GitHub 登录凭据、第三方源或旧版本自动降级。

`ReleaseClient` 现分别报告有证据的限流、普通 HTTP 状态、来源拒绝、非HTTP、目录超限和损坏元数据，保留网络层错误。限流日期来自有效 `Retry-After`；只有主额度耗尽时才采用 `X-RateLimit-Reset`，避免把主窗口时间误当作次限流解除时间。响应正文不进入应用错误提示，公开记录省略出口 IP；原始诊断响应仅保存在本地忽略目录。

该轮新增回归使用会话局部 URLProtocol 注入官方 URL 的响应，保留当时生产重定向 delegate、流式8MiB上限及取消检查；覆盖限流头、状态码、失败重试、来源、大小边界、无效元数据和取消时缓存不变。本轮已移除本地导入所需的发行目录缓存；上述是当时的回归范围。原有三个仅验证渲染/连通性的集成用例也改用非持久 DataStore，避免写入日常 profile。

实际验证全部完成：

- 新增 ReleaseClient 定向18项通过，1.593秒；`build/verification/release-catalog-targeted.log`。
- 全量 Core 74项通过、1项可选在线下载测试跳过，0失败；汇总75项/5 suites，4.686秒；`release-catalog-core-complete.log`。
- 实际 Xcode Sandbox App 58项通过、1项可选个人后端测试跳过，0失败；汇总59项/16 suites，33.640秒，真实官方 ZIP 两项启用；`release-catalog-app.log`、`release-catalog-app.xcresult`、`release-catalog-app-summary.json`。
- `Scripts/build-debug.sh` 实际成功，arm64产物和最终副本注册成功；`release-catalog-debug-build.log`。更新的试用包仍位于 `build/Debug/ZashDock.app`。当前用户面板保持打开，没有为了更新错误提示而中断用户正在填写的后端配置；新提示在下次启动生效。

以上除特别注明路径外均位于 `build/verification/`。本轮未发布 Release。

## 历史阶段证据

这些记录反映当时实现。旧加密桥接测试的通过不作为当前 WebKit 架构的测试证据。

| 阶段 | 当时实际结果与记录 |
| --- | --- |
| 初始工程到更新回滚 | 各阶段编译后再推进；`phase1.log`、`stage2-live-retry.log`、`phase4-xcode-tests.log`、`phase5-xcode-tests.log`、`phase6-retry-tests.xcresult` |
| GitHub 更新通道 | 固定 Sparkle 2.10.0，实际 arm64 App 构建、签名验证；Core 汇总36 / App汇总24项（可选网络按条件跳过）；`github-final-build.log`、`github-final-tests.xcresult` |
| P1 修复 | 实际构建，Core汇总41 / App汇总41项；`audit-p1-complete.xcresult` |
| P2 修复 | 实际构建，Core汇总54 / App汇总57项；`audit-p2-complete.xcresult`；具体问题见 [修复记录](REMEDIATION.md) |
| 发布诊断 | 实际 ad hoc Release Archive 和匹配 dSYM，独立7项安全回归、Swift/Shell/Actionlint；`build/audit/release-diagnostics/RESULTS.md`；未发布 |

上述除特别注明路径外位于 `build/verification/`。早期构建遇到官方下载超时、测试误用生产 Keychain service 和后台 timer 节流，均有失败与修复后的重跑记录；没有放宽 ACL、关闭 App Sandbox 或清空生产 WebsiteDataStore。

## 尚未完成的环境验收

- 独立 macOS 26.0 设备、OS 重启和长时间运行；当前真实运行系统是 macOS 27.0.1。
- Developer ID、公证和真实签名 Sparkle 旧版升级新版；没有执行正式发布。
- 用户真实 LAN/VPN 后端的认证 REST、WebSocket 和持续订阅。
- 两份不同官方发行的真实在线更新、已有旧 Service Worker 反例、更多网络及文件系统故障注入。回滚与 N 保留规则已移除，不再作为当前验收项。
- 完整辅助功能、所有原生文件面板的人工操作和窗口恢复。已有 UI 历史观察不能替代重构后所有流程的人工复验。
