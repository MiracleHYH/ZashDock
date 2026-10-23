import CryptoKit
import Foundation
import Testing
@testable import ZashDockCore

private struct FixedSnapshotKey: StorageSnapshotKeyProviding {
    var byte: UInt8 = 0x5a
    func encryptionKey(createIfMissing: Bool) throws -> SymmetricKey { SymmetricKey(data: Data(repeating: byte, count: 32)) }
}

private struct UnavailableSnapshotKey: StorageSnapshotKeyProviding {
    func encryptionKey(createIfMissing: Bool) throws -> SymmetricKey { throw StorageSnapshotError.keyUnavailable(-25308) }
}

private func snapshotDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockSnapshotTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func absentSnapshotDoesNotRequireOrCreateAKey() async throws {
    let directory = try snapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vault = StorageSnapshotVault(url: directory.appendingPathComponent("storage"), keyProvider: UnavailableSnapshotKey())
    let result = try await vault.load()
    #expect(result.snapshot == nil)
    #expect(result.recovery == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

@Test func twoRemotesSurviveVaultRecreationAndAreEncrypted() async throws {
    let directory = try snapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("storage")
    let secret = "do-not-log-REMOTE-SECRET-83f482cb"
    let backends: [[String: String]] = [
        ["type": "clash", "protocol": "http", "host": "10.0.0.2", "port": "9090", "secondaryPath": "", "password": secret, "uuid": "first-fixture"],
        ["type": "clash", "protocol": "http", "host": "vpn.example", "port": "9090", "secondaryPath": "", "password": "secondary-fixture", "uuid": "second-fixture"]
    ]
    let values = ["setup/api-list": String(decoding: try JSONEncoder().encode(backends), as: UTF8.self), "setup/active-uuid": "second-fixture", "config/auto-theme": "true"]
    try await StorageSnapshotVault(url: url, keyProvider: FixedSnapshotKey()).save(values)
    let recreated = StorageSnapshotVault(url: url, keyProvider: FixedSnapshotKey())
    #expect(try await recreated.load().snapshot == values)
    let restored = try #require(try await recreated.load().snapshot)
    let list = try JSONDecoder().decode([[String: String]].self, from: Data(try #require(restored["setup/api-list"]).utf8))
    #expect(list.count == 2)
    #expect(list.map { $0["host"] } == ["10.0.0.2", "vpn.example"])
    #expect(restored["setup/active-uuid"] == "second-fixture")
    let encrypted = try Data(contentsOf: url)
    #expect(encrypted.range(of: Data(secret.utf8)) == nil)
    #expect(encrypted.range(of: Data("vpn.example".utf8)) == nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func emptySnapshotIsDurableAndDistinctFromNeverSaved() async throws {
    let directory = try snapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("storage")
    let vault = StorageSnapshotVault(url: url, keyProvider: FixedSnapshotKey())
    try await vault.save(["remote": "first"])
    try await vault.save([:])
    let result = try await StorageSnapshotVault(url: url, keyProvider: FixedSnapshotKey()).load()
    #expect(result.snapshot == [:])
    #expect(result.snapshot != nil)
}

@Test func damagedPrimaryRecoversAuthenticatedBackupWithExplicitStatus() async throws {
    let directory = try snapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("storage")
    let vault = StorageSnapshotVault(url: url, keyProvider: FixedSnapshotKey())
    try await vault.save(["remote": "first"])
    try await vault.save(["remote": "second"])
    try Data("damaged".utf8).write(to: url)
    let result = try await vault.load()
    #expect(result.snapshot == ["remote": "first"])
    #expect(result.recovery == .backupRecovered)
    #expect(!StorageSnapshotRecovery.backupRecovered.explanation.isEmpty)
    #expect(try await vault.load().snapshot == ["remote": "first"])
    #expect(try await vault.load().recovery == nil)
}

@Test func missingPrimaryRecoversBackupAfterInterruptedReplacement() async throws {
    let directory = try snapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("storage")
    let vault = StorageSnapshotVault(url: url, keyProvider: FixedSnapshotKey())
    try await vault.save(["remote": "first"])
    try await vault.save(["remote": "second"])
    try FileManager.default.removeItem(at: url)
    let result = try await vault.load()
    #expect(result.recovery == .backupRecovered)
    #expect(result.snapshot == ["remote": "first"])
}

@Test func corruptionAndWrongKeyNeverBecomeEmptyConfiguration() async throws {
    let directory = try snapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("storage")
    let vault = StorageSnapshotVault(url: url, keyProvider: FixedSnapshotKey())
    try await vault.save(["remote": "first"])
    try await vault.save(["remote": "second"])
    let wrongKey = StorageSnapshotVault(url: url, keyProvider: FixedSnapshotKey(byte: 0xff))
    await #expect(throws: StorageSnapshotError.corruptSnapshot) { try await wrongKey.load() }
    let damaged = Data("not an encrypted snapshot".utf8)
    try damaged.write(to: url)
    try damaged.write(to: vault.backupURL)
    await #expect(throws: StorageSnapshotError.corruptSnapshot) { try await vault.load() }
    await #expect(throws: StorageSnapshotError.corruptSnapshot) { try await vault.save([:]) }
    #expect(try Data(contentsOf: url) == damaged)
}

@Test func payloadLimitsRejectWithoutReplacingGoodSnapshot() async throws {
    let directory = try snapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("storage")
    let vault = StorageSnapshotVault(url: url, keyProvider: FixedSnapshotKey())
    let original = ["remote": "preserve"]
    try await vault.save(original)
    let tooMany = Dictionary(uniqueKeysWithValues: (0...StorageSnapshotLimits.maximumKeyCount).map { (String($0), "") })
    let oversized: [[String: String]] = [
        [String(repeating: "x", count: StorageSnapshotLimits.maximumKeyBytes + 1): ""],
        ["value": String(repeating: "x", count: StorageSnapshotLimits.maximumValueBytes + 1)],
        tooMany,
        ["a": String(repeating: "x", count: StorageSnapshotLimits.maximumValueBytes), "b": String(repeating: "x", count: StorageSnapshotLimits.maximumValueBytes)],
        // Escaped JSON size, rather than only the sum of raw UTF-8 values, also counts.
        ["escaped": String(repeating: "\u{01}", count: StorageSnapshotLimits.maximumValueBytes / 2)]
    ]
    for snapshot in oversized {
        await #expect(throws: StorageSnapshotError.payloadTooLarge) { try await vault.save(snapshot) }
        #expect(try await vault.load().snapshot == original)
    }
}

@Test func keychainErrorsNeverWritePlaintextFallback() async throws {
    let directory = try snapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vault = StorageSnapshotVault(url: directory.appendingPathComponent("storage"), keyProvider: UnavailableSnapshotKey())
    await #expect(throws: StorageSnapshotError.keyUnavailable(-25308)) { try await vault.save(["secret": "sensitive"]) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

@Test func liveSaveReportsBackupRecoveryInsteadOfSilentlyReplacingData() async throws {
    let directory = try snapshotDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("storage")
    let vault = StorageSnapshotVault(url: url, keyProvider: FixedSnapshotKey())
    try await vault.save(["remote": "first"])
    try await vault.save(["remote": "second"])
    try Data("damaged".utf8).write(to: url)
    let recovery = try await vault.saveReportingRecovery(["remote": "current page"])
    #expect(recovery == .backupRecovered)
    #expect(try await vault.load().snapshot == ["remote": "current page"])
}
