import Foundation
import Observation
import WebKit
import ZashDockCore

@MainActor @Observable
final class AppModel {
    enum Phase { case starting, uninstalled, installing, ready, damaged, unavailable, configurationRecovery }
    enum Activity { case starting, checkingUpdates, preparingInstall, switchingVersion, reconnecting, migrating }
    private enum ErrorRecovery { case openPanel, checkUpdates, downloadPanel }
    private struct ListenerStartFailure: LocalizedError {
        let underlying: any Error
        var errorDescription: String? { underlying.localizedDescription }
    }
    var phase: Phase = .starting
    var startupIssue: ConfigurationLoadFailure?
    var configurationRecoveryBackup: URL?
    var errorMessage: String?
    var errorTitle = "操作未完成"
    var updateCheckResult: String?
    private var errorRecovery: ErrorRecovery?
    var status = "正在检查本地安装…"
    var configuration = AppConfiguration()
    var currentVersion: InstalledVersion?
    var session: WebSession?
    var updater: ZashboardUpdateManager?
    var isBusy = false
    private(set) var activity: Activity?
    private var isCommitting = false
    var settingsVisible = false
    @ObservationIgnored let dataStore: WKWebsiteDataStore
    @ObservationIgnored let originStorage: OriginStorageTransfer
    @ObservationIgnored var paths: AppPaths?
    @ObservationIgnored var store: VersionStore?
    @ObservationIgnored var configurationStore: ConfigurationStore?
    @ObservationIgnored var server: LoopbackHTTPServer?
    @ObservationIgnored var operation: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private let suppliedPaths: AppPaths?
    @ObservationIgnored private let legacyKeyReader: any LegacyStorageKeyReading
    @ObservationIgnored private var legacyImportFailed = false
    @ObservationIgnored private let portCandidates: @Sendable (Set<UInt16>) -> [UInt16]

    init(paths: AppPaths? = nil, dataStore: WKWebsiteDataStore = .default(),
         legacyKeyReader: any LegacyStorageKeyReading = KeychainLegacyStorageKeyReader(),
         portCandidates: @escaping @Sendable (Set<UInt16>) -> [UInt16] = { AutomaticPortPolicy.candidates(excluding: $0) }) {
        suppliedPaths = paths; self.dataStore = dataStore; self.legacyKeyReader = legacyKeyReader
        self.portCandidates = portCandidates
        originStorage = OriginStorageTransfer(dataStore: dataStore)
    }
    var isContentBlocked: Bool { isBusy && activity != .checkingUpdates && activity != .preparingInstall }
    var canCancel: Bool { operation != nil && !isCommitting }
    var configurationFileURL: URL? { paths?.configuration }
    var panelAddress: URL? { startupIssue == nil && configuration.automaticPortSelection ? origin(configuration.port) : nil }
    var errorRecoveryTitle: String? {
        switch errorRecovery {
        case .openPanel: "重新打开面板"
        case .checkUpdates: "重试检查"
        case .downloadPanel: "重试下载"
        case nil: nil
        }
    }
    func retryFailedOperation() {
        errorMessage = nil
        switch errorRecovery {
        case .openPanel: retryStart()
        case .checkUpdates: checkForUpdates()
        case .downloadPanel: install(release: updater?.latest)
        case nil: break
        }
    }
    var recoverableOriginPort: UInt16? { configurationStore?.recoverableConfiguration()?.port }
    var canManageVersions: Bool { updater != nil && !legacyImportFailed && startupIssue == nil }
    var zashboardVersionDescription: String {
        guard let currentVersion else { return "尚未安装" }
        return currentVersion.source == .localArchive ? "本地导入（版本未知）" : currentVersion.tag
    }
    private func origin(_ port: UInt16) -> URL { URL(string: "http://127.0.0.1:\(port)")! }

