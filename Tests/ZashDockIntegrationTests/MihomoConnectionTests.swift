import AppKit
import CryptoKit
import Foundation
import Network
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

@Suite(.serialized)
@MainActor
struct MihomoConnectionTests {
    @Test(.timeLimit(.minutes(1)))
    func webPageUsesHTTPRESTPreflightAndWebSocketAcrossOrigins() async throws {
        _ = NSApplication.shared
        let directory = try connectionFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let panel = try await bindFixture(directory)
        defer { panel.stop() }
        let mihomo = try await MockMihomoServer.bind(allowing: panel.baseURL, excluding: panel.port)
        defer { mihomo.stop() }
        #expect(panel.port != mihomo.port)

        let session = WebSession(origin: panel.baseURL, dataStore: .nonPersistent())
        defer { session.stop() }
        try await session.loadAndVerify()

        let rest = try await session.page.callJavaScript("""
            const response = await fetch(endpoint + '/version', {
                method: 'GET',
                headers: { 'Authorization': 'Bearer ' + token },
                cache: 'no-store',
                signal: AbortSignal.timeout(8000)
            });
            const body = await response.json();
            return { status: response.status, version: body.version, meta: body.meta };
            """, arguments: ["endpoint": mihomo.baseURL.absoluteString, "token": MockMihomoServer.fixtureToken])
        let response = try #require(rest as? [String: Any])
        #expect((response["status"] as? NSNumber)?.intValue == 200)
        #expect(response["version"] as? String == "fixture-mihomo")
        #expect(response["meta"] as? Bool == true)

        let traffic = try await session.page.callJavaScript("""
            return await new Promise((resolve, reject) => {
                const url = new URL(endpoint + '/traffic');
                url.protocol = 'ws:';
                url.searchParams.set('token', token);
                const socket = new WebSocket(url);
                let settled = false;
                const timeout = setTimeout(() => {
                    if (settled) return;
                    settled = true;
                    socket.close();
                    reject(new Error('fixture WebSocket timed out'));
                }, 8000);
                socket.onmessage = event => {
                    if (settled) return;
                    settled = true;
                    clearTimeout(timeout);
                    try { resolve(JSON.parse(event.data)); }
                    catch (error) { reject(error); }
                    socket.close(1000, 'fixture complete');
                };
                socket.onerror = () => {
                    if (settled) return;
                    settled = true;
                    clearTimeout(timeout);
                    socket.close();
                    reject(new Error('fixture WebSocket handshake failed'));
                };
                socket.onclose = () => {
                    if (settled) return;
                    settled = true;
                    clearTimeout(timeout);
                    reject(new Error('fixture WebSocket closed before a message'));
                };
            });
            """, arguments: ["endpoint": mihomo.baseURL.absoluteString, "token": MockMihomoServer.fixtureToken])
        let sample = try #require(traffic as? [String: Any])
        #expect((sample["up"] as? NSNumber)?.intValue == 128)
        #expect((sample["down"] as? NSNumber)?.intValue == 256)

        let observed = await mihomo.snapshot()
        #expect(observed.preflights >= 1)
        #expect(observed.authorizedRESTRequests == 1)
        #expect(observed.authorizedWebSocketHandshakes == 1)
        #expect(observed.rejectedRequests == 0)
    }

    /// This intentionally has no real credential support. A public 401 proves reachability only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZASHDOCK_MIHOMO_URL"] != nil), .timeLimit(.minutes(1)))
    func optionalPublicMihomoHTTPReachability() async throws {
        _ = NSApplication.shared
        let configured = try #require(ProcessInfo.processInfo.environment["ZASHDOCK_MIHOMO_URL"])
        let endpoint = try #require(URL(string: configured))
        #expect(endpoint.scheme == "http" || endpoint.scheme == "https")
        guard let scheme = endpoint.scheme, ["http", "https"].contains(scheme), endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw ZashDockError.invalidConfiguration("测试端点必须是无凭据、无查询参数的 HTTP(S) URL。")
        }
        let directory = try connectionFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let panel = try await bindFixture(directory)
        defer { panel.stop() }
        let session = WebSession(origin: panel.baseURL, dataStore: .nonPersistent())
        defer { session.stop() }
        try await session.loadAndVerify()
        let result = try await session.page.callJavaScript("""
            const response = await fetch(endpoint, {
                method: 'GET', cache: 'no-store', credentials: 'omit',
                signal: AbortSignal.timeout(10000)
            });
            return response.status;
            """, arguments: ["endpoint": endpoint.appendingPathComponent("version").absoluteString])
        let status = try #require((result as? NSNumber)?.intValue)
        #expect(status == 200 || status == 401)
        if status == 401 {
            print("Live Mihomo: HTTP 401，可达；未验证认证成功、WebSocket 订阅或真实配置。")
        } else {
            print("Live Mihomo: HTTP 200，可达；此测试未使用真实 Secret。")
        }
    }

    private func connectionFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zashdock-mihomo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let html = """
            <!doctype html><html><body><div id="app"><main>WebKit Mihomo integration fixture</main></div>
            <script>document.documentElement.dataset.loaded = 'yes';</script></body></html>
            """
        try Data(html.utf8).write(to: directory.appendingPathComponent("index.html"))
        return directory
    }
}

