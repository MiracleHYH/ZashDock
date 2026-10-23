# 独立进程存储验收

运行 `Scripts/test-storage-processes.sh`。仅验证日常持久化时可运行 `Scripts/test-storage-processes.sh --persistence-only`。

脚本使用 Xcode 的 `swiftc` 编译 arm64、macOS 26.0 最低部署目标的独立测试 App，完整模式直接编译生产 `OriginStorageTransfer.swift`。它与生产 App 的 Bundle ID 不同，每个场景使用新建的随机持久 DataStore UUID；不打开 `.default()`，不访问 Keychain，不生成 LocalStorage/IndexedDB 内容的原生快照文件。

每一步直接启动独立 App 进程并等待它结束。结果只记录 PID、阶段、端口元数据和 sentinel 连接数；网页数据仅留在测试 WebKit profile。测试结束使用公开 API 删除这些明确标记的测试 profile。

覆盖场景：

- 写入两个官方字段格式的虚构 Remote、选中项、主题、特殊 LocalStorage 字符串，然后正常退出；另一个 PID 读回。
- 按官方 v3.29.1 的两个数据库结构写入 `base64` 背景 DataURL、`connection-history` JSON 字符串，跨进程核对。
- 另一进程监听旧端口并统计连接。通过生产 Transfer 读取旧 Origin、恢复并验证新 Origin，要求旧端口连接数为 0。
- 迁移进程退出后，新进程验证目标数据，再清理旧 Origin；最后再启动一个进程确认目标数据仍存在。
- 由外部脚本发送真正的 `SIGKILL`，分别中断写入进程、端口元数据提交前和提交后；新进程按主配置选择的端口验证。

**证据边界：** 这是独立测试 App 的跨进程验收，不是同进程释放 WebPage，也不是操作系统重启。测试 App 未开启 App Sandbox；生产沙盒兼容性由单独的 Xcode 宿主测试验证。提交前后中断场景只建立“原子主端口配置 + 待清理端口”这一最小元数据契约，不构成生产 AppModel 全流程强退证明。提交后中断在元数据提交、目标读回和短暂 sentinel 观察后发生。

结果保存在被忽略的 `build/verification/storage-processes.*/`，包括 `process-pids.txt`、每阶段 JSON 和脱敏日志。2026-10-23 完整实跑：19 个不同 PID、三个 `SIGKILL` 边界、旧端口连接数 0，整个脚本及测试 profile 清理退出 0；系统为 macOS 27.0.1、Xcode 27.1。macOS 26 的真实运行仍需另行验证。
