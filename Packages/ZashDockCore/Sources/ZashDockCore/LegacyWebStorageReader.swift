import CryptoKit
import Darwin
import Foundation
import Security

public enum LegacyWebStorageError: LocalizedError, Equatable, Sendable {
    case keyUnavailable(Int32), invalidData, fileAccess
    public var errorDescription: String? {
        switch self {
        case .keyUnavailable(let status): "无法读取旧配置的原 Keychain 密钥（状态 \(status)）；原文件未被修改。"
        case .invalidData: "旧配置未通过认证或超过格式限制；原文件未被修改。"
        case .fileAccess: "无法安全读取旧配置文件；原文件未被修改。"
        }
    }
}

public protocol LegacyStorageKeyReading: Sendable {
    func readKey() throws -> SymmetricKey
}

/// Compatibility access to the original key only. This type cannot create or replace keys.
public struct KeychainLegacyStorageKeyReader: LegacyStorageKeyReading {
    private let service: String
    private let account: String
    public init(service: String = "app.zashdock.mac.storage", account: String = "primary") {
        self.service = service; self.account = account
    }
    public func readKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw LegacyWebStorageError.keyUnavailable(status) }
        guard let bytes = result as? Data, bytes.count == 32 else { throw LegacyWebStorageError.invalidData }
        return SymmetricKey(data: bytes)
    }
}

/// One-time compatibility reader for AES-GCM v1 files. WebKit owns all ongoing website data.
/// No method writes files, repairs ciphertext, rotates backups, or generates a Keychain key.
public struct LegacyWebStorageReader: Sendable {
    private let primaryURL: URL
    private let keyReader: any LegacyStorageKeyReading
    private static let header = Data("ZASHDOCK-SNAPSHOT-1\n".utf8)
    private static let maximumEncodedBytes = 8 * 1024 * 1024

    public init(primaryURL: URL, keyReader: any LegacyStorageKeyReading = KeychainLegacyStorageKeyReader()) {
        self.primaryURL = primaryURL; self.keyReader = keyReader
    }

    public func read() throws -> [String: String]? {
        try Task.checkCancellation()
        let sources = try [primaryURL, primaryURL.appendingPathExtension("backup")].filter { try exists($0) }
        guard !sources.isEmpty else { return nil }
        let key = try keyReader.readKey()
        var accessFailed = false
        for source in sources {
            do { return try decrypt(source, using: key) }
            catch is CancellationError { throw CancellationError() }
            catch LegacyWebStorageError.fileAccess { accessFailed = true }
            catch {}
        }
        throw accessFailed ? LegacyWebStorageError.fileAccess : .invalidData
    }

    private func decrypt(_ source: URL, using key: SymmetricKey) throws -> [String: String] {
        let encrypted = try readFile(source)
        do {
            guard encrypted.starts(with: Self.header) else { throw LegacyWebStorageError.invalidData }
            let box = try AES.GCM.SealedBox(combined: encrypted.dropFirst(Self.header.count))
            let plaintext = try AES.GCM.open(box, using: key, authenticating: Self.header)
            guard plaintext.count <= Self.maximumEncodedBytes else { throw LegacyWebStorageError.invalidData }
            let values = try JSONDecoder().decode([String: String].self, from: plaintext)
            guard values.count <= 4096 else { throw LegacyWebStorageError.invalidData }
            var bytes = 0
            for (name, value) in values {
                guard name.utf8.count <= 64 * 1024, value.utf8.count <= 4 * 1024 * 1024 else { throw LegacyWebStorageError.invalidData }
                bytes += name.utf8.count + value.utf8.count
                guard bytes <= Self.maximumEncodedBytes else { throw LegacyWebStorageError.invalidData }
            }
            return values
        } catch let error as LegacyWebStorageError { throw error }
        catch { throw LegacyWebStorageError.invalidData }
    }

    private func exists(_ source: URL) throws -> Bool {
        var info = stat()
        if lstat(source.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw LegacyWebStorageError.fileAccess
    }

    private func readFile(_ source: URL) throws -> Data {
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw LegacyWebStorageError.fileAccess }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG else { throw LegacyWebStorageError.fileAccess }
        guard initial.st_size > Self.header.count + 28,
              initial.st_size <= Self.maximumEncodedBytes + Self.header.count + 28 else { throw LegacyWebStorageError.invalidData }
        var encrypted = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        encrypted.reserveCapacity(Int(initial.st_size))
        while encrypted.count < initial.st_size {
            try Task.checkCancellation()
            let limit = min(buffer.count, Int(initial.st_size) - encrypted.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, limit) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LegacyWebStorageError.fileAccess }
            encrypted.append(contentsOf: buffer.prefix(count))
        }
        var extra: UInt8 = 0
        var tail: Int
        repeat { tail = Darwin.read(descriptor, &extra, 1) } while tail < 0 && errno == EINTR
        var current = stat(), path = stat()
        guard tail == 0, fstat(descriptor, &current) == 0, lstat(source.path, &path) == 0,
              path.st_mode & S_IFMT == S_IFREG, path.st_dev == initial.st_dev, path.st_ino == initial.st_ino,
              current.st_size == initial.st_size,
              current.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec, current.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else {
            throw LegacyWebStorageError.fileAccess
        }
        return encrypted
    }
}
