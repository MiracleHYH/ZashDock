import Foundation
import Network
import Darwin

enum StaticHTTPBounds {
    static let chunkBytes = 65_536
    static let connections = 32
    static let bufferedBytes = chunkBytes * connections
}

/// Internal counters for regression tests; never exposed over HTTP or to web content.
struct HTTPTransferStatistics: Sendable {
    var bytesRead: Int64 = 0
    var bufferedBytes = 0
    var peakBufferedBytes = 0
    var activeConnections = 0
}

/// A static-only HTTP/1.1 listener pinned to one validated version directory and IPv4 loopback.
@MainActor
public final class LoopbackHTTPServer {
    public static let healthcheckPath = "/__zashdock_health"
    public let port: UInt16
    public let versionID: String
    public let nonce: String
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    public var healthcheckURL: URL { baseURL.appendingPathComponent("__zashdock_health") }
    private let core: StaticServerCore
    var transferStatistics: HTTPTransferStatistics { core.transferStatistics() }

    public init(root: URL, port: UInt16, versionID: String? = nil) throws {
        guard port >= 1024 else { throw ZashDockError.invalidConfiguration("本地服务端口必须在 1024–65535 之间。") }
        let id = versionID ?? root.deletingLastPathComponent().lastPathComponent
        guard !id.isEmpty, id.utf8.count <= 128,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }) else {
            throw ZashDockError.invalidConfiguration("网页版本标识无效。")
        }
        self.port = port; self.versionID = id; self.nonce = UUID().uuidString
        core = try StaticServerCore(root: root, port: port, versionID: id, nonce: nonce)
    }

    /// Returns only after the requested endpoint is really bound and the listener is ready.
    public func start() async throws -> URL {
        let core = core
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                core.start { continuation.resume(with: $0) }
            }
        } onCancel: { core.stop() }
        do { try Task.checkCancellation() }
        catch { core.stop(); throw error }
        return result
    }

    public func stop() { core.stop() }
    deinit { core.stop() }
}