/// Test-only server. It implements exactly the HTTP and RFC 6455 paths exercised above.
/// All mutable state is confined to queue; no proxy, filesystem or general command route exists.
final class MockMihomoServer: @unchecked Sendable {
    static let fixtureToken = "zashdock-fixture-token-not-a-real-secret"
    struct Snapshot: Sendable {
        var preflights = 0
        var authorizedRESTRequests = 0
        var authorizedWebSocketHandshakes = 0
        var rejectedRequests = 0
    }
    let port: UInt16
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private let allowedOrigin: String
    fileprivate let queue = DispatchQueue(label: "app.zashdock.tests.mock-mihomo")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var listener: NWListener?
    private var startup: CheckedContinuation<Void, any Error>?
    private var clients: [UUID: MockMihomoConnection] = [:]
    private var observed = Snapshot()
    private var ready = false

    private init(port: UInt16, allowedOrigin: URL) {
        self.port = port
        self.allowedOrigin = allowedOrigin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        queue.setSpecific(key: queueKey, value: 1)
    }

    static func bind(allowing origin: URL, excluding excludedPort: UInt16) async throws -> MockMihomoServer {
        for _ in 0..<30 {
            try Task.checkCancellation()
            let port = UInt16.random(in: 20000...60000)
            guard port != excludedPort else { continue }
            let server = MockMihomoServer(port: port, allowedOrigin: origin)
            do { try await server.start(); return server }
            catch { server.stop(); try Task.checkCancellation() }
        }
        throw ZashDockError.server("测试无法绑定 mock Mihomo loopback 端口。")
    }

