# 审计修复记录

日期：2026-10-23。基线为 `3c58f45917c2a01d1c9526b6e03a0021da258f97`，原始问题见 [审计报告](AUDIT-2026-10-23.md)。修复与验证不创建 Tag 或发布 Release；源码提交和 GitHub CI 结果以对应提交记录为准。

P1、P2 表格记录各阶段完成时的实现和验证。随后按用户明确选型替换了存储架构，当前行为以“配置架构收敛”节和 [架构文档](ARCHITECTURE.md) 为准；旧桥接、密文恢复界面和退出保存策略不再属于当前产品。

## P1 阶段

| 问题 | 已实现修复 | 回归 |
| --- | --- | --- |
| F01 文档重载丢配置 | 初次注入只消费一次；区分文档身份和修订；过期消息不能覆盖当前配置；BFCache 恢复时验证当前文档 | 普通重载、同源导航、即时清理 sessionStorage 并重载、真实前进后退缓存、后续编辑及两 Remote 持久化 |
| F02 原生网页对话框 | WebPage.DialogPresenting 接入 AppKit，限定主框架和精确 Origin | alert、confirm、prompt、真实文件输入读 JSON/PNG，取消、异源、子框架与权限边界 |
| F03 网页 Blob 导出 | 受限字节通道、一次用户手势、原生保存位置、16 MiB 上限 | 官方立即 revoke URL 的模式、UTF-8 内容、取消不覆盖、非法/超限请求、停用和写入失败 |
| F04 普通设置损坏 | 可重新读取，或先保全原文件再恢复默认应用设置；不重置 Remote 与版本 | JSON 格式/字段/范围、备份失败、四版本与两 Remote 保留、原端口占用后的恢复 |

阶段完成后才开始 P2。实际 arm64 Xcode 构建成功，Core 41 项、App 宿主 41 项通过，官方 v3.29.1 ZIP 两项实际启用。证据：`build/verification/audit-p1-build.log`、`audit-p1-core.log`、`audit-p1-complete.log`、`audit-p1-complete.xcresult`。

## P2 阶段

| 问题 | 已实现修复 | 回归 |
| --- | --- | --- |
| F05 损坏历史占保留名额 | 验证后只从健康历史选 N 个，保护当前和活跃目录；取消/权限 I/O 不误判损坏；清理计划原子保存 | N=0/1/3、坏 v2 不挤掉健康 v1、回滚/重启双 Remote、manifest/content/assets 权限、符号链接 |
| F06 配置不可读无恢复入口 | 区分密钥暂不可读/缺失、认证失败、文件 I/O；默认重新读取；高级恢复折叠；保全原始文件后才能提交 | 认证恢复、错密钥/无密钥拒绝、不生成替代密钥、导出不读密钥、两 Remote 重启 |
| F07 运行中页面与退出失败 | 持续观察公开导航事件；新文档通过验证后才允许写回配置；错误可重载；退出可重试/取消/明确保留已存配置退出 | 真实断连、空白文档、空白文档主动 clear 不覆盖持久配置、旧会话晚回调、取消与退出策略 |
| F08 Settings 不能取消 | 操作状态和取消按钮位于禁用的设置区之外，检查更新取消不报告失败 | 实际宿主取消入口的任务逻辑、错误状态及重新操作 |
| F09 符号丢失 | 归档后立即保存匹配的 dSYM、白名单构建元数据及摘要，成功发行长期附资产，失败工作流保留 90 天 | 实际 ad-hoc Release Archive、UUID 匹配、7 项安全回归、Swift/Shell/Actionlint |

交叉审查还验证并修复了网页导出跨文档的手势和等待中保存问题；正式回归覆盖 BFCache 不借用其他文档手势、导航取消旧保存及晚返回结果。所有测试均使用独立目录、随机测试 Origin 和虚构凭据，不操作生产配置或生产 Keychain。

本阶段实际 arm64 Xcode 构建成功，Core **54 项/3 suites，4.747 秒**，完整 App 宿主 **57 项/14 suites，25.292 秒**通过，官方 v3.29.1 ZIP 两项启用。证据：`build/verification/audit-p2-build.log`、`audit-p2-core.log`、`audit-p2-complete.log`、`audit-p2-complete.xcresult`。dSYM 的实际 ad-hoc Release Archive 和 7 项安全回归另见 `build/audit/release-diagnostics/RESULTS.md`。

完整 UI 验收仍与自动宿主测试区分：真实 AppKit Alert/Confirm/Prompt 已操作；文件面板在选中 JSON 后 CUA 持续超时，后续真实面板保存操作保留待验，不能标为通过。记录在本地 `build/audit/native-ui/RESULTS.md`。

## 配置架构收敛

用户明确采用“WebKit 日常持久化＋改端口时一次性转移完整数据”。生产实现已替换：固定持久 DataStore 是日常配置唯一来源；移除了常驻存储桥接、原生密文写入、Keychain 密钥创建和相关恢复界面。合法网页 clear 会正常持久化，不回放旧值；正常退出仅停用页面并停止服务。

已核对 Apple 文档与 macOS 26/27 SDK：公开 `WKWebsiteDataStore` 无 Origin 重命名接口，`fetchData`/`restoreData` 的不透明数据不能传入端口映射；未使用私有 `_renameOrigin`。生产 `OriginStorageTransfer` 使用公开 `WebPage.load(simulatedRequest:responseHTML:)` 加载可信空文档，旧端口被占时也不向其发送请求。

端口事务先停用旧页面与唯一监听器，再读取 LocalStorage 和官方两个 IndexedDB 到内存；目标绑定、写入、核验、真实页面验证后，才原子提交端口。旧业务记录在提交后清理，只有小型 pending 清理标记进入原生设置；失败不修改源数据。旧密文仅由只读 reader 一次导入，成功后不再访问其 Keychain 项，原文件保留。

更新和回滚先在临时 nonPersistent profile 验证候选，避免失败候选清空日常配置；资源指针提交后才加载持久 profile，成功后清理版本。没有创建用户数据回滚版本。

生产替换后已经分阶段实际编译与测试。另补了两个真正的进程工具：Transfer 模型19个 PID、3个 SIGKILL 边界；正式 AppModel 7个 PID，外部观察真实端口提交后 SIGKILL 再冷启动，Remote 和两数据库保留、旧端口 sentinel 连接数为0。两个 harness 不启用 Sandbox，真实 Sandbox 另由 Xcode 测试宿主覆盖。统一回归和已知边界见 [测试记录](TESTING.md)。

交叉审查还复现并修复了预取消任务无法卸载旧网页的问题：停用操作使用独立任务完成，真实回归验证旧计时器停止、WebSocket 断开、旧上下文消失，不会在迁移后继续写入源 Origin。

## 仍需独立验收

- 独立 macOS 26.0 设备、Developer ID/公证与真实签名 Sparkle 旧版升级新版。
- 真实用户 LAN/VPN 后端的认证和持续订阅（尚无 Secret）；既有 401 记录仅代表可达性。
- 两份不同官方版本的更新/回滚、已有旧 Service Worker 反例、网络与文件系统故障注入、长时间运行、辅助功能与产品图标/本地化。
- 后续官方版本如改变或新增数据库 schema，需要扩展适配和回归；当前未知结构会安全拒绝迁移。当前保证 LocalStorage 与已核验的两个业务 IndexedDB，不声称复制任意 WebsiteDataStore。
