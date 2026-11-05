import AppKit
import Observation
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
    @State private var settingsNavigation = SettingsNavigation()
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
            .commands { ZashDockCommands(model: model, wrapperUpdater: wrapperUpdater, navigation: settingsNavigation) }
        Settings { SettingsView(model: model, wrapperUpdater: wrapperUpdater, navigation: settingsNavigation) }
    }
}

enum SettingsTab: Hashable { case general, updates, about }

@Observable
final class SettingsNavigation {
    var selection: SettingsTab = .general
}

struct ZashDockCommands: Commands {
    @Environment(\.openSettings) private var openSettings
    let model: AppModel
    let wrapperUpdater: WrapperUpdateController
    let navigation: SettingsNavigation
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 ZashDock") { showAbout() }
        }
        CommandGroup(after: .appInfo) {
            Button("检查 ZashDock 更新…") { wrapperUpdater.checkForUpdates() }
                .disabled(!wrapperUpdater.canCheckForUpdates)
        }
        CommandGroup(after: .toolbar) {
            Button("重新载入 Zashboard 面板") { model.reload() }
                .keyboardShortcut("r").disabled(model.currentVersion == nil || model.isBusy)
            Button("检查 Zashboard 面板更新…") {
                navigation.selection = .updates
                openSettings()
                model.checkForUpdates()
            }.disabled(model.isBusy || model.updater == nil)
        }
        CommandGroup(after: .help) {
            Button("复制面板地址") {
                guard let address = model.panelAddress else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address.absoluteString, forType: .string)
            }
            .disabled(model.panelAddress == nil)
            .help("远程 Mihomo 服务限制面板来源时，可将此地址提供给服务管理员。")
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Group {
            if model.phase == .configurationRecovery {
                ConfigurationRecoveryView(model: model)
            } else if model.phase == .ready, let session = model.session {
                WebView(session.page)
                    .webViewMagnificationGestures(.enabled)
                    .allowsHitTesting(!model.isContentBlocked)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: stateSymbol)
                        .font(.system(size: 48)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(title).font(.largeTitle.bold())
                    if model.phase == .starting || model.isBusy {
                        PanelOperationStatus(model: model)
                            .frame(maxWidth: 340)
                    } else {
                        if model.phase != .uninstalled {
                            Text(model.phase == .damaged ? "面板资源无法读取。重新安装后，已有面板数据将继续保留。" : model.status)
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        if model.phase == .uninstalled || model.phase == .damaged {
                            HStack(spacing: 12) {
                                Button(model.phase == .damaged ? "重新下载并安装" : "下载并安装", systemImage: "arrow.down.circle") { model.install() }
                                    .buttonStyle(.borderedProminent)
                                Button("导入 ZIP", systemImage: "square.and.arrow.down.on.square") { importing = true }
                                    .labelStyle(.iconOnly).help("导入面板 ZIP…")
                            }.controlSize(.large).disabled(!model.canManageVersions)
                        } else if model.phase == .unavailable {
                            Button(model.session?.hasRuntimeFailure == true ? "重新载入面板" : "重试打开面板") { model.retryStart() }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                            if model.canManageVersions {
                                DisclosureGroup("更多恢复选项") {
                                    HStack {
                                        Button("重新下载面板") { model.install() }
                                        Button("导入面板 ZIP…") { importing = true }
                                    }.padding(.top, 8)
                                }.frame(maxWidth: 340)
                            }
                        }
                        if let error = model.errorMessage, model.phase == .unavailable || model.phase == .damaged {
                            TechnicalDetails(message: error).frame(maxWidth: 340)
                        }
                    }
                }.frame(maxWidth: 560).padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .overlay(alignment: .bottomTrailing) {
            if model.isBusy && model.phase == .ready {
                PanelOperationStatus(model: model)
                    .padding(16).frame(width: 340)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.65 : 0.12), lineWidth: 1)
                    }
                    .padding(16)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): model.install(zip: url)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    model.errorTitle = "无法选择面板安装文件"
                    model.errorMessage = error.localizedDescription
                }
            }
        }
        .alert(model.errorTitle, isPresented: Binding(get: {
            model.errorMessage != nil && !model.settingsVisible && model.phase != .configurationRecovery && model.phase != .unavailable && model.phase != .damaged
        }, set: { if !$0 { model.errorMessage = nil } })) {
            if let recoveryTitle = model.errorRecoveryTitle {
                Button(recoveryTitle) { model.retryFailedOperation() }
            }
            Button("关闭", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var stateSymbol: String {
        switch model.phase {
        case .damaged: "wrench.and.screwdriver"
        case .unavailable: "exclamationmark.triangle"
        case .starting: "arrow.triangle.2.circlepath"
        default: "square.and.arrow.down"
        }
    }
    private var title: String {
        switch model.phase {
        case .starting: "正在启动"
        case .uninstalled: "安装 Zashboard 面板"
        case .installing: "正在安装 Zashboard 面板"
        case .damaged: "修复 Zashboard 面板"
        case .unavailable: model.session?.hasRuntimeFailure == true ? "面板显示已中断" : "暂时无法打开面板"
        case .configurationRecovery: "恢复应用设置"
        case .ready: "Zashboard 面板"
        }
    }
}

struct PanelOperationStatus: View {
    let model: AppModel
    private var status: String {
        model.updater?.isBusy == true ? model.updater?.status ?? model.status : model.status
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if model.updater?.progress == nil || model.updater?.isBusy != true {
                    ProgressView().controlSize(.small).accessibilityLabel("面板操作进行中")
                }
                Text(status).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.canCancel {
                    Button("取消", role: .cancel) { model.cancel() }
                }
            }
            if let progress = model.updater?.progress, model.updater?.isBusy == true {
                ProgressView(value: progress.fractionCompleted).accessibilityLabel("面板下载进度")
                Text("\(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct TechnicalDetails: View {
    let message: String
    var body: some View {
        DisclosureGroup("技术详情") {
            Text(message).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
    }
}

struct ConfigurationRecoveryView: View {
    @Bindable var model: AppModel
    @State private var confirmingReset = false
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("恢复应用设置").font(.largeTitle.bold())
            Text("应用设置无法读取。原设置文件与面板数据已保留。")
                .multilineTextAlignment(.center)
            if model.isBusy { ProgressView() }
            if model.recoverableOriginPort != nil {
                Text("已找到原有面板的连接信息，可以恢复应用设置后继续使用。")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("重新读取设置") { Task { await model.retryStartup() } }
                    Button("恢复应用设置…") { confirmingReset = true }
                        .buttonStyle(.borderedProminent)
                }.disabled(model.isBusy)
            } else {
                Text("暂时无法确认原有面板数据的位置。请恢复设置文件后重试。")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重新读取设置") { Task { await model.retryStartup() } }
                    .buttonStyle(.borderedProminent).disabled(model.isBusy)
            }
            if let file = model.configurationFileURL {
                Button("在 Finder 中查看设置文件") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            TechnicalDetails(message: model.startupIssue?.localizedDescription ?? model.status)
        }.padding(40).frame(maxWidth: 620).frame(maxWidth: .infinity, maxHeight: .infinity)
            .confirmationDialog("恢复应用设置？", isPresented: $confirmingReset) {
                Button("保留原文件并恢复") { Task { await model.resetConfigurationAndRestart(preservingPort: model.recoverableOriginPort) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("窗口行为将恢复默认值。原设置文件会单独备份，已安装面板、远程服务配置和面板数据均会保留。")
            }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var wrapperUpdater: WrapperUpdateController
    @Bindable var navigation: SettingsNavigation
    var body: some View {
        TabView(selection: $navigation.selection) {
            GeneralSettings(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }.tag(SettingsTab.general)
            UpdatesSettings(model: model, wrapperUpdater: wrapperUpdater)
                .tabItem { Label("更新", systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.updates)
            AboutSettings(wrapperUpdater: wrapperUpdater, zashboardVersion: model.zashboardVersionDescription)
                .tabItem { Label("关于", systemImage: "info.circle") }.tag(SettingsTab.about)
        }.padding().frame(minWidth: 560, idealWidth: 640, minHeight: 460, idealHeight: 540)
            .onAppear { model.settingsVisible = true }
            .onDisappear { model.settingsVisible = false }
            .alert(model.errorTitle, isPresented: Binding(get: { model.errorMessage != nil && model.settingsVisible }, set: { if !$0 { model.errorMessage = nil } })) {
                if let recoveryTitle = model.errorRecoveryTitle {
                    Button(recoveryTitle) { model.retryFailedOperation() }
                }
                Button("关闭", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
}

struct AboutSettings: View {
    let wrapperUpdater: WrapperUpdateController
    let zashboardVersion: String
    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().interpolation(.high).frame(width: 64, height: 64).accessibilityHidden(true)
                    Text("ZashDock").font(.title2.weight(.semibold))
                    Text("使用 Zashboard 面板连接远程 Mihomo 服务。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            Section("版本") {
                AppVersions(wrapperVersion: wrapperUpdater.versionDescription, zashboardVersion: zashboardVersion)
            }
            Section("项目与支持") {
                Link("ZashDock 项目", destination: WrapperUpdateController.repositoryURL)
                Link("ZashDock 发布版本", destination: WrapperUpdateController.releasesURL)
                Link("Zashboard 面板项目", destination: URL(string: "https://github.com/Zephyruso/zashboard")!)
            }
            Section("开源许可") {
                Link("ZashDock · MIT License", destination: WrapperUpdateController.repositoryURL.appendingPathComponent("blob/main/LICENSE"))
                Link("Zashboard · MIT License", destination: URL(string: "https://github.com/Zephyruso/zashboard/blob/main/LICENSE")!)
                Link("Sparkle 许可", destination: URL(string: "https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE")!)
            }
        }.formStyle(.grouped)
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
            Section("ZashDock 应用") {
                LabeledContent("ZashDock 版本", value: wrapperUpdater.versionDescription)
                Button("检查 ZashDock 更新…") { wrapperUpdater.checkForUpdates() }
                    .disabled(!wrapperUpdater.canCheckForUpdates)
                Toggle("自动检查 ZashDock 更新", isOn: Binding(
                    get: { wrapperUpdater.automaticallyChecksForUpdates },
                    set: { wrapperUpdater.setAutomaticallyChecksForUpdates($0) }
                )).disabled(!wrapperUpdater.hasStarted)
                Link("查看 ZashDock 发布版本", destination: WrapperUpdateController.releasesURL)
                Text("应用更新由 ZashDock 项目提供，并通过更新签名验证。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Zashboard 面板") {
                LabeledContent("Zashboard 版本", value: model.zashboardVersionDescription)
                LabeledContent("最新稳定版", value: model.updater?.latest?.tag ?? "尚未检查")
                if !model.isBusy, let result = model.updateCheckResult {
                    Label(result, systemImage: "info.circle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("检查更新") { model.checkForUpdates() }
                    if let latest = model.updater?.latest, latest.tag != model.currentVersion?.tag {
                        Button("安装 \(latest.tag)") { model.install(release: latest) }
                    }
                    Button("导入面板 ZIP…") { importing = true }
                }.disabled(model.isBusy || !model.canManageVersions)
                if model.isBusy {
                    PanelOperationStatus(model: model)
                }
            }
        }.formStyle(.grouped)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
                switch result {
                case .success(let url): model.install(zip: url)
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        model.errorTitle = "无法选择面板安装文件"
                        model.errorMessage = error.localizedDescription
                    }
                }
            }
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Form {
            if model.startupIssue != nil {
                Section("设置需要恢复") {
                    Text("恢复应用设置后，可以继续调整窗口行为。")
                    Button("打开恢复界面") { openWindow(id: "main") }
                }
            }
            Section {
                Toggle("关闭最后一个窗口后退出", isOn: Binding(get: { model.configuration.quitAfterLastWindowCloses }, set: { model.setQuitAfterLastWindow($0) }))
            } header: {
                Text("窗口")
            } footer: {
                Text("退出 ZashDock 不影响远程 Mihomo 服务运行。")
            }.disabled(model.startupIssue != nil || model.isBusy)
            if let backup = model.configurationRecoveryBackup {
                Section("配置恢复备份") {
                    Button("在 Finder 中查看原配置备份") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
