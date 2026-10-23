import Foundation
import Darwin

public struct InstalledVersion: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let tag: String
    public let sha256: String
    public let installedAt: Date
    /// Only the validated content directory is served; manifests and activation state are outside it.
    public let directoryURL: URL
    public init(id: String, tag: String, sha256: String, installedAt: Date, directoryURL: URL) {
        self.id = id; self.tag = tag; self.sha256 = sha256; self.installedAt = installedAt; self.directoryURL = directoryURL
    }
}

public actor VersionStore {
    private let paths: AppPaths
    private var stateURL: URL { paths.root.appendingPathComponent("versions-state.json") }
    private let extractor: SafeZIPExtractor
    private struct State: Codable { var schema = 1; var currentID: String?; var activationOrder: [String] }
    private struct Manifest: Codable {
        let schema: Int; let id: String; let release: ZashboardRelease; let installedAt: Date; let files: [FileRecord]
    }
    private struct FileRecord: Codable { let path: String; let size: Int; let sha256: String }

    /// Owns root/versions, root/staging and root/versions-state.json. Storage snapshots are never touched.
    public init(root: URL, extractor: SafeZIPExtractor = .init()) throws {
        paths = AppPaths(root: root); self.extractor = extractor
        try paths.createDirectories()
        // Staging never contains an active version. Interrupted downloads/extractions are safe to discard.
        for temporary in try FileManager.default.contentsOfDirectory(at: paths.staging, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: temporary)
        }
    }

    /// Verify and unpack into a version directory, without changing the active version or pruning history.
    public func prepare(zip: URL, release: ZashboardRelease) throws -> InstalledVersion {
        try release.validate(); try Task.checkCancellation()
        let baseID = release.tag + "-" + release.sha256.prefix(16)
        var id = baseID
        var final = paths.versions.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: final.path) {
            if let existing = try? validatedVersion(id: id) { return existing }
            // A replacement gets a new directory. The prior current path is never removed mid-transaction.
            id = baseID + "-" + UUID().uuidString.prefix(8)
            final = paths.versions.appendingPathComponent(id, isDirectory: true)
        }
        let temporary = paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        var moved = false, finished = false
        defer { if moved && !finished { try? FileManager.default.removeItem(at: final) } }
        let input = temporary.appendingPathComponent("input.zip")
        try BoundedZIPInput(url: zip, expectedSize: release.assetSize).copy(to: input)
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard Int64(size) == release.assetSize, try ReleaseClient.digest(of: input, maximumBytes: release.assetSize) == release.sha256 else {
            throw ZashDockError.verification("ZIP 与官方 SHA-256 或文件大小不符；当前版本保持不变。")
        }
        let candidate = temporary.appendingPathComponent("version", isDirectory: true)
        let content = candidate.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try extractor.extract(input, to: content)
        let installedAt = Date()
        let manifest = Manifest(schema: 1, id: id, release: release, installedAt: installedAt, files: try fileRecords(in: content))
        try AtomicFile.encode(manifest, to: candidate.appendingPathComponent("manifest.json"))
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: candidate, to: final)
        moved = true
        let directoryHandle = open(paths.versions.path, O_RDONLY)
        if directoryHandle >= 0 { _ = fsync(directoryHandle); close(directoryHandle) }
        let version = try validatedVersion(id: id)
        finished = true
        return version
    }

    public func current() throws -> InstalledVersion? {
        guard let id = try readState().currentID else { return nil }
        return try validatedVersion(id: id)
    }

    /// Most recently activated historical versions first. Staged, never activated versions are excluded.
    public func history() throws -> [InstalledVersion] {
        let state = try readState()
        return state.activationOrder.reversed().filter { $0 != state.currentID }.compactMap { try? validatedVersion(id: $0) }
    }

    public func validate(_ version: InstalledVersion) throws -> InstalledVersion {
        let actual = try validatedVersion(id: version.id)
        guard actual == version else { throw ZashDockError.invalidInstallation("版本描述不匹配。") }
        return actual
    }

    /// Removes an uncommitted candidate after a failed webpage validation. Activated versions are protected.
    public func discardPrepared(_ version: InstalledVersion) throws {
        guard validID(version.id) else { throw ZashDockError.invalidInstallation("版本目录名称无效。") }
        let state = try readState()
        guard state.currentID != version.id, !state.activationOrder.contains(version.id) else { return }
        let directory = paths.versions.appendingPathComponent(version.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    /// Caller must first verify an actual webpage load. One atomic state write is the only commit point.
    public func activate(_ version: InstalledVersion) throws {
        _ = try validate(version)
        var state: State
        do { state = try readState() }
        catch {
            // Preserve the original for diagnostics and allow explicit repair installation to commit.
            if FileManager.default.fileExists(atPath: stateURL.path) {
                try FileManager.default.copyItem(at: stateURL, to: paths.root.appendingPathComponent("versions-state-corrupt-\(UUID().uuidString).json"))
            }
            state = State(currentID: nil, activationOrder: [])
        }
        state.activationOrder.removeAll { $0 == version.id }
        state.activationOrder.append(version.id); state.currentID = version.id
        try AtomicFile.encode(state, to: stateURL)
    }

    /// Pruning is deliberately separate from activation and is called only after verified commit.
    /// An active server's protected ID is always retained, even if a caller has not yet released it.
    public func prune(maxHistory: Int, protecting: Set<String> = []) throws {
        guard (0...100).contains(maxHistory) else { throw ZashDockError.invalidConfiguration("历史版本保留数必须在 0–100 之间。") }
        var state = try readState()
        guard let currentID = state.currentID else { return }
        _ = try validatedVersion(id: currentID)
        let historical = state.activationOrder.reversed().filter { $0 != currentID }
        let keep = Set(historical.prefix(maxHistory)).union(protecting).union([currentID])
        // Persist the pruned activation list first. A crash can leave harmless unreferenced directories.
        state.activationOrder = state.activationOrder.filter { keep.contains($0) }
        try AtomicFile.encode(state, to: stateURL)
        for directory in try FileManager.default.contentsOfDirectory(at: paths.versions, includingPropertiesForKeys: nil) {
            if !keep.contains(directory.lastPathComponent) { try FileManager.default.removeItem(at: directory) }
        }
    }

    private func readState() throws -> State {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return State(currentID: nil, activationOrder: []) }
        let state = try AtomicFile.decode(State.self, from: stateURL)
        guard state.schema == 1, Set(state.activationOrder).count == state.activationOrder.count,
              state.activationOrder.allSatisfy(validID), state.currentID.map(validID) ?? true,
              state.currentID.map({ state.activationOrder.contains($0) }) ?? state.activationOrder.isEmpty else {
            throw ZashDockError.invalidInstallation("版本指针损坏，请使用安装界面修复。")
        }
        return state
    }
    private func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) } && id != "." && id != ".."
    }
    private func validatedVersion(id: String) throws -> InstalledVersion {
        guard validID(id) else { throw ZashDockError.invalidInstallation("版本目录名称无效。") }
        let directory = paths.versions.appendingPathComponent(id, isDirectory: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ZashDockError.invalidInstallation("版本目录不存在或无效。") }
        let manifest = try AtomicFile.decode(Manifest.self, from: directory.appendingPathComponent("manifest.json"))
        try manifest.release.validate()
        guard manifest.schema == 1, manifest.id == id,
              (id == manifest.release.tag + "-" + manifest.release.sha256.prefix(16) || id.hasPrefix(manifest.release.tag + "-" + manifest.release.sha256.prefix(16) + "-")) else { throw ZashDockError.invalidInstallation("安装清单无效。") }
        let content = directory.appendingPathComponent("content", isDirectory: true)
        let actual = try fileRecords(in: content)
        guard actual.count == manifest.files.count,
              zip(actual, manifest.files).allSatisfy({ $0.path == $1.path && $0.size == $1.size && $0.sha256 == $1.sha256 }),
              actual.contains(where: { $0.path == "index.html" && $0.size > 0 }), actual.contains(where: { $0.path.hasSuffix(".js") }) else {
            throw ZashDockError.invalidInstallation("安装文件已损坏，请重新安装官方版本。")
        }
        return InstalledVersion(id: id, tag: manifest.release.tag, sha256: manifest.release.sha256,
                                installedAt: manifest.installedAt, directoryURL: content)
    }
    private func fileRecords(in content: URL) throws -> [FileRecord] {
        let values = try content.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let enumerator = FileManager.default.enumerator(atPath: content.path) else {
            throw ZashDockError.invalidInstallation("安装内容目录无效。")
        }
        var records: [FileRecord] = []; var total = 0
        while let path = enumerator.nextObject() as? String {
            try Task.checkCancellation()
            let url = content.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw ZashDockError.invalidInstallation("安装含不安全文件。") }
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? -1
            total += max(0, size)
            guard size >= 0, size <= extractor.limits.maxFileBytes, total <= extractor.limits.maxExpandedBytes,
                  records.count < extractor.limits.maxEntries else { throw ZashDockError.invalidInstallation("安装文件超过安全限制。") }
            records.append(FileRecord(path: path, size: size, sha256: try ReleaseClient.digest(of: url)))
        }
        return records.sorted { $0.path < $1.path }
    }
}

