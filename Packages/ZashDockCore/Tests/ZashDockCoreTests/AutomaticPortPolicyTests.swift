import Foundation
import Testing
@testable import ZashDockCore

struct AutomaticPortPolicyTests {
    @Test
    func candidatesStayInHighRangeWithoutRepeatsOrExcludedOrigins() {
        let excluded: Set<UInt16> = [49_152, 53_000, 65_535, 9099]
        let candidates = AutomaticPortPolicy.candidates(excluding: excluded)
        #expect(candidates.count == 128)
        #expect(Set(candidates).count == candidates.count)
        #expect(candidates.allSatisfy { AutomaticPortPolicy.range.contains($0) && !excluded.contains($0) })
    }

    @Test
    func exhaustionAndAttemptLimitsHaveFiniteResults() {
        let all = Set(AutomaticPortPolicy.range)
        #expect(AutomaticPortPolicy.candidates(excluding: all).isEmpty)
        #expect(AutomaticPortPolicy.candidates(limit: 0).isEmpty)
        #expect(AutomaticPortPolicy.candidates(limit: -1).isEmpty)
        #expect(AutomaticPortPolicy.candidates(limit: 3).count == 3)
        let remaining = AutomaticPortPolicy.candidates(excluding: all.subtracting([50_001, 60_001]))
        #expect(Set(remaining) == [50_001, 60_001])
    }

    @Test
    func automaticSelectionSurvivesCommitAndRecoveryWithoutGuessingAnotherOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockAutomaticPort-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(url: root.appendingPathComponent("configuration.json"))
        var committed = AppConfiguration()
        committed.port = 53_001
        committed.automaticPortSelection = true
        committed.pendingOriginCleanup = 9099
        committed.legacyStorageImported = true
        try store.save(committed)
        #expect(try store.load() == committed)
        #expect(store.recoverableConfiguration() == committed)

        let broken = Data("{damaged preferences".utf8)
        try broken.write(to: store.url)
        #expect(throws: ConfigurationLoadFailure.self) { try store.load() }
        let backup = try #require(try store.resetToDefaultsPreservingOriginal())
        #expect(try Data(contentsOf: backup) == broken)
        #expect(try store.load() == committed)

        try FileManager.default.removeItem(at: store.url)
        #expect(throws: ConfigurationLoadFailure(kind: .missingPrimary)) { try store.load() }
        #expect(try store.resetToDefaultsPreservingOriginal() == nil)
        #expect(try store.load() == committed)
    }

    @Test
    func unreadableOriginMetadataNeverCreatesARandomReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockUnknownOrigin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ConfigurationStore(url: root.appendingPathComponent("configuration.json"))
        let broken = Data("{origin unknown".utf8)
        try broken.write(to: store.url)
        #expect(store.recoverableConfiguration() == nil)
        #expect(throws: (any Error).self) { try store.resetToDefaultsPreservingOriginal() }
        #expect(try Data(contentsOf: store.url) == broken)
        #expect(!FileManager.default.fileExists(atPath: store.recoveryCopyURL.path))
    }
}
