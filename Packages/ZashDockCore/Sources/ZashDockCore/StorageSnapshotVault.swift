import CryptoKit
import Foundation
import Security

public enum StorageSnapshotError: LocalizedError, Equatable, Sendable {
    case invalidPayload
    case payloadTooLarge
    case keyUnavailable(Int32)
    case corruptSnapshot
    case fileIO

    public var errorDescription: String? {
        switch self {
        case .invalidPayload: "网页存储快照格式不正确。"
        case .payloadTooLarge: "网页存储快照超过安全大小限制。"
        case let .keyUnavailable(status): "无法读取存储加密密钥（Keychain 状态 \(status)）；配置未被覆盖。"
        case .corruptSnapshot: "存储快照或加密密钥损坏，且没有可恢复的有效备份；配置未被覆盖。"
        case .fileIO: "无法安全读写加密存储快照；配置未被覆盖。"
        }
    }
}

public enum StorageSnapshotLimits {
    public static let maximumPayloadBytes = 8 * 1024 * 1024
    public static let maximumKeyBytes = 16 * 1024
    public static let maximumValueBytes = 4 * 1024 * 1024
    public static let maximumKeyCount = 4096

    public static func validate(_ snapshot: [String: String]) throws {
        guard snapshot.count <= maximumKeyCount else { throw StorageSnapshotError.payloadTooLarge }
        var byteCount = 0
        for (key, value) in snapshot {
            let keyBytes = key.utf8.count
            let valueBytes = value.utf8.count
            guard keyBytes <= maximumKeyBytes, valueBytes <= maximumValueBytes else { throw StorageSnapshotError.payloadTooLarge }
            byteCount += keyBytes + valueBytes
            guard byteCount <= maximumPayloadBytes else { throw StorageSnapshotError.payloadTooLarge }
        }
        let data = try encoded(snapshot)
        guard data.count <= maximumPayloadBytes else { throw StorageSnapshotError.payloadTooLarge }
    }

    static func encoded(_ snapshot: [String: String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }
}

public protocol StorageSnapshotKeyProviding: Sendable {
    func encryptionKey(createIfMissing: Bool) throws -> SymmetricKey
}

/// Only the stable service/account pair identifies the key. No synchronizable or shared access group is used.
public struct KeychainSnapshotKeyProvider: StorageSnapshotKeyProviding {
    private let service: String
    private let account: String
    public init(service: String = "app.zashdock.mac.storage", account: String = "primary") {
        self.service = service
        self.account = account
    }
    public func encryptionKey(createIfMissing: Bool) throws -> SymmetricKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let bytes = result as? Data, bytes.count == 32 else { throw StorageSnapshotError.corruptSnapshot }
            return SymmetricKey(data: bytes)
        }
        guard status == errSecItemNotFound, createIfMissing else { throw StorageSnapshotError.keyUnavailable(status) }
        let key = SymmetricKey(size: .bits256)
        query.removeValue(forKey: kSecMatchLimit as String)
        query.removeValue(forKey: kSecReturnData as String)
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem { return try encryptionKey(createIfMissing: false) }
        guard addStatus == errSecSuccess else { throw StorageSnapshotError.keyUnavailable(addStatus) }
        return key
    }
}

public enum StorageSnapshotRecovery: String, Codable, Sendable {
    case backupRecovered
    public var explanation: String { "当前存储快照不可用，已从上一次有效的加密备份恢复；最近一次更改可能需要重新输入。" }
}

public struct StorageSnapshotLoadResult: Sendable {
    public let snapshot: [String: String]?
    public let recovery: StorageSnapshotRecovery?
    public init(snapshot: [String: String]?, recovery: StorageSnapshotRecovery? = nil) {
        self.snapshot = snapshot
        self.recovery = recovery
    }
}

