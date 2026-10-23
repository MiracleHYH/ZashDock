import Foundation
import Darwin
import Testing
@testable import ZashDockCore

private enum ServerFixture {
    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockServerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("<!doctype html><html><script src=\"/assets/app.js\"></script></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("window.ready=true;".utf8).write(to: root.appendingPathComponent("assets/app.js"))
        try Data("body{color:red}".utf8).write(to: root.appendingPathComponent("assets/app.css"))
        try Data([0,1,2,3]).write(to: root.appendingPathComponent("assets/font.woff2"))
        return root
    }
    static func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ZashDockError.server("test socket") }
        defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw ZashDockError.server("test bind") }
        var count = socklen_t(MemoryLayout<sockaddr_in>.size)
        let name = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &count) }
        }
        guard name == 0 else { throw ZashDockError.server("test getsockname") }
        return UInt16(bigEndian: address.sin_port)
    }
    static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }
    static func raw(_ request: String, port: UInt16, host: String = "127.0.0.1") async throws -> String {
        try await Task.detached {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw ZashDockError.server("test socket") }
            defer { close(descriptor) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1; setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr(host)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { throw ZashDockError.server("test connection refused") }
            let data = Data(request.utf8)
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, data.count) }
            guard written == data.count else { throw ZashDockError.server("test write") }
            var response = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 && errno == ECONNRESET && !response.isEmpty { break }
                guard count > 0 else { throw ZashDockError.server("test read timeout") }
                response.append(contentsOf: buffer.prefix(count))
                if let headerEnd = response.range(of: Data([13,10,13,10])),
                   let headers = String(data: response.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8),
                   let lengthLine = headers.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("Content-Length: ") }),
                   let length = Int(lengthLine.dropFirst("Content-Length: ".count)), response.count >= headerEnd.upperBound + length { break }
            }
            return String(decoding: response, as: UTF8.self)
        }.value
    }
    static func nonLoopbackIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == AF_INET,
                  item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}

@MainActor @Test func serverServesGETHEADMIMEAndHealthcheck() async throws {
    let root = try ServerFixture.root(), port = try ServerFixture.availablePort()
    let server = try LoopbackHTTPServer(root: root, port: port, versionID: "v-test")
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    let url = try await server.start()
    #expect(url == server.baseURL)
    let (body, response) = try await ServerFixture.request(url)
    #expect(response.statusCode == 200); #expect(String(decoding: body, as: UTF8.self).contains("<!doctype"))
    #expect(response.value(forHTTPHeaderField: "X-ZashDock-Version") == "v-test")
    #expect(response.value(forHTTPHeaderField: "Cache-Control")?.contains("no-store") == true)
    #expect(response.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
    let (headBody, head) = try await ServerFixture.request(url, method: "HEAD")
    #expect(headBody.isEmpty); #expect(head.value(forHTTPHeaderField: "Content-Length") == String(body.count))
    for (path, mime) in [("assets/app.js", "text/javascript"), ("assets/app.css", "text/css"), ("assets/font.woff2", "font/woff2")] {
        let (_, asset) = try await ServerFixture.request(url.appendingPathComponent(path))
        #expect(asset.statusCode == 200); #expect(asset.value(forHTTPHeaderField: "Content-Type")?.hasPrefix(mime) == true)
    }
    let (healthBody, health) = try await ServerFixture.request(server.healthcheckURL)
    let object = try #require(JSONSerialization.jsonObject(with: healthBody) as? [String: String])
    #expect(health.statusCode == 200); #expect(object == ["nonce": server.nonce, "version": "v-test"])
}

@MainActor @Test func serverSPAFallbackOnlyForRoutes() async throws {
    let root = try ServerFixture.root(), server = try LoopbackHTTPServer(root: root, port: ServerFixture.availablePort(), versionID: "test")
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    let url = try await server.start()
    let (_, route) = try await ServerFixture.request(url.appendingPathComponent("proxies/groups"))
    let (_, missingAsset) = try await ServerFixture.request(url.appendingPathComponent("assets/missing.js"))
    #expect(route.statusCode == 200); #expect(missingAsset.statusCode == 404)
}

