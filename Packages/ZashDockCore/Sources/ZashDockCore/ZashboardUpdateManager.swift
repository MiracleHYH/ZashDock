import Foundation
import Observation

@MainActor @Observable
public final class ZashboardUpdateManager {
    public private(set) var latest: ZashboardRelease?
    public private(set) var progress: DownloadProgress?
    public private(set) var isBusy = false
    public private(set) var status = ""
    public private(set) var lastError: String?
    public let store: VersionStore
    @ObservationIgnored private let client: ReleaseClient
    @ObservationIgnored private let downloadDirectory: URL
    @ObservationIgnored private var stagingTask: Task<InstalledVersion, Error>?

    public init(store: VersionStore, client: ReleaseClient, downloadDirectory: URL) {
        self.store = store; self.client = client; self.downloadDirectory = downloadDirectory
    }

    public func checkForUpdates() async throws {
        guard !isBusy else { throw ZashDockError.invalidConfiguration("另一个版本操作正在进行。") }
        isBusy = true; lastError = nil; status = "正在检查官方稳定版…"
        defer { isBusy = false }
        do {
            try Task.checkCancellation()
            let release = try await client.latest()
            try Task.checkCancellation()
            latest = release; status = "已获取最新官方稳定版。"
        } catch {
            if error is CancellationError || Task.isCancelled {
                lastError = nil; status = "已取消检查更新。"; throw CancellationError()
            }
            lastError = error.localizedDescription; status = "检查失败，可重试或导入本地 ZIP。"; throw error
        }
    }

    public func stageLatest() async throws -> InstalledVersion { try await runStage(localZIP: nil, release: nil) }
    public func stage(release: ZashboardRelease) async throws -> InstalledVersion { try await runStage(localZIP: nil, release: release) }
    public func stageLocalZIP(_ zip: URL) async throws -> InstalledVersion { try await runStage(localZIP: zip, release: nil) }
    public func cancel() { stagingTask?.cancel() }

    /// The caller verifies the persistent live webpage before removing obsolete resources.
    public func commit(version: InstalledVersion) async throws {
        try await store.activate(version)
        do { try await store.removeInactiveVersions() }
        catch { status = "版本已切换；旧资源清理将在下次启动时重试。"; lastError = error.localizedDescription; return }
        status = "已启用 \(version.tag)。"
    }

    private func runStage(localZIP: URL?, release providedRelease: ZashboardRelease?) async throws -> InstalledVersion {
        guard !isBusy else { throw ZashDockError.invalidConfiguration("另一个版本操作正在进行。") }
        isBusy = true; lastError = nil; progress = nil
        status = localZIP == nil ? "正在获取官方稳定版…" : "正在导入本地 ZIP…"
        let client = client, store = store, downloadDirectory = downloadDirectory
        let task = Task { [weak self] () throws -> InstalledVersion in
            try Task.checkCancellation()
            if let localZIP {
                self?.status = "正在解压本地 ZIP…"
                return try await store.prepareLocalZIP(localZIP)
            }
            let release: ZashboardRelease
            if let providedRelease { release = providedRelease }
            else { release = try await client.latest(); self?.latest = release }
            try Task.checkCancellation()
            self?.status = "正在下载官方 \(release.tag)…"
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let zip = downloadDirectory.appendingPathComponent("download-\(UUID().uuidString).zip")
            defer { try? FileManager.default.removeItem(at: zip) }
            try await client.download(release, to: zip) { [weak self] update in
                await MainActor.run { self?.progress = update }
            }
            try Task.checkCancellation()
            self?.status = "正在校验并解压 \(release.tag)…"
            return try await store.prepare(zip: zip, release: release)
        }
        stagingTask = task
        defer { isBusy = false; stagingTask = nil }
        do {
            let version = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            status = "资源已准备，正在载入网页。"
            return version
        } catch {
            if error is CancellationError || task.isCancelled || Task.isCancelled {
                status = "已取消；现有版本保持可用。"; throw CancellationError()
            }
            lastError = error.localizedDescription; status = "安装失败，可重试。"; throw error
        }
    }
}
