import AppKit
import Darwin
import Foundation
import WebKit

private enum HarnessFailure: Error { case invalidArguments, fixtureMismatch, unexpectedNetworkAccess, unavailablePort }

/// Only fixture identity and port metadata cross process boundaries. Website values stay in WebKit.
private struct FixtureIdentity: Codable {
    let fixture: String
    let profile: UUID
    let oldPort: UInt16
    let newPort: UInt16
    static let marker = "ZashDockOriginProcessHarness-1"
}

private struct PortMetadata: Codable {
    var currentPort: UInt16
    var pendingOriginCleanup: UInt16?
}

private struct ProcessResult: Codable {
    let phase: String
    let pid: Int32
    let success: Bool
    let currentPort: UInt16
    let pendingOriginCleanup: UInt16?
    let sentinelConnections: Int
    let note: String
}

private final class PortSentinel: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var connections = 0
    var count: Int { lock.withLock { connections } }
    init(port: UInt16) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HarnessFailure.unavailablePort }
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
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "app.zashdock.tests.process-origin-sentinel"))
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                self?.lock.withLock { self?.connections += 1 }
                close(client)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }
    deinit { source.cancel() }
}

@MainActor
private final class HarnessDelegate: NSObject, NSApplicationDelegate {
    private var page: WebPage?
    private var store: WKWebsiteDataStore?
    private var sentinel: PortSentinel?
    private let values = [
        "setup/api-list": #"[{"type":"clash","protocol":"http","host":"192.0.2.1","port":"9090","secondaryPath":"","password":"process-fixture-one","uuid":"83e0c9a9-61ac-4162-bff4-b457ed393111","label":"LAN fixture"},{"type":"clash","protocol":"http","host":"kernel.vpn.example","port":"9090","secondaryPath":"mihomo","password":"process-fixture-two","uuid":"cf07b53e-84ed-4fe0-be92-d4758d405222","label":"VPN fixture"}]"#,
        "setup/active-uuid": "cf07b53e-84ed-4fe0-be92-d4758d405222",
        "config/default-theme": "light", "config/custom-background-image": "local-image",
        "__proto__": "ordinary string key", "fixture/escaped": "quoted \" string\nsecond line"
    ]
    private var databases: [String: [String: String]] {
        ["base64": ["background-image": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jr1cAAAAASUVORK5CYII="],
         "connection-history": ["cf07b53e-84ed-4fe0-be92-d4758d405222-sourceIP": #"[{"key":"192.0.2.2","download":1024,"upload":512,"count":2}]"#]]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run() }
            catch {
                // Error descriptions may contain evaluated JavaScript and fixture values.
                // Reports deliberately contain only the phase and a stable failure marker.
                let failure = error as NSError
                let line = "FAIL: process storage harness (PID \(getpid())), error type \(String(reflecting: type(of: error))), code \(failure.code)\n"
                FileHandle.standardError.write(Data(line.utf8))
                Darwin.exit(1)
            }
        }
    }

    private func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { throw HarnessFailure.invalidArguments }
        let mode = arguments[1], root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let resultURL = root.appendingPathComponent("\(mode).json")
        let identityURL = root.appendingPathComponent("fixture.json"), metadataURL = root.appendingPathComponent("configuration.json")
        if mode == "prepare" {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let oldPort = try availablePort(), newPort = try availablePort(excluding: oldPort)
            try write(FixtureIdentity(fixture: FixtureIdentity.marker, profile: UUID(), oldPort: oldPort, newPort: newPort), to: identityURL)
            try write(PortMetadata(currentPort: oldPort), to: metadataURL)
            try report(mode, resultURL: resultURL, metadata: .init(currentPort: oldPort), note: "random isolated profile allocated")
            NSApp.terminate(nil); return
        }
        let identity = try JSONDecoder().decode(FixtureIdentity.self, from: Data(contentsOf: identityURL))
        guard identity.fixture == FixtureIdentity.marker, identity.oldPort >= 1024, identity.newPort >= 1024, identity.oldPort != identity.newPort else { throw HarnessFailure.invalidArguments }
        if mode == "cleanup-profile" {
            // Initialize WebKit's storage machinery for this test identifier before its
            // first process operation is removal. No default profile is opened.
            var cleanupStore: WKWebsiteDataStore? = autoreleasepool { WKWebsiteDataStore(forIdentifier: identity.profile) }
            _ = await cleanupStore?.dataRecords(ofTypes: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeIndexedDBDatabases])
            cleanupStore = nil
            try await Task.sleep(for: .milliseconds(20))
            try await WKWebsiteDataStore.remove(forIdentifier: identity.profile)
            NSApp.terminate(nil); return
        }
        let metadataData = try Data(contentsOf: metadataURL)
        let fields = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        guard let fields, Set(fields.keys).isSubset(of: ["currentPort", "pendingOriginCleanup"]) else { throw HarnessFailure.fixtureMismatch }
        var metadata = try JSONDecoder().decode(PortMetadata.self, from: metadataData)
        if arguments.contains("--expect-old"), metadata.currentPort != identity.oldPort { throw HarnessFailure.fixtureMismatch }
        if arguments.contains("--expect-new"), metadata.currentPort != identity.newPort { throw HarnessFailure.fixtureMismatch }
        let dataStore = WKWebsiteDataStore(forIdentifier: identity.profile)
        store = dataStore
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        configuration.defaultNavigationPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        let webpage = WebPage(configuration: configuration)
        page = webpage
        if mode == "seed" {
            try await bootstrap(webpage, port: identity.oldPort)
            let payload = try JSONSerialization.data(withJSONObject: ["localStorage": values, "databases": databases], options: [.sortedKeys])
            let text = String(decoding: payload, as: UTF8.self)
            _ = try await webpage.callJavaScript(Self.seedScript, arguments: ["text": text])
            try await assertStoredFixture(webpage, port: identity.oldPort)
        } else if mode == "verify-old" || mode == "verify-current" {
            try await bootstrap(webpage, port: mode == "verify-old" ? identity.oldPort : metadata.currentPort)
            try await assertStoredFixture(webpage, port: mode == "verify-old" ? identity.oldPort : metadata.currentPort)
        } else {
            #if PROCESS_TRANSFER
            let transfer = OriginStorageTransfer(dataStore: dataStore)
            if mode == "transfer" || mode == "before-commit" || mode == "after-commit" {
                sentinel = try PortSentinel(port: identity.oldPort)
                let payload = try await transfer.read(origin: origin(identity.oldPort))
                guard payload.localStorage == values, payload.databases == databases else { throw HarnessFailure.fixtureMismatch }
                try await transfer.restore(payload, to: origin(identity.newPort))
                try await transfer.verify(payload, at: origin(identity.newPort))
                if mode != "before-commit" {
                    metadata.currentPort = identity.newPort
                    metadata.pendingOriginCleanup = identity.oldPort
                    try write(metadata, to: metadataURL)
                }
                try await Task.sleep(for: .milliseconds(100))
                guard sentinel?.count == 0 else { throw HarnessFailure.unexpectedNetworkAccess }
            } else if mode == "finish-cleanup" {
                guard metadata.currentPort == identity.newPort else { throw HarnessFailure.fixtureMismatch }
                try await transfer.verify(.init(localStorage: values, databases: databases), at: origin(metadata.currentPort))
                if let previous = metadata.pendingOriginCleanup {
                    sentinel = try PortSentinel(port: previous)
                    try await transfer.clear(origin: origin(previous))
                    let cleared = try await transfer.read(origin: origin(previous))
                    guard cleared.localStorage.isEmpty, cleared.databases.values.allSatisfy(\.isEmpty) else { throw HarnessFailure.fixtureMismatch }
                    metadata.pendingOriginCleanup = nil
                    try write(metadata, to: metadataURL)
                }
            } else { throw HarnessFailure.invalidArguments }
            #else
            throw HarnessFailure.invalidArguments
            #endif
        }
        try report(mode, resultURL: resultURL, metadata: metadata, connections: sentinel?.count ?? 0,
                   note: mode == "before-commit" || mode == "after-commit" ? "metadata commit boundary reached; awaiting external SIGKILL" : "two remotes and both official databases verified")
        if arguments.contains("--hold") { return }
        page?.stopLoading(); page = nil; store = nil
        NSApp.terminate(nil)
    }

