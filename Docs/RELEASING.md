# ZashDock 构建、发布与应用更新

ZashDock 原生应用的源码、发布包和应用更新均使用 [MiracleHYH/ZashDock](https://github.com/MiracleHYH/ZashDock)。Zashboard 网页资源仍通过 Zephyruso/zashboard 官方 Releases 独立安装和更新；二者的版本、下载来源及保留规则互不混用。

首次源码推送阶段仅提交了源码和配置，没有创建 Release 或发行标签。仓库中的初始 `appcast.xml` 是已签名的空 Feed；它不代表存在可下载的正式版本。应用的 Sparkle Feed 固定为：

```text
https://raw.githubusercontent.com/MiracleHYH/ZashDock/main/appcast.xml
```

## 首个正式版：v1.0.0

本项目通过 GitHub Releases 直接分发，不需要上架 App Store。首个正式版准备使用标签 `v1.0.0`，应用的 `CFBundleShortVersionString` 为 `1.0.0`、`CFBundleVersion` 为 `2`，使此前 Build `1` 的试用安装能识别更新。维护者目前没有 Apple Developer Program 会员，因此显式选择 `signing_mode=adhoc`，使用实际 arm64 Release Archive 和 ad hoc 签名。

正式版定位与 Apple 的分发信任机制分别记录。Apple 的 Developer ID 签名、公证与 App Store 上架是不同事项：本次没有 Developer ID 身份，没有公证票据或装订，`codesign` 完整性检查成功也不代表 Gatekeeper 接受。**网络下载后的应用可能被 Gatekeeper 阻止启动**；尚未在全新独立 Mac 上完成下载到首次启动的完整验收。相关要求见 [Apple 软件分发说明](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)。开发者可按 [README](https://github.com/MiracleHYH/ZashDock/blob/main/README.md#构建与运行) 从源码自行构建。

此次正式发行准备遵循以下要求：

1. 固定并审查源码提交，完成实际 Release 归档、arm64/Bundle ID/版本/沙盒权限/签名完整性检查，验证包中没有 Zashboard dist、网页配置、测试插件、密钥或个人信息。
2. 保留与归档程序 UUID 一致的 dSYM，仅生成白名单诊断元数据。运行对应源码的 CI 并确认成功后，再按同一源码提交创建正式 Release。
3. 计划上传应用 ZIP、`SHA256SUMS.txt`、独立 dSYM ZIP、白名单构建元数据和诊断摘要。最终文件名、源码提交及摘要以实际 Release 资产为准，不上传整个 Archive、工作目录或测试日志。
4. 使用专用 Sparkle 私钥签名应用 ZIP 和 Feed，并用应用内公钥独立验证；将正式条目写入稳定 `appcast.xml`。该签名证明更新包和 Feed 的完整性，不提供 Apple Developer ID 身份，也不等同 Apple 公证。
5. 后续发行的 **Build 必须大于 `2` 并持续递增**；标签、公开资产及其摘要不得原地覆盖。

公开说明源文件为 [RELEASE-NOTES-1.0.0.md](https://github.com/MiracleHYH/ZashDock/blob/main/Docs/RELEASE-NOTES-1.0.0.md)，发行脚本将复制其正文并追加自动构建信息。默认 `developer-id` 模式仍要求 Apple 证书及公证凭据；只有显式选择 `adhoc` 才使用本次模式，不存在凭据缺失后的隐式降级。

ad hoc Release 保留 App Sandbox 和 Hardened Runtime。由于此模式没有 Apple Team ID，加载 Sparkle 动态框架需要临时加入 `com.apple.security.cs.disable-library-validation` 例外；它降低动态库同团队签名验证的防护，仅在用户显式选择的 `adhoc` 发布模式生效，不写入共享 entitlements。默认 `developer-id` 模式不允许此例外。该选择依据 [Apple 库验证说明](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation) 和 [Sparkle 官方集成说明](https://sparkle-project.org/documentation/)，不关闭系统 Gatekeeper 或 App Sandbox。

## 持续集成

`Build and test` 在 `main` 推送、Pull Request 和手动触发时运行。使用 GitHub 标准 `macos-26` Apple Silicon runner，检查 arm64、执行 Core 测试和实际 `xcodebuild test`，上传供开发使用的 ad hoc Debug App ZIP 及测试记录，保留 7 天。官方 Actions 固定到提交 SHA；不使用第三方构建 Action。Runner 架构依据 [GitHub 官方规格](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。

CI 只有 `contents: read` 权限，不持有发行证书、Sparkle 私钥或公证凭据，不创建 Release。官方网页和真实后端的可选网络测试不默认启用。GitHub 上第一次 CI 的实际结果应以仓库 Actions 页面为准，不能用本地历史测试记录代替。

## 首次正式发布前的仓库配置

在 GitHub 中完成以下配置，然后再手动运行发行工作流：

1. 工作流和脚本已限定仅从 `main` 手动发布，并在关键步骤复查源码提交。Job 使用 `release` 环境记录部署；YAML 中的环境名称本身不代表存在额外审批。维护者可在 Settings → Environments 为它增加部署分支规则或 Required reviewers，这些仓库访问策略需单独配置，不能把工作流中的名称当作已启用的保护。
2. 建议在 Settings → General 的 Releases 区域启用 **Enable release immutability**，由 GitHub 在发布后锁定资产和标签。该设置的查询需要管理员权限，因此工作流不申请额外管理权限；未启用时脚本仍通过拒绝重复版本、标签和资产覆盖保护发布历史。参见 [GitHub 不可变发行说明](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)。
3. 将所选 `signing_mode` 所需的凭据配置为 `release` Environment Secrets，或按仓库策略使用 Repository Secrets。只有发行 Job 读取这些值。普通 CI 不需要它们；两种模式均需要 `SPARKLE_PRIVATE_KEY`。
4. 确认发布 Job 的 `GITHUB_TOKEN` 能创建发行并向 `main` 提交 Feed。工作流仅对该 Job 声明 `contents: write`；其他 Job 为只读。如果分支规则不允许直接提交 Feed，需按仓库策略配置发布身份或采用经审核的 Feed 提交流程。脚本不会强制推送或绕过分支规则。

| Secret | 适用模式 | 内容 |
| --- | --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | `developer-id` | 包含私钥的 **Developer ID Application** `.p12` 导出的 Base64 文本；不是 Developer ID Installer 或 ad hoc 证书 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | `developer-id` | 该 `.p12` 的导出密码 |
| `APPLE_TEAM_ID` | `developer-id` | 证书所属 Apple Developer Team ID，10 位字母数字 |
| `NOTARY_KEY_P8_BASE64` | `developer-id` | App Store Connect API `.p8` 私钥文件的 Base64 文本，用于 `notarytool` |
| `NOTARY_KEY_ID` | `developer-id` | 上述 API Key ID，10 位字母数字 |
| `NOTARY_ISSUER_ID` | `developer-id` | 上述 API Key 的 Issuer UUID |
| `SPARKLE_PRIVATE_KEY` | 两种模式 | 官方 Sparkle `generate_keys` 导出的 Base64 密钥文本；当前格式为 32 字节种子，直接保存文本，**不要再次 Base64 编码** |

`GH_TOKEN` 使用工作流自动提供的 `github.token`，不需要另存个人 PAT。所选模式的任一必需 Secret 缺失都会明确报出缺失名称并停止，不会跳过 Sparkle 签名或自动切换为 ad hoc。`adhoc` 模式不要求 Apple 发行凭据。

2026-10-23 接入时已配置仓库加密 Secret `SPARKLE_PRIVATE_KEY`。维护者目前没有 Apple Developer Program 会员，因此此次正式版显式选择 `adhoc`。将来选择 `developer-id` 时须先配置 Apple 证书、Team ID 和公证凭据。源码推送与普通 CI 不受影响。

Sparkle 公钥仅保存在应用 `Info.plist` 的 `SUPublicEDKey`，不再维护一份 Repository Variable。发布脚本从私钥派生公钥，并与源码和已导出 App 的公钥分别比对。应用要求 ZIP 和 Feed 的 EdDSA 签名；不能用 HTTPS 或 Developer ID 签名代替 Sparkle 签名。

妥善离线备份 Sparkle 私钥，并保留稳定的发布身份。不要将 `.p12`、`.p8`、Keychain、私钥或含凭据的环境文件提交 Git。仓库 `.gitignore` 已覆盖这些本地文件。密钥轮换需要专门的兼容迁移设计，不能直接生成另一把密钥替换现有公钥，否则已安装应用无法验证更新。

## 手动正式发布

准备好并审查 `main` 最新提交，确认其 CI 成功后，打开 Actions → **Publish signed ZashDock** → Run workflow，选择 `main`：

| 输入 | 示例与规则 |
| --- | --- |
| `version` | `1.0.0`，不含 `v`；仅接受三段稳定版版本号 |
| `build_number` | 首个正式版为 `2`；1–999999999 的纯正整数，必须大于已有 Feed 中所有 Build，后续发行大于 `2` |
| `signing_mode` | 默认 `developer-id`；本次显式选择 `adhoc`。两种模式都进行 Sparkle 包和 Feed 签名 |
| `confirm` | 精确输入 `PUBLISH`；其他值不会进入发布 Job |

工作流仅由 `workflow_dispatch` 触发。源码推送、标签推送和首次推送都不会发布。固定并发组保证同一时间只有一个发行流程处理 Feed；Job 还会反复检查自己构建的提交仍是默认分支 `main` 的最新提交。

脚本通过 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 为本次 Archive 设置输入版本，导出后核对 App 的实际版本、Bundle ID、架构、公钥和 Feed 配置。标签为 `v<version>`，指向实际构建的源码提交；不允许复用现有标签、草稿或公开 Release。

发行流程依次执行：

1. 在尚未将发行凭据注入进程时重跑 Core 和实际 App 宿主测试，并对 ad-hoc Release Archive 执行符号工件安全回归；然后验证输入、必需凭据、默认分支、源码提交、现有标签和现有 Feed 签名，确认 Build 递增。
2. 按显式模式归档：`developer-id` 在临时 Keychain 导入 Developer ID Application 身份，Archive 后用 `developer-id` 方式导出；`adhoc` 使用 ad hoc Release 归档产物，不导入 Apple 身份或提交公证。
3. 检查所选模式的原生签名、hardened runtime、arm64 及实际 Bundle 版本；`developer-id` 另核对 Team ID，`adhoc` 记录无 Developer ID 身份的限制。两者都要求 Feed 验签失败不降级，并在解压更新前验签。
4. `developer-id` 用 `notarytool` 提交临时 ZIP，要求 Accepted 并检查公证日志；对导出的 App staple 并验证，再重新生成最终 ZIP。此顺序符合 [Apple 公证和 Staple 流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。`adhoc` 明确跳过此 Apple 公证阶段，发行说明披露 Gatekeeper 限制。
5. 下载固定版本 **Sparkle 2.10.0** 官方工具并验证固定 SHA-256。复制原 Feed，使用 `generate_appcast` 签名新 ZIP 和 Feed；保留全部旧条目，关闭差分包生成，核对新条目的版本、长度和下载 URL，并使用 App 公钥独立验证最终 ZIP 的 EdDSA 签名。
6. 创建草稿 Release，一次上传 `ZashDock-<version>-arm64.zip`、`appcast.xml`、`SHA256SUMS.txt`，以及下面说明的独立 dSYM ZIP、构建元数据与诊断摘要。全部验证完成才发布；启用仓库 Release immutability 时，GitHub 随即锁定资产及标签。此顺序遵循 [GitHub 不可变发行建议](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)。
7. 再次检查 `main` 未变，将已签名 Feed 原样提交并正常 fast-forward 推送到 `main`，供应用检查更新。

Feed 从官方 `generate_appcast` 自动获得 EdDSA 签名。**签名后不能重新排版、改变换行或手工修改 XML**；任何改动均需重新签名。Feed 生成与签名行为见 [Sparkle 官方文档](https://sparkle-project.org/documentation/)。旧条目未重新指向本次标签，历史 ZIP 仍使用各自按版本固定的 Release URL，脚本不会覆盖这些历史资产。

临时证书、私钥、API Key、Keychain、Archive 和工具文件在脚本退出时清理；只创建所选模式需要的临时凭据。Archive 成功后立即另存匹配的 dSYM 和白名单构建元数据，后续导出、公证或发布失败也不会连带删除这些文件。发行 Job 只上传明确列出的公开资产，不上传整个工作目录、Archive 或私钥。首次真实 Developer ID 签名和公证必须在具备对应凭据并实际运行后才能记为通过；ad hoc 正式版的成功不代表该 Apple 流程已完成。Sparkle 在线安装也需单独端到端验证。

## 崩溃符号与构建追溯

每个成功发行还附带三个按版本、Build 和架构命名的资产：

- `ZashDock-<version>-build<build>-arm64-dSYMs.zip`：主程序及静态链接 ZashDockCore 的匹配符号；不声称包含第三方 Sparkle 自身的符号。
- `ZashDock-<version>-build<build>-arm64-build-metadata.json`：源码提交、应用版本和 Build、arm64 UUID、最低系统、Xcode/SDK 版本、归档程序与符号 SHA-256，以及工作流链接。
- `ZashDock-<version>-build<build>-arm64-diagnostics-SHA256SUMS.txt`：前两项的摘要。

这些是独立 Release 资产，随对应发行长期保留，避免依赖会到期的 Actions artifact。启用不可变发行后，它们与其他发行资产一同锁定。失败运行的诊断文件通过 `always()` 上传为 `release-diagnostics-<run>-<attempt>` artifact，保留 90 天；应在到期前下载调查需要的文件。工作流 artifact 可能因保留策略或运行记录删除而消失，不能充当永久符号仓库，参见 [GitHub artifact 保留规则](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)。

`prepare-release-diagnostics.swift` 先核对归档应用与 dSYM 的 arm64 UUID、Bundle ID、版本和 Build。ZIP 仅包含 DWARF 文件和重建的白名单 Info.plist；不复制任意附加文件、扩展属性、资源分支、环境变量、日志、证书、密钥或完整 Archive。诊断输出始终位于独立目录，**不会进入 `generate_appcast` 扫描的 updates 目录**。导出 App 后还会再次比较 UUID；签名和 Staple 可能改变文件摘要，因此符号配对以 UUID 为准，最终安装包摘要仍使用发行的 `SHA256SUMS.txt`。

保留原始匹配 dSYM，不要为已发行版本重新编译并假定符号兼容。使用崩溃报告中的 UUID 选择对应资产；同一源码的另一轮构建也可能产生不同 UUID。操作依据见 [Apple 崩溃符号化说明](https://developer.apple.com/documentation/xcode/adding-identifiable-symbol-names-to-a-crash-report)。

2026-10-23 已实际执行本机 ad-hoc arm64 Release Archive，结果 `ARCHIVE SUCCEEDED`，并运行：

```sh
Scripts/test-release-diagnostics.sh build/audit/release-diagnostics/ZashDock.xcarchive
```

7 项检查通过：实际 dSYM/程序 UUID、ZIP 内容和摘要/来源信息；现有输出保留；未知凭据参数拒绝；无效工作流信息拒绝且清除部分输出；缺失符号拒绝；符号链接拒绝；不同 arm64 程序 UUID 拒绝。测试额外放入虚构私钥文件、Info.plist 字段和扩展属性 canary，确认均未打包。构建及测试日志位于被忽略的 `build/audit/release-diagnostics/`。这次 Archive 包含开发中的修复，传入 HEAD 用于验证元数据格式与链路，不能当作已发行源码追溯记录；正式工作流会在构建前要求源码匹配 `GITHUB_SHA` 且跟踪文件干净。该次诊断回归仅验证本机归档和符号工具，没有执行 `--publish`、公证、Tag 或 Release。

## 失败恢复

发布前失败不会更改线上 Feed。若草稿已经创建但尚未公开，先检查工作流失败原因和草稿状态；脚本不会自动覆盖草稿、标签或资产。修正后使用新的版本和 Build，或按维护者审查结果处理未发布草稿。

GitHub Release 与 Git 分支提交无法组成一个原子事务。如果公开发行成功后，`main` 被并发更新或分支规则拒绝 Feed 推送，脚本会保留已经公开的发行和原有有效 Feed，并明确报错。该版本暂时不会通过旧 Feed 向用户推荐；不可覆盖已经公开的 ZIP、Feed 资产或标签。

恢复时从最新 `main` 开始，核对公开 Release 的标签和源码提交，下载其已经发布的 ZIP 并校验公开摘要。将最新有效 Feed 和该 ZIP 放入独立临时目录，使用同一固定版本的 `generate_appcast` 与原 Sparkle 密钥重新生成并验证签名 Feed，再审查提交更新后的 `appcast.xml`。必须保留其间新增的条目，不能直接强推之前失败流程生成的旧 Feed。不要通过再次运行同一版本发布流程绕过重复发行检查。

WebKit 中的 Remote 和网页设置、原生普通配置及早期开发版遗留的只读兼容密文均独立于应用发布包和 Zashboard 资源目录。日常不创建新的原生配置快照。应用更新不能清除这些数据；真实更新前后数据保留和 Sparkle 安装流程仍需在正式签名测试版本上进行端到端验收。