@MainActor @Test func serverRejectsHostOriginServiceWorkerAndMutation() async throws {
    let root = try ServerFixture.root(), port = try ServerFixture.availablePort()
    let server = try LoopbackHTTPServer(root: root, port: port, versionID: "test")
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    let url = try await server.start()
    for header in [["Origin": "https://attacker.example"], ["Origin": "null"], ["Sec-Fetch-Site": "cross-site"], ["Service-Worker": "script"], ["Sec-Fetch-Dest": "serviceworker"]] {
        let (_, response) = try await ServerFixture.request(url, headers: header)
        #expect(response.statusCode == 403)
        #expect(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
    }
    let (_, sameOrigin) = try await ServerFixture.request(url, headers: ["Origin": url.absoluteString])
    #expect(sameOrigin.statusCode == 200)
    let (_, post) = try await ServerFixture.request(url, method: "POST")
    #expect(post.statusCode == 405); #expect(post.value(forHTTPHeaderField: "Allow") == "GET, HEAD")
    let host = try await ServerFixture.raw("GET / HTTP/1.1\r\nHost: attacker.example:\(port)\r\n\r\n", port: port)
    #expect(host.hasPrefix("HTTP/1.1 400"))
    let duplicate = try await ServerFixture.raw("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nHost: 127.0.0.1:\(port)\r\n\r\n", port: port)
    #expect(duplicate.hasPrefix("HTTP/1.1 400"))
    let body = try await ServerFixture.raw("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 1\r\n\r\nx", port: port)
    #expect(body.hasPrefix("HTTP/1.1 400"))
}

@MainActor @Test func serverRejectsTraversalSymlinksAndLargeHeaders() async throws {
    let root = try ServerFixture.root(), port = try ServerFixture.availablePort()
    let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
    try Data("secret".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside.deletingLastPathComponent())
    let server = try LoopbackHTTPServer(root: root, port: port, versionID: "test")
    defer { server.stop(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    _ = try await server.start()
    for path in ["/../outside.txt", "/%2e%2e/outside.txt", "/%252e%252e/outside.txt", "/%00", "/a%5cb", "/a//b", "/link.txt", "/linked/\(outside.lastPathComponent)"] {
        let response = try await ServerFixture.raw("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n", port: port)
        #expect(response.hasPrefix("HTTP/1.1 403")); #expect(!response.contains("secret"))
    }
    let huge = try await ServerFixture.raw("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-Padding: \(String(repeating: "x", count: 17_000))\r\n\r\n", port: port)
    #expect(huge.hasPrefix("HTTP/1.1 431"))
}

@MainActor @Test func serverConfirmsBindingConflictAndOnlyLoopback() async throws {
    let root = try ServerFixture.root(), port = try ServerFixture.availablePort()
    let first = try LoopbackHTTPServer(root: root, port: port, versionID: "test")
    let second = try LoopbackHTTPServer(root: root, port: port, versionID: "test")
    defer { first.stop(); second.stop(); try? FileManager.default.removeItem(at: root) }
    _ = try await first.start()
    await #expect(throws: (any Error).self) { try await second.start() }
    let (_, stillWorking) = try await ServerFixture.request(first.baseURL)
    #expect(stillWorking.statusCode == 200)
    if let address = ServerFixture.nonLoopbackIPv4() {
        await #expect(throws: (any Error).self) {
            try await ServerFixture.raw("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n", port: port, host: address)
        }
    }
    first.stop()
    _ = try await second.start()
    let (_, rebound) = try await ServerFixture.request(second.baseURL)
    #expect(rebound.statusCode == 200)
}

@MainActor @Test func serverRejectsInvalidConfigurationAndSymlinkRoot() throws {
    let root = try ServerFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: (any Error).self) { try LoopbackHTTPServer(root: root, port: 80, versionID: "test") }
    #expect(throws: (any Error).self) { try LoopbackHTTPServer(root: root, port: 9099, versionID: "bad\r\nHeader:x") }
    let symlink = root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
    #expect(throws: (any Error).self) { try LoopbackHTTPServer(root: symlink, port: 9099, versionID: "test") }
}

