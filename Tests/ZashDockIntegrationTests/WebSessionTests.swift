import AppKit
import Foundation
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

@Suite(.serialized)
@MainActor
struct WebSessionTests {
    @Test(.timeLimit(.minutes(1)))
    func nativeWebPageLoadsLoopbackAndKeepsPersistentStore() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zashdock-web-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<html><body><div id='app'>原生 WebPage 测试</div><script>document.documentElement.dataset.loaded='yes';</script></body></html>".utf8).write(to: directory.appendingPathComponent("index.html"))
        let server = try await bindFixture(directory)
        defer { server.stop() }
        let session = WebSession(origin: server.baseURL, dataStore: .nonPersistent())
        try await session.loadAndVerify()
        let result = try await session.page.callJavaScript("return document.documentElement.dataset.loaded;")
        #expect(result as? String == "yes")
        session.stop()
    }
}

@MainActor
func bindFixture(_ directory: URL) async throws -> LoopbackHTTPServer {
    for _ in 0..<30 {
        let server = try LoopbackHTTPServer(root: directory, port: UInt16.random(in: 20000...60000), versionID: "fixture")
        do { _ = try await server.start(); return server }
        catch { server.stop() }
    }
    throw ZashDockError.server("测试无法绑定 loopback 端口。")
}