/// Every mutable property below is confined to queue. Cross-queue entry points enqueue or synchronize.
private final class StaticServerCore: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.zashdock.mac.static-http")
    let rootDescriptor: Int32
    let port: UInt16
    let versionID: String
    let nonce: String
    let origin: String
    private var listener: NWListener?
    private var ready = false
    private var generation = UUID()
    private var startup: (@Sendable (Result<URL, any Error>) -> Void)?
    private var clients: [UUID: StaticHTTPConnection] = [:]
    private var statistics = HTTPTransferStatistics()
    private let queueKey = DispatchSpecificKey<UInt8>()

    init(root: URL, port: UInt16, versionID: String, nonce: String) throws {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ZashDockError.server("无法安全打开已安装的网页目录。") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor); throw ZashDockError.server("网页服务根目录无效。")
        }
        self.rootDescriptor = descriptor; self.port = port; self.versionID = versionID
        self.nonce = nonce; origin = "http://127.0.0.1:\(port)"
        queue.setSpecific(key: queueKey, value: 1)
    }
    deinit { close(rootDescriptor) }

    func start(completion: @escaping @Sendable (Result<URL, any Error>) -> Void) {
        queue.async { [self] in
            if ready { completion(.success(URL(string: origin)!)); return }
            guard startup == nil else { completion(.failure(ZashDockError.server("本地服务正在启动。"))); return }
            let token = UUID(); generation = token; startup = completion
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: NWEndpoint.Port(rawValue: port)!)
                parameters.allowLocalEndpointReuse = false
                parameters.includePeerToPeer = false
                let newListener = try NWListener(using: parameters)
                listener = newListener
                newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                    guard let self, self.generation == token else { return }
                    switch state {
                    case .ready:
                        guard newListener?.port?.rawValue == self.port else {
                            self.failStartup("本地服务绑定了非预期端口。"); return
                        }
                        self.ready = true
                        self.finishStartup(.success(URL(string: self.origin)!))
                    case .failed(let error): self.failStartup("无法绑定 127.0.0.1:\(self.port)：\(error.localizedDescription)")
                    case .cancelled:
                        self.ready = false
                        self.finishStartup(.failure(CancellationError()))
                    default: break
                    }
                }
                newListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                newListener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.generation == token, self.startup != nil else { return }
                    self.failStartup("本地服务绑定超时，请确认端口可用。")
                }
            } catch { failStartup("无法创建本地服务：\(error.localizedDescription)") }
        }
    }
    func stop() {
        let cancellation = DispatchSemaphore(value: 0)
        let work = { [self] in
            generation = UUID(); ready = false
            if let listener {
                listener.newConnectionHandler = nil
                listener.stateUpdateHandler = { state in
                    if case .cancelled = state { cancellation.signal() }
                }
                listener.cancel(); self.listener = nil
            } else { cancellation.signal() }
            let connections = Array(clients.values); clients.removeAll()
            for client in connections { client.finish() }
            finishStartup(.failure(CancellationError()))
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { work() }
        else {
            queue.sync(execute: work)
            // .cancelled confirms Network has released the bound listener before a transaction rebinds.
            _ = cancellation.wait(timeout: .now() + 2)
        }
    }
    private func finishStartup(_ result: Result<URL, any Error>) {
        let completion = startup; startup = nil; completion?(result)
    }
    private func failStartup(_ message: String) {
        ready = false; listener?.cancel(); listener = nil
        finishStartup(.failure(ZashDockError.server(message)))
    }
    private func accept(_ connection: NWConnection) {
        guard ready, clients.count < StaticHTTPBounds.connections else { connection.cancel(); return }
        // The bound endpoint already excludes all external interfaces. Check peer type as defense in depth.
        guard case let .hostPort(host, _) = connection.endpoint,
              case let .ipv4(address) = host, address == IPv4Address("127.0.0.1")! else { connection.cancel(); return }
        let client = StaticHTTPConnection(connection: connection, server: self)
        clients[client.id] = client; client.start()
    }
    func remove(_ id: UUID) { clients.removeValue(forKey: id) }
    func recordRead(_ count: Int) { statistics.bytesRead += Int64(count) }
    func reserveBuffer(_ count: Int) -> Bool {
        guard count <= StaticHTTPBounds.chunkBytes, statistics.bufferedBytes + count <= StaticHTTPBounds.bufferedBytes else { return false }
        statistics.bufferedBytes += count
        statistics.peakBufferedBytes = max(statistics.peakBufferedBytes, statistics.bufferedBytes)
        return true
    }
    func releaseBuffer(_ count: Int) { statistics.bufferedBytes -= count }
    func transferStatistics() -> HTTPTransferStatistics {
        let snapshot = { [self] in
            var result = statistics; result.activeConnections = clients.count; return result
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { return snapshot() }
        return queue.sync(execute: snapshot)
    }

    func response(to request: HTTPRequest) -> HTTPResponse {
        guard request.headers["host"] == "127.0.0.1:\(port)" else { return .error(400) }
        if let originHeader = request.headers["origin"], originHeader != origin { return .error(403) }
        if request.headers["sec-fetch-site"]?.lowercased() == "cross-site" { return .error(403) }
        guard request.headers["service-worker"] == nil,
              request.headers["sec-fetch-dest"]?.lowercased() != "serviceworker" else { return .error(403) }
        guard request.method == "GET" || request.method == "HEAD" else { return .error(405) }
        guard request.headers["transfer-encoding"] == nil,
              request.headers["content-length"].map({ $0 == "0" }) ?? true else { return .error(400) }
        do {
            let path = try safePath(request.target)
            if path == ["__zashdock_health"] {
                let data = try JSONSerialization.data(withJSONObject: ["nonce": nonce, "version": versionID], options: .sortedKeys)
                return HTTPResponse(status: 200, mime: "application/json; charset=utf-8", body: data)
            }
            let components = path.isEmpty ? ["index.html"] : path
            do { return try openFile(components, head: request.method == "HEAD") }
            catch FileReadError.missing {
                guard components.last.map({ !$0.contains(".") }) ?? false else { return .error(404) }
                return try openFile(["index.html"], head: request.method == "HEAD")
            }
        } catch FileReadError.forbidden { return .error(403) }
        catch FileReadError.tooLarge { return .error(413) }
        catch FileReadError.changed { return .error(409) }
        catch FileReadError.missing { return .error(404) }
        catch { return .error(400) }
    }
    private func safePath(_ target: String) throws -> [String] {
        guard target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("#"), target.utf8.count <= 4_096,
              let decoded = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]).removingPercentEncoding,
              !decoded.contains("\\"), !decoded.contains("%"), !decoded.contains("\0"),
              decoded.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw FileReadError.forbidden }
        if decoded == "/" { return [] }
        var path = String(decoded.dropFirst())
        if path.hasSuffix("/") { path.removeLast() }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= 32,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw FileReadError.forbidden }
        return components
    }
    private enum FileReadError: Error { case missing, forbidden, tooLarge, changed }
    private func openFile(_ components: [String], head: Bool) throws -> HTTPResponse {
        var descriptor = dup(rootDescriptor)
        guard descriptor >= 0 else { throw FileReadError.forbidden }
        defer { if descriptor >= 0 { close(descriptor) } }
        for (index, component) in components.enumerated() {
            let last = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (last ? 0 : O_DIRECTORY)
            let next = openat(descriptor, component, flags)
            guard next >= 0 else {
                if errno == ENOENT { throw FileReadError.missing }
                throw FileReadError.forbidden
            }
            close(descriptor); descriptor = next
        }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw FileReadError.forbidden }
        guard before.st_size >= 0, before.st_size <= 64 * 1_024 * 1_024 else { throw FileReadError.tooLarge }
        let ext = (components.last! as NSString).pathExtension.lowercased()
        let mime = Self.mime[ext] ?? "application/octet-stream"
        if head { return HTTPResponse(status: 200, mime: mime, payload: .metadata(length: Int(before.st_size))) }
        let stream = StaticFileStream(descriptor: descriptor, initial: before)
        descriptor = -1 // Ownership moves to the bounded stream; every error/close releases the fd.
        return HTTPResponse(status: 200, mime: mime, payload: .file(stream))
    }
    private static let mime = [
        "html": "text/html; charset=utf-8", "css": "text/css; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8", "map": "application/json; charset=utf-8", "webmanifest": "application/manifest+json", "svg": "image/svg+xml",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf", "wasm": "application/wasm", "txt": "text/plain; charset=utf-8", "mp3": "audio/mpeg"
    ]
}

