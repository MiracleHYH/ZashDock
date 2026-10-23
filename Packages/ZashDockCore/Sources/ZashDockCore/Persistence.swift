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
    public var snapshot: URL { root.appendingPathComponent("storage.aesgcm") }
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

public struct ConfigurationStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfiguration() }
        let value = try AtomicFile.decode(AppConfiguration.self, from: url)
        try validate(value)
        return value
    }
    public func save(_ configuration: AppConfiguration) throws {
        try validate(configuration)
        try AtomicFile.encode(configuration, to: url)
    }
    private func validate(_ configuration: AppConfiguration) throws {
        guard configuration.port >= 1024 else { throw ZashDockError.invalidConfiguration("端口必须在 1024–65535 之间。") }
        guard (0...100).contains(configuration.maxRollbackVersions) else {
            throw ZashDockError.invalidConfiguration("历史版本保留数必须在 0–100 之间。")
        }
    }
}
