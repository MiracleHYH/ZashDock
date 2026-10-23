import Foundation
import CryptoKit
import Testing
@testable import ZashDockCore

private final class CatalogProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var bytes = 0
    private var stopped = false
    func start(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    func delivered(_ count: Int) { lock.withLock { bytes += count } }
    func stop() { lock.withLock { stopped = true } }
    var didStart: Bool { lock.withLock { !requests.isEmpty } }
    var deliveredBytes: Int { lock.withLock { bytes } }
    var didStop: Bool { lock.withLock { stopped } }
    var request: URLRequest? { lock.withLock { requests.first } }
}

private struct CatalogStub: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var responseURL: URL?
    var nonHTTP = false
    var error: URLError.Code?
    var pauseBeforeHeaders = false
    var pauseAfterBody = false
    let probe = CatalogProbe()
}

/// Session-local interception; never registered with URLProtocol.registerClass.
private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    private final class Queue: @unchecked Sendable {
        private let lock = NSLock()
        private var stubs: [CatalogStub] = []
        func install(_ values: [CatalogStub]) { lock.withLock { stubs = values } }
        func take() -> CatalogStub? { lock.withLock { stubs.isEmpty ? nil : stubs.removeFirst() } }
    }
    private static let queue = Queue()
    private let lock = NSLock()
    private var worker: Task<Void, Never>?
    private var probe: CatalogProbe?
    private var cancelled = false

    static func install(_ stubs: [CatalogStub]) { queue.install(stubs) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canInit(with task: URLSessionTask) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.queue.take() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        lock.withLock { probe = stub.probe }
        stub.probe.start(request)
        let task = Task { @Sendable [self, stub] in
            do {
                if stub.pauseBeforeHeaders { try await Task.sleep(for: .seconds(30)) }
                try Task.checkCancellation()
                if let error = stub.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
                let url = stub.responseURL ?? request.url!
                let response: URLResponse = stub.nonHTTP
                    ? URLResponse(url: url, mimeType: "application/json", expectedContentLength: stub.body.count, textEncodingName: "utf-8")
                    : HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !stub.body.isEmpty {
                    client?.urlProtocol(self, didLoad: stub.body)
                    stub.probe.delivered(stub.body.count)
                }
                if stub.pauseAfterBody { try await Task.sleep(for: .seconds(30)) }
                try Task.checkCancellation()
                client?.urlProtocolDidFinishLoading(self)
            } catch { /* stopLoading owns cancellation; never emit delayed response bytes. */ }
        }
        lock.withLock { worker = task; if cancelled { task.cancel() } }
    }
    override func stopLoading() {
        let current = lock.withLock { cancelled = true; return (worker, probe) }
        current.0?.cancel(); current.1?.stop()
    }
}

