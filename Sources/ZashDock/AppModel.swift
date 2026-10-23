import Foundation
import Observation
import ZashDockCore

@MainActor @Observable
final class AppModel {
    enum Phase { case starting, uninstalled, installing, ready, damaged, unavailable }
    var phase: Phase = .starting
    var errorMessage: String?
    var status = "正在检查本地安装…"
    var configuration = AppConfiguration()
    var currentVersion: InstalledVersion?
    var session: WebSession?
    var updater: ZashboardUpdateManager?
    var history: [InstalledVersion] = []
    var isBusy = false
    var settingsVisible = false
    @ObservationIgnored var paths: AppPaths?
    @ObservationIgnored var store: VersionStore?
    @ObservationIgnored var configurationStore: ConfigurationStore?
    @ObservationIgnored var server: LoopbackHTTPServer?
    @ObservationIgnored var snapshotVault: StorageSnapshotVault?
    @ObservationIgnored var operation: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private let suppliedPaths: AppPaths?
    @ObservationIgnored private let keyProvider: any StorageSnapshotKeyProviding

    init(paths: AppPaths? = nil, keyProvider: any StorageSnapshotKeyProviding = KeychainSnapshotKeyProvider()) {
        suppliedPaths = paths; self.keyProvider = keyProvider
    }

    func start() async {
        guard !didStart else { return }; didStart = true
        isBusy = true
        defer { isBusy = false }
        do {
            let paths = try suppliedPaths ?? AppPaths.application()
            try paths.createDirectories(); self.paths = paths
            let configurationStore = ConfigurationStore(url: paths.configuration)
            self.configurationStore = configurationStore
            configuration = try configurationStore.load()
            let snapshotVault = StorageSnapshotVault(url: paths.snapshot, keyProvider: keyProvider)
            self.snapshotVault = snapshotVault
            let recovered = try await snapshotVault.load()
            if let recovery = recovered.recovery { errorMessage = recovery.explanation }
            let store = try VersionStore(root: paths.root); self.store = store
            updater = ZashboardUpdateManager(store: store, client: ReleaseClient(catalogURL: paths.root.appendingPathComponent("official-releases.json")), downloadDirectory: paths.staging)
            do { currentVersion = try await store.current() }
            catch { phase = .damaged; throw error }
            guard let currentVersion else { phase = .uninstalled; status = "首次使用需要安装官方网页资源。"; return }
            try await show(currentVersion)
            do { try await store.prune(maxHistory: configuration.maxRollbackVersions) }
            catch { status = "当前版本可用；历史清理将在下次启动时重试。" }
            history = try await store.history()
        } catch { if phase != .damaged { phase = .unavailable }; errorMessage = error.localizedDescription }
    }

