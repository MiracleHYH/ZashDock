import Foundation
import Testing
@testable import ZashDockCore

struct CorruptHistoryTests {
    private func installed(_ count: Int, in store: VersionStore, root: URL) async throws -> [InstalledVersion] {
        var versions: [InstalledVersion] = []
        for number in 1...count {
            let version = try await Fixture.install(number, store: store, root: root)
            try await store.activate(version)
            versions.append(version)
        }
        return versions
    }

    private func corrupt(_ version: InstalledVersion) throws {
        try Data("corrupted historical resource".utf8).write(to: version.directoryURL.appendingPathComponent("index.html"))
    }

    @Test
    func damagedV2CannotDisplaceHealthyV1ForCurrentV3() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root)
        let versions = try await installed(3, in: store, root: root)
        let snapshot = root.appendingPathComponent("storage.aesgcm"), backup = root.appendingPathComponent("storage.aesgcm.backup")
        let sentinel = Data("unrelated encrypted data".utf8)
        try sentinel.write(to: snapshot); try sentinel.write(to: backup)
        try corrupt(versions[1])
        let report = try #require(try await store.prune(maxHistory: 1))
        #expect(try await store.current() == versions[2])
        #expect(try await store.history() == [versions[0]])
        #expect(report.invalidHistoryIDs == [versions[1].id])
        #expect(report.retainedHistoryIDs == [versions[0].id])
        #expect(report.plannedRemovalIDs == [versions[1].id])
        #expect(!FileManager.default.fileExists(atPath: versions[1].directoryURL.path))
        #expect(try await store.validate(versions[0]) == versions[0])
        #expect(try Data(contentsOf: snapshot) == sentinel && Data(contentsOf: backup) == sentinel)
        let reopened = try VersionStore(root: root)
        #expect(try await reopened.lastPruneReport() == report)
        try await reopened.activate(versions[0]); try await reopened.prune(maxHistory: 1)
        #expect(try await reopened.current() == versions[0])
        #expect(try await reopened.history() == [versions[2]])
        #expect(try await reopened.lastInvalidHistoryReport() == report)
    }

    @Test(arguments: [0, 1, 3])
    func healthyActivationOrderDeterminesRetentionAfterMultipleCorruptVersions(maxHistory: Int) async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root)
        let versions = try await installed(6, in: store, root: root)
        try corrupt(versions[1]); try corrupt(versions[4])
        let report = try #require(try await store.prune(maxHistory: maxHistory))
        let expected = Array([versions[3], versions[2], versions[0]].prefix(maxHistory))
        #expect(try await store.current() == versions[5])
        #expect(try await store.history() == expected)
        #expect(report.invalidHistoryIDs == [versions[4].id, versions[1].id])
        #expect(report.retainedHistoryIDs == expected.map(\.id))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("versions").path).count == expected.count + 1)
        if let rollback = expected.last {
            try await store.activate(rollback); try await store.prune(maxHistory: maxHistory)
            #expect(try await store.current() == rollback)
            #expect(try await store.history().first == versions[5])
            #expect(try await store.history().count == maxHistory)
        }
    }

    @Test
    func protectedDamagedVersionIsNotDeletedAndDoesNotConsumeHealthyRollbackSlot() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root)
        let versions = try await installed(3, in: store, root: root)
        try corrupt(versions[1])
        let report = try #require(try await store.prune(maxHistory: 1, protecting: [versions[1].id]))
        #expect(try await store.current() == versions[2])
        #expect(try await store.history() == [versions[0]])
        #expect(report.invalidHistoryIDs == [versions[1].id] && report.protectedIDs == [versions[1].id])
        #expect(report.plannedRemovalIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: versions[1].directoryURL.path))
        try await store.prune(maxHistory: 1)
        #expect(!FileManager.default.fileExists(atPath: versions[1].directoryURL.path))
        #expect(try await store.history() == [versions[0]])
    }

    @Test
    func damagedCurrentPreventsAnyHistoryCleanup() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root)
        let versions = try await installed(3, in: store, root: root)
        let pointer = root.appendingPathComponent("versions-state.json"), bytes = try Data(contentsOf: pointer)
        try corrupt(versions[2])
        await #expect(throws: (any Error).self) { try await store.prune(maxHistory: 0) }
        #expect(try Data(contentsOf: pointer) == bytes)
        for version in versions { #expect(FileManager.default.fileExists(atPath: version.directoryURL.path)) }
    }

    @Test
    func cancelledValidationDoesNotClassifyHistoryAsCorruptOrDeleteIt() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root)
        let versions = try await installed(3, in: store, root: root)
        let pointer = root.appendingPathComponent("versions-state.json"), bytes = try Data(contentsOf: pointer)
        let pruning = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.prune(maxHistory: 0)
        }
        await #expect(throws: CancellationError.self) { try await pruning.value }
        #expect(try Data(contentsOf: pointer) == bytes)
        for version in versions { #expect(FileManager.default.fileExists(atPath: version.directoryURL.path)) }
    }

    @Test
    func historicalSymlinkCleanupNeverRemovesItsExternalTarget() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root)
        let versions = try await installed(3, in: store, root: root)
        let outside = root.appendingPathComponent("unmanaged"), marker = outside.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside must survive".utf8).write(to: marker)
        let historicalDirectory = versions[1].directoryURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: historicalDirectory)
        try FileManager.default.createSymbolicLink(at: historicalDirectory, withDestinationURL: outside)
        let report = try #require(try await store.prune(maxHistory: 1))
        #expect(report.invalidHistoryIDs == [versions[1].id])
        #expect(try Data(contentsOf: marker) == Data("outside must survive".utf8))
        #expect(try await store.history() == [versions[0]])
        #expect(!FileManager.default.fileExists(atPath: historicalDirectory.path))
    }

    @Test(arguments: ["manifest.json", "content", "content/assets"])
    func temporarilyUnreadableHistoryAbortsBeforeDeletingAnyVersion(relativePath: String) async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root)
        let versions = try await installed(3, in: store, root: root)
        let pointer = root.appendingPathComponent("versions-state.json"), bytes = try Data(contentsOf: pointer)
        let restricted = versions[1].directoryURL.deletingLastPathComponent().appendingPathComponent(relativePath)
        let originalMode = try FileManager.default.attributesOfItem(atPath: restricted.path)[.posixPermissions] as? NSNumber
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: originalMode ?? 0o700], ofItemAtPath: restricted.path) }
        await #expect(throws: (any Error).self) { try await store.prune(maxHistory: 0) }
        #expect(try Data(contentsOf: pointer) == bytes)
        for version in versions { #expect(FileManager.default.fileExists(atPath: version.directoryURL.path)) }
    }
}