@Suite(.serialized)
struct ReleaseClientTests {
    private let apiURL = URL(string: "https://api.github.com/repos/Zephyruso/zashboard/releases/latest")!
    private func client(_ stubs: [CatalogStub]) -> ReleaseClient {
        CatalogURLProtocol.install(stubs)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        return ReleaseClient(sessionConfiguration: configuration)
    }
    private func object(tag: String = "v9.8.7") -> [String: Any] {
        let digest = SHA256.hash(data: Data(tag.utf8)).map { String(format: "%02x", $0) }.joined()
        return ["tag_name": tag, "published_at": "2026-10-23T01:00:00Z", "draft": false, "prerelease": false,
            "assets": [["name": "dist.zip", "state": "uploaded", "size": 123, "digest": "sha256:" + digest,
                        "browser_download_url": "https://github.com/Zephyruso/zashboard/releases/download/\(tag)/dist.zip"]]]
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func error(_ operation: () async throws -> ZashboardRelease) async -> ReleaseCatalogError? {
        do { _ = try await operation(); Issue.record("Expected a catalog failure"); return nil }
        catch let error as ReleaseCatalogError { return error }
        catch { Issue.record("Unexpected error type: \(type(of: error))"); return nil }
    }
    private func wait(until condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func successfulLatestUsesOnlyOfficialMetadataRequestWithoutAuthentication() async throws {
        let response = CatalogStub(body: try json(object())), client = client([response])
        let latest = try await client.latest()
        #expect(latest.tag == "v9.8.7")
        #expect(response.probe.request?.url == apiURL)
        #expect(response.probe.request?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(response.probe.request?.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(response.probe.request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test(arguments: [403, 429])
    func primaryRateLimitHasStatusAndResetDateWithoutExposingBody(status: Int) async {
        let reset = Int64(Date().timeIntervalSince1970) + 3600
        let privateBody = "rate limit fixture: private response body must not be displayed"
        let response = CatalogStub(status: status, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(reset)], body: Data(privateBody.utf8))
        let client = client([response]), failure = await error { try await client.latest() }
        #expect(failure == .rateLimited(status: status, retryAt: Date(timeIntervalSince1970: TimeInterval(reset))))
        #expect(failure?.localizedDescription.contains(privateBody) == false)
    }

    @Test(arguments: [403, 429])
    func retryAfterProvidesABoundedRetryDate(status: Int) async throws {
        let client = client([CatalogStub(status: status, headers: ["Retry-After": "60", "X-RateLimit-Remaining": "10"])])
        let before = Date(), failure = await error { try await client.latest() }, after = Date()
        guard case let .rateLimited(actualStatus, retryAt) = failure else { Issue.record("Expected rate limit"); return }
        let retry = try #require(retryAt)
        #expect(actualStatus == status)
        #expect(retry >= before.addingTimeInterval(60) && retry <= after.addingTimeInterval(60))
    }

    @Test(arguments: ["bad", "-1", "99999999999999999999999999", "604801"])
    func malformedRetryHeadersDoNotInventDates(value: String) async {
        let client = client([CatalogStub(status: 429, headers: ["Retry-After": value, "X-RateLimit-Reset": value])])
        #expect(await error { try await client.latest() } == .rateLimited(status: 429, retryAt: nil))
    }

    @Test func primaryLimitWithoutUsableResetAndBare429RemainExplicit() async {
        let client = client([
            CatalogStub(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "not-a-date"]),
            CatalogStub(status: 429)
        ])
        #expect(await error { try await client.latest() } == .rateLimited(status: 403, retryAt: nil))
        #expect(await error { try await client.latest() } == .rateLimited(status: 429, retryAt: nil))
    }

    @Test func secondary429DoesNotTreatPrimaryResetAsItsRetryTime() async {
        let reset = Int64(Date().timeIntervalSince1970) + 3600
        let client = client([CatalogStub(status: 429, headers: ["X-RateLimit-Remaining": "12", "X-RateLimit-Reset": String(reset)])])
        #expect(await error { try await client.latest() } == .rateLimited(status: 429, retryAt: nil))
    }

    @Test(arguments: [403, 404, 500, 503])
    func ordinaryHTTPFailuresAreNotGuessedToBeOfflineOrLimited(status: Int) async {
        let client = client([CatalogStub(status: status, headers: ["Retry-After": "invalid", "X-RateLimit-Remaining": "12"], body: Data("not for display".utf8))])
        #expect(await error { try await client.latest() } == .httpStatus(status))
    }

    @Test(arguments: [
        "http://api.github.com/repos/Zephyruso/zashboard/releases/latest",
        "https://attacker.example/repos/Zephyruso/zashboard/releases/latest",
        "https://api.github.com/repos/another/project/releases/latest",
        "https://user@api.github.com/repos/Zephyruso/zashboard/releases/latest",
        "https://api.github.com:444/repos/Zephyruso/zashboard/releases/latest"
    ])
    func untrustedFinalURLsAreRejectedEvenWithValidJSON(text: String) async throws {
        let client = client([CatalogStub(body: try json(object()), responseURL: URL(string: text)!)])
        #expect(await error { try await client.latest() } == .untrustedSource)
    }

    @Test func unsupportedRedirectAndNonHTTPResponsesAreDistinct() async {
        let client = client([CatalogStub(status: 302, headers: ["Location": "https://attacker.example/releases"]), CatalogStub(nonHTTP: true)])
        #expect(await error { try await client.latest() } == .untrustedSource)
        #expect(await error { try await client.latest() } == .invalidResponse)
    }

    @Test func catalogByteLimitAcceptsExactlyEightMiBAndRejectsOneMore() async throws {
        let maximum = 8_388_608
        var exact = try json(object())
        exact.append(Data(repeating: 0x20, count: maximum - exact.count))
        var oversized = exact; oversized.append(0x20)
        let client = client([CatalogStub(body: exact), CatalogStub(body: oversized)])
        #expect(try await client.latest().tag == "v9.8.7")
        #expect(await error { try await client.latest() } == .responseTooLarge)
    }

    @Test func declaredOversizeIsRejectedWithoutConsumingItsBody() async {
        let client = client([CatalogStub(headers: ["Content-Length": "8388609"])])
        #expect(await error { try await client.latest() } == .responseTooLarge)
    }

    @Test(arguments: [false, true])
    func malformedJSONOrMissingMetadataIsExplicit(metadata: Bool) async throws {
        var release = object()
        release["assets"] = [["name": "dist.zip", "state": "uploaded", "size": 123, "browser_download_url": "https://attacker.example/dist.zip"]]
        let body = metadata ? try json(release) : Data("<html>not the GitHub API</html>".utf8)
        let client = client([CatalogStub(body: body)])
        #expect(await error { try await client.latest() } == (metadata ? .invalidMetadata : .invalidJSON))
    }

    @Test(arguments: ["asset-source", "digest", "size"])
    func invalidOfficialAssetMetadataCannotBeInstalled(field: String) async throws {
        var release = object(), assets = try #require(object()["assets"] as? [[String: Any]])
        switch field {
        case "asset-source": assets[0]["browser_download_url"] = "https://attacker.example/dist.zip"
        case "digest": assets[0]["digest"] = "sha256:not-a-valid-digest"
        default: assets[0]["size"] = 0
        }
        release["assets"] = assets
        let client = client([CatalogStub(body: try json(release))])
        #expect(await error { try await client.latest() } == .invalidMetadata)
    }

    @Test func networkErrorsRemainNetworkErrorsAndCancellationIsNormalized() async throws {
        let client = client([CatalogStub(error: .notConnectedToInternet), CatalogStub(error: .cancelled)])
        do { _ = try await client.latest(); Issue.record("Expected network failure") }
        catch { #expect((error as? URLError)?.code == .notConnectedToInternet) }
        await #expect(throws: CancellationError.self) { try await client.latest() }
    }

    @Test func preCancelledRequestDoesNotStartOrReturnFallback() async throws {
        let stub = CatalogStub(body: try json(object())), client = client([stub])
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await client.latest() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!stub.probe.didStart)
    }

    @Test(arguments: [false, true])
    func cancellationWhileAwaitingHeadersOrBodyStopsTheRequest(waitForBody: Bool) async throws {
        let stub = CatalogStub(body: waitForBody ? Data("{".utf8) : Data(), pauseBeforeHeaders: !waitForBody, pauseAfterBody: waitForBody)
        let client = client([stub]), task = Task { try await client.latest() }
        try await wait { waitForBody ? stub.probe.deliveredBytes > 0 : stub.probe.didStart }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await wait { stub.probe.didStop }
    }

    @MainActor @Test func managerFailureCanRetryAndCheckUsesOneLatestRequest() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let success = CatalogStub(body: try json(object()))
        let client = client([CatalogStub(status: 403, headers: ["X-RateLimit-Remaining": "0"]), success])
        let store = try VersionStore(root: root)
        let manager = ZashboardUpdateManager(store: store, client: client, downloadDirectory: root.appendingPathComponent("staging"))
        await #expect(throws: ReleaseCatalogError.self) { try await manager.checkForUpdates() }
        #expect(manager.lastError?.contains("HTTP 403") == true && manager.latest == nil && !manager.isBusy)
        try await manager.checkForUpdates() // No history stub exists: a second request would fail.
        #expect(manager.lastError == nil && !manager.isBusy && manager.latest?.tag == "v9.8.7")
        #expect(success.probe.request?.url == apiURL)
        #expect(try await store.current() == nil)
    }