    func start() async {
        guard !didStart else { return }; didStart = true
        await initializeStartup()
    }
    func retryStartup() async {
        guard !isBusy, operation == nil, session == nil else { return }
        didStart = true
        await initializeStartup()
    }
    func resetConfigurationAndRestart(preservingPort: UInt16? = nil) async {
        guard !isBusy, operation == nil, startupIssue != nil, let configurationStore else { return }
        isBusy = true
        errorTitle = "无法恢复应用设置"
        do {
            configurationRecoveryBackup = try configurationStore.resetToDefaultsPreservingOriginal(preservingPort: preservingPort)
        } catch { isBusy = false; errorMessage = error.localizedDescription; return }
        isBusy = false
        await initializeStartup()
    }
    private func initializeStartup() async {
        isBusy = true
        activity = .starting
        defer { isBusy = false; activity = nil }
        startupIssue = nil; errorMessage = nil; legacyImportFailed = false
        errorTitle = "无法打开面板"
        errorRecovery = .openPanel
        phase = .starting; status = "正在准备面板…"
        currentVersion = nil; updater = nil; store = nil
        do {
            let paths = try suppliedPaths ?? AppPaths.application()
            try paths.createDirectories(); self.paths = paths
            let configurationStore = ConfigurationStore(url: paths.configuration)
            self.configurationStore = configurationStore
            do { configuration = try configurationStore.load() }
            catch let issue as ConfigurationLoadFailure {
                startupIssue = issue; phase = .configurationRecovery
                errorTitle = "应用设置需要恢复"
                errorRecovery = nil
                status = "暂时无法确认原有面板位置。应用设置和面板数据已保留。"
                throw issue
            }
            let store = try VersionStore(root: paths.root); self.store = store
            updater = ZashboardUpdateManager(store: store, client: ReleaseClient(), downloadDirectory: paths.staging)
            do { currentVersion = try await store.current() }
            catch { phase = .damaged; throw error }
            try await importLegacyStorageIfNeeded()
            if !configuration.automaticPortSelection {
                try await performPortChange(to: nil)
            }
            guard let currentVersion else { phase = .uninstalled; status = ""; return }
            if session == nil { try await showWithAutomaticRecovery(currentVersion) }
            do { try await store.removeInactiveVersions() }
            catch { status = "当前版本可用；旧资源清理将在下次启动时重试。" }
            await retryPendingCleanup()
        } catch {
            if phase != .damaged, phase != .configurationRecovery {
                phase = .unavailable
                status = "原有面板数据已保留，请重试打开。"
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Compatibility with pre-WebKit-only builds. No new ciphertext or keys are ever created.
    /// The original files remain untouched, and the committed flag prevents future replays.
    private func importLegacyStorageIfNeeded() async throws {
        guard !configuration.legacyStorageImported, let paths, let configurationStore else { return }
        do {
            let reader = LegacyWebStorageReader(primaryURL: paths.legacyStorage, keyReader: legacyKeyReader)
            guard let values = try reader.read() else { return }
            let location = origin(configuration.port)
            let existing = try await originStorage.read(origin: location)
            let imported = OriginStoragePayload(localStorage: values, databases: existing.databases)
            try await originStorage.restore(imported, to: location)
            try await originStorage.verify(imported, at: location)
            try Task.checkCancellation()
            var proposed = configuration; proposed.legacyStorageImported = true
            try configurationStore.save(proposed); configuration = proposed
            legacyImportFailed = false
        } catch {
            legacyImportFailed = true
            status = "旧版配置尚未完成兼容导入，原文件均保留。请检查原钥匙串与旧版配置后重试启动。"
            throw error
        }
    }

    func install(zip: URL? = nil, release: ZashboardRelease? = nil) {
        guard !isBusy, operation == nil, !legacyImportFailed, let updater else { return }
        isBusy = true; errorMessage = nil
        activity = .preparingInstall
        status = zip == nil ? "正在准备下载面板…" : "正在准备导入面板…"
        errorTitle = zip == nil ? "无法下载并安装面板" : "无法导入面板"
        errorRecovery = zip == nil ? .downloadPanel : nil
        let previousPhase = phase
        if phase != .ready { phase = .installing }
        operation = Task {
            var candidate: InstalledVersion?
            defer { isBusy = false; operation = nil; activity = nil; isCommitting = false }
            do {
                if let zip {
                    let access = zip.startAccessingSecurityScopedResource()
                    defer { if access { zip.stopAccessingSecurityScopedResource() } }
                    candidate = try await updater.stageLocalZIP(zip)
                } else if let release { candidate = try await updater.stage(release: release) }
                else { candidate = try await updater.stageLatest() }
                try Task.checkCancellation()
                if let candidate { try await activateVersion(candidate) }
            } catch {
                if let candidate { try? await store?.discardPrepared(candidate) }
                if phase == .installing { phase = previousPhase }
                if error is CancellationError || Task.isCancelled {
                    updateCheckResult = "已取消安装，原有面板数据已保留。"
                } else {
                    updateCheckResult = "安装未完成，原有面板数据已保留。"
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    func prepareToQuit() async -> Bool {
        cancel()
        await operation?.value
        await quiesce()
        return true
    }
    func cancel() { updater?.cancel(); operation?.cancel() }
    func checkForUpdates() {
        guard !isBusy, operation == nil, let updater else { return }
        isBusy = true
        activity = .checkingUpdates
        status = "正在检查面板更新…"
        errorTitle = "无法检查面板更新"
        errorRecovery = .checkUpdates
        errorMessage = nil
        updateCheckResult = nil
        operation = Task {
            defer { isBusy = false; operation = nil; activity = nil }
            do {
                try Task.checkCancellation()
                try await updater.checkForUpdates()
                if let latest = updater.latest {
                    if currentVersion?.source == .localArchive {
                        updateCheckResult = "最新稳定版为 \(latest.tag)。当前面板来自本地导入。"
                    } else if latest.tag == currentVersion?.tag {
                        updateCheckResult = "面板已是最新稳定版。"
                    } else {
                        updateCheckResult = "可安装稳定版 \(latest.tag)。"
                    }
                }
                status = updateCheckResult ?? "检查已完成。"
            }
            catch {
                if error is CancellationError || Task.isCancelled { updateCheckResult = "已取消检查更新。" }
                else { updateCheckResult = "检查未完成，请重试。"; errorMessage = error.localizedDescription }
                status = updateCheckResult ?? "检查未完成。"
            }
        }
    }
    /// Candidate code first runs against an empty disposable WebKit store. Same-Origin
    /// updates keep the persistent profile in place and do not use the port-transfer codec.
    /// Before commit, rejected or cancelled previews cannot touch the persistent profile.
    /// There is only one HTTP listener throughout.
    private func activateVersion(_ version: InstalledVersion) async throws {
        guard let store, let updater else { throw ZashDockError.invalidConfiguration("版本管理尚未就绪。") }
        _ = try await store.validate(version)
        activity = .switchingVersion
        errorTitle = "无法启用新面板"
        let previous = currentVersion, previousPhase = phase, wasRunning = server != nil
        if !configuration.automaticPortSelection { try await performPortChange(to: nil) }
        await quiesce()
        var listener: LoopbackHTTPServer?
        var candidate: WebSession?
        do {
            status = "正在载入 Zashboard…"; phase = .installing
            let service = try await activationListener(for: version)
            listener = service
            activity = .switchingVersion
            errorTitle = "无法启用新面板"
            let validationStore = WKWebsiteDataStore.nonPersistent()
            let validation = WebSession(origin: service.baseURL, expectedVersion: version.id, expectedNonce: service.nonce, dataStore: validationStore)
            candidate = validation
            try await validation.loadAndVerify()
            await validation.suspend(); candidate = nil
            try Task.checkCancellation()
            // The version has rendered successfully. Commit its selection before running
            // its migrations in the persistent profile, so a process exit restarts this version.
            isCommitting = true
            try await store.activate(version)
            currentVersion = version; server = service
            // A cancellation after the durable commit cannot abandon its live session.
            await Task { @MainActor [self] in
                do {
                    await WebCacheController.clearLoopbackCaches(in: dataStore)
                    let live = WebSession(origin: service.baseURL, expectedVersion: version.id, expectedNonce: service.nonce, dataStore: dataStore)
                    attachSessionFailure(live); session = live
                    try await live.loadAndVerify()
                    phase = .ready
                    try await updater.commit(version: version)
                    status = updater.status
                    updateCheckResult = "已启用 \(zashboardVersionDescription)。"
                } catch {
                    phase = .unavailable
                    errorTitle = "新面板需要重新载入"
                    errorRecovery = .openPanel
                    status = "新面板已安装，暂时无法显示。原有面板数据已保留，请重新载入。"
                    errorMessage = error.localizedDescription
                }
            }.value
        } catch {
            await candidate?.suspend(); listener?.stop()
            currentVersion = previous
            if wasRunning, let previous {
                await Task { @MainActor [self] in
                    do { try await show(previous) }
                    catch { phase = .unavailable; status = "原面板与数据已保留，请重试打开。" }
                }.value
            } else { phase = previousPhase == .installing ? .uninstalled : previousPhase }
            throw error
        }
    }
    func reload() { retryStart() }
    func setQuitAfterLastWindow(_ enabled: Bool) {
        guard !isBusy, startupIssue == nil, let configurationStore else { return }
        errorTitle = "无法保存窗口设置"
        errorRecovery = nil
        do {
            var proposed = configuration; proposed.quitAfterLastWindowCloses = enabled
            try configurationStore.save(proposed); configuration = proposed
        } catch { errorMessage = error.localizedDescription }
    }

    /// Only port metadata is committed. The old Origin stays intact until all target
    /// data and the real webpage have been verified; the wrapper never persists the payload.
    func changePort(to requested: UInt16?) async throws {
        guard !isBusy else { throw ZashDockError.invalidConfiguration("另一个操作正在进行。") }
        isBusy = true
        defer { isBusy = false; activity = nil; isCommitting = false }
        try await performPortChange(to: requested)
    }
    private func performPortChange(to requested: UInt16?) async throws {
        guard let paths, let configurationStore, startupIssue == nil else { throw ZashDockError.invalidConfiguration("应用尚未就绪。") }
        if let requested, requested < 1024 { throw ZashDockError.invalidConfiguration("端口必须在 1024–65535 之间。") }
        if requested == configuration.port, server != nil, phase == .ready { return }
        activity = .migrating
        errorTitle = "无法准备面板连接"
        defer { isCommitting = false }
        try await importLegacyStorageIfNeeded()
        // Do not lose an earlier cleanup marker when switching again.
        if configuration.pendingOriginCleanup != nil { try await finishPendingCleanup() }
        let oldPort = configuration.port, previousPhase = phase, wasRunning = server != nil
        var targetService: LoopbackHTTPServer?, targetPage: WebSession?
        let probe = paths.root.appendingPathComponent("port-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        await quiesce()
        do {
            status = "正在读取当前网页数据…"
            let payload = try await originStorage.read(origin: origin(oldPort))
            let root: URL
            if let currentVersion { root = currentVersion.directoryURL }
            else { try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); root = probe }
            let ports = requested.map { [$0] } ?? portCandidates([oldPort])
            var bindError: (any Error)?
            for port in ports {
                try Task.checkCancellation()
                status = "正在准备可用的面板连接…"
                let service = try LoopbackHTTPServer(root: root, port: port, versionID: currentVersion?.id ?? "port-probe")
                do {
                    _ = try await service.start()
                    if requested == nil {
                        // A free TCP endpoint can still own data from an earlier session.
                        // Automatic selection must never overwrite another stored Origin.
                        let existing = try await originStorage.read(origin: service.baseURL)
                        guard existing == OriginStoragePayload(localStorage: [:]) else { service.stop(); continue }
                    }
                    targetService = service
                    break
                } catch {
                    service.stop()
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    bindError = error
                    if requested != nil { throw error }
                }
            }
            guard let target = targetService else {
                throw ZashDockError.server("暂时无法建立本地面板连接，请稍后重试。\(bindError.map { "\n\($0.localizedDescription)" } ?? "")")
            }
            try Task.checkCancellation()
            if target.port != oldPort {
                status = "正在转移并核验网页数据…"
                try await originStorage.restore(payload, to: target.baseURL)
                try await originStorage.verify(payload, at: target.baseURL)
            }
            if let currentVersion {
                await WebCacheController.clearLoopbackCaches(in: dataStore)
                let live = WebSession(origin: target.baseURL, expectedVersion: currentVersion.id, expectedNonce: target.nonce, dataStore: dataStore)
                attachSessionFailure(live); targetPage = live
                try await live.loadAndVerify()
            }
            try Task.checkCancellation()
            var proposed = configuration; proposed.port = target.port; proposed.automaticPortSelection = true
            proposed.pendingOriginCleanup = target.port == oldPort ? nil : oldPort
            isCommitting = true
            try configurationStore.save(proposed)
            // No throwing operation follows the sole durable port commit.
            configuration = proposed
            session = targetPage
            if targetPage != nil { server = target; phase = .ready }
            else { target.stop(); phase = .uninstalled }
            status = "面板连接已就绪，原有数据已保留。"
            await retryPendingCleanup()
        } catch {
            await targetPage?.suspend(); targetService?.stop()
            if let targetService, targetService.port != oldPort {
                // This Origin never became current. Keep cleanup independent of a
                // cancelled caller; failure cannot alter the authoritative old Origin.
                await Task { @MainActor [self] in try? await originStorage.clear(origin: targetService.baseURL) }.value
            }
            if wasRunning, let currentVersion {
                await Task { @MainActor [self] in
                    do { try await show(currentVersion) }
                    catch { phase = .unavailable; status = "原面板数据已保留，请重试打开。" }
                }.value
            } else { phase = previousPhase }
            status = "面板连接未更改，原有配置和数据已保留。"
            throw error
        }
    }
    private func finishPendingCleanup() async throws {
        guard let previousPort = configuration.pendingOriginCleanup, let configurationStore else { return }
        try Task.checkCancellation()
        try configurationStore.ensureRecoveryCopy(configuration)
        try await originStorage.clear(origin: origin(previousPort))
        var proposed = configuration; proposed.pendingOriginCleanup = nil
        try configurationStore.save(proposed); configuration = proposed
    }
    private func retryPendingCleanup() async {
        guard configuration.pendingOriginCleanup != nil else { return }
        do { try await finishPendingCleanup() }
        catch { status = "面板和数据已保存；旧数据清理将在下次启动时重试。" }
    }
    func retryStart() {
        guard !isBusy, operation == nil else { return }
        isBusy = true
        activity = .reconnecting
        errorTitle = "无法打开面板"
        errorRecovery = .openPanel
        operation = Task {
            defer { isBusy = false; operation = nil; activity = nil; isCommitting = false }
            do {
                errorMessage = nil
                if legacyImportFailed || currentVersion == nil { await initializeStartup() }
                else if let currentVersion {
                    if !configuration.automaticPortSelection { try await performPortChange(to: nil) }
                    else { try await showWithAutomaticRecovery(currentVersion) }
                    await retryPendingCleanup()
                }
            } catch {
                phase = .unavailable
                status = "原有面板数据已保留，请重试打开。"
                errorMessage = error.localizedDescription
            }
        }
    }
    private func attachSessionFailure(_ webpage: WebSession) {
        webpage.onFailure = { [weak self, weak webpage] message in
            guard let self, let webpage, self.session === webpage else { return }
            self.phase = .unavailable; self.status = "面板显示已中断，原有数据已保留，可以重新载入。"
            self.errorTitle = "面板显示已中断"
            self.errorRecovery = .openPanel
            self.errorMessage = message
        }
    }
    private func quiesce() async {
        await session?.suspend(); session?.stop(); session = nil
        server?.stop(); server = nil
    }
    private func showWithAutomaticRecovery(_ version: InstalledVersion) async throws {
        do { try await show(version) }
        catch is ListenerStartFailure {
            try Task.checkCancellation()
            try await performPortChange(to: nil)
        }
    }
    private func activationListener(for version: InstalledVersion) async throws -> LoopbackHTTPServer {
        // A previously reserved address may have been claimed while the user chose
        // an archive or while resources downloaded. Only a bind failure changes it.
        for _ in 0..<3 {
            let service = try LoopbackHTTPServer(root: version.directoryURL, port: configuration.port, versionID: version.id)
            do { _ = try await service.start(); return service }
            catch {
                service.stop()
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                try await performPortChange(to: nil)
                await quiesce()
            }
        }
        throw ZashDockError.server("面板连接暂时不可用，原有数据已保留，请重试。")
    }
    private func show(_ version: InstalledVersion) async throws {
        await quiesce()
        let service = try LoopbackHTTPServer(root: version.directoryURL, port: configuration.port, versionID: version.id)
        var live: WebSession?
        do {
            do { _ = try await service.start() }
            catch {
                service.stop()
                if error is CancellationError { throw error }
                throw ListenerStartFailure(underlying: error)
            }
            await WebCacheController.clearLoopbackCaches(in: dataStore)
            let webpage = WebSession(origin: service.baseURL, expectedVersion: version.id, expectedNonce: service.nonce, dataStore: dataStore)
            live = webpage; attachSessionFailure(webpage)
            try await webpage.loadAndVerify()
            session = webpage; server = service; phase = .ready
        } catch { await live?.suspend(); service.stop(); throw error }
    }
}