/// Serializes writes and authenticates every previous snapshot before rotating it to the backup.
public actor StorageSnapshotVault {
    public nonisolated let url: URL
    public nonisolated let backupURL: URL
    private let keyProvider: any StorageSnapshotKeyProviding
    private static let header = Data("ZASHDOCK-SNAPSHOT-1\n".utf8)

    public init(url: URL, keyProvider: any StorageSnapshotKeyProviding = KeychainSnapshotKeyProvider()) {
        self.url = url
        self.backupURL = url.appendingPathExtension("backup")
        self.keyProvider = keyProvider
    }

    public func load() throws -> StorageSnapshotLoadResult {
        let hasPrimary = FileManager.default.fileExists(atPath: url.path)
        let hasBackup = FileManager.default.fileExists(atPath: backupURL.path)
        guard hasPrimary || hasBackup else { return StorageSnapshotLoadResult(snapshot: nil) }
        // Existing ciphertext must never cause a new key to be generated.
        let key = try keyProvider.encryptionKey(createIfMissing: false)
        if hasPrimary, let primary = try? readAndDecrypt(url, key: key) {
            return StorageSnapshotLoadResult(snapshot: primary.snapshot)
        }
        if hasBackup, let backup = try? readAndDecrypt(backupURL, key: key) {
            do { try AtomicFile.write(backup.data, to: url) }
            catch { throw StorageSnapshotError.fileIO }
            return StorageSnapshotLoadResult(snapshot: backup.snapshot, recovery: .backupRecovered)
        }
        throw StorageSnapshotError.corruptSnapshot
    }

    public func save(_ snapshot: [String: String]) throws {
        _ = try saveReportingRecovery(snapshot)
    }

    /// Used by the live bridge so recovery during a write is reported, as well as recovery during startup.
    @discardableResult
    public func saveReportingRecovery(_ snapshot: [String: String]) throws -> StorageSnapshotRecovery? {
        try StorageSnapshotLimits.validate(snapshot)
        let hasExisting = FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: backupURL.path)
        var recovery: StorageSnapshotRecovery?
        if hasExisting {
            let previous = try load()
            recovery = previous.recovery
            if previous.snapshot == snapshot { return recovery }
        }
        let key = try keyProvider.encryptionKey(createIfMissing: !hasExisting)
        let plaintext = try StorageSnapshotLimits.encoded(snapshot)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.header)
        guard let combined = sealed.combined else { throw StorageSnapshotError.corruptSnapshot }
        let encrypted = Self.header + combined
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let previous = try readAndDecrypt(url, key: key)
                try AtomicFile.write(previous.data, to: backupURL)
            }
            try AtomicFile.write(encrypted, to: url)
        } catch let error as StorageSnapshotError { throw error }
        catch { throw StorageSnapshotError.fileIO }
        return recovery
    }

    private func readAndDecrypt(_ source: URL, key: SymmetricKey) throws -> (snapshot: [String: String], data: Data) {
        do {
            // A URL can cache the size of the inode replaced by AtomicFile. Inspect the current inode.
            var uncachedSource = source
            uncachedSource.removeAllCachedResourceValues()
            let resource = try uncachedSource.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard resource.isRegularFile == true, resource.isSymbolicLink != true,
                  let size = resource.fileSize, size > Self.header.count + 28,
                  size <= StorageSnapshotLimits.maximumPayloadBytes + Self.header.count + 28 else {
                throw StorageSnapshotError.corruptSnapshot
            }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            // Bound the read even if another process replaces or grows the file after the metadata check.
            let encrypted = try handle.read(upToCount: StorageSnapshotLimits.maximumPayloadBytes + Self.header.count + 29) ?? Data()
            guard encrypted.count == size, encrypted.starts(with: Self.header) else { throw StorageSnapshotError.corruptSnapshot }
            let sealed = try AES.GCM.SealedBox(combined: encrypted.dropFirst(Self.header.count))
            let plaintext = try AES.GCM.open(sealed, using: key, authenticating: Self.header)
            let snapshot = try JSONDecoder().decode([String: String].self, from: plaintext)
            try StorageSnapshotLimits.validate(snapshot)
            return (snapshot, encrypted)
        } catch let error as StorageSnapshotError { throw error }
        catch { throw StorageSnapshotError.corruptSnapshot }
    }
}
