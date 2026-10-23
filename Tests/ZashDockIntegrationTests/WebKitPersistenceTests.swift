import AppKit
import Foundation
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

@Suite(.serialized) @MainActor
struct WebKitPersistenceTests {
    private func fixture(_ body: (URL, LoopbackHTTPServer, WKWebsiteDataStore) async throws -> Void) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockWebKitPersistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let html = "<html><body><div id='app'>Persistent fixture</div><script>window.firstStorage=JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(k=>[k,localStorage.getItem(k)])));</script></body></html>"
        for name in ["index.html", "next.html"] { try Data(html.utf8).write(to: root.appendingPathComponent(name)) }
        let listener = try await bindFixture(root)
        defer { listener.stop() }
        let store = WKWebsiteDataStore(forIdentifier: UUID())
        do { try await body(root, listener, store) }
        catch {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            throw error
        }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    private func read(_ page: WebPage, first: Bool = false) async throws -> [String: String] {
        let text = try #require(try await page.callJavaScript(first ? "return window.firstStorage;" : "return JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(k=>[k,localStorage.getItem(k)])));") as? String)
        return try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
    }
    private let initial = ["setup/api-list": #"[{"uuid":"one","password":"fictional-one"}]"#, "setup/active-uuid": "one"]
    private func write(_ values: [String: String], to page: WebPage) async throws {
        let json = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        try await page.callJavaScript("for(const [k,v] of Object.entries(JSON.parse(json)))localStorage.setItem(k,v);", arguments: ["json": json])
    }
    private var updated: [String: String] {
        ["setup/api-list": #"[{"uuid":"one","password":"fictional-one"},{"uuid":"two","password":"fictional-two"}]"#,
         "setup/active-uuid": "two", "config/default-theme": "dark", "__proto__": "ordinary value", "fixture/unicode": "中文\n\"\\"]
    }

    @Test(.timeLimit(.minutes(1)))
    func reloadNavigationAndRecreatedPageKeepLatestTwoRemotesWithoutNativeBridge() async throws {
        try await fixture { root, listener, store in
            let first = WebSession(origin: listener.baseURL, dataStore: store)
            defer { first.stop() }
            try await first.loadAndVerify()
            try await write(initial, to: first.page)
            try await write(updated, to: first.page)
            for try await _ in first.page.load(URLRequest(url: listener.baseURL)) {}
            #expect(try await read(first.page, first: true) == updated)
            for try await _ in first.page.load(URLRequest(url: listener.baseURL.appendingPathComponent("next.html"))) {}
            #expect(try await read(first.page, first: true) == updated)
            await first.suspend()
            let recreated = WebSession(origin: listener.baseURL, dataStore: store)
            defer { recreated.stop() }
            try await recreated.loadAndVerify()
            #expect(try await read(recreated.page, first: true) == updated)
            #expect(try await recreated.page.callJavaScript("return typeof window.__zashdockStorageSnapshot;") as? String == "undefined")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("storage.aesgcm").path))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func intentionalClearStaysClearedAcrossReloadWithoutReplayingAnOldSeed() async throws {
        try await fixture { _, listener, store in
            let session = WebSession(origin: listener.baseURL, dataStore: store)
            defer { session.stop() }
            try await session.loadAndVerify()
            try await write(updated, to: session.page)
            try await session.page.callJavaScript("localStorage.clear();sessionStorage.clear();")
            for try await _ in session.page.load(URLRequest(url: listener.baseURL)) {}
            #expect(try await read(session.page, first: true).isEmpty)
        }
    }
}