/// Pins the selected regular file before copying. It never follows a final symlink, never copies more
/// than the authenticated asset size, and rejects path replacement or file mutation during the copy.
final class BoundedZIPInput {
    private let url: URL
    private let descriptor: Int32
    private let initial: stat
    private let expectedSize: Int64
    init(url: URL, expectedSize: Int64) throws {
        guard expectedSize > 0, expectedSize <= SafeZIPExtractor.Limits.standard.maxArchiveBytes else {
            throw ZashDockError.verification("ZIP 大小超过安全限制。")
        }
        let source = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard source >= 0 else { throw ZashDockError.verification("无法安全打开 ZIP；不允许符号链接。") }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == expectedSize else {
            close(source); throw ZashDockError.verification("ZIP 必须是大小与官方资产一致的普通文件。")
        }
        self.url = url; self.descriptor = source; self.initial = info; self.expectedSize = expectedSize
    }
    deinit { close(descriptor) }
    func copy(to destination: URL) throws {
        try validateIdentity()
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw ZashDockError.verification("无法读取 ZIP。") }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw ZashDockError.storage("无法创建 ZIP 暂存文件。") }
        var succeeded = false
        defer { close(output); if !succeeded { unlink(destination.path) } }
        var buffer = [UInt8](repeating: 0, count: 65_536), copied: Int64 = 0
        while copied < expectedSize {
            try Task.checkCancellation()
            let limit = Int(min(Int64(buffer.count), expectedSize - copied))
            let count = Darwin.read(descriptor, &buffer, limit)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ZashDockError.verification("ZIP 在复制期间被截断或不可读。") }
            var written = 0
            while written < count {
                let length = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: written), count - written) }
                if length < 0 && errno == EINTR { continue }
                guard length > 0 else { throw ZashDockError.storage("无法写入 ZIP 暂存文件。") }
                written += length
            }
            copied += Int64(count)
        }
        var extra: UInt8 = 0
        var tail: Int
        repeat { tail = Darwin.read(descriptor, &extra, 1) } while tail < 0 && errno == EINTR
        guard tail == 0 else { throw ZashDockError.verification("ZIP 在复制期间增长，已拒绝安装。") }
        try validateIdentity()
        try Task.checkCancellation()
        guard fsync(output) == 0 else { throw ZashDockError.storage("无法同步 ZIP 暂存文件。") }
        succeeded = true
    }
    private func validateIdentity() throws {
        var current = stat(), path = stat()
        guard fstat(descriptor, &current) == 0, lstat(url.path, &path) == 0,
              path.st_mode & S_IFMT == S_IFREG, path.st_dev == initial.st_dev, path.st_ino == initial.st_ino,
              current.st_dev == initial.st_dev, current.st_ino == initial.st_ino, current.st_size == expectedSize,
              current.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec, current.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else {
            throw ZashDockError.verification("ZIP 在安装期间被替换或修改，已拒绝安装。")
        }
    }
}
