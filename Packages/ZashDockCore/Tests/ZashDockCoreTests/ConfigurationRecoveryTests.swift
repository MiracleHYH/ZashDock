import Foundation
import Testing
@testable import ZashDockCore

struct ConfigurationRecoveryTests {
    private func withStore(_ body: (ConfigurationStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockConfigurationRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(ConfigurationStore(url: root.appendingPathComponent("configuration.json")), root)
    }

    @Test(arguments: [
        ("{broken", ConfigurationLoadFailure.Kind.malformedJSON),
        (#"{"port":"9099","maxRollbackVersions":1,"quitAfterLastWindowCloses":false}"#, .invalidFields),
        (#"{"port":9099,"maxRollbackVersions":1}"#, .invalidFields),
        (#"{"port":80,"maxRollbackVersions":1,"quitAfterLastWindowCloses":false}"#, .invalidValues),
        (#"{"port":65536,"maxRollbackVersions":1,"quitAfterLastWindowCloses":false}"#, .invalidValues),
        (#"{"port":9099,"maxRollbackVersions":-1,"quitAfterLastWindowCloses":false}"#, .invalidValues)
    ])
    func classifiesInvalidPreferencesWithoutChangingBytes(json: String, kind: ConfigurationLoadFailure.Kind) throws {
        try withStore { store, _ in
            let bytes = Data(json.utf8)
            try bytes.write(to: store.url)
            #expect(throws: ConfigurationLoadFailure(kind: kind)) { try store.load() }
            #expect(try Data(contentsOf: store.url) == bytes)
        }
    }

    @Test
    func explicitResetPreservesExactOriginalAndOnlyReplacesPreferences() throws {
        try withStore { store, root in
            let original = Data("{invalid ordinary preferences\n".utf8)
            try original.write(to: store.url)
            let snapshot = root.appendingPathComponent("storage.aesgcm")
            let version = root.appendingPathComponent("versions/version-fixture")
            try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
            let ciphertext = Data([0, 17, 88, 255]); try ciphertext.write(to: snapshot)
            let backup = try #require(try store.resetToDefaultsPreservingOriginal(preservingPort: 23001))
            #expect(try Data(contentsOf: backup) == original)
            var expected = AppConfiguration(); expected.port = 23001
            #expect(try store.load() == expected)
            #expect(try Data(contentsOf: snapshot) == ciphertext)
            #expect(FileManager.default.fileExists(atPath: version.path))
            let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
        }
    }

    @Test
    func backupFailureLeavesOriginalAndDoesNotCommitDefaults() throws {
        try withStore { store, root in
            let original = Data("{keep this broken file".utf8)
            try original.write(to: store.url)
            try Data("not a directory".utf8).write(to: root.appendingPathComponent("configuration-recovery"))
            #expect(throws: (any Error).self) { try store.resetToDefaultsPreservingOriginal(preservingPort: 23001) }
            #expect(try Data(contentsOf: store.url) == original)
        }
    }

    @Test
    func unreadablePathIsNotTreatedAsMissingOrOverwrittenOnReset() throws {
        try withStore { store, _ in
            try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
            let marker = store.url.appendingPathComponent("keep-me")
            try Data("original".utf8).write(to: marker)
            #expect(throws: ConfigurationLoadFailure(kind: .unreadable)) { try store.load() }
            #expect(throws: ConfigurationLoadFailure(kind: .unreadable)) { try store.resetToDefaultsPreservingOriginal() }
            #expect(try Data(contentsOf: marker) == Data("original".utf8))
        }
    }

    @Test
    func rereadingRepairedPreferencesSucceedsWithoutReset() throws {
        try withStore { store, root in
            try Data("bad".utf8).write(to: store.url)
            #expect(throws: ConfigurationLoadFailure.self) { try store.load() }
            var repaired = AppConfiguration(); repaired.port = 23001; repaired.maxRollbackVersions = 3
            try store.save(repaired)
            #expect(try store.load() == repaired)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("configuration-recovery").path))
        }
    }
}