@MainActor @Test func serverHEADStatsMetadataWithoutReadingLargeFile() async throws {
    let root = try ServerFixture.root(), file = root.appendingPathComponent("large.bin")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 64 * 1_024 * 1_024); try handle.close()
    let server = try LoopbackHTTPServer(root: root, port: ServerFixture.availablePort(), versionID: "head-test")
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    let url = try await server.start()
    let before = server.transferStatistics.bytesRead
    let (body, response) = try await ServerFixture.request(url.appendingPathComponent("large.bin"), method: "HEAD")
    #expect(response.statusCode == 200)
    #expect(response.value(forHTTPHeaderField: "Content-Length") == String(64 * 1_024 * 1_024))
    #expect(body.isEmpty)
    #expect(server.transferStatistics.bytesRead == before)
}

@MainActor @Test func serverStreamsLargeFileWithExactContentAndBoundedBuffers() async throws {
    let root = try ServerFixture.root()
    let block = Data((0..<65_536).map { UInt8($0 % 251) })
    let file = root.appendingPathComponent("stream.bin")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    for _ in 0..<64 { try handle.write(contentsOf: block) }
    try handle.close()
    let server = try LoopbackHTTPServer(root: root, port: ServerFixture.availablePort(), versionID: "stream-test")
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    let url = try await server.start()
    let (body, response) = try await ServerFixture.request(url.appendingPathComponent("stream.bin"))
    #expect(response.statusCode == 200)
    #expect(body.count == 4 * 1_024 * 1_024)
    for offset in stride(from: 0, to: body.count, by: block.count) {
        #expect(body.subdata(in: offset..<(offset + block.count)) == block)
    }
    let statistics = server.transferStatistics
    #expect(statistics.bytesRead == Int64(body.count))
    #expect(statistics.peakBufferedBytes <= StaticHTTPBounds.chunkBytes)
}

private extension ServerFixture {
    static func slowConnection(port: UInt16) async throws -> Int32 {
        try await Task.detached {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw ZashDockError.server("slow socket") }
            var succeeded = false
            defer { if !succeeded { close(descriptor) } }
            var receiveWindow: Int32 = 4_096
            setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveWindow, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else { throw ZashDockError.server("slow connect") }
            let request = Data("GET /large.bin HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8)
            let sent = request.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, request.count) }
            guard sent == request.count else { throw ZashDockError.server("slow write") }
            succeeded = true
            return descriptor // Deliberately leave the receive window unread to exercise backpressure.
        }.value
    }
}

@MainActor @Test func serverBoundsPayloadFor32SlowLargeFileClients() async throws {
    let root = try ServerFixture.root(), file = root.appendingPathComponent("large.bin")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 64 * 1_024 * 1_024); try handle.close()
    let server = try LoopbackHTTPServer(root: root, port: ServerFixture.availablePort(), versionID: "budget-test")
    var clients: [Int32] = []
    defer { for descriptor in clients { close(descriptor) }; server.stop(); try? FileManager.default.removeItem(at: root) }
    _ = try await server.start()
    for _ in 0..<StaticHTTPBounds.connections { clients.append(try await ServerFixture.slowConnection(port: server.port)) }
    for _ in 0..<100 {
        let state = server.transferStatistics
        if state.activeConnections == StaticHTTPBounds.connections && state.bytesRead > 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let state = server.transferStatistics
    #expect(state.activeConnections == StaticHTTPBounds.connections)
    #expect(state.bytesRead > 0)
    #expect(state.bytesRead < Int64(64 * 1_024 * 1_024 * StaticHTTPBounds.connections))
    #expect(state.bufferedBytes <= StaticHTTPBounds.bufferedBytes)
    #expect(state.peakBufferedBytes <= 2 * 1_024 * 1_024)
    #expect(state.peakBufferedBytes > 0)
    server.stop()
    #expect(server.transferStatistics.activeConnections == 0)
    #expect(server.transferStatistics.bufferedBytes == 0)
}
