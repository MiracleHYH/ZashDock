import Foundation
import Darwin

public struct InstalledVersion: Codable, Sendable, Identifiable, Equatable {
    public enum Source: String, Codable, Sendable { case githubRelease, localArchive }
    public let id: String
    public let tag: String
    public let sha256: String
    public let installedAt: Date
    public let source: Source
    /// Only the validated content directory is served; manifests and selection state are outside it.
    public let directoryURL: URL
    public init(id: String, tag: String, sha256: String, installedAt: Date, directoryURL: URL, source: Source = .githubRelease) {
        self.id = id; self.tag = tag; self.sha256 = sha256; self.installedAt = installedAt
        self.directoryURL = directoryURL; self.source = source
    }
    private enum CodingKeys: String, CodingKey { case id, tag, sha256, installedAt, directoryURL, source }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id); tag = try values.decode(String.self, forKey: .tag)
        sha256 = try values.decode(String.self, forKey: .sha256); installedAt = try values.decode(Date.self, forKey: .installedAt)
        directoryURL = try values.decode(URL.self, forKey: .directoryURL)
        source = try values.decodeIfPresent(Source.self, forKey: .source) ?? .githubRelease
    }
}

public actor VersionStore {
    private let paths: AppPaths
    private var stateURL: URL { paths.root.appendingPathComponent("versions-state.json") }
    private let extractor: SafeZIPExtractor
    // Older schema-1 selection files also contain activationOrder and prune reports.
    // Those fields are ignored; only the current resource selection remains authoritative.
    private struct State: Codable { var schema = 1; var currentID: String? }
    private struct Manifest: Codable {
        let schema: Int; let id: String
        let source: InstalledVersion.Source?
        let tag: String?; let sha256: String?
        let release: ZashboardRelease?
        let installedAt: Date; let files: [FileRecord]
    }
    private struct FileRecord: Codable { let path: String; let size: Int; let sha256: String }

    /// Owns root/versions, root/staging and root/versions-state.json. Website data is never touched.
    public init(root: URL, extractor: SafeZIPExtractor = .init()) throws {
        paths = AppPaths(root: root); self.extractor = extractor
        try paths.createDirectories()
        for temporary in try FileManager.default.contentsOfDirectory(at: paths.staging, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: temporary)
        }
    }

    /// Official downloads retain HTTPS source, published size and digest verification.
    public func prepare(zip: URL, release: ZashboardRelease) throws -> InstalledVersion {
        try release.validate(); try Task.checkCancellation()
        let baseID = release.tag + "-" + release.sha256.prefix(16)
        var id = baseID
        if FileManager.default.fileExists(atPath: paths.versions.appendingPathComponent(id).path) {
            if let existing = try? validatedVersion(id: id) { return existing }
            id = baseID + "-" + UUID().uuidString.prefix(8)
        }
        return try prepareArchive(zip, id: id, expectedSize: release.assetSize, release: release)
    }

    /// Local import is fully offline. Its digest identifies the private copied input only;
    /// it is never matched against a release catalog or presented as proof of official origin.
    public func prepareLocalZIP(_ zip: URL) throws -> InstalledVersion {
        try Task.checkCancellation()
        let size = try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        return try prepareArchive(zip, id: "local-" + UUID().uuidString, expectedSize: Int64(size), release: nil)
    }

    private func prepareArchive(_ zip: URL, id: String, expectedSize: Int64, release: ZashboardRelease?) throws -> InstalledVersion {
        let final = paths.versions.appendingPathComponent(id, isDirectory: true)
        let temporary = paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        var moved = false, finished = false
        defer { if moved && !finished { try? FileManager.default.removeItem(at: final) } }
        let input = temporary.appendingPathComponent("input.zip")
        try BoundedZIPInput(url: zip, expectedSize: expectedSize).copy(to: input)
        let digest = try ReleaseClient.digest(of: input, maximumBytes: expectedSize)
        if let release, digest != release.sha256 {
            throw ZashDockError.verification("ZIP 与官方 SHA-256 不符；当前版本保持不变。")
        }
        let candidate = temporary.appendingPathComponent("version", isDirectory: true)
        let content = candidate.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try extractor.extract(input, to: content, requiresJavaScript: release != nil)
        let manifest = Manifest(schema: 2, id: id, source: release == nil ? .localArchive : .githubRelease,
            tag: release?.tag ?? "本地导入", sha256: digest, release: release, installedAt: Date(), files: try fileRecords(in: content))
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

    public func validate(_ version: InstalledVersion) throws -> InstalledVersion {
        let actual = try validatedVersion(id: version.id)
        guard actual == version else { throw ZashDockError.invalidInstallation("版本描述不匹配。") }
        return actual
    }

    /// Only a non-current transaction candidate can be discarded.
    public func discardPrepared(_ version: InstalledVersion) throws {
        guard validID(version.id) else { throw ZashDockError.invalidInstallation("版本目录名称无效。") }
        guard try readState().currentID != version.id else { return }
        let directory = paths.versions.appendingPathComponent(version.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    /// Caller first verifies the candidate webpage. This atomic write is the resource commit point.
    public func activate(_ version: InstalledVersion) throws {
        _ = try validate(version)
        do { _ = try readState() }
        catch {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                try FileManager.default.copyItem(at: stateURL, to: paths.root.appendingPathComponent("versions-state-corrupt-\(UUID().uuidString).json"))
            }
        }
        try AtomicFile.encode(State(currentID: version.id), to: stateURL)
    }

    /// Called only after the current persistent webpage succeeds. Keeps current and explicitly
    /// active resources, including any temporarily protected old service; no rollback history exists.
    public func removeInactiveVersions(protecting: Set<String> = []) throws {
        guard protecting.allSatisfy(validID) else { throw ZashDockError.invalidConfiguration("受保护的版本标识无效。") }
        try Task.checkCancellation()
        let state = try readState()
        guard let currentID = state.currentID else { return }
        _ = try validatedVersion(id: currentID)
        let values = try paths.versions.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ZashDockError.invalidInstallation("受管版本目录无效。") }
        let directories = try FileManager.default.contentsOfDirectory(at: paths.versions, includingPropertiesForKeys: nil)
        guard directories.allSatisfy({ validID($0.lastPathComponent) }) else { throw ZashDockError.invalidInstallation("受管版本目录含无效名称。") }
        let keep = protecting.union([currentID])
        let removals = directories.filter { !keep.contains($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        try Task.checkCancellation()
        for directory in removals {
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func readState() throws -> State {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return State(currentID: nil) }
        let state = try AtomicFile.decode(State.self, from: stateURL)
        guard state.schema == 1, state.currentID.map(validID) ?? true else {
            throw ZashDockError.invalidInstallation("版本指针损坏，请使用安装界面修复。")
        }
        return state
    }
    private func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) } && id != "." && id != ".."
    }
    private func validatedVersion(id: String) throws -> InstalledVersion {
        try Task.checkCancellation()
        guard validID(id) else { throw ZashDockError.invalidInstallation("版本目录名称无效。") }
        let directory = paths.versions.appendingPathComponent(id, isDirectory: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ZashDockError.invalidInstallation("版本目录不存在或无效。") }
        let manifest = try AtomicFile.decode(Manifest.self, from: directory.appendingPathComponent("manifest.json"))
        guard (1...2).contains(manifest.schema), manifest.id == id else { throw ZashDockError.invalidInstallation("安装清单无效。") }
        guard manifest.schema == 1 || (manifest.source != nil && manifest.tag != nil && manifest.sha256 != nil) else {
            throw ZashDockError.invalidInstallation("安装清单缺少来源或完整性信息。")
        }
        let source = manifest.source ?? .githubRelease
        let tag: String, digest: String
        switch source {
        case .githubRelease:
            guard let release = manifest.release else { throw ZashDockError.invalidInstallation("官方安装清单缺少发行信息。") }
            try release.validate()
            guard (manifest.tag == nil || manifest.tag == release.tag), (manifest.sha256 == nil || manifest.sha256 == release.sha256),
                  (id == release.tag + "-" + release.sha256.prefix(16) || id.hasPrefix(release.tag + "-" + release.sha256.prefix(16) + "-")) else {
                throw ZashDockError.invalidInstallation("官方安装清单无效。")
            }
            tag = release.tag; digest = release.sha256
        case .localArchive:
            guard manifest.schema == 2, manifest.release == nil, manifest.tag == "本地导入",
                  id.hasPrefix("local-"), UUID(uuidString: String(id.dropFirst(6))) != nil,
                  let hash = manifest.sha256, hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw ZashDockError.invalidInstallation("本地安装清单无效。")
            }
            tag = "本地导入"; digest = hash
        }
        let content = directory.appendingPathComponent("content", isDirectory: true)
        let actual = try fileRecords(in: content)
        guard actual.count == manifest.files.count,
              zip(actual, manifest.files).allSatisfy({ $0.path == $1.path && $0.size == $1.size && $0.sha256 == $1.sha256 }),
              actual.contains(where: { $0.path == "index.html" && $0.size > 0 }),
              source == .localArchive || actual.contains(where: { $0.path.hasSuffix(".js") }) else {
            throw ZashDockError.invalidInstallation("安装文件已损坏，请重新安装网页资源。")
        }
        return InstalledVersion(id: id, tag: tag, sha256: digest, installedAt: manifest.installedAt, directoryURL: content, source: source)
    }
    private func fileRecords(in content: URL) throws -> [FileRecord] {
        let values = try content.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ZashDockError.invalidInstallation("安装内容目录无效。")
        }
        // Foundation may canonicalize an ancestor such as /var -> /private/var in results.
        // Enumerate the same canonical root used by the containment check.
        let enumerationRoot = content.resolvingSymlinksInPath().standardizedFileURL
        var enumerationFailure: (any Error)?
        guard let enumerator = FileManager.default.enumerator(at: enumerationRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey],
            errorHandler: { _, error in enumerationFailure = error; return false }) else {
            throw ZashDockError.storage("无法读取安装内容目录；已有版本未被清理。")
        }
        let prefix = enumerationRoot.path.hasSuffix("/") ? enumerationRoot.path : enumerationRoot.path + "/"
        var records: [FileRecord] = []; var total = 0
        while let item = enumerator.nextObject() {
            try Task.checkCancellation()
            if let enumerationFailure { throw enumerationFailure }
            guard let url = item as? URL else { throw ZashDockError.storage("安装目录枚举未返回有效的受管路径。") }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw ZashDockError.invalidInstallation("安装含不安全文件。") }
            // Normalize both sides: URL enumeration returns /private/var while Foundation's
            // standardized file URLs can expose the same directory as /var.
            let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalPath.hasPrefix(prefix) else { throw ZashDockError.invalidInstallation("安装路径超出受管内容目录。") }
            let path = String(canonicalPath.dropFirst(prefix.count))
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? -1
            total += max(0, size)
            guard size >= 0, size <= extractor.limits.maxFileBytes, total <= extractor.limits.maxExpandedBytes,
                  records.count < extractor.limits.maxEntries else { throw ZashDockError.invalidInstallation("安装文件超过安全限制。") }
            records.append(FileRecord(path: path, size: size, sha256: try ReleaseClient.digest(of: url)))
        }
        // atPath enumeration silently skips unreadable subdirectories. Explicitly propagate
        // enumeration errors so temporary permissions cannot turn into destructive pruning.
        if let enumerationFailure { throw enumerationFailure }
        return records.sorted { $0.path < $1.path }
    }
}

/// Pins the selected regular file before copying. It never follows a final symlink, never copies more
/// than the pinned input size, and rejects path replacement or file mutation during the copy.
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
            close(source); throw ZashDockError.verification("ZIP 必须是大小有效且未变化的普通文件。")
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
