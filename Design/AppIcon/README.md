# ZashDock 应用图标

当前图标为蓝靛色底与磨砂玻璃带状 Z，底部横笔表现停靠底座。图像使用内置 **image_gen** 生成并做一次定向修整，未使用 CLI/API fallback。原始选定输出保存在本目录的 [ZashDock-icon.png](ZashDock-icon.png)，保留透明通道。

运行 `Scripts/generate-app-icons.sh`，由系统 `sips` 仅转换分辨率，生成 `Sources/ZashDock/Resources/Assets.xcassets/AppIcon.appiconset/` 中的10张16–1024像素PNG。原图不随应用打包。Xcode 的 Debug 和 Release 均设置 `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`，由资源编译器生成并关联应用图标；Bundle ID 不变。

`Scripts/build-debug.sh` 在复制并验证 `build/Debug/ZashDock.app` 后，使用公开 `LSRegisterURL` 定向登记最终副本。Xcode 自动登记的是其 DerivedData 产物，不能代替对复制副本的登记。更新图标后，已运行会话可能仍保留旧显示，需正常退出并按最终路径重开；不清空全局缓存、不重启 Dock，也不在产品内强设运行时图标。

Apple 当前仍支持 macOS AppIcon asset catalog，本项目采用这一单图资源路径。Icon Composer 是后续制作分层及多外观图标的可选方向：[配置应用图标](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)。

## 生成提示

首次生成：

> Use case: logo-brand. Asset type: production macOS application icon for ZashDock, a lightweight native desktop home for the Zashboard dashboard. Generate one single finished icon, square 1024 by 1024 pixels. A bold, beautifully balanced uppercase Z formed as one continuous folded frosted-glass ribbon, with its lower horizontal stroke subtly evoking a docking base. Center it on a deep cobalt-to-indigo rounded-square tile with a restrained luminous cyan edge and gentle dimensional lighting. Contemporary native macOS quality, clean sculpted geometry, front-facing orthographic view, quiet and professional, excellent silhouette and legibility at 16 and 32 pixels. The Z is the only mark; no additional letters, no wordmark, no tiny UI, no network nodes, no rings, no cables, no dashboard screenshot, no product mockup. Keep generous consistent interior margins, no external cast shadow, actual transparent pixels outside the rounded tile. Precise smooth edges, restrained material depth, no noisy texture, no watermark. Deliver exactly one icon, not a sheet of alternatives.

最终修整提示（以上一张图为编辑对象，透明背景）：

> Refine this exact app icon for shipping. Keep the same centered folded glass Z silhouette, its legible proportions, and the blue-indigo tile. Change only the outer finish: remove the strong electric cyan/neon outer glow and all scattered/stray pixels or colored specks outside the rounded square. Give the tile an exceptionally clean, precise smooth rounded-square edge with a subtle soft highlight contained INSIDE the edge. Exterior pixels must be entirely transparent, with clean antialiasing, and no external shadow or halo. Tone down the top and left neon rim to a quiet native macOS material finish; keep the Z crisp and recognizable at small sizes. Preserve transparent background. Exactly square canvas 1024x1024, single icon, no text or additional symbols, no mockup.

选定的工具输出实际为1254×1254；打包时按槽位缩放，最大槽位为1024×1024。提示中的尺寸是生成意图，不替代对实际输出及构建产物的校验。
