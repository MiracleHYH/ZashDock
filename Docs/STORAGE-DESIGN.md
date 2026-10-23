# WebKit 持久化与按需端口转移

日期：2026-10-23。本文描述已落地的存储实现，取代先前方案评估。用户已选择 WebKit 日常持久化、修改端口时一次性转移；原先持续维护原生加密快照的要求随此次选型调整。

## 单一日常数据源

生产 `AppModel`、`WebSession` 和 `OriginStorageTransfer` 共用 `WKWebsiteDataStore.default()`。Remote、选中后端及网页设置由官方 Zashboard 正常写入 WebKit，保留原始键值。日常运行不创建或维护原生 Remote 文件，没有常驻存储桥接、周期快照、Storage 方法包装或退出前 flush。重新加载同一网页也不会注入旧 seed。

普通 `configuration.json` 只保存端口、窗口行为及两项兼容/清理标记；`configuration.last-valid.json` 是这些小型元数据的恢复镜像。它们没有网页数据，不是另一套配置历史。网页资源安装也不携带对应 Remote 副本。

WebKit 将数据按 `scheme + host + port` 隔离。`setup/api-list` 等上游键不含面板端口，改变原生端口不能直接重命名这些键。默认持久 DataStore 保留会话间数据的能力来自 [Apple 的公开接口](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/default())；具体运行证据另见 [TESTING.md](TESTING.md)。

## 受支持的数据范围

`OriginStoragePayload` 是仅在单次操作中使用的内存值：

```text
localStorage: [String: String]
databases:
  base64: [String: String]
  connection-history: [String: String]
```

LocalStorage 包含所有键，不按 `config/` 前缀筛选；包括两个 Remote、`setup/active-uuid`、主题和其他上游状态，不解析或重写内部 JSON。特殊键如 `__proto__` 通过 JSON 字符串传参和无原型字典保留。若同一集合存在两个拼写不同但 Unicode NFC 等价的键，Swift 字典不能区分它们；脚本会在数据跨入 Swift 或目标首个写入之前拒绝操作，保留原数据，避免静默合并丢键。

IndexedDB 范围固定于官方 v3.29.1 的业务格式：两个数据库均 version 1，各有一个同名 objectStore，`keyPath="key"`，没有 autoIncrement 或索引，记录严格为 `{key, value: string}`。`base64` 保存背景 DataURL，`connection-history` 保存历史 JSON 字符串。空数据库和不存在的数据库按相同的空业务数据语义比较；不会为了空数据创建原先不存在的数据库。

源或目标出现未知数据库、未知版本/schema、非字符串记录、额外字段或超限数据时停止，避免只搬一部分却清掉源。当前实现**不承诺任意 IndexedDB、Blob、索引、Cookie、凭据、sessionStorage 或所有 WebsiteData 的跨 Origin 迁移**。未来上游结构变化需要先增加格式支持和回归，不能靠跳过未知数据继续提交。

| 限制 | 默认上限 |
| --- | --- |
| LocalStorage 原始键值字节 | 8 MiB |
| 每个业务数据库原始键值字节 | 32 MiB |
| 总编码 payload | 64 MiB |
| LocalStorage 键数量 | 8,192 |
| 每个数据库记录数 | 32,768 |
| 单键 UTF-8 字节 | 64 KiB |
| 单字符串 UTF-8 字节 | 32 MiB |
| 单次操作超时 | 20 秒 |

Swift 和 JavaScript 两端均校验格式及限额。恢复前先校验目标已有数据结构，等待数据库事务完成后再返回；取消/超时会中止持有的事务并关闭连接，不留下延迟写入任务。跨两个数据库和 LocalStorage 的操作不是一个底层原子事务，因此不能把目标写入失败描述成 WebKit 自动回滚；端口协调器始终在提交前保留源 Origin。

## 不连接旧端口的可信文档

