import Foundation
import Observation

@MainActor @Observable
public final class ZashboardUpdateManager {
    public private(set) var releases: [ZashboardRelease] = []
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
            latest = try await client.latest()
            releases = try await client.stableReleases()
            status = "版本目录已更新。"
        } catch {
            if error is CancellationError || Task.isCancelled {
                lastError = nil; status = "已取消检查更新。"
                throw CancellationError()
            }
            lastError = error.localizedDescription; status = "检查失败，可重试或导入官方 ZIP。"; throw error
        }
    }

    public func stageLatest() async throws -> InstalledVersion {
        try await runStage(localZIP: nil, release: nil)
    }

    public func stage(release: ZashboardRelease) async throws -> InstalledVersion {
        try await runStage(localZIP: nil, release: release)
    }

    public func stageLocalZIP(_ zip: URL) async throws -> InstalledVersion {
        try await runStage(localZIP: zip, release: nil)
    }

    public func cancel() { stagingTask?.cancel() }

    /// Stage first, verify the candidate through WebKit, then call this explicit commit.
    public func commit(version: InstalledVersion, maxHistory: Int, protecting: Set<String> = []) async throws {
        try await store.activate(version)
        // Cleanup failure must never invalidate a successful activation or its current directory.
        do { try await store.prune(maxHistory: maxHistory, protecting: protecting) }
        catch { status = "版本已切换；历史清理将在下次操作时重试。"; lastError = error.localizedDescription; return }
        status = "已启用 \(version.tag)。"
    }

    private func runStage(localZIP: URL?, release providedRelease: ZashboardRelease?) async throws -> InstalledVersion {
        guard !isBusy else { throw ZashDockError.invalidConfiguration("另一个版本操作正在进行。") }
        isBusy = true; lastError = nil; progress = nil
        status = localZIP == nil ? "正在获取官方稳定版…" : "正在验证本地官方 ZIP…"
        let client = client, store = store, downloadDirectory = downloadDirectory
        let task = Task { [weak self] () throws -> InstalledVersion in
            let release: ZashboardRelease
            if let providedRelease { release = providedRelease }
            else if let localZIP { release = try await client.identifyLocalZIP(localZIP) }
            else { release = try await client.latest(); self?.latest = release }
            try Task.checkCancellation()
            self?.status = localZIP == nil ? "正在下载官方 \(release.tag)…" : "正在验证本地官方 ZIP…"
            let zip: URL
            var downloaded: URL?
            if let localZIP { zip = localZIP }
            else {
                try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                zip = downloadDirectory.appendingPathComponent("download-\(UUID().uuidString).zip")
                downloaded = zip
            }
            defer { if let downloaded { try? FileManager.default.removeItem(at: downloaded) } }
            if localZIP == nil {
                try await client.download(release, to: zip) { [weak self] update in
                    await MainActor.run { self?.progress = update }
                }
            }
            try Task.checkCancellation()
            self?.status = "正在校验并解压 \(release.tag)…"
            return try await store.prepare(zip: zip, release: release)
        }
        stagingTask = task
        defer { isBusy = false; stagingTask = nil }
        do {
            let version = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            status = "文件验证成功，等待网页加载验证。"
            return version
        } catch is CancellationError {
            status = "已取消；现有版本保持可用。"; throw CancellationError()
        } catch {
            if task.isCancelled || Task.isCancelled {
                status = "已取消；现有版本保持可用。"; throw CancellationError()
            }
            lastError = error.localizedDescription; status = "安装失败，可重试。"; throw error
        }
    }
}