    private func origin(_ port: UInt16) -> URL { URL(string: "http://127.0.0.1:\(port)")! }
    private func bootstrap(_ page: WebPage, port: UInt16) async throws {
        let html = "<!doctype html><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>Isolated persistence fixture</title>"
        for try await _ in page.load(simulatedRequest: URLRequest(url: origin(port)), responseHTML: html) {}
    }
    private func assertStoredFixture(_ page: WebPage, port: UInt16) async throws {
        let text = try await page.callJavaScript(Self.readScript)
        guard let text = text as? String, let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              value["origin"] as? String == origin(port).absoluteString,
              value["localStorage"] as? [String: String] == values,
              value["databases"] as? [String: [String: String]] == databases else { throw HarnessFailure.fixtureMismatch }
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
    private func report(_ phase: String, resultURL: URL, metadata: PortMetadata, connections: Int = 0, note: String) throws {
        try write(ProcessResult(phase: phase, pid: getpid(), success: true, currentPort: metadata.currentPort,
                                pendingOriginCleanup: metadata.pendingOriginCleanup, sentinelConnections: connections, note: note), to: resultURL)
        FileHandle.standardOutput.write(Data("PASS: \(phase), PID \(getpid()), sentinel connections \(connections)\n".utf8))
    }
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
        const transaction = database.transaction(name,'readwrite',{durability:'strict'});
        const store = transaction.objectStore(name); store.clear();
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
        request.onupgradeneeded = () => {request.transaction.abort();reject(new Error('unexpected fixture database creation'));};
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