`OriginStorageTransfer` 使用公开的 [WebPage.load(simulatedRequest:responseHTML:)](https://developer.apple.com/documentation/webkit/webpage/load(simulatedrequest:responsehtml:))，把应用生成的空 HTML 作为精确 loopback Origin 的模拟响应。它不需要旧服务仍在监听，也不向占用旧端口的程序请求页面。

文档具有禁止资源、连接、worker、frame 和表单的 CSP；导航策略只允许一次精确的 bootstrap 导航。原生随后用固定 `callJavaScript` 函数体执行读取/恢复，payload 经参数传入，脚本独立核验主框架及 `location.origin`。输入 Origin 只允许 `http://127.0.0.1:1024...65535`，不允许用户信息、路径、query 或 fragment。

这不是供官方网页调用的原生命令桥接，不暴露文件路径、命令或代理 HTTP API。源数据经临时内存转给目标 WebKit Origin；不写明文导出文件，不拼入 URL，不记录 Remote 或 Secret。

没有使用 WebKit 私有 Origin rename、内部目录/SQLite 修改，或篡改不透明 WebsiteData 导出字节。公开 `fetchData`/`restoreData` 没有 Origin 重映射参数，本项目不把它们当作改端口接口。

## 端口提交与失败恢复

`configuration.json` 是唯一持久端口提交点，正常流程只运行一个 HTTP 监听器：

1. 卸载官方网页并停止旧服务，避免转移期间继续写入。
2. 从旧 Origin 读取内存 payload，然后实际绑定目标端口。
3. 恢复到目标 Origin，重新读取并比对；加载官方网页，验证初始化首读、实际渲染和服务版本/nonce。
4. 原子写入新端口与 `pendingOriginCleanup=旧端口`。只有这一步成功才采用新配置。
5. 确保最新普通配置镜像写入成功，再清空旧 Origin 的 LocalStorage 和两个业务 objectStore；最后原子清除待清理标记。

提交前失败保留源数据、原端口元数据，关闭候选并尽力清空未提交目标、重启旧服务。源/目标数据不合并，切回曾用端口时以最新完整 payload 替换旧业务数据。旧端口被占时不影响可信读取；如果无法重新绑定旧服务，原数据仍保留，用户可在原生 Settings 指定新端口。

提交后清理失败保留新端口与待清理标记，下次启动重试。再次改端口前先处理未完成清理，避免丢失上一个旧端口标识。清理清空记录，不发出不可取消的 `deleteDatabase`，不删除 Cookie 或其他未迁移数据。

主配置写入后，镜像是 best effort；其失败不能报告成端口提交失败。在删除旧数据前 `ensureRecoveryCopy` 必须成功，所以旧镜像指向的业务数据在更新镜像前仍存在。正常 `load` 不静默使用镜像。配置损坏时由原生恢复界面显式保留可确认的原端口；没有有效镜像时要求用户输入原端口，避免猜测 9099 后展示空 Origin。可读取的原设置文件先保全；不可读取时不覆盖。

中断发生在端口提交前，启动仍选择旧 Origin；提交后选择新 Origin，待清理标记可重试。此协议处理配置层中断边界，不能额外保证 WebKit 未提供承诺的断电落盘时序；系统重启、各阶段强制断电并未因此自动得到验收。

## 更新保持同一份网页数据

更新不更改端口，不为资源安装保存用户配置。候选先将当前业务数据复制到独立 `.nonPersistent()` DataStore，在其中运行预检，防止失败候选在提交前破坏真实数据。预检成功后提交资源指针，再在持久 DataStore 启动新页面；只有持久 live 验证成功后才清理旧资源。应用只保留当前安装，没有资源回滚或历史保留设置。

提交后的页面失败保留新指针与暂未清理的原资源，提示重载，不自动回放旧用户数据。新代码可能已经迁移持久 schema。未知数据库/schema 会使转移或预检读取失败并保留现状。

## 一次性旧密文兼容

旧构建可能留下 `storage.aesgcm` 和 `.backup`。`LegacyWebStorageReader` 是只读兼容器：

- 无文件时返回 nil，不访问 Keychain；新安装不会创建旧密文或密钥。
- 只用 `SecItemCopyMatching` 读取原 service `app.zashdock.mac.storage`、account `primary` 的 32 字节密钥，绝不生成或替换密钥。
- 认证 AES-GCM v1 头与完整字典，主文件无效可用同一原密钥读取有效备份；拒绝符号链接、非普通文件、文件变更和超限输入。
- 不修复主文件、不轮换备份、不写明文、不导出、不删除原字节。

AppModel 在官方网页初始化前恢复旧 LocalStorage，保留当前 Origin 的两个业务数据库，读回核验后原子提交 `legacyStorageImported=true`。之后不再回放旧文件，用户在网页里有意清空也不会被重新填回。认证、Keychain 或提交失败时保留原文件并允许重试；该兼容入口不是日常恢复产品。

## 与上游设置导出的区别

固定 v3.29.1 的官方设置文件导出/导入只处理 `config/`，没有 Remote 的 `setup/` 键、背景数据库或连接历史。它保持原有用户用途，不能作为内部端口事务接口。URL 导入也发生在应用初始化后，不满足迁移首读顺序。依据见 [UPSTREAM.md](UPSTREAM.md)。

| 数据 | 官方设置文件导出 | 当前端口转移 |
| --- | --- | --- |
| `config/` 偏好 | 包含 | 包含所有原始字符串 |
| Remote 与选中项 | 不包含 | 完整 LocalStorage 包含 |
| 其他 LocalStorage | 不包含 | 包含 |
| 官方背景与连接历史 | 不包含 | 两个指定业务数据库 |
| Cookie / 任意数据库 | 不包含 | 不承诺迁移 |
| 平时原生 Remote 副本 | 无 | 无 |

## 回归与证据范围

正式回归覆盖 `OriginStorageTransferTests`、`PortMigrationTests`、`VersionLifecycleTests`、`LegacyStorageImportTests`、启动恢复及跨进程持久化用例。包括两个官方格式 Remote 和选中项、后续编辑/清空、背景 DataURL/历史、旧端口被占且 0 次请求、旧目标替换、绑定/提交/镜像失败、清理重试、配额/schema/取消和旧密文不重放。

早期 `OriginStorageAccessTests` 的 Blob/对象实验仅证明公开 API 可访问 Origin，不能当作生产通用数据库支持。独立进程脚本直接编译生产 Transfer，验证跨 PID 持久化、旧端口 0 次连接和最小元数据契约的 SIGKILL 边界；其测试 App 未开启 Sandbox，不构成生产 AppModel 全流程强退证明，详见 [独立进程验收说明](../Tests/OriginStorageProcessHarness/README.md)。生产沙盒另由 Xcode 宿主测试验证。

另有 [正式 AppModel 进程工具](../Tests/AppModelProcessHarness/README.md)，直接编译生产协调器，验证正常冷启动、旧端口占用后迁移、外部观察真实配置提交后 SIGKILL，以及后续冷启动读回与清理。本轮捕获了尚有待清理标记的提交，再由新进程完成清理。它不添加产品测试 hook，同样使用隔离 profile 且不启用 Sandbox；不宣称覆盖提交前所有强退时刻或 OS 重启。

阶段构建与实际测试结果以 [TESTING.md](TESTING.md) 为准；当前运行系统为 macOS 27.0.1，macOS 26 SDK 编译与 availability 不等于 macOS 26 实机或系统重启验收。历史审计保留当时证据，不覆盖本文件描述的现架构。