private struct HTTPRequest {
    let method: String; let target: String; let headers: [String: String]
    init(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw ZashDockError.server("无效 HTTP 请求。") }
        let lines = text.components(separatedBy: "\r\n")
        let words = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[2] == "HTTP/1.1" || words[2] == "HTTP/1.0",
              !words[0].isEmpty, !words[1].isEmpty else { throw ZashDockError.server("无效 HTTP 请求行。") }
        method = String(words[0]); target = String(words[1])
        var result: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.contains("\r"), !line.contains("\n"),
                  let colon = line.firstIndex(of: ":") else { throw ZashDockError.server("无效 HTTP 标头。") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }), result[name] == nil else {
                throw ZashDockError.server("重复或无效 HTTP 标头。")
            }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 || $0.value == 9 }) else { throw ZashDockError.server("HTTP 标头含控制字符。") }
            result[name] = value
        }
        headers = result
    }
}
private struct HTTPResponse {
    enum Payload {
        case data(Data)
        case file(StaticFileStream)
        case metadata(length: Int)
        var length: Int {
            switch self {
            case .data(let data): data.count
            case .file(let stream): stream.length
            case .metadata(let length): length
            }
        }
    }
    let status: Int; let mime: String; let payload: Payload
    init(status: Int, mime: String, body: Data) { self.status = status; self.mime = mime; self.payload = .data(body) }
    init(status: Int, mime: String, payload: Payload) { self.status = status; self.mime = mime; self.payload = payload }
    static func error(_ status: Int) -> HTTPResponse { HTTPResponse(status: status, mime: "text/plain; charset=utf-8", body: Data("\(status)\n".utf8)) }
    func encodedHeaders(version: String) -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict", 413: "Content Too Large", 431: "Request Header Fields Too Large"]
        var text = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Length: \(payload.length)\r\nContent-Type: \(mime)\r\nConnection: close\r\nCache-Control: no-store, max-age=0\r\nPragma: no-cache\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nCross-Origin-Resource-Policy: same-origin\r\nX-ZashDock-Version: \(version)\r\n"
        if status == 405 { text += "Allow: GET, HEAD\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }
}

/// Owns one openat-pinned regular file. At most one 64 KiB chunk is read ahead per connection.
private final class StaticFileStream {
    let length: Int
    private let descriptor: Int32
    private let initial: stat
    private var remaining: Int
    init(descriptor: Int32, initial: stat) {
        self.descriptor = descriptor; self.initial = initial; length = Int(initial.st_size); remaining = length
    }
    deinit { close(descriptor) }
    func nextChunk() throws -> Data? {
        try validate()
        guard remaining > 0 else { return nil }
        let size = min(StaticHTTPBounds.chunkBytes, remaining)
        var data = Data(count: size), offset = 0
        while offset < size {
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), size - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ZashDockError.server("网页文件在读取期间被截断。") }
            offset += count
        }
        try validate()
        remaining -= size
        return data
    }
    private func validate() throws {
        var current = stat()
        guard fstat(descriptor, &current) == 0, current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == initial.st_dev, current.st_ino == initial.st_ino, current.st_size == initial.st_size,
              current.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec, current.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else {
            throw ZashDockError.server("网页文件在读取期间发生变化。")
        }
    }
}

