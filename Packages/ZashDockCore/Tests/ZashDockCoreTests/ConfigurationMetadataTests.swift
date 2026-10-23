import Foundation
import Testing
@testable import ZashDockCore

struct ConfigurationMetadataTests {
    private func withStore(_ body: (ConfigurationStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockOriginMetadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(ConfigurationStore(url: root.appendingPathComponent("configuration.json")), root)
    }

    @Test
    func olderConfigurationIgnoresHistoryAndDefaultsOnlyNewMetadataFields() throws {
        let bytes = Data(#"{"port":23456,"maxRollbackVersions":3,"quitAfterLastWindowCloses":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: bytes)
        #expect(decoded.port == 23456 && decoded.quitAfterLastWindowCloses)
        #expect(decoded.pendingOriginCleanup == nil && !decoded.legacyStorageImported)
        try withStore { store, _ in
            try bytes.write(to: store.url)
            #expect(try store.load() == decoded)
            #expect(store.recoverableConfiguration() == nil)
        }
    }

    @Test(arguments: ["0", "1", "3", "-1", "101", "1000000000000", "\"invalid\"", "null", "{}", "[1,2,3]", "true"])
    func removedHistoryFieldIsIgnoredWithoutChangingCommittedOrigin(value: String) throws {
        try withStore { store, _ in
            let bytes = Data((#"{"port":34567,"quitAfterLastWindowCloses":true,"pendingOriginCleanup":23456,"legacyStorageImported":true,"maxRollbackVersions":"# + value + "}").utf8)
            try bytes.write(to: store.url)
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: bytes)
            #expect(decoded.port == 34567 && decoded.quitAfterLastWindowCloses)
            #expect(decoded.pendingOriginCleanup == 23456 && decoded.legacyStorageImported)
            #expect(try store.load() == decoded)
            #expect(try Data(contentsOf: store.url) == bytes)
            try store.save(decoded)
            #expect(try store.load() == decoded && store.recoverableConfiguration() == decoded)
            for url in [store.url, store.recoveryCopyURL] {
                let encoded = try Data(contentsOf: url)
                let fields = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                #expect(Set(fields.keys) == ["port", "quitAfterLastWindowCloses", "pendingOriginCleanup", "legacyStorageImported"])
            }
        }
    }

    @Test(arguments: [
        (#""pendingOriginCleanup":"23456""#, ConfigurationLoadFailure.Kind.invalidFields),
        (#""pendingOriginCleanup":true"#, .invalidFields),
        (#""pendingOriginCleanup":80"#, .invalidValues),
        (#""pendingOriginCleanup":-1"#, .invalidValues),
        (#""pendingOriginCleanup":65536"#, .invalidValues),
        (#""pendingOriginCleanup":9099"#, .invalidValues),
        (#""legacyStorageImported":0"#, .invalidFields),
        (#""legacyStorageImported":"false""#, .invalidFields),
        (#""legacyStorageImported":null"#, .invalidFields)
    ])
    func invalidMetadataIsRejectedWithoutChangingPrimaryOrMirror(field: String, kind: ConfigurationLoadFailure.Kind) throws {
        try withStore { store, _ in
            var original = AppConfiguration(); original.port = 23456
            try store.save(original)
            let mirror = try Data(contentsOf: store.recoveryCopyURL)
            let bytes = Data((#"{"port":9099,"quitAfterLastWindowCloses":false,"# + field + "}").utf8)
            try bytes.write(to: store.url)
            #expect(throws: ConfigurationLoadFailure(kind: kind)) { try store.load() }
            #expect(throws: (any Error).self) { try JSONDecoder().decode(AppConfiguration.self, from: bytes) }
            #expect(try Data(contentsOf: store.url) == bytes)
            #expect(try Data(contentsOf: store.recoveryCopyURL) == mirror)
        }
    }

    @Test
    func portCommitCleanupAndLegacyMarkerPersistAsSmallMetadata() throws {
        try withStore { store, _ in
            var original = AppConfiguration(); original.port = 23456; original.legacyStorageImported = true
            try store.save(original)
            var committed = original; committed.port = 34567; committed.pendingOriginCleanup = original.port
            try store.save(committed)
            #expect(try store.load() == committed)
            try store.ensureRecoveryCopy(committed)
            #expect(store.recoverableConfiguration() == committed)
            let bytes = try Data(contentsOf: store.recoveryCopyURL)
            let fields = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(Set(fields.keys) == ["port", "quitAfterLastWindowCloses", "pendingOriginCleanup", "legacyStorageImported"])
            #expect(bytes.count < 256)
            let mode = try FileManager.default.attributesOfItem(atPath: store.recoveryCopyURL.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
            committed.pendingOriginCleanup = nil
            try store.save(committed)
            #expect(try store.load() == committed && store.recoverableConfiguration() == committed)
            #expect(committed.port == 34567 && committed.legacyStorageImported)
        }
    }

    @Test
    func corruptPrimaryDoesNotSilentlyChooseMirrorAndResetKeepsOriginMetadata() throws {
        try withStore { store, _ in
            var committed = AppConfiguration(); committed.port = 34567; committed.pendingOriginCleanup = 23456
            committed.legacyStorageImported = true; committed.quitAfterLastWindowCloses = true
            try store.save(committed)
            let damaged = Data("{damaged primary".utf8); try damaged.write(to: store.url)
            #expect(throws: ConfigurationLoadFailure.self) { try store.load() }
            #expect(store.recoverableConfiguration() == committed)
            let preserved = try #require(try store.resetToDefaultsPreservingOriginal(preservingPort: 45678))
            #expect(try Data(contentsOf: preserved) == damaged)
            let recovered = try store.load()
            #expect(recovered.port == committed.port && recovered.pendingOriginCleanup == committed.pendingOriginCleanup)
            #expect(recovered.legacyStorageImported)
            #expect(!recovered.quitAfterLastWindowCloses)
        }
    }

    @Test
    func missingOriginMetadataRequiresExplicitOriginalPortBeforeReset() throws {
        try withStore { store, root in
            let damaged = Data("{unknown old port".utf8); try damaged.write(to: store.url)
            #expect(throws: (any Error).self) { try store.resetToDefaultsPreservingOriginal() }
            #expect(throws: (any Error).self) { try store.resetToDefaultsPreservingOriginal(preservingPort: 80) }
            #expect(try Data(contentsOf: store.url) == damaged)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("configuration-recovery").path))
            try store.resetToDefaultsPreservingOriginal(preservingPort: 24567)
            #expect(try store.load().port == 24567)
        }
    }

    @Test
    func mirrorFailureDoesNotMisreportAlreadyCommittedPortAndCanRetryExplicitly() throws {
        try withStore { store, _ in
            var original = AppConfiguration(); original.port = 23456
            try store.save(original)
            try FileManager.default.removeItem(at: store.recoveryCopyURL)
            try FileManager.default.createDirectory(at: store.recoveryCopyURL, withIntermediateDirectories: false)
            var committed = original; committed.port = 34567; committed.pendingOriginCleanup = original.port
            try store.save(committed)
            #expect(try store.load() == committed)
            #expect(store.recoverableConfiguration() == nil)
            #expect(throws: (any Error).self) { try store.ensureRecoveryCopy(committed) }
            #expect(try store.load() == committed)
            try FileManager.default.removeItem(at: store.recoveryCopyURL)
            try store.ensureRecoveryCopy(committed)
            #expect(store.recoverableConfiguration() == committed)
            #expect(throws: (any Error).self) { try store.ensureRecoveryCopy(original) }
            #expect(store.recoverableConfiguration() == committed)
        }
    }

    @Test
    func failedPrimaryCommitNeverAdvancesRecoveryMirror() throws {
        try withStore { store, _ in
            var original = AppConfiguration(); original.port = 23456
            try store.save(original)
            let bytes = try Data(contentsOf: store.recoveryCopyURL)
            try FileManager.default.removeItem(at: store.url)
            try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
            var proposed = original; proposed.port = 34567; proposed.pendingOriginCleanup = original.port
            #expect(throws: (any Error).self) { try store.save(proposed) }
            #expect(try Data(contentsOf: store.recoveryCopyURL) == bytes)
            #expect(store.recoverableConfiguration() == original)
        }
    }

    @Test
    func validPrimaryOriginWinsOlderMirrorDuringExplicitReset() throws {
        try withStore { store, _ in
            var older = AppConfiguration(); older.port = 23456
            try store.save(older)
            let olderBytes = try Data(contentsOf: store.recoveryCopyURL)
            var committed = older; committed.port = 34567; committed.pendingOriginCleanup = older.port; committed.legacyStorageImported = true
            try store.save(committed)
            try olderBytes.write(to: store.recoveryCopyURL)
            try store.resetToDefaultsPreservingOriginal()
            let recovered = try store.load()
            #expect(recovered.port == committed.port && recovered.pendingOriginCleanup == committed.pendingOriginCleanup && recovered.legacyStorageImported)
        }
    }

    @Test
    func missingPrimaryWithMirrorIsRecoveryNotAFresh9099Profile() throws {
        try withStore { store, _ in
            var committed = AppConfiguration(); committed.port = 34567; committed.pendingOriginCleanup = 23456; committed.legacyStorageImported = true
            try store.save(committed)
            try FileManager.default.removeItem(at: store.url)
            #expect(throws: ConfigurationLoadFailure(kind: .missingPrimary)) { try store.load() }
            #expect(store.recoverableConfiguration() == committed)
            #expect(try store.resetToDefaultsPreservingOriginal() == nil)
            #expect(try store.load() == committed)
        }
    }

    @Test(arguments: [UInt16(80), UInt16(23456)])
    func invalidMutableCleanupPortCannotCommitOrChangeMirror(pendingPort: UInt16) throws {
        try withStore { store, _ in
            var committed = AppConfiguration(); committed.port = 23456
            try store.save(committed)
            let primary = try Data(contentsOf: store.url), mirror = try Data(contentsOf: store.recoveryCopyURL)
            committed.pendingOriginCleanup = pendingPort
            #expect(throws: (any Error).self) { try store.save(committed) }
            #expect(try Data(contentsOf: store.url) == primary)
            #expect(try Data(contentsOf: store.recoveryCopyURL) == mirror)
        }
    }
}
