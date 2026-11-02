# ZashDock 1.0.1

修复更新 Zashboard 时可能出现“网页存储结构不受当前版本支持，原数据已保留”的问题。使用过 GeoIP 功能后，即使没有更改端口，也可能触发旧版的数据库迁移格式检查。

## 修复

- 同端口更新直接保留原 WebKit profile，Remote、选中后端、网页设置及所有 IndexedDB 原地沿用，不再为更新导出或复制网页数据。
- 候选资源继续在独立、空的临时 WebKit profile 中验证；提交前失败或取消时，正式 profile 不会被候选代码修改。成功后由新版 Zashboard 在原 profile 执行自身迁移。
- 增加 GeoIP ArrayBuffer、复合键、旧缓存 Blob 和两个 Remote 的回归，覆盖成功更新、重新创建 AppModel，以及失败候选对原数据的保全。
- 本地开发构建默认在验证 ZIP 可以完整还原后清理可运行 App 副本；需要调试时显式使用 `--keep-app`，减少聚焦中混入开发副本的情况。

## 安装与应用更新

**ZashDock 1.0.1（Build 3）**，Apple Silicon、macOS 26.0+。从 ZashDock 应用菜单选择“检查 ZashDock 更新…”安装本次 Wrapper 修复，完成后再更新 Zashboard 网页。现有 Remote 和设置无需重新录入。

本版本继续使用 ad hoc 签名，保留 App Sandbox 与 Hardened Runtime；没有 Developer ID 签名或 Apple 公证。与此前明确选择的发行配置相同，仅 ad hoc 模式包含加载 Sparkle 所需的库验证例外。应用 ZIP 和稳定 Sparkle Feed 使用专用 Ed25519 密钥签名，更新完整性验证独立于 Apple 公证。

首次从 GitHub 下载并放入“应用程序”后，macOS 可能阻止打开。确认来源后可按 [Apple 官方说明](https://support.apple.com/zh-cn/102445)，在“系统设置 → 隐私与安全性”找到 ZashDock，选择“仍要打开”，再完成系统确认。

## 验证与边界

本地实际运行 `xcodebuild test`：63 项通过、1 项可选个人后端网络测试跳过，新增两项测试在旧实现中失败、修复后通过。实际 arm64 Debug 构建和归档还原验证通过；正式发行还会执行对应源码的 GitHub CI、Release 归档、签名及匹配 dSYM 检查。结果和运行环境见 [测试说明](https://github.com/MiracleHYH/ZashDock/blob/main/Docs/TESTING.md)。

空 profile 预检验证资源和渲染，不模拟所有用户数据上的上游迁移路径。端口迁移继续对超限或不支持的数据库结构停止操作并保留源数据；本次没有扩展 GeoIP 二进制库的跨 Origin 迁移范围。未增加独立 macOS 26.0 设备或真实 Sparkle 安装替换全过程的验收记录。