private final class StaticHTTPConnection: @unchecked Sendable {
    let id = UUID()
    private let connection: NWConnection
    private weak var server: StaticServerCore?
    private var received = Data()
    private var responded = false
    private var closed = false
    private var response: HTTPResponse?
    private var pendingBytes = 0
    private enum SendNext: Sendable { case body, finish }
    init(connection: NWConnection, server: StaticServerCore) { self.connection = connection; self.server = server }
    func start() {
        guard let server else { return }
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
            if case .cancelled = state { self?.finish() }
        }
        connection.start(queue: server.queue)
        server.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.closed, !self.responded else { return }; self.send(.error(408), head: false)
        }
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] content, _, complete, error in
            guard let self, !self.closed, !self.responded else { return }
            if let content { self.received.append(content) }
            if let range = self.received.range(of: Data([13,10,13,10])) {
                guard range.upperBound <= 16_384 else { self.send(.error(431), head: false); return }
                guard range.upperBound == self.received.count else { self.send(.error(400), head: false); return }
                do {
                    let request = try HTTPRequest(self.received.subdata(in: 0..<range.lowerBound))
                    guard let server = self.server else { self.finish(); return }
                    self.send(server.response(to: request), head: request.method == "HEAD")
                } catch { self.send(.error(400), head: false) }
            } else if self.received.count >= 16_384 { self.send(.error(431), head: false) }
            else if complete || error != nil { self.finish() }
            else { self.receive() }
        }
    }
    private func send(_ response: HTTPResponse, head: Bool) {
        guard !closed, !responded, let server else { return }; responded = true
        received.removeAll(keepingCapacity: false)
        self.response = head ? nil : response
        sendPiece(response.encodedHeaders(version: server.versionID), next: head ? .finish : .body)
        server.queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish() }
    }
    private func sendNextChunk() {
        guard !closed, let response, let server else { finish(); return }
        switch response.payload {
        case .data(let data):
            self.response = nil
            sendPiece(data, next: .finish)
        case .metadata: finish()
        case .file(let stream):
            do {
                guard let chunk = try stream.nextChunk() else { finish(); return }
                server.recordRead(chunk.count)
                sendPiece(chunk, next: .body)
            } catch { finish() } // A changed/truncated file closes an incomplete response; no stale tail is served.
        }
    }
    private func sendPiece(_ data: Data, next: SendNext) {
        guard !closed, pendingBytes == 0, let server, server.reserveBuffer(data.count) else { finish(); return }
        pendingBytes = data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            self.server?.releaseBuffer(self.pendingBytes); self.pendingBytes = 0
            guard error == nil else { self.finish(); return }
            switch next {
            case .body: self.sendNextChunk()
            case .finish: self.finish()
            }
        })
    }
    func finish() {
        guard !closed else { return }; closed = true
        response = nil
        if pendingBytes > 0 { server?.releaseBuffer(pendingBytes); pendingBytes = 0 }
        connection.stateUpdateHandler = nil; connection.cancel(); server?.remove(id)
    }
}
