import CryptoKit
import Foundation
import Testing
@testable import ZashDockCore

private final class LegacyFixtureKey: LegacyStorageKeyReading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let byte: UInt8
    private let unavailable: Bool
    var readCount: Int { lock.withLock { calls } }
    init(byte: UInt8 = 0x5a, unavailable: Bool = false) { self.byte = byte; self.unavailable = unavailable }
    func readKey() throws -> SymmetricKey {
        lock.withLock { calls += 1 }
        if unavailable { throw LegacyWebStorageError.keyUnavailable(-25300) }
        return SymmetricKey(data: Data(repeating: byte, count: 32))
    }
}

struct LegacyWebStorageReaderTests {
    private let header = Data("ZASHDOCK-SNAPSHOT-1\n".utf8)
    private let values = ["setup/api-list": #"[{"uuid":"one","host":"192.0.2.1","password":"fixture-one"},{"uuid":"two","host":"kernel.vpn.example","password":"fixture-two"}]"#,
                          "setup/active-uuid": "two", "config/default-theme": "light", "__proto__": "data", "empty": ""]
    private func withSource(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockLegacyRead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("storage.aesgcm"), root)
    }
    private func seal(_ plaintext: Data, byte: UInt8 = 0x5a) throws -> Data {
        let key = SymmetricKey(data: Data(repeating: byte, count: 32))
        return header + (try #require(try AES.GCM.seal(plaintext, using: key, authenticating: header).combined))
    }
    private func encoded(_ values: [String: String]) throws -> Data { try seal(JSONEncoder().encode(values)) }

    @Test
    func newProfileDoesNotReadOrCreateAnyKeyOrFile() throws {
        try withSource { source, root in
            let key = LegacyFixtureKey(unavailable: true)
            let result = try LegacyWebStorageReader(primaryURL: source, keyReader: key).read()
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(result == nil)
            #expect(key.readCount == 0)
            #expect(files.isEmpty)
        }
    }

    @Test
    func authenticatesCompleteDictionaryWithoutTouchingSourceBytes() throws {
        try withSource { source, root in
            let encrypted = try encoded(values); try encrypted.write(to: source)
            let key = LegacyFixtureKey()
            #expect(try LegacyWebStorageReader(primaryURL: source, keyReader: key).read() == values)
            #expect(key.readCount == 1)
            #expect(try Data(contentsOf: source) == encrypted)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [source.lastPathComponent])
        }
    }

    @Test
    func damagedPrimaryFallsBackToAuthenticatedBackupWithoutRepairingEitherFile() throws {
        try withSource { source, root in
            let damaged = Data("retain the damaged original".utf8), backup = source.appendingPathExtension("backup")
            let encrypted = try encoded(values)
            try damaged.write(to: source); try encrypted.write(to: backup)
            let key = LegacyFixtureKey()
            #expect(try LegacyWebStorageReader(primaryURL: source, keyReader: key).read() == values)
            #expect(key.readCount == 1)
            #expect(try Data(contentsOf: source) == damaged && Data(contentsOf: backup) == encrypted)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
        }
    }

    @Test
    func backupOnlyProfileImportsAndRetainsItsCiphertext() throws {
        try withSource { source, _ in
            let backup = source.appendingPathExtension("backup"), encrypted = try encoded(values)
            try encrypted.write(to: backup)
            #expect(try LegacyWebStorageReader(primaryURL: source, keyReader: LegacyFixtureKey()).read() == values)
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(try Data(contentsOf: backup) == encrypted)
        }
    }

    @Test
    func unavailableKeyNeverChangesExistingFiles() throws {
        try withSource { source, _ in
            let encrypted = try encoded(values); try encrypted.write(to: source)
            let key = LegacyFixtureKey(unavailable: true)
            #expect(throws: LegacyWebStorageError.keyUnavailable(-25300)) { try LegacyWebStorageReader(primaryURL: source, keyReader: key).read() }
            #expect(key.readCount == 1)
            #expect(try Data(contentsOf: source) == encrypted)
        }
    }

    @Test
    func wrongKeyAndAuthenticatedWrongFormatAreRejectedWithoutWrites() throws {
        try withSource { source, root in
            let encrypted = try encoded(values); try encrypted.write(to: source)
            #expect(throws: LegacyWebStorageError.invalidData) { try LegacyWebStorageReader(primaryURL: source, keyReader: LegacyFixtureKey(byte: 0x8a)).read() }
            #expect(try Data(contentsOf: source) == encrypted)
            let wrongFormat = try seal(Data(#"{"non-string":42}"#.utf8)); try wrongFormat.write(to: source)
            #expect(throws: LegacyWebStorageError.invalidData) { try LegacyWebStorageReader(primaryURL: source, keyReader: LegacyFixtureKey()).read() }
            #expect(try Data(contentsOf: source) == wrongFormat)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        }
    }

    @Test(arguments: ["key", "value", "count", "encoded"])
    func boundedLegacyPayloadRejectsExcessWithoutModifyingIt(limit: String) throws {
        try withSource { source, _ in
            let large: [String: String]
            switch limit {
            case "key": large = [String(repeating: "k", count: 64 * 1024 + 1): ""]
            case "value": large = ["v": String(repeating: "v", count: 4 * 1024 * 1024 + 1)]
            case "count": large = Dictionary(uniqueKeysWithValues: (0...4096).map { (String($0), "") })
            default: large = ["escaped": String(repeating: "\u{1}", count: 1_500_000)]
            }
            let encrypted = try encoded(large); try encrypted.write(to: source)
            #expect(throws: LegacyWebStorageError.invalidData) { try LegacyWebStorageReader(primaryURL: source, keyReader: LegacyFixtureKey()).read() }
            #expect(try Data(contentsOf: source) == encrypted)
        }
    }

    @Test
    func refusesSymlinkAndDirectoryWithoutFollowingOrOverwritingThem() throws {
        try withSource { source, root in
            let target = root.appendingPathComponent("unmanaged.aesgcm"), encrypted = try encoded(values)
            try encrypted.write(to: target)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
            #expect(throws: LegacyWebStorageError.fileAccess) { try LegacyWebStorageReader(primaryURL: source, keyReader: LegacyFixtureKey()).read() }
            #expect(try Data(contentsOf: target) == encrypted)
            #expect(try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            #expect(throws: LegacyWebStorageError.fileAccess) { try LegacyWebStorageReader(primaryURL: source, keyReader: LegacyFixtureKey()).read() }
            #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeDirectory)
        }
    }
}
