import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import ZashDockCore

@main
struct ZashDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @State private var model = AppModel()
    @State private var wrapperUpdater = WrapperUpdateController()
    var body: some Scene {
        Window("ZashDock", id: "main") {
            MainWindow(model: model).task {
                delegate.model = model
                delegate.reopenWindow = { openWindow(id: "main") }
                if NSClassFromString("XCTestCase") == nil {
                    wrapperUpdater.start()
                    await model.start()
                }
            }
        }.defaultSize(width: 1160, height: 780)
            .commands { ZashDockCommands(model: model, wrapperUpdater: wrapperUpdater) }
        Settings { SettingsView(model: model, wrapperUpdater: wrapperUpdater) }
    }
}

struct ZashDockCommands: Commands {
    let model: AppModel
    let wrapperUpdater: WrapperUpdateController
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 ZashDock") { showAbout() }
        }
        CommandGroup(after: .appInfo) {
            Button("检查 ZashDock 更新…") { wrapperUpdater.checkForUpdates() }
                .disabled(!wrapperUpdater.canCheckForUpdates)
        }
        CommandGroup(after: .toolbar) {
            Button("重新载入 Zashboard") { model.reload() }
                .keyboardShortcut("r").disabled(model.currentVersion == nil || model.isBusy)
            Button("检查 Zashboard 更新…") { model.checkForUpdates() }.disabled(model.isBusy || model.updater == nil)
        }
    }

    private func showAbout() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let versions = NSAttributedString(
            string: "ZashDock 版本：\(wrapperUpdater.versionDescription)\nZashboard 版本：\(model.zashboardVersionDescription)",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .paragraphStyle: paragraph]
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "ZashDock", .applicationVersion: "", .version: "", .credits: versions
        ])
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var importing = false
    var body: some View {
        Group {
            if model.phase == .configurationRecovery {
                ConfigurationRecoveryView(model: model)
            } else if model.phase == .ready, let session = model.session {
                WebView(session.page).webViewMagnificationGestures(.enabled).allowsHitTesting(!model.isBusy)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: model.phase == .damaged ? "wrench.and.screwdriver" : "square.and.arrow.down").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text(title).font(.largeTitle.bold())
                    if model.phase != .uninstalled {
                        Text(model.updater?.isBusy == true ? model.updater?.status ?? "" : model.status)
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if model.phase == .starting || model.isBusy {
                        if let progress = model.updater?.progress {
                            ProgressView(value: progress.fractionCompleted).frame(width: 320)
                            Text("\(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))").font(.caption.monospacedDigit())
                        } else { ProgressView() }
                        if model.isBusy { Button("取消", role: .cancel) { model.cancel() } }
                    } else {
                        if model.phase == .unavailable {
                            if model.session?.hasRuntimeFailure == true {
                                Button("重新载入 Zashboard") { model.reload() }.buttonStyle(.borderedProminent)
                            }
                            SettingsLink { Text("在设置中检查或更改端口") }.buttonStyle(.borderedProminent)
                        }
                        HStack(spacing: 12) {
                            Button("下载并安装", systemImage: "arrow.down.circle") { model.install() }
                                .buttonStyle(.borderedProminent)
                            Button("导入 ZIP", systemImage: "square.and.arrow.down.on.square") { importing = true }
                                .labelStyle(.iconOnly).help("导入 ZIP…")
                        }.controlSize(.large).disabled(!model.canManageVersions)
                        if model.currentVersion != nil || model.phase == .unavailable { Button("重试启动") { model.retryStart() } }
                    }
                }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .overlay(alignment: .top) {
            if model.isBusy && model.phase == .ready {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.updater?.isBusy == true ? model.updater?.status ?? model.status : model.status).font(.callout)
                    if let progress = model.updater?.progress, model.updater?.isBusy == true {
                        ProgressView(value: progress.fractionCompleted).frame(width: 120).accessibilityLabel("下载进度")
                    }
                    Button("取消", role: .cancel) { model.cancel() }
                }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): model.install(zip: url)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { model.errorMessage = error.localizedDescription }
            }
        }
        .alert("ZashDock", isPresented: Binding(get: { model.errorMessage != nil && !model.settingsVisible }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var title: String {
        switch model.phase {
        case .starting: "正在启动"
        case .uninstalled: "安装 Zashboard"
        case .installing: "正在安装 Zashboard"
        case .damaged: "修复 Zashboard 安装"
        case .unavailable: model.session?.hasRuntimeFailure == true ? "Zashboard 显示已中断" : "本地服务无法启动"
        case .configurationRecovery: "恢复应用设置"
        case .ready: "Zashboard"
        }
    }
}

struct ConfigurationRecoveryView: View {
    @Bindable var model: AppModel
    @State private var confirmingReset = false
    @State private var originalPort = ""
    private var preservedPort: UInt16? { model.recoverableOriginPort ?? UInt16(originalPort).flatMap { $0 >= 1024 ? $0 : nil } }
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("恢复应用设置").font(.largeTitle.bold())
            Text("应用设置无法读取。可以重新读取，或保留原端口后恢复窗口等应用设置。")
                .multilineTextAlignment(.center)
            Text(model.startupIssue?.localizedDescription ?? model.status)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.isBusy { ProgressView() }
            if let knownPort = model.recoverableOriginPort {
                Text("已找到原端口：\(knownPort)")
            } else {
                TextField("原本地端口", text: $originalPort).frame(width: 220)
                Text("请输入此前使用的端口，以定位原有网页数据。应用不会猜测或清除原数据。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("重新读取配置") { Task { await model.retryStartup() } }
                Button("保留原端口并恢复应用设置…") { confirmingReset = true }
                    .buttonStyle(.borderedProminent).disabled(preservedPort == nil)
            }.disabled(model.isBusy)
            Text("WebKit 中的 Remote、网页设置和已有网页版本会被保留。")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(40).frame(maxWidth: 620).frame(maxWidth: .infinity, maxHeight: .infinity)
            .confirmationDialog("保留原端口并恢复应用设置？", isPresented: $confirmingReset) {
                Button("保全原文件并恢复") { Task { await model.resetConfigurationAndRestart(preservingPort: preservedPort) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("本地服务保留原端口 \(preservedPort.map(String.init) ?? "")，窗口行为恢复默认值。原设置文件单独保全，网页数据和已有版本保持完整。")
            }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var wrapperUpdater: WrapperUpdateController
    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Label("通用", systemImage: "gearshape") }
            UpdatesSettings(model: model, wrapperUpdater: wrapperUpdater).tabItem { Label("更新", systemImage: "arrow.triangle.2.circlepath") }
            Form {
                AppVersions(wrapperVersion: wrapperUpdater.versionDescription, zashboardVersion: model.zashboardVersionDescription)
                Link("ZashDock 项目", destination: WrapperUpdateController.repositoryURL)
                Link("ZashDock 发布版本", destination: WrapperUpdateController.releasesURL)
                Link("ZashDock MIT License", destination: WrapperUpdateController.repositoryURL.appendingPathComponent("blob/main/LICENSE"))
                Link("Sparkle 许可", destination: URL(string: "https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE")!)
                Link("Zashboard 官方项目", destination: URL(string: "https://github.com/Zephyruso/zashboard")!)
                Link("Zashboard MIT License", destination: URL(string: "https://github.com/Zephyruso/zashboard/blob/main/LICENSE")!)
            }.formStyle(.grouped).tabItem { Label("关于", systemImage: "info.circle") }
        }.padding().frame(width: 640, height: 500)
            .onAppear { model.settingsVisible = true }
            .onDisappear { model.settingsVisible = false }
            .alert("ZashDock", isPresented: Binding(get: { model.errorMessage != nil && model.settingsVisible }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("好") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
}

struct AppVersions: View {
    let wrapperVersion: String
    let zashboardVersion: String
    var body: some View {
        LabeledContent("ZashDock 版本", value: wrapperVersion)
        LabeledContent("Zashboard 版本", value: zashboardVersion)
    }
}

struct UpdatesSettings: View {
    @Bindable var model: AppModel
    @Bindable var wrapperUpdater: WrapperUpdateController
    @State private var importing = false
    var body: some View {
        Form {
            if model.isBusy {
                Section("操作状态") {
                    Text(model.updater?.isBusy == true ? model.updater?.status ?? model.status : model.status)
                    if let progress = model.updater?.progress, model.updater?.isBusy == true {
                        ProgressView(value: progress.fractionCompleted).accessibilityLabel("下载进度")
                    } else { ProgressView().controlSize(.small) }
                    if model.operation != nil { Button("取消", role: .cancel) { model.cancel() } }
                }
            }
            Section("版本") {
                AppVersions(wrapperVersion: wrapperUpdater.versionDescription, zashboardVersion: model.zashboardVersionDescription)
            }
            Section("ZashDock 应用") {
                Button("检查 ZashDock 更新…") { wrapperUpdater.checkForUpdates() }
                    .disabled(!wrapperUpdater.canCheckForUpdates)
                Toggle("自动检查 ZashDock 更新", isOn: Binding(
                    get: { wrapperUpdater.automaticallyChecksForUpdates },
                    set: { wrapperUpdater.setAutomaticallyChecksForUpdates($0) }
                )).disabled(!wrapperUpdater.hasStarted)
                Link("查看 ZashDock 发布版本", destination: WrapperUpdateController.releasesURL)
                Text("应用更新来自 MiracleHYH/ZashDock 的签名发布包。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Zashboard 网页") {
                LabeledContent("最新稳定版", value: model.updater?.latest?.tag ?? "尚未检查")
                HStack {
                    Button("检查更新") { model.checkForUpdates() }
                    if let latest = model.updater?.latest, latest.tag != model.currentVersion?.tag {
                        Button("安装 \(latest.tag)") { model.install(release: latest) }
                    }
                    Button("导入 ZIP…") { importing = true }
                }
                if let updater = model.updater, !updater.status.isEmpty {
                    Text(updater.status).font(.caption).foregroundStyle(.secondary)
                }
                if model.isBusy {
                    if let progress = model.updater?.progress { ProgressView(value: progress.fractionCompleted) }
                    else { ProgressView().controlSize(.small) }
                }
            }.disabled(model.isBusy || !model.canManageVersions)
        }.formStyle(.grouped)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
                switch result {
                case .success(let url): model.install(zip: url)
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { model.errorMessage = error.localizedDescription }
                }
            }
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var port = "9099"
    var body: some View {
        Form {
            if model.startupIssue != nil {
                Section("设置需要恢复") {
                    Text("请先恢复普通设置文件，再修改端口或窗口选项。")
                    Button("打开恢复界面") { openWindow(id: "main") }
                }
            }
            Section("本地服务") {
                HStack {
                    TextField("端口", text: $port).frame(maxWidth: 240)
                    Button("应用") { model.requestPort(port) }
                        .disabled(UInt16(port).map { $0 < 1024 } ?? true)
                }
                LabeledContent("当前端口", value: "\(model.configuration.port)")
                Button("自动选择并保存可用端口") { model.requestPort(nil) }
                Text("有效范围 1024–65535。迁移验证成功后才保存；更改后请同步检查 Mihomo 的 CORS Origin 白名单。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.startupIssue != nil)
            Section("启动与窗口") {
                Toggle("关闭最后一个窗口后退出", isOn: Binding(get: { model.configuration.quitAfterLastWindowCloses }, set: { model.setQuitAfterLastWindow($0) }))
            }.disabled(model.startupIssue != nil)
            if let backup = model.configurationRecoveryBackup {
                Section("配置恢复备份") {
                    Button("在 Finder 中查看原配置备份") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                }
            }
            if model.isBusy { ProgressView(model.status).controlSize(.small) }
        }
        .formStyle(.grouped).disabled(model.isBusy)
        .onAppear { port = String(model.configuration.port) }
        .onChange(of: model.configuration.port) { _, value in port = String(value) }
    }
}
