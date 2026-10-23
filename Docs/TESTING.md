# 实际构建与测试记录

执行日期：2026-10-23，Asia/Shanghai。设备为 Apple Silicon arm64，运行 macOS 27.0.1（26A434），完整 Xcode 27.1（27A9275）。最低部署版本为 macOS 26.0，架构固定 arm64；未在独立 macOS 26.0 设备上运行。

## 当前存储实现

当前生产代码采用 WebKit 日常持久化。改端口才读取完整 LocalStorage 和官方 `base64`、`connection-history` 两个业务 IndexedDB 到内存，目标写入和核验均发生在官方页面初始化之前；端口提交后清理旧 Origin 业务记录。没有持续原生配置副本、写入捕获桥接或退出时导出配置。旧版密文只保留一次性只读兼容。

“完整数据”限定为已核验的官方业务存储，不能解释成复制任意 WebsiteDataStore。未知数据库、数据库版本或 schema 会拒绝迁移，保留源数据。Cookie、sessionStorage、Service Worker 和可丢弃缓存不属于配置迁移范围。

## 本轮验证

本轮按阶段先验证公开 API 和隔离转移组件，再替换生产 AppModel、WebSession 和原生 UI。阶段记录如下，最终统一结果见本节末尾：

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

最终统一验证结果：

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

未提供变量的可选测试明确跳过。官方 ZIP 测试使用可信 v3.29.1 元数据，不接受任意同名压缩包；ZIP 不进入 App Bundle。最新本地全量验证启用了官方 ZIP，未重复访问个人后端。

新存储测试使用随机 UUID 的独立持久 WebsiteDataStore、临时目录和虚构凭据；只清理本轮 fixture。旧版兼容测试通过假只读 Keychain reader 和手工生成的测试密文验证，不创建、读取或删除生产密钥，不操作生产 default DataStore。测试代码中的同一个 AppModel 重新创建和真实不同 PID 的进程测试分别记录，不混为一谈。

## 当前验收映射

| 项目 | 已执行的覆盖和边界 |
| --- | --- |
| A 首次启动 | AppModel 无安装时没有 WebSession；原生安装界面已有历史人工观察 |
| B 取消 / 失败 / 重试 / ZIP | Core 下载与解压取消、未知 ZIP 拒绝、失败重试；真实官方 ZIP 首次安装取消后重试及页面渲染；没有原生配置密文落盘 |
| C 两个 Remote 重启保留 | 官方 setup/api-list + setup/active-uuid；普通重载、同源导航、会话重建，独立进程读回持久 WebKit 数据；主动 clear 后不回放旧值 |
| D HTTP REST / WebSocket | 真实 WebPage Authorization 预检、REST 200、WebSocket 握手与 JSON 帧；未关闭同源、CORS 或 App Sandbox |
| E 端口占用 | 实际监听器占用；失败不提交新端口，原服务重建；显式手动或自动选择 |
| F 端口迁移 | 真实 AppModel：首读即含两个 Remote、选中项、主题、两 IDB；源数据只在提交后清理；失败保留原配置字节与数据，未提交目标记录清理 |
| G 启动前旧端口被占 | 旧 Origin 通过可信模拟文档直接读写，不请求占用者；新端口加载成功；不依赖原生 Remote 文件 |
| H 更新后保留 | 同一 Origin 的不同 fixture 版本；候选在 nonPersistent store 中验证，即使候选清空自己存储后失败或取消，活跃 profile 仍保留 |
| I N=0/1/3 | 实际网页切换后检查 current/history 和物理目录；健康历史不被坏历史挤占；Core 另测顺序和 I/O 边界 |
| J 回滚 | 实际 DOM / JS / 服务版本、两个 Remote、IDB 与历史顺序；候选验证和持久页面加载后才清理资源 |
| K 损坏 ZIP | CRC、摘要、截断、路径、ZIP Slip、符号链接、压缩比、配额、有界复制、源文件替换；失败不改当前版本 |
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
- 两份不同官方发行的更新 / 回滚、已有旧 Service Worker 反例、更多网络及文件系统故障注入。
- 完整辅助功能、所有原生文件面板的人工操作和窗口恢复。已有 UI 历史观察不能替代重构后所有流程的人工复验。
