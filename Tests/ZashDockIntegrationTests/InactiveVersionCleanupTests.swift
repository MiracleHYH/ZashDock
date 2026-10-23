import AppKit
import Foundation
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

@MainActor @Suite(.serialized)
struct InactiveVersionCleanupTests {
    @Test(.timeLimit(.minutes(1)))
    func legacyOfficialManifestsLoadAndOldHistoryIsRemovedAfterCurrentPageRenders() async throws {
        _ = NSApplication.shared
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockInactiveVersions-\(UUID())"))
        try paths.createDirectories()
        let first = try writePersistedInstallation(paths, tag: "v0.95.1")
        let damaged = try writePersistedInstallation(paths, tag: "v0.95.2")
        let current = try writePersistedInstallation(paths, tag: "v0.95.3")
        // This is the on-disk schema from the old rollback build, including a damaged
        // inactive resource. It must be readable without keeping historical versions.
        try Data("damaged inactive version".utf8).write(to: damaged.directoryURL.appendingPathComponent("index.html"))
        try JSONSerialization.data(withJSONObject: ["schema": 1, "currentID": current.id,
            "activationOrder": [current.id, damaged.id, first.id]])
            .write(to: paths.root.appendingPathComponent("versions-state.json"))
        let reservation = try await bindFixture(current.directoryURL)
        var configuration = AppConfiguration(); configuration.port = reservation.port
        reservation.stop(); try ConfigurationStore(url: paths.configuration).save(configuration)
        let fixture = PortMigrationFixture(paths: paths, webRoot: current.directoryURL)
        let expected = OriginStoragePayload(localStorage: fixtureRemoteStorage(), databases: fixtureBusinessDatabases())
        try await OriginStorageTransfer(dataStore: fixture.dataStore).restore(expected, to: fixtureOrigin(configuration.port))
        do {
            let model = fixture.model(); await model.start()
            #expect(model.phase == .ready && model.currentVersion == current)
            #expect(model.currentVersion?.source == .githubRelease)
            try await assertPage(model, expected: expected)
            #expect(!FileManager.default.fileExists(atPath: first.directoryURL.path))
            #expect(!FileManager.default.fileExists(atPath: damaged.directoryURL.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: paths.versions.path).count == 1)
            #expect(try await model.store?.validate(current) == current)
            await fixture.shutdown(model)
            let restarted = fixture.model(); await restarted.start()
            #expect(restarted.currentVersion == current && restarted.phase == .ready)
            try await assertPage(restarted, expected: expected)
            await fixture.cleanUp()
        } catch { await fixture.cleanUp(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func damagedCurrentVersionDoesNotDeleteOldResourcesOrBusinessData() async throws {
        _ = NSApplication.shared
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockDamagedCurrent-\(UUID())"))
        try paths.createDirectories()
        let old = try writePersistedInstallation(paths, tag: "v0.96.1")
        let damaged = try writePersistedInstallation(paths, tag: "v0.96.2")
        try JSONSerialization.data(withJSONObject: ["schema": 1, "currentID": damaged.id,
            "activationOrder": [damaged.id, old.id]])
            .write(to: paths.root.appendingPathComponent("versions-state.json"))
        let reservation = try await bindFixture(old.directoryURL)
        var configuration = AppConfiguration(); configuration.port = reservation.port
        reservation.stop(); try ConfigurationStore(url: paths.configuration).save(configuration)
        let fixture = PortMigrationFixture(paths: paths, webRoot: old.directoryURL)
        let expected = OriginStoragePayload(localStorage: fixtureRemoteStorage(), databases: fixtureBusinessDatabases())
        let transfer = OriginStorageTransfer(dataStore: fixture.dataStore)
        try await transfer.restore(expected, to: fixtureOrigin(configuration.port))
        try Data("corrupt".utf8).write(to: damaged.directoryURL.appendingPathComponent("index.html"))
        do {
            let model = fixture.model(); await model.start()
            #expect(model.phase == .damaged && model.session == nil && model.server == nil)
            #expect(FileManager.default.fileExists(atPath: old.directoryURL.path))
            #expect(FileManager.default.fileExists(atPath: damaged.directoryURL.path))
            try await transfer.verify(expected, at: fixtureOrigin(configuration.port))
            await fixture.cleanUp()
        } catch { await fixture.cleanUp(); throw error }
    }

    private func assertPage(_ model: AppModel, expected: OriginStoragePayload) async throws {
        let session = try #require(model.session)
        let initial = try #require(try await session.page.callJavaScript("return window.initialStorageJSON;") as? String)
        #expect(try JSONDecoder().decode([String:String].self, from: Data(initial.utf8)) == expected.localStorage)
        #expect(try await initialBusinessDatabases(session) == expected.databases)
        try await model.originStorage.verify(expected, at: session.origin)
    }
}
