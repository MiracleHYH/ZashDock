import AppKit
import Foundation
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

@MainActor @Suite(.serialized)
struct AppLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func normalQuitRetainsWebKitConfigurationWithoutNativeSnapshots() async throws {
        try await withStorageAppFixture { paths, dataStore, _ in
            let expected = OriginStoragePayload(localStorage: fixtureRemoteStorage(), databases: fixtureBusinessDatabases())
            let transfer = OriginStorageTransfer(dataStore: dataStore)
            let port = try ConfigurationStore(url: paths.configuration).load().port
            try await transfer.restore(expected, to: fixtureOrigin(port))
            let model = AppModel(paths: paths, dataStore: dataStore)
            defer { model.session?.stop(); model.server?.stop() }
            await model.start()
            #expect(model.phase == .ready)
            #expect(await model.prepareToQuit())
            #expect(try await transfer.read(origin: fixtureOrigin(port)) == expected)
            #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("storage.aesgcm").path))
            let restarted = AppModel(paths: paths, dataStore: dataStore)
            defer { restarted.session?.stop(); restarted.server?.stop() }
            await restarted.start()
            #expect(restarted.phase == .ready)
            #expect(try await transfer.read(origin: fixtureOrigin(port)) == expected)
            #expect(await restarted.prepareToQuit())
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func quittingCancelsAndWaitsForTheCurrentOperation() async throws {
        try await withStorageAppFixture { paths, dataStore, _ in
            let model = AppModel(paths: paths, dataStore: dataStore)
            defer { model.session?.stop(); model.server?.stop() }
            await model.start()
            var operationFinished = false
            let pending = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(30)) } catch {}
                operationFinished = true
            }
            model.operation = pending
            #expect(await model.prepareToQuit())
            #expect(pending.isCancelled && operationFinished)
            model.operation = nil
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func failureFromReplacedSessionCannotInvalidateCurrentSession() async throws {
        try await withStorageAppFixture { paths, dataStore, version in
            let model = AppModel(paths: paths, dataStore: dataStore)
            defer { model.session?.stop(); model.server?.stop() }
            await model.start()
            let oldSession = try #require(model.session)
            let oldCallback = try #require(oldSession.onFailure)
            let reservation = try await bindFixture(version.directoryURL)
            let port = reservation.port; reservation.stop()
            try await model.changePort(to: port)
            let current = try #require(model.session)
            oldCallback("Previous session failed")
            #expect(model.phase == .ready && model.session === current)
            current.onFailure?("Current session failed")
            #expect(model.phase == .unavailable)
            #expect(await model.prepareToQuit())
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func immediatelyCancelledUpdateCheckDoesNotBecomeAnErrorOrStartNetworkWork() async throws {
        try await withStorageAppFixture { paths, dataStore, _ in
            let model = AppModel(paths: paths, dataStore: dataStore)
            defer { model.session?.stop(); model.server?.stop() }
            await model.start()
            model.checkForUpdates()
            let operation = try #require(model.operation)
            model.cancel()
            await operation.value
            #expect(model.status == "已取消检查更新。")
            #expect(model.errorMessage == nil && model.updater?.lastError == nil)
            #expect(!model.isBusy && model.operation == nil)
            #expect(await model.prepareToQuit())
        }
    }
}
