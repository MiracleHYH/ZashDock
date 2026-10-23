import Foundation
import Darwin

public enum ZashDockError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case invalidInstallation(String)
    case server(String)
    case storage(String)
    case verification(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message), let .invalidInstallation(message), let .server(message), let .storage(message), let .verification(message): message
        }
    }
}

public struct AppPaths: Sendable {
    public let root: URL
    public var configuration: URL { root.appendingPathComponent("configuration.json") }
    public var legacyStorage: URL { root.appendingPathComponent("storage.aesgcm") }
    public var versions: URL { root.appendingPathComponent("versions", isDirectory: true) }
    public var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }
    public init(root: URL) { self.root = root }
    public static func application() throws -> AppPaths {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return AppPaths(root: support.appendingPathComponent("app.zashdock.mac", isDirectory: true))
    }
    public func createDirectories() throws {
        for directory in [root, versions, staging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

/// The temporary file is in the destination directory so rename is atomic on the same volume.
public enum AtomicFile {
    public static func write(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ZashDockError.storage("无法创建原子写入临时文件。")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw ZashDockError.storage("无法提交原子文件（errno \(errno)）。")
        }
        let directory = open(parent.path, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }
    public static func encode<T: Encodable>(_ value: T, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try write(encoder.encode(value), to: destination)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from source: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: source))
    }
}

/// Only wrapper preferences are covered by this error and its reset workflow.
/// Encrypted website state, its key, and installed versions have separate recovery policies.
public struct ConfigurationLoadFailure: LocalizedError, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case malformedJSON, invalidFields, invalidValues, unreadable, missingPrimary
    }
    public let kind: Kind
    public init(kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .malformedJSON: "普通设置文件不是有效的 JSON；原文件已保留。"
        case .invalidFields: "普通设置文件缺少必要字段，或字段类型不正确；原文件已保留。"
        case .invalidValues: "普通设置文件中的当前端口或待清理端口无效；原文件已保留。"
        case .unreadable: "无法读取普通设置文件；请检查文件访问权限后重试。原文件未被覆盖。"
        case .missingPrimary: "普通设置文件已丢失；恢复副本和已有网页数据仍保留，请恢复原端口后继续。"
        }
    }
}

public struct ConfigurationStore: Sendable {
    public let url: URL
    /// A small mirror of committed wrapper preferences; it never contains website storage.
    public var recoveryCopyURL: URL { url.deletingPathExtension().appendingPathExtension("last-valid.json") }
    public init(url: URL) { self.url = url }
    public func load() throws -> AppConfiguration {
        guard let data = try readExisting() else {
            // A prior mirror proves this is not a fresh profile. Never guess 9099 and
            // show an empty Origin just because the primary metadata disappeared.
            if FileManager.default.fileExists(atPath: recoveryCopyURL.path) {
                throw ConfigurationLoadFailure(kind: .missingPrimary)
            }
            return AppConfiguration()
        }
        return try decode(data)
    }

