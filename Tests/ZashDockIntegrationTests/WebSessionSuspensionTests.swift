import AppKit
import CryptoKit
import Foundation
import Network
import Testing
import UniformTypeIdentifiers
import WebKit
@testable import ZashDock
import ZashDockCore

@MainActor
private final class SuspensionPanels: WebPanelDriving {
    private(set) var cancellationCount = 0
    func alert(_ message: String) async {}
    func confirm(_ message: String) async -> Bool { false }
    func prompt(_ message: String, defaultText: String?) async -> String? { nil }
    func chooseFiles(allowsMultipleSelection: Bool, allowsDirectories: Bool) async -> [URL]? { nil }
    func chooseSaveDestination(suggestedName: String, contentType: UTType?) async -> URL? { nil }
    func exportFailed() async {}
    func cancel() { cancellationCount += 1 }
}

/// Only performs a WebSocket handshake and observes the client's close/EOF; no remote API is exposed.
private final class SuspensionSocket: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.zashdock.tests.suspension-socket")
    private let listener: NWListener
    private var startup: CheckedContinuation<Void, any Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var opened = 0
    private var closed = 0
    private(set) var port: UInt16 = 0
    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
    }
    static func bind() async throws -> SuspensionSocket {
        let server = try SuspensionSocket()
        try await server.start()
        return server
    }
    private func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            startup = continuation
            listener.stateUpdateHandler = { [self] state in
                guard let continuation = startup else { return }
                if case .ready = state {
                    startup = nil; port = listener.port!.rawValue
                    continuation.resume()
                } else if case let .failed(error) = state {
                    startup = nil; continuation.resume(throwing: error)
                } else if case .cancelled = state {
                    startup = nil; continuation.resume(throwing: CancellationError())
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receiveHeaders(connection, id: id, previous: Data())
    }
    private func receiveHeaders(_ connection: NWConnection, id: UUID, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] bytes, _, complete, error in
            guard let self, connections[id] != nil else { return }
            var data = previous
            if let bytes { data.append(bytes) }
            guard data.count < 8_192, error == nil, !complete else { finish(id); return }
            guard data.range(of: Data("\r\n\r\n".utf8)) != nil else {
                receiveHeaders(connection, id: id, previous: data); return
            }
            let headers = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
            guard let key = headers.first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") })?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) else { finish(id); return }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let response = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
            connection.send(content: response, completion: .contentProcessed { [weak self] error in
                guard let self, connections[id] != nil else { return }
                guard error == nil else { finish(id); return }
                opened += 1
                receiveClose(connection, id: id)
            })
        }
    }
    private func receiveClose(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { [weak self] bytes, _, complete, error in
            guard let self, connections[id] != nil else { return }
            if complete || error != nil || bytes?.first.map({ $0 & 0x0f == 8 }) == true {
                closed += 1; finish(id)
            } else { receiveClose(connection, id: id) }
        }
    }
    private func finish(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
    func counts() async -> (opened: Int, closed: Int) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: (opened, closed)) }
        }
    }
    func stop() {
        queue.sync {
            listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }
}

@Suite(.serialized) @MainActor
struct WebSessionSuspensionTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func suspensionUnloadsContextStopsTimersAndClosesSocketsEvenForPreCancelledCaller(cancelCaller: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockSuspension-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<div id='app'>Suspension fixture</div>".utf8).write(to: root.appendingPathComponent("index.html"))
        let server = try await bindFixture(root)
        defer { server.stop() }
        let socket = try await SuspensionSocket.bind()
        defer { socket.stop() }
        let panels = SuspensionPanels()
        let session = WebSession(origin: server.baseURL, dataStore: .nonPersistent(), panels: panels)
        defer { session.stop() }
        try await session.loadAndVerify()
        try await session.page.callJavaScript("""
            window.suspensionContext = true;
            let count = 0;
            window.suspensionTimer = setInterval(() => localStorage.setItem('suspension-ticks', String(++count)), 5);
            window.suspensionSocket = new WebSocket(endpoint);
            await new Promise((resolve, reject) => {
                const timeout = setTimeout(() => reject(new Error('fixture socket did not open')), 5000);
                window.suspensionSocket.onopen = () => {clearTimeout(timeout); resolve();};
                window.suspensionSocket.onerror = () => {clearTimeout(timeout); reject(new Error('fixture socket failed'));};
            });
            """, arguments: ["endpoint": "ws://127.0.0.1:\(socket.port)/fixture"])
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if try await session.page.callJavaScript("return Number(localStorage.getItem('suspension-ticks'))>=2;") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await session.page.callJavaScript("return Number(localStorage.getItem('suspension-ticks'))>=2;") as? Bool == true)
        #expect(await socket.counts().opened == 1)
        let unloading = Task { @MainActor in await session.suspend() }
        if cancelCaller { unloading.cancel() }
        await unloading.value
        #expect(unloading.isCancelled == cancelCaller)
        #expect(panels.cancellationCount == 1)
        #expect(try await session.page.callJavaScript("return location.pathname;") as? String == "/__zashdock_suspended")
        #expect(try await session.page.callJavaScript("return typeof window.suspensionContext;") as? String == "undefined")
        let counter = try #require(try await session.page.callJavaScript("return localStorage.getItem('suspension-ticks');") as? String)
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await session.page.callJavaScript("return localStorage.getItem('suspension-ticks');") as? String == counter)
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await socket.counts().closed == 0 && ContinuousClock.now < closeDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await socket.counts().closed == 1)
        // Repeated cancelled cleanup shares the completed unload and never resumes the original document.
        let repeated = Task { @MainActor in await session.suspend() }
        repeated.cancel(); await repeated.value
        #expect(panels.cancellationCount == 1)
        #expect(try await session.page.callJavaScript("return typeof window.suspensionContext;") as? String == "undefined")
    }
}
