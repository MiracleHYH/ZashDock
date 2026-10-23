# 原生 UI 实际验收记录

## 系统菜单与完整版本展示（当前）

2026-10-23，按用户最新要求移除主窗口右上角原生设置和版本控件。通过 CUA 操作直接复用当前生产视图、`ZashDockCommands` 和 `Settings` Scene 的隔离 App（`build/ui-simplification/`），使用独立 Bundle ID、临时应用目录与非持久 WebKit，不加载或重置生产 Remote。

- 主安装窗口截图和辅助功能树确认没有 Toolbar 或右上角按钮，首次页仍显示标题、下载按钮及右侧导入图标。
- 实际点击系统应用菜单中的 `Settings…` 可打开独立设置窗口；关闭后执行 ⌘, 再次打开，窗口 ID 为 `com_apple_SwiftUI_Settings_window`。系统当前为英文，因此该菜单项由系统显示为 `Settings…`。
- 设置的更新页在同一个“版本”区域同时显示 `ZashDock 版本 1.0.0 (1)` 和 `Zashboard 版本 v3.29.1`，截图确认无截断。后者仅为隔离 fixture 的已安装展示元数据，不声称 fixture 启动了真实官方页面。
- 实际点击生产菜单命令“关于 ZashDock”，标准 About 面板同时显示上述两行；未安装状态则明确显示“Zashboard 版本：尚未安装”。显式空默认版本项没有产生重复 Version 行；当前深色外观的文字可读，两行均完整。
- 两个隔离 App 最后均通过 ⌘Q 正常退出。没有修改系统外观、生产端口、Remote、Secret 或网页数据；未测试新版本在 macOS 26.0 实机上的显示。

本轮 Xcode 构建、回归测试和 Debug 交付证据见 [TESTING.md](TESTING.md)。以下保留旧界面的历史观察，旧 Toolbar、回滚配置与导入说明已被后续用户要求替代。

## 早期 Debug 界面（历史）

日期：2026-10-23（Asia/Shanghai）。通过 CUA 的原生辅助功能树、实际菜单/快捷键操作及一次主窗口截图检查完成。验收对象为最终 Debug 构建：

`build/Xcode/Build/Products/Debug/ZashDock.app`（相对于工程根目录）

验收期间暂停了同 Bundle ID 的测试宿主运行，观察到的主窗口为“安装 Zashboard”，不是测试宿主的“正在启动”。关于页显示 Wrapper `1.0.0 (1)`，Zashboard 尚未安装。这是当时构建的观察记录，不代表后续仓库更新功能已完成运行验收。

## 实际观察

| 项目 | 操作与观察 | 结果 |
| --- | --- | --- |
| A：首次安装页面 | 主窗口为原生安装页面，显示下载 SF Symbol、“首次使用需要安装官方网页资源。”、“安装最新稳定版”和“从本地官方 ZIP 导入…”按钮，以及“仅接受官方发布的 dist.zip；首次离线导入支持 v3.29.1。”提示。没有空白 WebView。 | 通过页面与控件检查；本次未点击安装或导入。 |
| 标准 Toolbar | 主窗口具有原生 Toolbar，右侧为“设置”齿轮按钮。截图中安装内容正常居中，按钮与说明可读。 | 通过当前浅色外观检查。 |
| Settings 入口 | `Command-,` 打开独立原生设置窗口，辅助功能窗口 ID 为 `com_apple_SwiftUI_Settings_window`。 | 通过。 |
| General／通用 | 显示端口输入框与当前端口 `9099`、“应用”、“自动选择并保存可用端口”、`1024–65535` 范围与迁移说明，以及关闭最后窗口后退出开关。开关当前为关闭。 | 内容可访问；未修改值或开关。 |
| Updates／更新 | 显示“尚未安装”“尚未检查”、“检查更新”“导入官方 ZIP…”；历史保留 Stepper 当前为 `1`，说明不含当前版本、总保留上限为 `2`，并显示暂无可回滚本地版本。 | 内容可访问；未检查网络更新、导入或修改保留数。 |
| About／关于 | 显示 `1.0.0 (1)`、Zashboard 尚未安装、官方项目与 MIT License 链接。链接目标分别为 `github.com/Zephyruso/zashboard` 和该仓库 `blob/main/LICENSE`。 | 内容与链接目标检查通过；未打开外部浏览器。 |
| 关闭设置 | 设置窗口中执行 `Command-W`，返回仍存在的主安装窗口。 | 通过。 |
| 系统菜单 | 应用菜单包含 About、Settings、Services、Hide、Quit；菜单栏同时有 Edit、View、Window、Help。实际点击系统 Quit 后应用退出。 | 通过已操作菜单。 |
| 关闭主窗口并保留进程 | 独立复核中执行 `Command-W`，CUA 返回 `noWindowsAvailable`；随后应用清单确认 `app.zashdock.mac` 仍运行，符合当前“关闭最后一个窗口后退出”为关闭的设置。 | 通过。 |
| 仍运行时重开窗口 | 在上述无窗口但进程仍运行的状态，对精确构建路径执行系统 `open`，主窗口 `main` 恢复，并正常显示原生安装页面。 | 通过。 |
| 完全退出后再次启动 | 系统 Quit 后辅助功能返回 `App quit`，应用清单确认不再运行；系统 `open` 后重新出现正常安装页面。 | 通过。 |
| `Command-Q` 退出 | 对可见主窗口执行 `Command-Q`，观察到 `App quit`，应用清单确认不再运行。最后一次退出也以进程不存在状态得到确认。 | 通过；本次验收结束时保持退出。 |

## 工具环境说明

普通受限 Shell 执行 `open` 曾返回 LaunchServices `-10827 / kLSNoExecutableErr`。只读检查确认 Bundle 中的 `Contents/MacOS/ZashDock`、Debug dylib 和 `CFBundleExecutable` 实际存在且名称一致。随后仅针对同一条精确路径 `open` 命令使用工具沙箱外执行权限，命令成功，窗口正常恢复。未重置 LaunchServices、修改签名或更改系统设置。

因此本记录将该次 `-10827` 归为工具执行环境限制，不将其写为产品缺陷。后续关闭窗口／重开与完全退出／重开验证使用的是成功的系统 `open` 路径。

一次 CUA 重绑定曾返回 ScreenCaptureKit `-3811` 捕获错误；随后只读辅助功能状态正常，验收继续。`noWindowsAvailable`、`App quit` 和退出后 `procNotFound` 则与实际窗口或进程已关闭的观察一致，并通过应用清单交叉确认。

## 范围与边界

本次没有点击安装或 ZIP 导入，没有创建真实 Remote，没有更改端口、回滚数量、启动开关或系统外观。安装、迁移、版本更新、取消恢复和缓存行为的程序化实际测试结果见 [TESTING.md](TESTING.md)；本记录只报告上述真实 UI 操作，不以按钮存在代替其业务流程验收。

当前浅色外观的安装页面已通过截图目视检查。没有手动切换深色模式、辅助功能选项或测试已安装后的真实 Zashboard 主界面；这些不能依据本次观察宣称通过。截图由 CUA 直接查看，未额外保存图像资产。
