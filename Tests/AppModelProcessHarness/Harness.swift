import AppKit
import CryptoKit
import Darwin
import Foundation
import WebKit
import ZashDockCore

private enum HarnessFailure: Error {
    case invalidArguments, fixtureMismatch, unexpectedKeyAccess, unexpectedNetworkAccess, unavailablePort, startupFailed
}

/// This marker contains identity and ordinary port metadata only. Business data stays in WebKit.
private struct FixtureIdentity: Codable {
    let fixture: String
    let profile: UUID
    let oldPort: UInt16
    let newPort: UInt16
    static let marker = "ZashDockAppModelProcessHarness-1"
}

private struct ProcessResult: Codable {
    let phase: String
    let pid: Int32
    let success: Bool
    let currentPort: UInt16
    let pendingOriginCleanup: UInt16?
}

private struct SentinelResult: Codable { let pid: Int32; let connections: Int }

/// A separate process holds the old port across the AppModel writer's SIGKILL.
private final class PortSentinel: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var connections = 0
    init(port: UInt16, reportURL: URL) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HarnessFailure.unavailablePort }
        // The preceding real HTTP session may leave TIME_WAIT sockets. This does
        // not permit another live listener, unlike SO_REUSEPORT.
        var reuseAddress: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { close(descriptor); throw HarnessFailure.unavailablePort }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "app.zashdock.tests.appmodel-sentinel"))
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                if let self {
                    let count = self.lock.withLock { self.connections += 1; return self.connections }
                    try? AtomicFile.encode(SentinelResult(pid: getpid(), connections: count), to: reportURL)
                }
                close(client)
            }
        }
        source.setCancelHandler { close(descriptor) }
        try AtomicFile.encode(SentinelResult(pid: getpid(), connections: 0), to: reportURL)
        source.resume()
    }
    deinit { source.cancel() }
}

private struct DeniedKeyReader: LegacyStorageKeyReading {
    func readKey() throws -> SymmetricKey { throw HarnessFailure.unexpectedKeyAccess }
}