    func install(zip: URL? = nil, release: ZashboardRelease? = nil) {
        guard !isBusy, operation == nil, let updater else { return }
        isBusy = true
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
                guard let candidate else { return }
                try await activateVersion(candidate)
            } catch {
                if let candidate { try? await store?.discardPrepared(candidate) }
                if phase == .installing { phase = previousPhase }
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }
    func prepareToQuit() async -> Bool {
        cancel()
        await operation?.value
        do {
            try await session?.flush()
            session?.stop(); server?.stop()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func cancel() { updater?.cancel(); operation?.cancel() }

    func checkForUpdates() {
        guard !isBusy, operation == nil, let updater else { return }
        isBusy = true
        operation = Task {
            defer { isBusy = false; operation = nil }
            do { try await updater.checkForUpdates(); history = try await updater.store.history() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func rollback(_ version: InstalledVersion) {
        guard !isBusy, operation == nil else { return }
        operation = Task {
            defer { operation = nil }
            do { try await switchVersion(version) }
            catch { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
        }
    }

    func switchVersion(_ version: InstalledVersion) async throws {
        guard !isBusy else { throw ZashDockError.invalidConfiguration("另一个操作正在进行。") }
        isBusy = true
        defer { isBusy = false }
        try await activateVersion(version)
    }

    /// Version directories and the native snapshot survive every pre-commit failure.
    private func activateVersion(_ version: InstalledVersion) async throws {
        guard let store, let updater, let snapshotVault else { throw ZashDockError.invalidConfiguration("版本管理尚未就绪。") }
        _ = try await store.validate(version)
        let previousVersion = currentVersion, previousPhase = phase
        let wasRunning = server != nil
        try await session?.flush()
        let snapshot = try await snapshotVault.load().snapshot
        session?.storageBridge?.disableAutomaticPersistence()
        status = "正在验证 \(version.tag)…"; phase = .installing
        await session?.suspend()
        server?.stop(); server = nil; session = nil
        var candidateServer: LoopbackHTTPServer?
        var candidateSession: WebSession?
        do {
            let candidate = try await makeSession(version, snapshot: snapshot)
            candidateServer = candidate.0; candidateSession = candidate.1
            let stagedSnapshot = try await candidate.1.storageBridge?.flush(candidate.1.page)
            // Establish encrypted durability before the very first installation commits.
            // Later versions already have the authoritative pre-update snapshot and its encrypted backup.
            if snapshot == nil, let stagedSnapshot { try await snapshotVault.save(stagedSnapshot) }
            try Task.checkCancellation()
            try await updater.commit(version: version, maxHistory: configuration.maxRollbackVersions)
            currentVersion = version; server = candidate.0; session = candidate.1; phase = .ready
            candidate.1.storageBridge?.enableAutomaticPersistence()
            do { try await candidate.1.flush() } catch { errorMessage = error.localizedDescription }
            history = (try? await store.history()) ?? []
            status = updater.status
        } catch {
            candidateSession?.stop(); candidateServer?.stop()
            currentVersion = previousVersion
            if wasRunning, let previousVersion {
                do {
                    // A fresh task is necessary: a cancelled update must not cancel its own recovery.
                    let restored = try await Task { @MainActor [self] in
                        let restored = try await makeSession(previousVersion, snapshot: snapshot)
                        restored.1.storageBridge?.enableAutomaticPersistence()
                        try await restored.1.flush()
                        return restored
                    }.value
                    server = restored.0; session = restored.1; phase = .ready
                } catch {
                    phase = .unavailable
                    status = "原版本与快照已保留；本地服务需要重新启动或更换端口。"
                }
            } else { phase = previousPhase == .installing ? .uninstalled : previousPhase }
            throw error
        }
    }

    func setRetention(_ count: Int) {
        guard !isBusy, let configurationStore, let store else { return }
        isBusy = true
        operation = Task {
            defer { isBusy = false; operation = nil }
            do {
                var proposed = configuration; proposed.maxRollbackVersions = count
                try configurationStore.save(proposed); configuration = proposed
                try await store.prune(maxHistory: count, protecting: Set([server?.versionID].compactMap { $0 }))
                history = try await store.history()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func reload() {
        guard !isBusy else { return }
        isBusy = true
        operation = Task {
            defer { isBusy = false; operation = nil }
            do {
                try await session?.flush()
                if let currentVersion { try await show(currentVersion) }
            } catch { phase = .unavailable; errorMessage = error.localizedDescription }
        }
    }

    func requestPort(_ text: String?) {
        guard !isBusy, operation == nil else { return }
        let requested: UInt16?
        if let text {
            guard let parsed = UInt16(text), parsed >= 1024 else {
                errorMessage = "端口必须在 1024–65535 之间。"; return
            }
            requested = parsed
        } else { requested = nil }
        operation = Task {
            defer { operation = nil }
            do { try await changePort(to: requested) }
            catch { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
        }
    }

    func setQuitAfterLastWindow(_ enabled: Bool) {
        guard !isBusy, let configurationStore else { return }
        do {
            var proposed = configuration; proposed.quitAfterLastWindowCloses = enabled
            try configurationStore.save(proposed); configuration = proposed
        } catch { errorMessage = error.localizedDescription }
    }

    /// The configuration file is the commit point. The old listener remains alive until it succeeds.
    func changePort(to requested: UInt16?) async throws {
        guard !isBusy, let paths, let configurationStore, let snapshotVault else {
            throw ZashDockError.invalidConfiguration("应用尚未就绪，或另一个操作正在进行。")
        }
        if let requested, requested < 1024 { throw ZashDockError.invalidConfiguration("端口必须在 1024–65535 之间。") }
        if requested == configuration.port, server != nil, phase == .ready { return }
        isBusy = true; status = "正在备份网页设置…"
        defer { isBusy = false }
        let oldSession = session, oldServer = server
        try await oldSession?.flush()
        oldSession?.storageBridge?.disableAutomaticPersistence()
        var candidateServer: LoopbackHTTPServer?
        var candidateSession: WebSession?
        let probe = paths.root.appendingPathComponent("port-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        do {
            let snapshot = try await snapshotVault.load().snapshot
            let root: URL
            if let currentVersion { root = currentVersion.directoryURL }
            else {
                try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                root = probe
            }
            let ports: [UInt16]
            if let requested { ports = [requested] }
            else {
                ports = (9099..<9199).map(UInt16.init).filter { $0 != oldServer?.port }
            }
            var bindError: (any Error)?
            for port in ports {
                try Task.checkCancellation()
                status = "正在绑定 127.0.0.1:\(port)…"
                let listener = try LoopbackHTTPServer(root: root, port: port, versionID: currentVersion?.id ?? "port-probe")
                do { _ = try await listener.start(); candidateServer = listener; break }
                catch { listener.stop(); bindError = error; if requested != nil { throw error } }
            }
            guard let listener = candidateServer else { throw bindError ?? ZashDockError.server("未能找到可用端口，请手动指定。") }
            try Task.checkCancellation()
            if let currentVersion {
                status = "正在迁移并验证网页设置…"
                await WebCacheController.clearLoopbackCaches()
                let bridge = try ZashboardStorageBridge(origin: listener.baseURL, vault: snapshotVault, snapshot: snapshot, automaticallyPersists: false)
                let webpage = WebSession(origin: listener.baseURL, storageBridge: bridge, expectedVersion: currentVersion.id, expectedNonce: listener.nonce)
                candidateSession = webpage
                try await webpage.loadAndVerify()
                // Capture/validate without writing the authoritative snapshot before commit.
                try await webpage.flush()
            }
            try Task.checkCancellation()
            var proposed = configuration; proposed.port = listener.port
            try configurationStore.save(proposed)
            // No throwing transaction operations follow this durable commit.
            configuration = proposed
            oldSession?.stop(); oldServer?.stop()
            if let webpage = candidateSession {
                session = webpage; server = listener; phase = .ready
                webpage.storageBridge?.onPersistenceError = { [weak self] message in self?.errorMessage = message }
                webpage.storageBridge?.enableAutomaticPersistence()
                do { try await webpage.flush() } catch { errorMessage = error.localizedDescription }
            } else { listener.stop(); session = nil; server = nil; phase = .uninstalled }
            status = "已将本地端口设为 \(listener.port)，网页设置已保留。"
        } catch {
            candidateSession?.stop(); candidateServer?.stop()
            oldSession?.storageBridge?.enableAutomaticPersistence()
            status = "端口未更改，原有配置和快照保持完整。"
            throw error
        }
    }
    func retryStart() {
        guard !isBusy, let currentVersion else { return }
        isBusy = true
        operation = Task {
            defer { isBusy = false; operation = nil }
            do { try await show(currentVersion) }
            catch { phase = .unavailable; errorMessage = error.localizedDescription }
        }
    }
    private func makeSession(_ version: InstalledVersion, snapshot: [String: String]?) async throws -> (LoopbackHTTPServer, WebSession) {
        guard let snapshotVault else { throw ZashDockError.storage("存储快照尚未就绪。") }
        let listener = try LoopbackHTTPServer(root: version.directoryURL, port: configuration.port, versionID: version.id)
        do {
            let url = try await listener.start()
            await WebCacheController.clearLoopbackCaches()
            let bridge = try ZashboardStorageBridge(origin: url, vault: snapshotVault, snapshot: snapshot, automaticallyPersists: false)
            bridge.onPersistenceError = { [weak self] message in self?.errorMessage = message }
            let webpage = WebSession(origin: url, storageBridge: bridge, expectedVersion: version.id, expectedNonce: listener.nonce)
            try await webpage.loadAndVerify()
            return (listener, webpage)
        } catch { listener.stop(); throw error }
    }

    private func show(_ version: InstalledVersion) async throws {
        await session?.suspend()
        server?.stop(); session?.stop(); session = nil
        do {
            guard let snapshotVault else { throw ZashDockError.storage("存储快照尚未就绪。") }
            let snapshot = try await snapshotVault.load().snapshot
            let candidate = try await makeSession(version, snapshot: snapshot)
            session = candidate.1; server = candidate.0
            candidate.1.storageBridge?.enableAutomaticPersistence()
            try await candidate.1.flush()
            phase = .ready
        } catch { server?.stop(); session?.stop(); session = nil; server = nil; throw error }
    }
}
