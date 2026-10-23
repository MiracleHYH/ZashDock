import Foundation
import Testing
@testable import ZashDockCore

struct VersionCleanupTests {
    private func installed(_ count: Int, in store: VersionStore, root: URL) async throws -> [InstalledVersion] {
        var versions: [InstalledVersion] = []
        for number in 1...count {
            let version = try await Fixture.install(number, store: store, root: root)
            try await store.activate(version); versions.append(version)
        }
        return versions
    }

    @Test func cleanupRemovesAllHealthyAndDamagedInactiveResourcesWithoutTouchingUserFiles() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root), versions = try await installed(3, in: store, root: root)
        let userFile = root.appendingPathComponent("unrelated-user-data"), sentinel = Data("keep this file".utf8)
        try sentinel.write(to: userFile)
        try Data("corrupt".utf8).write(to: versions[1].directoryURL.appendingPathComponent("index.html"))
        try await store.removeInactiveVersions()
        #expect(try await store.current() == versions[2])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("versions").path) == [versions[2].id])
        #expect(try Data(contentsOf: userFile) == sentinel)
        let reopened = try VersionStore(root: root)
        #expect(try await reopened.current() == versions[2])
    }

    @Test func activeProtectionExpiresWithoutCreatingRollbackHistory() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root), versions = try await installed(3, in: store, root: root)
        try await store.removeInactiveVersions(protecting: [versions[0].id])
        #expect(FileManager.default.fileExists(atPath: versions[0].directoryURL.path))
        #expect(!FileManager.default.fileExists(atPath: versions[1].directoryURL.path))
        try await store.removeInactiveVersions()
        #expect(!FileManager.default.fileExists(atPath: versions[0].directoryURL.path))
        #expect(try await store.current() == versions[2])
    }

    @Test func corruptCurrentStopsBeforeDeletingAnyCandidateOrPreviousResources() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root), versions = try await installed(3, in: store, root: root)
        let pointer = root.appendingPathComponent("versions-state.json"), original = try Data(contentsOf: pointer)
        try Data("corrupt".utf8).write(to: versions[2].directoryURL.appendingPathComponent("index.html"))
        await #expect(throws: (any Error).self) { try await store.removeInactiveVersions() }
        #expect(try Data(contentsOf: pointer) == original)
        for version in versions { #expect(FileManager.default.fileExists(atPath: version.directoryURL.path)) }
    }

    @Test func preCancelledCleanupDoesNotDeleteResourcesOrChangePointer() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root), versions = try await installed(3, in: store, root: root)
        let pointer = root.appendingPathComponent("versions-state.json"), original = try Data(contentsOf: pointer)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; try await store.removeInactiveVersions() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: pointer) == original)
        for version in versions { #expect(FileManager.default.fileExists(atPath: version.directoryURL.path)) }
    }

    @Test func inactiveSymlinkRemovalDoesNotTouchExternalTarget() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root), versions = try await installed(2, in: store, root: root)
        let outside = root.appendingPathComponent("outside"), marker = outside.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside survives".utf8).write(to: marker)
        let inactive = versions[0].directoryURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: inactive)
        try FileManager.default.createSymbolicLink(at: inactive, withDestinationURL: outside)
        try await store.removeInactiveVersions()
        #expect(try Data(contentsOf: marker) == Data("outside survives".utf8))
        #expect(!FileManager.default.fileExists(atPath: inactive.path))
        #expect(try await store.current() == versions[1])
    }

    @Test(arguments: ["manifest.json", "content", "content/assets"])
    func unreadableCurrentCannotTriggerDestructiveCleanup(relativePath: String) async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root), versions = try await installed(2, in: store, root: root)
        let restricted = versions[1].directoryURL.deletingLastPathComponent().appendingPathComponent(relativePath)
        let original = try FileManager.default.attributesOfItem(atPath: restricted.path)[.posixPermissions] as? NSNumber
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: original ?? 0o700], ofItemAtPath: restricted.path) }
        await #expect(throws: (any Error).self) { try await store.removeInactiveVersions() }
        #expect(FileManager.default.fileExists(atPath: versions[0].directoryURL.path))
    }

    @Test func legacyOfficialManifestAndSelectionRemainReadable() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root), version = try await Fixture.install(1, store: store, root: root)
        let manifestURL = version.directoryURL.deletingLastPathComponent().appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["schema"] = 1; manifest.removeValue(forKey: "source"); manifest.removeValue(forKey: "tag"); manifest.removeValue(forKey: "sha256")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let oldState: [String: Any] = ["schema": 1, "currentID": version.id, "activationOrder": [version.id], "lastPruneReport": ["obsolete": "ignored"]]
        try JSONSerialization.data(withJSONObject: oldState).write(to: root.appendingPathComponent("versions-state.json"))
        let reopened = try VersionStore(root: root)
        #expect(try await reopened.current() == version)
        #expect(try await reopened.current()?.source == .githubRelease)
        try await reopened.removeInactiveVersions()
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    @Test func localInlineArchiveNeedsNoOfficialMetadataAndKeepsOnlyItsOwnIntegrityManifest() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root)
        let html = Data("<!doctype html><html><body><div id='app'></div><script>document.querySelector('#app').textContent='inline local site';</script></body></html>".utf8)
        let source = root.appendingPathComponent("arbitrary-source-version-name.zip"), bytes = Fixture.zip([ZIPItem(path: "index.html", data: html)])
        try bytes.write(to: source)
        let first = try await store.prepareLocalZIP(source), second = try await store.prepareLocalZIP(source)
        #expect(first.id != second.id && first.id.hasPrefix("local-"))
        #expect(UUID(uuidString: String(first.id.dropFirst(6))) != nil)
        #expect(first.source == .localArchive && first.tag == "本地导入")
        #expect(first.sha256 == (try ReleaseClient.digest(of: source)))
        let manifestURL = first.directoryURL.deletingLastPathComponent().appendingPathComponent("manifest.json")
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        #expect(manifest["release"] == nil)
        #expect(try Data(contentsOf: first.directoryURL.appendingPathComponent("index.html")) == html)
        try await store.activate(first); try await store.removeInactiveVersions()
        #expect(try await store.current() == first)
        #expect(!FileManager.default.fileExists(atPath: second.directoryURL.path))
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test(arguments: ["path", "crc", "symlink", "missing-index", "empty-index"])
    func invalidLocalArchivePreservesCurrentAndLeavesNoCandidate(kind: String) async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root), current = try await Fixture.install(1, store: store, root: root)
        try await store.activate(current)
        var items = Fixture.items()
        switch kind {
        case "path": items.append(ZIPItem(path: "../escape.js", data: Data([1])))
        case "crc": items[0].crcOverride = 1
        case "symlink": items.append(ZIPItem(path: "link", data: Data("outside".utf8), mode: 0xa1ff))
        case "missing-index": items.removeFirst()
        default: items[0].data = Data()
        }
        let source = root.appendingPathComponent("bad-local.zip"); try Fixture.zip(items).write(to: source)
        let pointer = root.appendingPathComponent("versions-state.json"), original = try Data(contentsOf: pointer)
        await #expect(throws: (any Error).self) { try await store.prepareLocalZIP(source) }
        #expect(try await store.current() == current)
        #expect(try Data(contentsOf: pointer) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("versions").path) == [current.id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path).isEmpty)
    }
}
