# ZashDock 构建、发布与应用更新

ZashDock 原生应用的源码、发布包和应用更新均使用 [MiracleHYH/ZashDock](https://github.com/MiracleHYH/ZashDock)。Zashboard 网页资源仍通过 Zephyruso/zashboard 官方 Releases 独立安装和更新；二者的版本、下载来源及保留规则互不混用。

首次推送仅提交源码和配置，不创建 Release，也不推送发行标签。仓库中的初始 `appcast.xml` 是已签名的空 Feed；它不代表存在可下载的正式版本。应用的 Sparkle Feed 固定为：

```text
https://raw.githubusercontent.com/MiracleHYH/ZashDock/main/appcast.xml
```

## 持续集成

`Build and test` 在 `main` 推送、Pull Request 和手动触发时运行。使用 GitHub 标准 `macos-26` Apple Silicon runner，检查 arm64、执行 Core 测试和实际 `xcodebuild test`，上传供开发使用的 ad hoc Debug App ZIP 及测试记录，保留 7 天。官方 Actions 固定到提交 SHA；不使用第三方构建 Action。Runner 架构依据 [GitHub 官方规格](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。

CI 只有 `contents: read` 权限，不持有发行证书、Sparkle 私钥或公证凭据，不创建 Release。官方网页和真实后端的可选网络测试不默认启用。GitHub 上第一次 CI 的实际结果应以仓库 Actions 页面为准，不能用本地历史测试记录代替。

## 首次正式发布前的仓库配置

在 GitHub 中完成以下配置，然后再手动运行发行工作流：

1. 在仓库 Settings → Environments 创建 `release` 环境，设置允许部署的分支为 `main`，并配置 Required reviewers。YAML 中写有 `environment: release` 本身不会自动创建审批保护；应在配置完成后才使用该工作流。
2. 建议在 Settings → General 的 Releases 区域启用 **Enable release immutability**，由 GitHub 在发布后锁定资产和标签。该设置的查询需要管理员权限，因此工作流不申请额外管理权限；未启用时脚本仍通过拒绝重复版本、标签和资产覆盖保护发布历史。参见 [GitHub 不可变发行说明](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)。
3. 将下面的凭据配置为 `release` Environment Secrets，或按仓库策略使用 Repository Secrets。只有发行 Job 读取这些值。普通 CI 不需要它们。
4. 确认发布 Job 的 `GITHUB_TOKEN` 能创建发行并向 `main` 提交 Feed。工作流仅对该 Job 声明 `contents: write`；其他 Job 为只读。如果分支规则不允许直接提交 Feed，需按仓库策略配置发布身份或采用经审核的 Feed 提交流程。脚本不会强制推送或绕过分支规则。

| Secret | 内容 |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | 包含私钥的 **Developer ID Application** `.p12` 导出的 Base64 文本；不是 Developer ID Installer 或 ad hoc 证书 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | 该 `.p12` 的导出密码 |
| `APPLE_TEAM_ID` | 证书所属 Apple Developer Team ID，10 位字母数字 |
| `NOTARY_KEY_P8_BASE64` | App Store Connect API `.p8` 私钥文件的 Base64 文本，用于 `notarytool` |
| `NOTARY_KEY_ID` | 上述 API Key ID，10 位字母数字 |
| `NOTARY_ISSUER_ID` | 上述 API Key 的 Issuer UUID |
| `SPARKLE_PRIVATE_KEY` | 官方 Sparkle `generate_keys` 导出的 Base64 密钥文本；当前格式为 32 字节种子，直接保存文本，**不要再次 Base64 编码** |

`GH_TOKEN` 使用工作流自动提供的 `github.token`，不需要另存个人 PAT。任何必需 Secret 缺失都会明确报出缺失名称并停止，不会降级为未签名发布。未提供 Apple 发行凭据时，源码、CI 和本机 Debug 开发仍可使用。

2026-10-23 本次接入已配置仓库加密 Secret `SPARKLE_PRIVATE_KEY`。其余 Apple 发行证书、Team ID 和公证凭据尚待维护者在正式发布前配置；首次源码推送与普通 CI 不受影响。

Sparkle 公钥仅保存在应用 `Info.plist` 的 `SUPublicEDKey`，不再维护一份 Repository Variable。发布脚本从私钥派生公钥，并与源码和已导出 App 的公钥分别比对。应用要求 ZIP 和 Feed 的 EdDSA 签名；不能用 HTTPS 或 Developer ID 签名代替 Sparkle 签名。

妥善离线备份 Sparkle 私钥，并保留稳定的发布身份。不要将 `.p12`、`.p8`、Keychain、私钥或含凭据的环境文件提交 Git。仓库 `.gitignore` 已覆盖这些本地文件。密钥轮换需要专门的兼容迁移设计，不能直接生成另一把密钥替换现有公钥，否则已安装应用无法验证更新。

## 手动发布

准备好并审查 `main` 最新提交，确认其 CI 成功后，打开 Actions → **Publish signed ZashDock** → Run workflow，选择 `main`：

| 输入 | 示例与规则 |
| --- | --- |
| `version` | `1.0.0`，不含 `v`；仅接受三段稳定版版本号 |
| `build_number` | `1`，1–999999999 的纯正整数，必须大于已有 Feed 中所有 Build |
| `confirm` | 精确输入 `PUBLISH`；其他值不会进入发布 Job |

工作流仅由 `workflow_dispatch` 触发。源码推送、标签推送和首次推送都不会发布。固定并发组保证同一时间只有一个发行流程处理 Feed；Job 还会反复检查自己构建的提交仍是默认分支 `main` 的最新提交。

脚本通过 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 为本次 Archive 设置输入版本，导出后核对 App 的实际版本、Bundle ID、架构、公钥和 Feed 配置。标签为 `v<version>`，指向实际构建的源码提交；不允许复用现有标签、草稿或公开 Release。

发行流程依次执行：

1. 在尚未将发行凭据注入进程时重跑 Core 和实际 App 宿主测试；然后验证输入、必需凭据、默认分支、源码提交、现有标签和现有 Feed 签名，确认 Build 递增。
2. 在临时 Keychain 导入 Developer ID Application 身份，Archive 后用 `developer-id` 方式导出。
3. 检查原生签名、Team ID、hardened runtime、arm64 及实际 Bundle 版本，同时要求 Feed 验签失败不降级，并在解压更新前验签。
4. 用 `notarytool` 提交临时 ZIP，要求 Accepted 并检查公证日志；对导出的 App staple 并验证，再重新生成最终 ZIP。此顺序符合 [Apple 公证和 Staple 流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。
5. 下载固定版本 **Sparkle 2.10.0** 官方工具并验证固定 SHA-256。复制原 Feed，使用 `generate_appcast` 签名新 ZIP 和 Feed；保留全部旧条目，关闭差分包生成，核对新条目的版本、长度和下载 URL，并使用 App 公钥独立验证最终 ZIP 的 EdDSA 签名。
6. 创建草稿 Release，一次上传 `ZashDock-<version>-arm64.zip`、`appcast.xml` 和 `SHA256SUMS.txt`。全部验证完成才发布；启用仓库 Release immutability 时，GitHub 随即锁定资产及标签。此顺序遵循 [GitHub 不可变发行建议](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)。
7. 再次检查 `main` 未变，将已签名 Feed 原样提交并正常 fast-forward 推送到 `main`，供应用检查更新。

Feed 从官方 `generate_appcast` 自动获得 EdDSA 签名。**签名后不能重新排版、改变换行或手工修改 XML**；任何改动均需重新签名。Feed 生成与签名行为见 [Sparkle 官方文档](https://sparkle-project.org/documentation/)。旧条目未重新指向本次标签，历史 ZIP 仍使用各自按版本固定的 Release URL，脚本不会覆盖这些历史资产。

临时证书、私钥、API Key、Keychain、Archive 和工具文件在脚本退出时清理。发行 Job 仅将三个明确列出的公开资产上传到 Release，不上传整个工作目录或私钥。首次真实 Developer ID 签名、公证、在线更新及发布流程必须在配置凭据并实际手动运行后才能记为通过；本次接入并未执行正式发布。

## 失败恢复

发布前失败不会更改线上 Feed。若草稿已经创建但尚未公开，先检查工作流失败原因和草稿状态；脚本不会自动覆盖草稿、标签或资产。修正后使用新的版本和 Build，或按维护者审查结果处理未发布草稿。

GitHub Release 与 Git 分支提交无法组成一个原子事务。如果公开发行成功后，`main` 被并发更新或分支规则拒绝 Feed 推送，脚本会保留已经公开的发行和原有有效 Feed，并明确报错。该版本暂时不会通过旧 Feed 向用户推荐；不可覆盖已经公开的 ZIP、Feed 资产或标签。

恢复时从最新 `main` 开始，核对公开 Release 的标签和源码提交，下载其已经发布的 ZIP 并校验公开摘要。将最新有效 Feed 和该 ZIP 放入独立临时目录，使用同一固定版本的 `generate_appcast` 与原 Sparkle 密钥重新生成并验证签名 Feed，再审查提交更新后的 `appcast.xml`。必须保留其间新增的条目，不能直接强推之前失败流程生成的旧 Feed。不要通过再次运行同一版本发布流程绕过重复发行检查。

应用安装目录中的 Remote、设置和加密备份独立于应用发布包和 Zashboard 版本目录。应用更新不能清除这些数据；真实更新前后数据保留和 Sparkle 安装流程仍需在正式签名测试版本上进行端到端验收。