    @MainActor @Test func localImportNeedsNoAPIRequestOrReleaseDigest() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let forbiddenRequest = CatalogStub(status: 500), client = client([forbiddenRequest])
        let store = try VersionStore(root: root), original = try await Fixture.install(1, store: store, root: root)
        try await store.activate(original)
        let manager = ZashboardUpdateManager(store: store, client: client, downloadDirectory: root.appendingPathComponent("staging"))
        let zip = root.appendingPathComponent("any-name.zip")
        try Fixture.zip([ZIPItem(path: "index.html", data: Data("<html><div id='app'>local</div></html>".utf8))]).write(to: zip)
        let candidate = try await manager.stageLocalZIP(zip)
        #expect(candidate.source == .localArchive && candidate.tag == "本地导入")
        #expect(try await store.current() == original && !forbiddenRequest.probe.didStart)
        try await manager.commit(version: candidate)
        #expect(try await store.current() == candidate)
        #expect(!FileManager.default.fileExists(atPath: original.directoryURL.path))
    }

    @MainActor @Test func managerCancellationDoesNotBecomeAnInstallationFailure() async throws {
        let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let stub = CatalogStub(pauseBeforeHeaders: true), client = client([stub])
        let store = try VersionStore(root: root)
        let manager = ZashboardUpdateManager(store: store, client: client, downloadDirectory: root.appendingPathComponent("staging"))
        let task = Task { try await manager.checkForUpdates() }
        try await wait { stub.probe.didStart }; task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(manager.lastError == nil && !manager.isBusy && manager.latest == nil)
    }
}