    private func start() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    startup = continuation
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: NWEndpoint.Port(rawValue: port)!)
                        parameters.allowLocalEndpointReuse = false
                        parameters.includePeerToPeer = false
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self else { return }
                            switch state {
                            case .ready: self.ready = true; self.completeStartup(.success(()))
                            case .failed: self.completeStartup(.failure(ZashDockError.server("mock Mihomo 绑定失败。")))
                            case .cancelled: self.completeStartup(.failure(CancellationError()))
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        listener.start(queue: queue)
                        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                            guard let self, self.startup != nil else { return }
                            self.completeStartup(.failure(ZashDockError.server("mock Mihomo 绑定超时。")))
                        }
                    } catch { completeStartup(.failure(error)) }
                }
            }
        } onCancel: { self.stop() }
        do { try Task.checkCancellation() }
        catch { stop(); throw error }
    }

    private func completeStartup(_ result: Result<Void, any Error>) {
        let continuation = startup; startup = nil; continuation?.resume(with: result)
    }
    func stop() {
        let work = { [self] in
            ready = false
            listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
            listener?.cancel(); listener = nil
            let active = Array(clients.values); clients.removeAll()
            for client in active { client.finish() }
            completeStartup(.failure(CancellationError()))
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { work() }
        else { queue.sync(execute: work) }
    }
    func snapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.observed) } }
    }
    private func accept(_ connection: NWConnection) {
        guard ready, clients.count < 8,
              case let .hostPort(host, _) = connection.endpoint,
              case let .ipv4(address) = host, address == IPv4Address("127.0.0.1")! else { connection.cancel(); return }
        let client = MockMihomoConnection(connection: connection, server: self)
        clients[client.id] = client; client.start()
    }
    fileprivate func remove(_ id: UUID) { clients.removeValue(forKey: id) }
    fileprivate func handle(_ request: MockMihomoRequest, client: MockMihomoConnection) {
        guard request.headers["host"] == "127.0.0.1:\(port)", request.headers["origin"] == allowedOrigin else {
            observed.rejectedRequests += 1; client.http(status: 403, body: Data()); return
        }
        let parsed = URLComponents(string: baseURL.absoluteString + request.target)
        guard let parsed, request.target.hasPrefix("/") else {
            observed.rejectedRequests += 1; client.http(status: 400, body: Data()); return
        }
        if request.method == "OPTIONS", parsed.path == "/version" {
            let requested = request.headers["access-control-request-headers"]?.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            guard request.headers["access-control-request-method"] == "GET", requested.contains("authorization") else {
                observed.rejectedRequests += 1; client.http(status: 403, body: Data()); return
            }
            observed.preflights += 1
            client.http(status: 204, body: Data(), headers: corsHeaders + [
                "Access-Control-Allow-Methods: GET, OPTIONS", "Access-Control-Allow-Headers: Authorization",
                "Access-Control-Allow-Private-Network: true", "Access-Control-Max-Age: 0"
            ])
        } else if request.method == "GET", parsed.path == "/version" {
            guard request.headers["authorization"] == "Bearer \(Self.fixtureToken)" else {
                observed.rejectedRequests += 1; client.http(status: 401, body: Data(), headers: corsHeaders); return
            }
            observed.authorizedRESTRequests += 1
            client.http(status: 200, body: Data(#"{"version":"fixture-mihomo","meta":true}"#.utf8), headers: corsHeaders)
        } else if request.method == "GET", parsed.path == "/traffic" {
            let tokens = parsed.queryItems?.filter { $0.name == "token" } ?? []
            guard tokens.count == 1, tokens.first?.value == Self.fixtureToken,
                  request.headers["upgrade"]?.lowercased() == "websocket",
                  request.headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
                  request.headers["sec-websocket-version"] == "13",
                  let key = request.headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else {
                observed.rejectedRequests += 1; client.http(status: 401, body: Data(), headers: corsHeaders); return
            }
            observed.authorizedWebSocketHandshakes += 1
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            client.webSocket(accept: accept, json: Data(#"{"up":128,"down":256}"#.utf8))
        } else {
            observed.rejectedRequests += 1; client.http(status: 404, body: Data(), headers: corsHeaders)
        }
    }
    private var corsHeaders: [String] { ["Access-Control-Allow-Origin: \(allowedOrigin)", "Vary: Origin"] }
}

private struct MockMihomoRequest {
    let method: String
    let target: String
    let headers: [String: String]
    init(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw ZashDockError.server("无效 mock HTTP。") }
        let lines = text.components(separatedBy: "\r\n")
        let words = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[2] == "HTTP/1.1" else { throw ZashDockError.server("无效 mock 请求行。") }
        method = String(words[0]); target = String(words[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw ZashDockError.server("无效 mock 标头。") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, headers[name] == nil else { throw ZashDockError.server("重复 mock 标头。") }
            headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
    }
}

private final class MockMihomoConnection: @unchecked Sendable {
    let id = UUID()
    private let connection: NWConnection
    private weak var server: MockMihomoServer?
    private var bytes = Data()
    private var responded = false
    private var closed = false
    init(connection: NWConnection, server: MockMihomoServer) { self.connection = connection; self.server = server }
    func start() {
        guard let server else { return }
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
            if case .cancelled = state { self?.finish() }
        }
        connection.start(queue: server.queue)
        server.queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish() }
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] content, _, complete, error in
            guard let self, !self.closed, !self.responded else { return }
            if let content { self.bytes.append(content) }
            guard self.bytes.count <= 8192 else { self.http(status: 431, body: Data()); return }
            if let end = self.bytes.range(of: Data([13, 10, 13, 10])) {
                guard end.upperBound == self.bytes.count else { self.http(status: 400, body: Data()); return }
                do {
                    let request = try MockMihomoRequest(self.bytes.subdata(in: 0..<end.lowerBound))
                    self.server?.handle(request, client: self)
                } catch { self.http(status: 400, body: Data()) }
            } else if complete || error != nil { self.finish() }
            else { self.receive() }
        }
    }
    func http(status: Int, body: Data, headers: [String] = []) {
        guard !closed, !responded else { return }; responded = true
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 431: "Request Header Fields Too Large"][status] ?? "Error"
        let lines = ["HTTP/1.1 \(status) \(reason)", "Content-Length: \(body.count)", "Content-Type: application/json", "Connection: close", "Cache-Control: no-store"] + headers
        var encoded = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8); encoded.append(body)
        connection.send(content: encoded, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }
    func webSocket(accept: String, json: Data) {
        guard !closed, !responded, json.count < 126 else { finish(); return }; responded = true
        var encoded = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
        encoded.append(contentsOf: [0x81, UInt8(json.count)]) // FIN, text, unmasked server frame.
        encoded.append(json)
        connection.send(content: encoded, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.finish(); return }
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] _, _, _, _ in self?.finish() }
        })
    }
    func finish() {
        guard !closed else { return }; closed = true
        connection.stateUpdateHandler = nil; connection.cancel(); server?.remove(id)
    }
}
