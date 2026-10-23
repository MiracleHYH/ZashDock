import AppKit
import Foundation
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

@Suite(.serialized) @MainActor
struct WebRuntimeRecoveryTests {
    private func waitForFailure(_ session: WebSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !session.hasRuntimeFailure && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
        #expect(session.hasRuntimeFailure)
    }

    @Test(.timeLimit(.minutes(1)))
    func subsequentNavigationFailureReloadsCurrentWebKitConfigurationAndNeverTrapsQuit() async throws {
        try await withStorageAppFixture { paths, dataStore, _ in
            let port = try ConfigurationStore(url: paths.configuration).load().port
            let transfer = OriginStorageTransfer(dataStore: dataStore)
            let expected = OriginStoragePayload(localStorage: fixtureRemoteStorage(), databases: fixtureBusinessDatabases())
            try await transfer.restore(expected, to: fixtureOrigin(port))
            let model = AppModel(paths: paths, dataStore: dataStore)
            defer { model.session?.stop(); model.server?.stop() }
            await model.start()
            let session = try #require(model.session)
            model.server?.stop()
            _ = try? await session.page.callJavaScript("location.href='/unreachable?fixture-secret';")
            try await waitForFailure(session)
            #expect(model.phase == .unavailable)
            #expect(model.errorMessage?.contains("fixture-secret") == false)
            #expect(try await transfer.read(origin: fixtureOrigin(port)) == expected)
            model.reload()
            await model.operation?.value
            #expect(model.phase == .ready)
            let restored = try #require(model.session)
            let initial = try #require(try await restored.page.callJavaScript("return window.initialStorageJSON;") as? String)
            #expect(try JSONDecoder().decode([String: String].self, from: Data(initial.utf8)) == expected.localStorage)
            #expect(try await transfer.read(origin: fixtureOrigin(port)) == expected)
            model.server?.stop()
            _ = try? await restored.page.callJavaScript("location.href='/unreachable-again';")
            try await waitForFailure(restored)
            #expect(await model.prepareToQuit())
            #expect(try await transfer.read(origin: fixtureOrigin(port)) == expected)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func blankDocumentAndIntentionalJavaScriptClearDoNotReintroduceAnOlderSeed() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockRuntimeDocument-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<div id='app'>Ready</div>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("<div id='app'></div><script>localStorage.clear();</script>".utf8).write(to: root.appendingPathComponent("blank.html"))
        let server = try await bindFixture(root)
        defer { server.stop() }
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let transfer = OriginStorageTransfer(dataStore: dataStore)
        try await transfer.restore(.init(localStorage: fixtureRemoteStorage(), databases: fixtureBusinessDatabases()), to: server.baseURL)
        let session = WebSession(origin: server.baseURL, dataStore: dataStore)
        defer { session.stop() }
        var failures = 0
        session.onFailure = { _ in failures += 1 }
        try await session.loadAndVerify()
        _ = try? await session.page.callJavaScript("location.href='/blank.html';")
        try await waitForFailure(session)
        #expect(failures == 1)
        let cleared = try await transfer.read(origin: server.baseURL)
        #expect(cleared.localStorage.isEmpty)
        #expect(cleared.databases == fixtureBusinessDatabases())
        session.stop()
        let restarted = WebSession(origin: server.baseURL, dataStore: dataStore)
        defer { restarted.stop() }
        try await restarted.loadAndVerify()
        #expect(try await transfer.read(origin: server.baseURL) == cleared)
        restarted.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(failures == 1 && !restarted.hasRuntimeFailure)
    }

    @Test func cancelledAndExternalNavigationDoNotInvalidateLocalPage() {
        #expect(WebSession.ignoresNavigationError(URLError(.cancelled)))
        #expect(WebSession.ignoresNavigationError(WebPage.NavigationError.failedProvisionalNavigation(URLError(.cancelled))))
        #expect(WebSession.ignoresNavigationError(NSError(domain: "WebKitErrorDomain", code: 102)))
        #expect(!WebSession.ignoresNavigationError(URLError(.cannotConnectToHost)))
        #expect(!WebSession.ignoresNavigationError(WebPage.NavigationError.webContentProcessTerminated))
    }
}
