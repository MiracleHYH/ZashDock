# 真实 AppModel 跨进程回归

在 Apple Silicon、macOS 26+、已初始化的完整 Xcode 与 `jq` 环境执行：

```sh
Scripts/test-appmodel-processes.sh
```

脚本在独立 scratch 目录构建 Core，将正式 `AppModel.swift`、`WebSession.swift`、`WebInteractionCoordinator.swift` 和 `OriginStorageTransfer.swift` 编译进不可见的 AppKit 测试 App。无需给正式产品添加测试 hook，不占用 UI 焦点，不执行 Release。

所有进程显式传入随机 `WKWebsiteDataStore(forIdentifier:)` 和临时 `AppPaths`。拒绝读取 Keychain 的 reader 替换正式 reader。WebKit 中保存两个虚构 Remote、当前选中项、设置、特殊字符键、官方 `base64` 和 `connection-history` 数据库。原生 fixture 文件只含随机 profile 标识、端口和版本元数据；报告不保存网页数据。

初始配置标记为已自动管理，两个 fixture 端口都从 49152–65535 中实际绑定取得。测试通过正式 `AppModel` 构造器注入候选顺序，将占用恢复的目标固定为 fixture 的新端口；生产默认仍使用随机候选。注入只控制候选，不代替监听、迁移、核验或持久提交，也不在产品中增加提交回调。

测试按真实进程生命周期执行：

1. 正式 AppModel 启动服务器，网页写入 LocalStorage 和两个 IndexedDB，等待严格事务完成，正常退出。
2. 全新进程重新启动 AppModel，验证网页首个脚本读取到完整 LocalStorage，再独立读取两个数据库，正常退出。
3. 独立 sentinel 进程占用原端口。新的 AppModel 进程在正式 `start()` 内遇到绑定失败后自动选择候选并迁移数据，不经过 unavailable 页面或显式调用 `changePort`。启动前先写入无业务数据的观察标记，让 shell 覆盖完整自动恢复阶段。
4. shell 从外部观察正式 `configuration.json` 的端口提交，立即发出真实 `SIGKILL`。未注入产品回调；强退可能发生在提交后的旧 Origin 清理中，也可能在清理完成后。
5. 原端口继续被占用，两个全新进程各自重启正式 AppModel，验证新端口、首个脚本读到的两个 Remote、两个数据库、旧 Origin 清理和配置提交。sentinel 网络连接数必须为 0。

构建和脱敏证据位于 `build/AppModelProcessHarness/` 与 `build/verification/appmodel-processes.*/`。退出 trap 仅根据本轮 fixture marker 清理该随机 WebKit profile。脚本本身不启用 App Sandbox；项目的 `xcodebuild` 集成测试另行验证实际 Sandbox 宿主。此脚本不宣称覆盖操作系统重启、断电或提交前任意时刻强退。