@MainActor
private final class HarnessDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var dataStore: WKWebsiteDataStore?
    private var sentinel: PortSentinel?
    private let localStorage = [
        "setup/api-list": #"[{"type":"clash","protocol":"http","host":"192.0.2.1","port":"9090","secondaryPath":"","password":"appmodel-fixture-one","uuid":"appmodel-one","label":"LAN fixture"},{"type":"clash","protocol":"http","host":"kernel.vpn.example","port":"9090","secondaryPath":"mihomo","password":"appmodel-fixture-two","uuid":"appmodel-two","label":"VPN fixture"}]"#,
        "setup/active-uuid": "appmodel-two", "config/default-theme": "light",
        "__proto__": "ordinary key", "fixture/escaped": "quoted \" value\nsecond line"
    ]
    private var databases: [String: [String: String]] {
        ["base64": ["background-image": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jr1cAAAAASUVORK5CYII="],
         "connection-history": ["appmodel-two-sourceIP": #"[{"key":"192.0.2.20","download":1024,"upload":512,"count":2}]"#]]
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run() }
            catch {
                // Never print a JavaScript body, URL, or stored business value.
                let line = "FAIL: AppModel process harness PID \(getpid()), type \(String(reflecting: type(of: error))), code \((error as NSError).code)\n"
                FileHandle.standardError.write(Data(line.utf8))
                Darwin.exit(1)
            }
        }
    }
    private func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw HarnessFailure.invalidArguments }
        let mode = arguments[1], root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let identityURL = root.appendingPathComponent("fixture.json")
        let paths = AppPaths(root: root.appendingPathComponent("app-root", isDirectory: true))
        if mode == "prepare" {
            try paths.createDirectories()
            let oldPort = try availablePort(), newPort = try availablePort(excluding: oldPort)
            let identity = FixtureIdentity(fixture: FixtureIdentity.marker, profile: UUID(), oldPort: oldPort, newPort: newPort)
            try AtomicFile.encode(identity, to: identityURL)
            var configuration = AppConfiguration(); configuration.port = oldPort
            try ConfigurationStore(url: paths.configuration).save(configuration)
            try writeInstallation(paths)
            try report(mode, at: root, configuration: configuration)
            NSApp.terminate(nil); return
        }
        let identity = try AtomicFile.decode(FixtureIdentity.self, from: identityURL)
        guard identity.fixture == FixtureIdentity.marker, identity.oldPort >= 1024, identity.newPort >= 1024,
              identity.oldPort != identity.newPort else { throw HarnessFailure.invalidArguments }
        if mode == "sentinel" {
            for attempt in 0..<100 {
                do {
                    sentinel = try PortSentinel(port: identity.oldPort, reportURL: root.appendingPathComponent("sentinel-count.json"))
                    break
                } catch {
                    if attempt == 99 { throw error }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            try report(mode, at: root, configuration: ConfigurationStore(url: paths.configuration).load())
            return
        }
        if mode == "cleanup-profile" {
            var store: WKWebsiteDataStore? = autoreleasepool { WKWebsiteDataStore(forIdentifier: identity.profile) }
            _ = await store?.dataRecords(ofTypes: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeIndexedDBDatabases])
            store = nil
            try await Task.sleep(for: .milliseconds(20))
            try await WKWebsiteDataStore.remove(forIdentifier: identity.profile)
            NSApp.terminate(nil); return
        }
        let store = WKWebsiteDataStore(forIdentifier: identity.profile)
        dataStore = store
        let appModel = AppModel(paths: paths, dataStore: store, legacyKeyReader: DeniedKeyReader())
        model = appModel
        await appModel.start()
        if mode == "transfer" {
            // The real startup must encounter the separately occupied old port first.
            guard appModel.phase == .unavailable, appModel.session == nil,
                  appModel.currentVersion != nil, appModel.configuration.port == identity.oldPort else { throw HarnessFailure.startupFailed }
            try report("transfer-started", at: root, configuration: appModel.configuration)
            try await appModel.changePort(to: identity.newPort)
            try await assertStoredFixture(appModel, expectedPort: identity.newPort)
            try report(mode, at: root, configuration: appModel.configuration)
            // Shell may kill during changePort cleanup, or here if cleanup already completed.
            return
        }
        let expectedPort = mode == "verify-new" || mode == "verify-new-again" ? identity.newPort : identity.oldPort
        guard appModel.phase == .ready, appModel.configuration.port == expectedPort else { throw HarnessFailure.startupFailed }
        if mode == "seed" {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: ["localStorage": localStorage, "databases": databases], options: [.sortedKeys]), as: UTF8.self)
            _ = try await appModel.session?.page.callJavaScript(Self.seedScript, arguments: ["text": text])
        } else if mode == "verify-old" || mode == "verify-new" || mode == "verify-new-again" {
            // The fixture captures LS in the first inline script, before app initialization.
            let initial = try await appModel.session?.page.callJavaScript("return window.initialStorageJSON;")
            guard let initial = initial as? String,
                  try JSONSerialization.jsonObject(with: Data(initial.utf8)) as? [String: String] == localStorage else { throw HarnessFailure.fixtureMismatch }
        } else { throw HarnessFailure.invalidArguments }
        try await assertStoredFixture(appModel, expectedPort: expectedPort)
        if mode == "verify-new" || mode == "verify-new-again" {
            guard appModel.configuration.pendingOriginCleanup == nil else { throw HarnessFailure.fixtureMismatch }
            let old = try await appModel.originStorage.read(origin: origin(identity.oldPort))
            guard old.localStorage.isEmpty, old.databases.values.allSatisfy(\.isEmpty) else { throw HarnessFailure.fixtureMismatch }
        }
        guard !FileManager.default.fileExists(atPath: paths.legacyStorage.path) else { throw HarnessFailure.fixtureMismatch }
        guard await appModel.prepareToQuit() else { throw HarnessFailure.fixtureMismatch }
        try report(mode, at: root, configuration: appModel.configuration)
        model = nil; dataStore = nil
        NSApp.terminate(nil)
    }
    private func assertStoredFixture(_ model: AppModel, expectedPort: UInt16) async throws {
        guard let page = model.session?.page, model.session?.origin == origin(expectedPort),
              let text = try await page.callJavaScript(Self.readScript) as? String,
              let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              value["origin"] as? String == origin(expectedPort).absoluteString,
              value["localStorage"] as? [String: String] == localStorage,
              value["databases"] as? [String: [String: String]] == databases else { throw HarnessFailure.fixtureMismatch }
        let saved = try ConfigurationStore(url: model.paths!.configuration).load()
        guard saved.port == expectedPort else { throw HarnessFailure.fixtureMismatch }
    }
    private func report(_ phase: String, at root: URL, configuration: AppConfiguration) throws {
        try AtomicFile.encode(ProcessResult(phase: phase, pid: getpid(), success: true, currentPort: configuration.port,
                                            pendingOriginCleanup: configuration.pendingOriginCleanup), to: root.appendingPathComponent("\(phase).json"))
        FileHandle.standardOutput.write(Data("PASS: actual AppModel \(phase), PID \(getpid())\n".utf8))
    }
    private func origin(_ port: UInt16) -> URL { URL(string: "http://127.0.0.1:\(port)")! }
    private func availablePort(excluding: UInt16? = nil) throws -> UInt16 {
        for _ in 0..<20 {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw HarnessFailure.unavailablePort }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0 }
            }
            close(descriptor)
            let port = UInt16(bigEndian: address.sin_port)
            if result, port >= 1024, port != excluding { return port }
        }
        throw HarnessFailure.unavailablePort
    }
    private func writeInstallation(_ paths: AppPaths) throws {
        let tag = "v0.93.0", sha = String(repeating: "a", count: 64), id = "v0.93.0-" + String(repeating: "a", count: 16)
        let directory = paths.versions.appendingPathComponent(id, isDirectory: true), content = directory.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: content.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let html = "<html><head><script>window.initialStorageJSON=JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(key=>[key,localStorage.getItem(key)])));</script><script src='/assets/app.js'></script></head><body><div id='app'>AppModel fixture</div></body></html>"
        let files = [("assets/app.js", Data("window.ready=true;".utf8)), ("index.html", Data(html.utf8))]
        for (path, data) in files { try data.write(to: content.appendingPathComponent(path)) }
        let manifest: [String: Any] = ["schema": 1, "id": id, "installedAt": "2026-01-01T00:00:00Z",
            "release": ["tag": tag, "publishedAt": "2026-01-01T00:00:00Z", "assetURL": "https://github.com/Zephyruso/zashboard/releases/download/\(tag)/dist.zip", "assetSize": 1, "sha256": sha],
            "files": files.map { path, data in ["path": path, "size": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()] as [String: Any] }]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: ["schema": 1, "currentID": id, "activationOrder": [id]]).write(to: paths.root.appendingPathComponent("versions-state.json"))
    }
    private static let seedScript = #"""
    const fixture = JSON.parse(text);
    localStorage.clear();
    for (const [key,value] of Object.entries(fixture.localStorage)) localStorage.setItem(key,value);
    for (const [name,records] of Object.entries(fixture.databases)) {
      const database = await new Promise((resolve,reject) => {
        const request = indexedDB.open(name,1);
        request.onupgradeneeded = () => request.result.createObjectStore(name,{keyPath:'key'});
        request.onerror = () => reject(new Error('fixture database create failed'));
        request.onsuccess = () => resolve(request.result);
      });
      await new Promise((resolve,reject) => {
        const transaction = database.transaction(name,'readwrite',{durability:'strict'}), store = transaction.objectStore(name);
        store.clear();
        for (const [key,value] of Object.entries(records)) store.put({key,value});
        transaction.oncomplete = resolve;
        transaction.onerror = transaction.onabort = () => reject(new Error('fixture database write failed'));
      });
      database.close();
    }
    return true;
    """#
    private static let readScript = #"""
    const result = {origin:location.origin,localStorage:Object.fromEntries(Object.keys(localStorage).map(key=>[key,localStorage.getItem(key)])),databases:{}};
    const names = (await indexedDB.databases()).map(database=>database.name);
    for (const name of ['base64','connection-history']) {
      if (!names.includes(name)) throw new Error('fixture database missing');
      const database = await new Promise((resolve,reject) => {
        const request = indexedDB.open(name);
        request.onerror = () => reject(new Error('fixture database open failed'));
        request.onupgradeneeded = () => {request.transaction.abort();reject(new Error('unexpected database creation'));};
        request.onsuccess = () => resolve(request.result);
      });
      if (database.version !== 1 || database.objectStoreNames.length !== 1 || !database.objectStoreNames.contains(name)) throw new Error('fixture schema mismatch');
      result.databases[name] = await new Promise((resolve,reject) => {
        const transaction = database.transaction(name,'readonly'), store = transaction.objectStore(name), request = store.getAll();
        if (store.keyPath !== 'key' || store.autoIncrement || store.indexNames.length) throw new Error('fixture store mismatch');
        transaction.oncomplete = () => resolve(Object.fromEntries(request.result.map(record=>[record.key,record.value])));
        transaction.onerror = transaction.onabort = () => reject(new Error('fixture database read failed'));
      });
      database.close();
    }
    return JSON.stringify(result);
    """#
}

@main
private enum HarnessMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let delegate = HarnessDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
