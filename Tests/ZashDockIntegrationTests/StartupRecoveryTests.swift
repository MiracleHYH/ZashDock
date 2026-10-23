import AppKit
import Foundation
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

@MainActor @Suite(.serialized)
struct StartupRecoveryTests {
    private func withPaths(_ body: (AppPaths, WKWebsiteDataStore, UInt16) async throws -> Void) async throws {
        _ = NSApplication.shared
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockStartupRecovery-\(UUID().uuidString)"))
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let reservation = try await bindFixture(paths.root)
        var configuration = AppConfiguration(); configuration.port = reservation.port
        reservation.stop(); try ConfigurationStore(url: paths.configuration).save(configuration)
        try await body(paths, .nonPersistent(), configuration.port)
    }

    @Test(.timeLimit(.minutes(1)))
    func malformedPreferencesCanBeRereadAfterRepairWithoutChangingWebsiteData() async throws {
        try await withPaths { paths, dataStore, port in
            let transfer = OriginStorageTransfer(dataStore: dataStore)
            let original = OriginStoragePayload(localStorage: fixtureRemoteStorage(), databases: fixtureBusinessDatabases())
            try await transfer.restore(original, to: fixtureOrigin(port))
            let malformed = Data("{broken preferences".utf8); try malformed.write(to: paths.configuration)
            let model = AppModel(paths: paths, dataStore: dataStore)
            await model.start()
            #expect(model.phase == .configurationRecovery)
            #expect(model.startupIssue?.kind == .malformedJSON)
            #expect(model.session == nil && model.updater == nil && model.store == nil)
            model.setQuitAfterLastWindow(true)
            #expect(try Data(contentsOf: paths.configuration) == malformed)
            await model.retryStartup()
            #expect(model.phase == .configurationRecovery)
            var repaired = AppConfiguration(); repaired.port = port
            try ConfigurationStore(url: paths.configuration).save(repaired)
            await model.retryStartup()
            #expect(model.phase == .uninstalled)
            #expect(model.startupIssue == nil)
            #expect(model.updater != nil && model.store != nil)
            #expect(model.configuration.port == port)
            #expect(try await transfer.read(origin: fixtureOrigin(port)) == original)
            #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("storage.aesgcm").path))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func nativeRecoveryPreservesCommittedOriginThenCleansInactiveVersionsAfterRender(primaryMissing: Bool) async throws {
        try await withStorageAppFixture { paths, dataStore, firstVersion in
            let transfer = OriginStorageTransfer(dataStore: dataStore)
            let configurationStore = ConfigurationStore(url: paths.configuration)
            let port = try configurationStore.load().port
            let original = OriginStoragePayload(localStorage: fixtureRemoteStorage(), databases: fixtureBusinessDatabases())
            try await transfer.restore(original, to: fixtureOrigin(port))
            var versions = [firstVersion]
            for number in 1...3 { versions.append(try writePersistedInstallation(paths, tag: "v0.92.\(number)")) }
            let current = try #require(versions.last), pointer = paths.root.appendingPathComponent("versions-state.json")
            try JSONSerialization.data(withJSONObject: ["schema": 1, "currentID": current.id, "activationOrder": versions.map(\.id)]).write(to: pointer)
            let broken = Data("{invalid preferences".utf8)
            if primaryMissing { try FileManager.default.removeItem(at: paths.configuration) }
            else { try broken.write(to: paths.configuration) }
            let model = AppModel(paths: paths, dataStore: dataStore)
            defer { model.session?.stop(); model.server?.stop() }
            await model.start()
            #expect(model.phase == .configurationRecovery)
            #expect(model.startupIssue?.kind == (primaryMissing ? .missingPrimary : .malformedJSON))
            #expect(try FileManager.default.contentsOfDirectory(atPath: paths.versions.path).count == 4)
            await model.resetConfigurationAndRestart()
            #expect(model.phase == .ready)
            #expect(model.configuration.port == port)
            #expect(model.currentVersion == current)
            if !primaryMissing {
                let backup = try #require(model.configurationRecoveryBackup)
                #expect(try Data(contentsOf: backup) == broken)
            }
            let store = try VersionStore(root: paths.root)
            #expect(try await store.validate(current) == current)
            for version in versions.dropLast() { #expect(!FileManager.default.fileExists(atPath: version.directoryURL.path)) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: paths.versions.path).count == 1)
            #expect(try await transfer.read(origin: fixtureOrigin(port)) == original)
            let session = try #require(model.session)
            let firstRead = try #require(try await session.page.callJavaScript("return window.initialStorageJSON;") as? String)
            #expect(try JSONDecoder().decode([String: String].self, from: Data(firstRead.utf8)) == original.localStorage)
            #expect(await model.prepareToQuit())
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func unknownOriginalPortRequiresExplicitInputInsteadOfSilentlySelecting9099() async throws {
        try await withPaths { paths, dataStore, oldPort in
            let configurationStore = ConfigurationStore(url: paths.configuration)
            try FileManager.default.removeItem(at: configurationStore.recoveryCopyURL)
            let original = OriginStoragePayload(localStorage: fixtureRemoteStorage(), databases: fixtureBusinessDatabases())
            let transfer = OriginStorageTransfer(dataStore: dataStore)
            try await transfer.restore(original, to: fixtureOrigin(oldPort))
            let broken = Data("broken".utf8); try broken.write(to: paths.configuration)
            let model = AppModel(paths: paths, dataStore: dataStore)
            await model.start()
            await model.resetConfigurationAndRestart()
            #expect(model.phase == .configurationRecovery)
            #expect(try Data(contentsOf: paths.configuration) == broken)
            await model.resetConfigurationAndRestart(preservingPort: oldPort)
            #expect(model.phase == .uninstalled)
            #expect(model.configuration.port == oldPort)
            #expect(try await transfer.read(origin: fixtureOrigin(oldPort)) == original)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func unreadableConfigurationCannotBeOverwrittenByReset() async throws {
        try await withPaths { paths, dataStore, port in
            try FileManager.default.removeItem(at: paths.configuration)
            try FileManager.default.createDirectory(at: paths.configuration, withIntermediateDirectories: false)
            let marker = paths.configuration.appendingPathComponent("preserve")
            try Data("original".utf8).write(to: marker)
            let model = AppModel(paths: paths, dataStore: dataStore)
            await model.start()
            #expect(model.startupIssue?.kind == .unreadable)
            await model.resetConfigurationAndRestart(preservingPort: port)
            #expect(model.phase == .configurationRecovery)
            #expect(model.configurationRecoveryBackup == nil)
            #expect(!model.isBusy)
            #expect(try Data(contentsOf: marker) == Data("original".utf8))
        }
    }
}
