import Foundation
import Observation
import WebKit
import ZashDockCore

@MainActor @Observable
final class AppModel {
    enum Phase { case starting, uninstalled, installing, ready, damaged, unavailable, configurationRecovery }
    var phase: Phase = .starting
    var startupIssue: ConfigurationLoadFailure?
    var configurationRecoveryBackup: URL?
    var errorMessage: String?
    var status = "正在检查本地安装…"
    var configuration = AppConfiguration()
    var currentVersion: InstalledVersion?
    var session: WebSession?
    var updater: ZashboardUpdateManager?
    var isBusy = false
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

    init(paths: AppPaths? = nil, dataStore: WKWebsiteDataStore = .default(),
         legacyKeyReader: any LegacyStorageKeyReading = KeychainLegacyStorageKeyReader()) {
        suppliedPaths = paths; self.dataStore = dataStore; self.legacyKeyReader = legacyKeyReader
        originStorage = OriginStorageTransfer(dataStore: dataStore)
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
        do {
            configurationRecoveryBackup = try configurationStore.resetToDefaultsPreservingOriginal(preservingPort: preservingPort)
        } catch { isBusy = false; errorMessage = error.localizedDescription; return }
        isBusy = false
        await initializeStartup()
    }
    private func initializeStartup() async {
        isBusy = true
        defer { isBusy = false }
        startupIssue = nil; errorMessage = nil; legacyImportFailed = false
        phase = .starting; status = "正在检查本地安装…"
        currentVersion = nil; updater = nil; store = nil
        do {
            let paths = try suppliedPaths ?? AppPaths.application()
            try paths.createDirectories(); self.paths = paths
            let configurationStore = ConfigurationStore(url: paths.configuration)
            self.configurationStore = configurationStore
            do { configuration = try configurationStore.load() }
            catch let issue as ConfigurationLoadFailure {
                startupIssue = issue; phase = .configurationRecovery
                status = "请恢复应用设置中的原端口；网页数据仍保存在 WebKit 中。"
                throw issue
            }
            let store = try VersionStore(root: paths.root); self.store = store
            updater = ZashboardUpdateManager(store: store, client: ReleaseClient(), downloadDirectory: paths.staging)
            do { currentVersion = try await store.current() }
            catch { phase = .damaged; throw error }
            try await importLegacyStorageIfNeeded()
            guard let currentVersion else { phase = .uninstalled; status = ""; return }
            try await show(currentVersion)
            do { try await store.removeInactiveVersions() }
            catch { status = "当前版本可用；旧资源清理将在下次启动时重试。" }
            await retryPendingCleanup()
        } catch {
            if phase != .damaged, phase != .configurationRecovery { phase = .unavailable }
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
        let previousPhase = phase
        if phase != .ready { phase = .installing }
        operation = Task {
            var candidate: InstalledVersion?
            defer { isBusy = false; operation = nil }
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
                if !(error is CancellationError), !Task.isCancelled { errorMessage = error.localizedDescription }
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
        operation = Task {
            defer { isBusy = false; operation = nil }
            do { try Task.checkCancellation(); try await updater.checkForUpdates() }
            catch {
                if error is CancellationError || Task.isCancelled { status = "已取消检查更新。" }
                else { errorMessage = error.localizedDescription }
            }
        }
    }
    /// Candidate code first runs against a disposable WebKit store. A bad or cancelled
    /// candidate cannot clear the active profile. There is only one HTTP listener throughout.
    private func activateVersion(_ version: InstalledVersion) async throws {
        guard let store, let updater else { throw ZashDockError.invalidConfiguration("版本管理尚未就绪。") }
        _ = try await store.validate(version)
        let previous = currentVersion, previousPhase = phase, wasRunning = server != nil
        await quiesce()
        var listener: LoopbackHTTPServer?
        var candidate: WebSession?
        do {
            let values = try await originStorage.read(origin: origin(configuration.port))
            status = "正在载入 Zashboard…"; phase = .installing
            let service = try LoopbackHTTPServer(root: version.directoryURL, port: configuration.port, versionID: version.id)
            listener = service; _ = try await service.start()
            let validationStore = WKWebsiteDataStore.nonPersistent()
            let validationTransfer = OriginStorageTransfer(dataStore: validationStore)
            try await validationTransfer.restore(values, to: service.baseURL)
            try await validationTransfer.verify(values, at: service.baseURL)
            let validation = WebSession(origin: service.baseURL, expectedVersion: version.id, expectedNonce: service.nonce, dataStore: validationStore)
            candidate = validation
            try await validation.loadAndVerify()
            await validation.suspend(); candidate = nil
            try Task.checkCancellation()
            // The version has rendered successfully. Commit its selection before running
            // its migrations in the persistent profile, so a process exit restarts this version.
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
                } catch {
                    phase = .unavailable
                    status = "已验证并启用 \(version.tag)；网页需要重新载入，原资源暂时保留。"
                    errorMessage = error.localizedDescription
                }
            }.value
        } catch {
            await candidate?.suspend(); listener?.stop()
            currentVersion = previous
            if wasRunning, let previous {
                await Task { @MainActor [self] in
                    do { try await show(previous) }
                    catch { phase = .unavailable; status = "原版本与网页数据已保留；请重新启动服务或更换端口。" }
                }.value
            } else { phase = previousPhase == .installing ? .uninstalled : previousPhase }
            throw error
        }
    }
    func reload() { retryStart() }
    func requestPort(_ text: String?) {
        guard !isBusy, operation == nil else { return }
        let requested: UInt16?
        if let text {
            guard let parsed = UInt16(text), parsed >= 1024 else { errorMessage = "端口必须在 1024–65535 之间。"; return }
            requested = parsed
        } else { requested = nil }
        operation = Task {
            defer { operation = nil }
            do { try await changePort(to: requested) }
            catch { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
        }
    }
    func setQuitAfterLastWindow(_ enabled: Bool) {
        guard !isBusy, startupIssue == nil, let configurationStore else { return }
        do {
            var proposed = configuration; proposed.quitAfterLastWindowCloses = enabled
            try configurationStore.save(proposed); configuration = proposed
        } catch { errorMessage = error.localizedDescription }
    }

    /// Only port metadata is committed. The old Origin stays intact until all target
    /// data and the real webpage have been verified; the wrapper never persists the payload.
    func changePort(to requested: UInt16?) async throws {
        guard !isBusy, let paths, let configurationStore, startupIssue == nil else { throw ZashDockError.invalidConfiguration("应用尚未就绪，或另一个操作正在进行。") }
        if let requested, requested < 1024 { throw ZashDockError.invalidConfiguration("端口必须在 1024–65535 之间。") }
        if requested == configuration.port, server != nil, phase == .ready { return }
        isBusy = true; defer { isBusy = false }
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
            let ports = requested.map { [$0] } ?? (9099..<9199).map(UInt16.init).filter { $0 != oldPort }
            var bindError: (any Error)?
            for port in ports {
                try Task.checkCancellation()
                status = "正在绑定 127.0.0.1:\(port)…"
                let service = try LoopbackHTTPServer(root: root, port: port, versionID: currentVersion?.id ?? "port-probe")
                do { _ = try await service.start(); targetService = service; break }
                catch { service.stop(); bindError = error; if requested != nil { throw error } }
            }
            guard let target = targetService else { throw bindError ?? ZashDockError.server("未能找到可用端口，请手动指定。") }
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
            var proposed = configuration; proposed.port = target.port
            proposed.pendingOriginCleanup = target.port == oldPort ? nil : oldPort
            try configurationStore.save(proposed)
            // No throwing operation follows the sole durable port commit.
            configuration = proposed
            session = targetPage
            if targetPage != nil { server = target; phase = .ready }
            else { target.stop(); phase = .uninstalled }
            status = "已将本地端口设为 \(target.port)，网页数据已保留。"
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
                    catch { phase = .unavailable; status = "原端口配置和网页数据已保留，请重新启动本地服务。" }
                }.value
            } else { phase = previousPhase }
            status = "端口未更改，原有配置和网页数据保持完整。"
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
        catch { status = "当前端口与网页数据已保存；原端口数据清理将在下次启动时重试。" }
    }
    func retryStart() {
        guard !isBusy, operation == nil else { return }
        isBusy = true
        operation = Task {
            defer { isBusy = false; operation = nil }
            do {
                errorMessage = nil
                if legacyImportFailed || currentVersion == nil { await initializeStartup() }
                else if let currentVersion { try await show(currentVersion); await retryPendingCleanup() }
            } catch { phase = .unavailable; errorMessage = error.localizedDescription }
        }
    }
    private func attachSessionFailure(_ webpage: WebSession) {
        webpage.onFailure = { [weak self, weak webpage] message in
            guard let self, let webpage, self.session === webpage else { return }
            self.phase = .unavailable; self.status = "网页运行已中断，可以重新载入。网页数据由 WebKit 持久管理。"
            self.errorMessage = message
        }
    }
    private func quiesce() async {
        await session?.suspend(); session?.stop(); session = nil
        server?.stop(); server = nil
    }
    private func show(_ version: InstalledVersion) async throws {
        await quiesce()
        let service = try LoopbackHTTPServer(root: version.directoryURL, port: configuration.port, versionID: version.id)
        var live: WebSession?
        do {
            _ = try await service.start()
            await WebCacheController.clearLoopbackCaches(in: dataStore)
            let webpage = WebSession(origin: service.baseURL, expectedVersion: version.id, expectedNonce: service.nonce, dataStore: dataStore)
            live = webpage; attachSessionFailure(webpage)
            try await webpage.loadAndVerify()
            session = webpage; server = service; phase = .ready
        } catch { await live?.suspend(); service.stop(); throw error }
    }
}