    private func decode(_ data: Data) throws -> AppConfiguration {
        do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw ConfigurationLoadFailure(kind: .malformedJSON) }
        let fields: ConfigurationFields
        do { fields = try JSONDecoder().decode(ConfigurationFields.self, from: data) }
        catch { throw ConfigurationLoadFailure(kind: .invalidFields) }
        guard (1024...65535).contains(fields.port),
              fields.pendingOriginCleanup.map({ (1024...65535).contains($0) && $0 != fields.port }) ?? true else {
            throw ConfigurationLoadFailure(kind: .invalidValues)
        }
        var value = AppConfiguration()
        value.port = UInt16(fields.port)
        value.quitAfterLastWindowCloses = fields.quitAfterLastWindowCloses
        value.pendingOriginCleanup = fields.pendingOriginCleanup.map(UInt16.init)
        value.legacyStorageImported = fields.legacyStorageImported
        return value
    }

    /// Explicit recovery only. Normal load never silently selects an older mirror or Origin.
    public func recoverableConfiguration() -> AppConfiguration? {
        guard let data = try? Data(contentsOf: recoveryCopyURL) else { return nil }
        return try? decode(data)
    }

    /// Call before deleting the previous Origin. Failure leaves pendingOriginCleanup committed
    /// so cleanup can retry later; it must not be reported as a failed port transaction.
    public func ensureRecoveryCopy(_ configuration: AppConfiguration) throws {
        try validate(configuration)
        guard let data = try readExisting(), try decode(data) == configuration else {
            throw ZashDockError.invalidConfiguration("只能为当前已提交的应用设置建立恢复副本。")
        }
        try AtomicFile.encode(configuration, to: recoveryCopyURL)
    }

    /// Requires an explicit user decision. A readable original is backed up before the
    /// atomic replacement; an unreadable original is never overwritten without a backup.
    @discardableResult
    public func resetToDefaultsPreservingOriginal(_ defaults: AppConfiguration = AppConfiguration(), preservingPort: UInt16? = nil) throws -> URL? {
        try validate(defaults)
        let existing = try readExisting()
        var recovered = defaults
        if let origin = existing.flatMap({ try? decode($0) }) ?? recoverableConfiguration() {
            recovered.port = origin.port
            recovered.pendingOriginCleanup = origin.pendingOriginCleanup
            recovered.legacyStorageImported = origin.legacyStorageImported
        } else if let preservingPort {
            guard preservingPort >= 1024 else { throw ZashDockError.invalidConfiguration("原端口必须在 1024–65535 之间。") }
            recovered.port = preservingPort
        } else {
            throw ZashDockError.invalidConfiguration("无法确认原本地端口。请指定原端口后再恢复应用设置，以保留该 Origin 的网页数据。")
        }
        try validate(recovered)
        let backup: URL?
        if let existing {
            let directory = url.deletingLastPathComponent().appendingPathComponent("configuration-recovery", isDirectory: true)
            let destination = directory.appendingPathComponent("configuration-\(UUID().uuidString).json")
            try AtomicFile.write(existing, to: destination)
            backup = destination
        } else { backup = nil }
        try save(recovered)
        return backup
    }
    public func save(_ configuration: AppConfiguration) throws {
        try validate(configuration)
        try AtomicFile.encode(configuration, to: url)
        // The primary file above is the sole commit point. A failed mirror must not make
        // the caller roll back an already committed port; cleanup explicitly retries it.
        try? ensureRecoveryCopy(configuration)
    }
    private func validate(_ configuration: AppConfiguration) throws {
        guard configuration.port >= 1024 else { throw ZashDockError.invalidConfiguration("端口必须在 1024–65535 之间。") }
        guard configuration.pendingOriginCleanup.map({ $0 >= 1024 && $0 != configuration.port }) ?? true else {
            throw ZashDockError.invalidConfiguration("待清理的原端口必须有效，且不能等于当前端口。")
        }
    }

    private func readExisting() throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoSuchFileError { return nil }
            throw ConfigurationLoadFailure(kind: .unreadable)
        }
    }

    private struct ConfigurationFields: Decodable {
        let port: Int
        let quitAfterLastWindowCloses: Bool
        let pendingOriginCleanup: Int?
        let legacyStorageImported: Bool

        private enum CodingKeys: String, CodingKey {
            case port, quitAfterLastWindowCloses, pendingOriginCleanup, legacyStorageImported
        }
        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            port = try fields.decode(Int.self, forKey: .port)
            quitAfterLastWindowCloses = try fields.decode(Bool.self, forKey: .quitAfterLastWindowCloses)
            pendingOriginCleanup = try fields.decodeIfPresent(Int.self, forKey: .pendingOriginCleanup)
            legacyStorageImported = fields.contains(.legacyStorageImported)
                ? try fields.decode(Bool.self, forKey: .legacyStorageImported) : false
        }
    }
}
