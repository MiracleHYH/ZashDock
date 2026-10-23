import Foundation
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

@MainActor @Suite(.serialized)
struct LegacyStorageImportTests {
    @Test(.timeLimit(.minutes(1)))
    func existingCiphertextIsImportedOnceWithoutReplacingIndexedDBOrReplayingAfterRestart() async throws {
        try await withStorageAppFixture { paths, dataStore, _ in
            let port = try ConfigurationStore(url: paths.configuration).load().port
            let transfer = OriginStorageTransfer(dataStore: dataStore)
            try await transfer.restore(.init(localStorage: [:], databases: fixtureBusinessDatabases()), to: fixtureOrigin(port))
            let legacy = paths.root.appendingPathComponent("storage.aesgcm")
            let originalValues = fixtureRemoteStorage()
            try writeLegacyFixture(originalValues, to: legacy)
            let originalCiphertext = try Data(contentsOf: legacy)
            let reader = FixtureLegacyKeyReader()
            let model = AppModel(paths: paths, dataStore: dataStore, legacyKeyReader: reader)
            defer { model.session?.stop(); model.server?.stop() }
            await model.start()
            #expect(model.phase == .ready)
            #expect(reader.accessCount == 1)
            #expect(model.configuration.legacyStorageImported)
            #expect(try ConfigurationStore(url: paths.configuration).load().legacyStorageImported)
            let imported = try await transfer.read(origin: fixtureOrigin(port))
            #expect(imported.localStorage == originalValues && imported.databases == fixtureBusinessDatabases())
            #expect(try Data(contentsOf: legacy) == originalCiphertext)
            let page = try #require(model.session).page
            let initial = try #require(try await page.callJavaScript("return window.initialStorageJSON;") as? String)
            #expect(try JSONDecoder().decode([String: String].self, from: Data(initial.utf8)) == originalValues)
            try await page.callJavaScript("localStorage.setItem('config/after-import','current WebKit state');")
            #expect(await model.prepareToQuit())
            reader.setUnavailable(true)
            let restarted = AppModel(paths: paths, dataStore: dataStore, legacyKeyReader: reader)
            defer { restarted.session?.stop(); restarted.server?.stop() }
            await restarted.start()
            #expect(restarted.phase == .ready)
            #expect(reader.accessCount == 1)
            var expected = originalValues; expected["config/after-import"] = "current WebKit state"
            #expect(try await transfer.read(origin: fixtureOrigin(port)).localStorage == expected)
            #expect(try Data(contentsOf: legacy) == originalCiphertext)
            #expect(await restarted.prepareToQuit())
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func newProfileNeverAccessesAKeyOrCreatesNativeWebsiteState() async throws {
        try await withStorageAppFixture { paths, dataStore, _ in
            let port = try ConfigurationStore(url: paths.configuration).load().port
            let transfer = OriginStorageTransfer(dataStore: dataStore)
            let expected = OriginStoragePayload(localStorage: fixtureRemoteStorage(), databases: fixtureBusinessDatabases())
            try await transfer.restore(expected, to: fixtureOrigin(port))
            let reader = FixtureLegacyKeyReader(unavailable: true)
            let model = AppModel(paths: paths, dataStore: dataStore, legacyKeyReader: reader)
            defer { model.session?.stop(); model.server?.stop() }
            await model.start()
            #expect(model.phase == .ready && reader.accessCount == 0)
            #expect(try await transfer.read(origin: fixtureOrigin(port)) == expected)
            #expect(await model.prepareToQuit())
            #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("storage.aesgcm").path))
            #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("storage-recovery").path))
            let preferences = try Data(contentsOf: paths.configuration)
            #expect(preferences.range(of: Data("storage-fixture-one".utf8)) == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func temporarilyUnavailableLegacyKeyCanBeRetriedWithoutChangingOldFiles() async throws {
        try await withStorageAppFixture { paths, dataStore, _ in
            let legacy = paths.root.appendingPathComponent("storage.aesgcm")
            try writeLegacyFixture(fixtureRemoteStorage(), to: legacy)
            let original = try Data(contentsOf: legacy), configuration = try Data(contentsOf: paths.configuration)
            let reader = FixtureLegacyKeyReader(unavailable: true)
            let model = AppModel(paths: paths, dataStore: dataStore, legacyKeyReader: reader)
            defer { model.session?.stop(); model.server?.stop() }
            await model.start()
            #expect(model.phase == .unavailable && !model.canManageVersions)
            #expect(!model.configuration.legacyStorageImported)
            #expect(try Data(contentsOf: legacy) == original)
            #expect(try Data(contentsOf: paths.configuration) == configuration)
            reader.setUnavailable(false)
            await model.retryStartup()
            #expect(model.phase == .ready && model.canManageVersions)
            #expect(reader.accessCount == 2)
            #expect(try Data(contentsOf: legacy) == original)
            #expect(await model.prepareToQuit())
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func invalidCiphertextOrWrongKeyCannotOverwriteCurrentWebsiteState(wrongKey: Bool) async throws {
        try await withStorageAppFixture { paths, dataStore, _ in
            let port = try ConfigurationStore(url: paths.configuration).load().port
            let expected = OriginStoragePayload(localStorage: ["current": "do not overwrite"], databases: fixtureBusinessDatabases())
            let transfer = OriginStorageTransfer(dataStore: dataStore)
            try await transfer.restore(expected, to: fixtureOrigin(port))
            let legacy = paths.root.appendingPathComponent("storage.aesgcm")
            if wrongKey { try writeLegacyFixture(fixtureRemoteStorage(), to: legacy, byte: 0x99) }
            else { try Data("damaged original".utf8).write(to: legacy) }
            let original = try Data(contentsOf: legacy), configuration = try Data(contentsOf: paths.configuration)
            let model = AppModel(paths: paths, dataStore: dataStore, legacyKeyReader: FixtureLegacyKeyReader())
            await model.start()
            #expect(model.phase == .unavailable && model.session == nil && !model.canManageVersions)
            #expect(!model.configuration.legacyStorageImported)
            #expect(try await transfer.read(origin: fixtureOrigin(port)) == expected)
            #expect(try Data(contentsOf: legacy) == original)
            #expect(try Data(contentsOf: paths.configuration) == configuration)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func legacyBackupCanBeReadWithoutRepairingOrRotatingTheOriginalFiles() async throws {
        try await withStorageAppFixture { paths, dataStore, _ in
            let legacy = paths.root.appendingPathComponent("storage.aesgcm"), backup = legacy.appendingPathExtension("backup")
            let damaged = Data("keep damaged original".utf8); try damaged.write(to: legacy)
            try writeLegacyFixture(fixtureRemoteStorage(), to: backup)
            let backupBytes = try Data(contentsOf: backup)
            let reader = FixtureLegacyKeyReader()
            let model = AppModel(paths: paths, dataStore: dataStore, legacyKeyReader: reader)
            defer { model.session?.stop(); model.server?.stop() }
            await model.start()
            #expect(model.phase == .ready && model.configuration.legacyStorageImported)
            #expect(try Data(contentsOf: legacy) == damaged)
            #expect(try Data(contentsOf: backup) == backupBytes)
            #expect(reader.accessCount == 1)
            #expect(await model.prepareToQuit())
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func intentionalClearRemainsEmptyAcrossReloadAndRestartAfterLegacyImport() async throws {
        try await withStorageAppFixture { paths, dataStore, _ in
            let legacy = paths.root.appendingPathComponent("storage.aesgcm")
            try writeLegacyFixture(fixtureRemoteStorage(), to: legacy)
            let reader = FixtureLegacyKeyReader()
            let model = AppModel(paths: paths, dataStore: dataStore, legacyKeyReader: reader)
            defer { model.session?.stop(); model.server?.stop() }
            await model.start()
            let session = try #require(model.session)
            try await session.page.callJavaScript("localStorage.clear();")
            model.reload(); await model.operation?.value
            #expect(model.phase == .ready)
            let empty = try await model.originStorage.read(origin: fixtureOrigin(model.configuration.port))
            #expect(empty.localStorage.isEmpty)
            #expect(await model.prepareToQuit())
            reader.setUnavailable(true)
            let restarted = AppModel(paths: paths, dataStore: dataStore, legacyKeyReader: reader)
            defer { restarted.session?.stop(); restarted.server?.stop() }
            await restarted.start()
            #expect(restarted.phase == .ready && reader.accessCount == 1)
            #expect(try await restarted.originStorage.read(origin: fixtureOrigin(restarted.configuration.port)).localStorage.isEmpty)
            #expect(await restarted.prepareToQuit())
        }
    }
}
