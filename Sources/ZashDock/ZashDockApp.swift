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
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("检查 ZashDock 更新…") { wrapperUpdater.checkForUpdates() }
                        .disabled(!wrapperUpdater.canCheckForUpdates)
                }
                CommandGroup(after: .toolbar) {
                    Button("重新载入 Zashboard") { model.reload() }
                        .keyboardShortcut("r").disabled(model.phase != .ready || model.isBusy)
                    Button("检查 Zashboard 更新…") { model.checkForUpdates() }.disabled(model.isBusy || model.updater == nil)
                }
            }
        Settings { SettingsView(model: model, wrapperUpdater: wrapperUpdater) }
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var importing = false
    var body: some View {
        Group {
            if model.phase == .ready, let session = model.session {
                WebView(session.page).webViewMagnificationGestures(.enabled).allowsHitTesting(!model.isBusy)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: model.phase == .damaged ? "wrench.and.screwdriver" : "square.and.arrow.down").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text(title).font(.largeTitle.bold())
                    Text(model.updater?.isBusy == true ? model.updater?.status ?? "" : model.status).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if model.phase == .starting || model.isBusy {
                        if let progress = model.updater?.progress {
                            ProgressView(value: progress.fractionCompleted).frame(width: 320)
                            Text("\(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))").font(.caption.monospacedDigit())
                        } else { ProgressView() }
                        if model.isBusy { Button("取消", role: .cancel) { model.cancel() } }
                    } else {
                        if model.phase == .unavailable {
                            SettingsLink { Text("在设置中检查或更改端口") }.buttonStyle(.borderedProminent)
                        }
                        Button("安装最新稳定版", systemImage: "arrow.down.circle") { model.install() }.buttonStyle(.borderedProminent)
                            .disabled(model.updater == nil)
                        Button("从本地官方 ZIP 导入…") { importing = true }
                        Text("仅接受官方发布的 dist.zip；首次离线导入支持 v3.29.1。") .font(.caption).foregroundStyle(.secondary)
                        if model.currentVersion != nil { Button("重新启动本地服务") { model.retryStart() } }
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
        .toolbar {
            if let version = model.currentVersion { Text(version.tag).font(.caption).foregroundStyle(.secondary) }
            SettingsLink { Label("设置", systemImage: "gearshape") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            switch result { case .success(let url): model.install(zip: url); case .failure(let error): model.errorMessage = error.localizedDescription }
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
        case .unavailable: "本地服务无法启动"
        case .ready: "Zashboard"
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
                LabeledContent("ZashDock", value: wrapperUpdater.versionDescription)
                LabeledContent("Zashboard", value: model.currentVersion?.tag ?? "尚未安装")
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

struct UpdatesSettings: View {
    @Bindable var model: AppModel
    @Bindable var wrapperUpdater: WrapperUpdateController
    @State private var importing = false
    var body: some View {
        Form {
            Section("ZashDock 应用") {
                LabeledContent("当前版本", value: wrapperUpdater.versionDescription)
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
                LabeledContent("当前版本", value: model.currentVersion?.tag ?? "尚未安装")
                LabeledContent("最新稳定版", value: model.updater?.latest?.tag ?? "尚未检查")
                HStack {
                    Button("检查更新") { model.checkForUpdates() }
                    if let latest = model.updater?.latest, latest.tag != model.currentVersion?.tag {
                        Button("安装 \(latest.tag)") { model.install(release: latest) }
                    }
                    Button("导入官方 ZIP…") { importing = true }
                }
                if let updater = model.updater, !updater.status.isEmpty {
                    Text(updater.status).font(.caption).foregroundStyle(.secondary)
                }
                if model.isBusy {
                    if let progress = model.updater?.progress { ProgressView(value: progress.fractionCompleted) }
                    else { ProgressView().controlSize(.small) }
                }
            }.disabled(model.isBusy || model.updater == nil)
            Section("Zashboard 回滚") {
                Stepper("最多保留 \(model.configuration.maxRollbackVersions) 个历史版本", value: Binding(get: { model.configuration.maxRollbackVersions }, set: { model.setRetention($0) }), in: 0...100)
                Text("不包含当前版本。总保留上限为 \(model.configuration.maxRollbackVersions + 1)；按最近激活顺序清理。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.history.isEmpty { Text("暂无可回滚的本地版本").foregroundStyle(.secondary) }
                ForEach(model.history) { version in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(version.tag)
                            Text(version.installedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("回滚") { model.rollback(version) }
                    }
                }
            }.disabled(model.isBusy || model.updater == nil)
            if let releases = model.updater?.releases, !releases.isEmpty {
                Section("官方历史版本") {
                    DisclosureGroup("可下载的稳定版（\(releases.count)）") {
                        ForEach(releases) { release in
                            HStack {
                                Text(release.tag)
                                Spacer()
                                Button("安装") { model.install(release: release) }
                                    .disabled(release.tag == model.currentVersion?.tag)
                            }
                        }
                    }
                }.disabled(model.isBusy || model.updater == nil)
            }
        }.formStyle(.grouped)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
                switch result {
                case .success(let url): model.install(zip: url)
                case .failure(let error): model.errorMessage = error.localizedDescription
                }
            }
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var port = "9099"
    var body: some View {
        Form {
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
            }
            Section("启动与窗口") {
                Toggle("关闭最后一个窗口后退出", isOn: Binding(get: { model.configuration.quitAfterLastWindowCloses }, set: { model.setQuitAfterLastWindow($0) }))
            }
            if model.isBusy { ProgressView(model.status).controlSize(.small) }
        }
        .formStyle(.grouped).disabled(model.isBusy)
        .onAppear { port = String(model.configuration.port) }
        .onChange(of: model.configuration.port) { _, value in port = String(value) }
    }
}
