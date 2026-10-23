import AppKit
import Darwin
import Foundation
import Testing
import WebKit
import ZashDockCore

/// A second program occupies the former loopback port and counts every accepted connection.
/// Any accidental network access is observable; it never supplies the bootstrap HTML.
private final class OccupiedOriginSentinel: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var count = 0
    var connectionCount: Int { lock.withLock { count } }
    init(port: UInt16) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 8) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
            Darwin.close(descriptor); throw POSIXError(code)
        }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "app.zashdock.test.origin-sentinel"))
        source.setEventHandler { [weak self] in
            while true {
                let client = Darwin.accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                if let self { self.lock.withLock { self.count += 1 } }
                Darwin.close(client)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }
    func stop() { source.cancel() }
    deinit { source.cancel() }
}

/// Architecture experiment only: no storage bridge, native vault, Keychain or production data store.
@Suite(.serialized)
@MainActor
struct OriginStorageAccessTests {
    private struct Probe: Decodable {
        let origin: String
        let storage: [String: String]
        let blobBase64: String
        let blobMIME: String
        let history: History
        struct History: Decodable, Equatable { let label: String; let bytes: Int }
    }
    private let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jr1cAAAAASUVORK5CYII="
    private let database = "zashdock-origin-prototype"
    private var values: [String: String] {
        let remotes = #"[{"type":"clash","protocol":"http","host":"10.0.0.2","port":"9090","secondaryPath":"","password":"prototype-fixture-one","uuid":"22b570a8-65b8-42e3-88f3-c36b04f5892a","label":"LAN fixture"},{"type":"clash","protocol":"http","host":"vpn.example","port":"9090","secondaryPath":"mihomo","password":"prototype-fixture-two","uuid":"676f9b3f-cfde-4bcc-bbe1-c605a268d973","label":"VPN fixture"}]"#
        return ["setup/api-list": remotes, "setup/active-uuid": "676f9b3f-cfde-4bcc-bbe1-c605a268d973", "config/default-theme": "light"]
    }
    private var readScript: String {
        """
        const db = await new Promise((resolve, reject) => {
          const request = indexedDB.open('\(database)', 3);
          request.onerror = () => reject(new Error('database open failed'));
          request.onsuccess = () => resolve(request.result);
        });
        const result = await new Promise((resolve, reject) => {
          const transaction = db.transaction(['files', 'history'], 'readonly');
          const image = transaction.objectStore('files').get('background');
          const history = transaction.objectStore('history').get('sample');
          transaction.onerror = () => reject(new Error('database read failed'));
          transaction.oncomplete = () => resolve({image:image.result, history:history.result});
        });
        db.close();
        const bytes = new Uint8Array(await result.image.arrayBuffer());
        let binary = ''; for (const byte of bytes) binary += String.fromCharCode(byte);
        return JSON.stringify({origin:location.origin,storage:Object.fromEntries(Object.keys(localStorage).map(key => [key,localStorage.getItem(key)])),blobBase64:btoa(binary),blobMIME:result.image.type,history:result.history});
        """
    }
    private func document(script: String = "") -> String {
        """
        <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'"></head>
        <body><div id="app">isolated origin probe</div><script>window.firstLocalStorage = JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(key => [key,localStorage.getItem(key)])));window.originProbe = (async () => {\(script)})();</script></body></html>
        """
    }
    private func directory() throws -> URL {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockOriginProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(document(script: readScript).utf8).write(to: root.appendingPathComponent("index.html"))
        try Data(document().utf8).write(to: root.appendingPathComponent("seed.html"))
        return root
    }
    private func page(store: WKWebsiteDataStore) -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = store
        configuration.defaultNavigationPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        return WebPage(configuration: configuration)
    }
    private func load(_ page: WebPage, url: URL) async throws {
        for try await _ in page.load(URLRequest(url: url)) {}
    }
    private func simulated(_ page: WebPage, origin: URL, script: String) async throws {
        for try await _ in page.load(simulatedRequest: URLRequest(url: origin.appendingPathComponent("__zashdock_trusted_bootstrap")), responseHTML: document(script: script)) {}
    }
    private func probe(_ page: WebPage) async throws -> Probe {
        let text = try #require(try await page.callJavaScript("return await window.originProbe;") as? String)
        return try JSONDecoder().decode(Probe.self, from: Data(text.utf8))
    }
    private func assertFixture(_ probe: Probe, origin: URL, expectedStorage: [String: String]) throws {
        #expect(probe.origin == "http://127.0.0.1:\(origin.port!)")
        #expect(probe.storage == expectedStorage)
        let remotes = try JSONDecoder().decode([[String: String]].self, from: Data(try #require(probe.storage["setup/api-list"]).utf8))
        #expect(remotes.count == 2)
        #expect(probe.storage["setup/active-uuid"] == remotes[1]["uuid"])
        #expect(probe.blobBase64 == pngBase64)
        #expect(probe.blobMIME == "image/png")
        #expect(probe.history == Probe.History(label: "fictional connection", bytes: 42))
    }
    private func writeScript(storage: [String: String], restoring captured: Probe? = nil) throws -> String {
        let transfer: [String: Any] = ["storage": storage, "blobBase64": captured?.blobBase64 ?? pngBase64, "blobMIME": captured?.blobMIME ?? "image/png", "history": ["label": captured?.history.label ?? "fictional connection", "bytes": captured?.history.bytes ?? 42]]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: transfer), as: UTF8.self)
        return """
        const transfer = \(encoded);
        for (const [key,value] of Object.entries(transfer.storage)) localStorage.setItem(key,value);
        const db = await new Promise((resolve,reject) => {
          const request = indexedDB.open('\(database)',3);
          request.onupgradeneeded = () => {request.result.createObjectStore('files');request.result.createObjectStore('history');};
          request.onerror = () => reject(new Error('database create failed'));
          request.onsuccess = () => resolve(request.result);
        });
        await new Promise((resolve,reject) => {
          const transaction = db.transaction(['files','history'],'readwrite');
          const bytes = Uint8Array.from(atob(transfer.blobBase64),character => character.charCodeAt(0));
          transaction.objectStore('files').put(new Blob([bytes],{type:transfer.blobMIME}),'background');
          transaction.objectStore('history').put(transfer.history,'sample');
          transaction.oncomplete = resolve;transaction.onerror = () => reject(new Error('database write failed'));
        });
        db.close();
        return true;
        """
    }

    @Test(.timeLimit(.minutes(2)))
    func simulatedBootstrapAccessesOccupiedPersistentOriginAndRestoresBeforeRealPageInitialization() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let storeID = UUID()
        var sourceStore: WKWebsiteDataStore? = WKWebsiteDataStore(forIdentifier: storeID)
        #expect(sourceStore?.isPersistent == true)
        let oldServer = try await bindFixture(root)
        defer { oldServer.stop() }
        let oldOrigin = oldServer.baseURL
        var sourcePage: WebPage? = page(store: try #require(sourceStore))
        try await load(try #require(sourcePage), url: oldOrigin.appendingPathComponent("seed.html"))
        #expect(try await sourcePage?.callJavaScript(try writeScript(storage: values)) as? Bool == true)
        sourcePage?.stopLoading(); sourcePage = nil; sourceStore = nil
        oldServer.stop()
        let blocker = try OccupiedOriginSentinel(port: UInt16(oldOrigin.port!))
        defer { blocker.stop() }
        // Recreate the named persistent store and page without a native snapshot.
        // This remains one App process; it does not establish a cold process/OS restart guarantee.
        let reopenedStore = WKWebsiteDataStore(forIdentifier: storeID)
        let bootstrap = page(store: reopenedStore)
        defer { bootstrap.stopLoading() }
        try await simulated(bootstrap, origin: oldOrigin, script: readScript)
        try assertFixture(try await probe(bootstrap), origin: oldOrigin, expectedStorage: values)
        #expect(blocker.connectionCount == 0)
        // The trusted, non-network document can write both storage systems as well.
        var changed = values; changed["prototype/roundtrip"] = "written by simulated bootstrap"
        #expect(try await bootstrap.callJavaScript(try writeScript(storage: changed)) as? Bool == true)
        try await simulated(bootstrap, origin: oldOrigin, script: readScript)
        let captured = try await probe(bootstrap)
        try assertFixture(captured, origin: oldOrigin, expectedStorage: changed)
        #expect(blocker.connectionCount == 0)
        let targetServer = try await bindFixture(root)
        defer { targetServer.stop() }
        #expect(targetServer.baseURL.port != oldOrigin.port)
        let target = page(store: reopenedStore)
        defer { target.stopLoading() }
        // Complete synchronous LocalStorage plus asynchronous IDB restore before the official page gets any JS turn.
        try await simulated(target, origin: targetServer.baseURL, script: try writeScript(storage: captured.storage, restoring: captured))
        #expect(try await target.callJavaScript("return await window.originProbe;") as? Bool == true)
        try await load(target, url: targetServer.baseURL)
        let first = try #require(try await target.callJavaScript("return window.firstLocalStorage;") as? String)
        #expect(try JSONDecoder().decode([String: String].self, from: Data(first.utf8)) == changed)
        try assertFixture(try await probe(target), origin: targetServer.baseURL, expectedStorage: changed)
        #expect(blocker.connectionCount == 0)
        // Only this UUID-scoped test store is cleared; the production default store is never opened.
        await reopenedStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
