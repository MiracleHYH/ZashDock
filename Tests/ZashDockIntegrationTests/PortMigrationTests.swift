import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing
import WebKit
import ZashDockCore

@testable import ZashDock

let originFirstReadFixtureScript = #"""
  window.initialStorageJSON = JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(key => [key,localStorage.getItem(key)])));
  window.initialDatabasesJSONPromise = (async () => {
   const known = await indexedDB.databases(), result = {base64:{},'connection-history':{}};
   for (const name of ['base64','connection-history']) {
    if (!known.some(item=>item.name===name)) continue;
    const db=await new Promise((resolve,reject)=>{const request=indexedDB.open(name);request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(new Error('fixture open'));});
    await new Promise((resolve,reject)=>{
     const transaction=db.transaction(name,'readonly'),cursor=transaction.objectStore(name).openCursor();
     cursor.onsuccess=()=>{if(cursor.result){Object.defineProperty(result[name],cursor.result.value.key,{value:cursor.result.value.value,enumerable:true});cursor.result.continue();}};
     transaction.oncomplete=resolve;transaction.onabort=transaction.onerror=()=>reject(new Error('fixture read'));
    });db.close();
   }return JSON.stringify(result);
  })();
  """#

@MainActor
func initialBusinessDatabases(_ session: WebSession) async throws -> [String: [String: String]] {
  let text = try #require(
    try await session.page.callJavaScript("return await window.initialDatabasesJSONPromise;")
      as? String)
  return try JSONDecoder().decode([String: [String: String]].self, from: Data(text.utf8))
}

@MainActor
final class PortMigrationFixture {
  let paths: AppPaths
  let webRoot: URL
  let profileIdentifier: UUID
  let dataStore: WKWebsiteDataStore
  private var models: [AppModel] = []
  private var blockers: [LoopbackHTTPServer] = []
  init(paths: AppPaths, webRoot: URL) {
    self.paths = paths
    self.webRoot = webRoot
    profileIdentifier = UUID()
    dataStore = WKWebsiteDataStore(forIdentifier: profileIdentifier)
  }
  func model() -> AppModel {
    let model = AppModel(paths: paths, dataStore: dataStore)
    models.append(model)
    return model
  }
  func availablePort(excluding: Set<UInt16> = []) async throws -> UInt16 {
    for _ in 0..<30 {
      let reservation = try await bindFixture(webRoot)
      let port = reservation.port
      reservation.stop()
      if !excluding.contains(port) { return port }
    }
    throw ZashDockError.server("端口迁移测试无法预留随机端口。")
  }
  func occupy(_ port: UInt16? = nil) async throws -> LoopbackHTTPServer {
    let server: LoopbackHTTPServer
    if let port {
      server = try LoopbackHTTPServer(root: webRoot, port: port, versionID: "port-blocker")
      _ = try await server.start()
    } else {
      server = try await bindFixture(webRoot)
    }
    blockers.append(server)
    return server
  }
  func shutdown(_ model: AppModel) async {
    #expect(await model.prepareToQuit())
    models.removeAll { $0 === model }
  }
  func cleanUp() async {
    for model in models.reversed() { #expect(await model.prepareToQuit()) }
    models.removeAll()
    for blocker in blockers { blocker.stop() }
    blockers.removeAll()
    await dataStore.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    try? await WKWebsiteDataStore.remove(forIdentifier: profileIdentifier)
    try? FileManager.default.removeItem(at: paths.root)
  }
}

/// A port owner that counts every TCP connection, so an accidental request to the old Origin is observable.
private final class MigrationPortSentinel: @unchecked Sendable {
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
      Darwin.close(descriptor)
      throw POSIXError(code)
    }
    _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    source = DispatchSource.makeReadSource(
      fileDescriptor: descriptor,
      queue: DispatchQueue(label: "app.zashdock.test.migration-port-sentinel"))
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

@MainActor
@Suite(.serialized)
struct PortMigrationTests {
  private let remoteIDs = [
    "10a86241-d292-46c1-9017-87da6e6a5a01", "20a86241-d292-46c1-9017-87da6e6a5a02",
  ]
  private func expectedPayload() throws -> OriginStoragePayload {
    let backends: [[String: String]] = [
      [
        "type": "clash", "protocol": "http", "host": "10.20.0.2", "port": "9090",
        "secondaryPath": "", "password": "port-fixture-secret-one", "uuid": remoteIDs[0],
        "label": "LAN migration fixture",
      ],
      [
        "type": "clash", "protocol": "http", "host": "mihomo.vpn.example", "port": "9090",
        "secondaryPath": "kernel", "password": "port-fixture-secret-two", "uuid": remoteIDs[1],
        "label": "VPN migration fixture",
      ],
    ]
    return OriginStoragePayload(
      localStorage: [
        "setup/api-list": String(decoding: try JSONEncoder().encode(backends), as: UTF8.self),
        "setup/active-uuid": remoteIDs[1], "config/default-theme": "light",
        "config/dark-theme": "dark", "config/auto-theme": "true",
        "__proto__": "special storage key", "quoted\"key": "中文 </script> \\ \u{2028}",
      ],
      databases: [
        "base64": ["background-image": "data:image/png;base64,cG9ydC1maXh0dXJl"],
        "connection-history": [
          "\(remoteIDs[1])-sourceIP": #"[{"key":"10.0.0.1","download":42,"upload":7,"count":1}]"#
        ],
      ])
  }
  private func assertOfficialRemotes(_ values: [String: String]) throws {
    let encoded = try #require(values["setup/api-list"])
    let backends = try JSONDecoder().decode([[String: String]].self, from: Data(encoded.utf8))
    #expect(backends.count == 2)
    #expect(backends.map { $0["uuid"] } == remoteIDs.map(Optional.some))
    #expect(values["setup/active-uuid"] == remoteIDs[1])
    #expect(values["config/dark-theme"] == "dark" && values["config/auto-theme"] == "true")
  }
  private func assertSession(_ model: AppModel, expected: OriginStoragePayload) async throws {
    let session = try #require(model.session)
    let encoded = try #require(
      try await session.page.callJavaScript("return window.initialStorageJSON;") as? String)
    let initial = try JSONDecoder().decode([String: String].self, from: Data(encoded.utf8))
    #expect(initial == expected.localStorage)
    try assertOfficialRemotes(initial)
    #expect(try await initialBusinessDatabases(session) == expected.databases)
    try await model.originStorage.verify(expected, at: session.origin)
  }
  private func seed(_ model: AppModel, _ payload: OriginStoragePayload) async throws {
    try await model.originStorage.restore(payload, to: try #require(model.session).origin)
  }
  private func origin(_ port: UInt16) -> URL { URL(string: "http://127.0.0.1:\(port)")! }
  private func assertMetadataOnly(_ fixture: PortMigrationFixture) throws {
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.legacyStorage.path))
    let store = ConfigurationStore(url: fixture.paths.configuration)
    for url in [fixture.paths.configuration, store.recoveryCopyURL]
    where FileManager.default.fileExists(atPath: url.path) {
      let data = try Data(contentsOf: url)
      let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(
        Set(fields.keys).isSubset(of: [
          "port", "quitAfterLastWindowCloses", "pendingOriginCleanup",
          "legacyStorageImported",
        ]))
      #expect(data.range(of: Data("port-fixture-secret-one".utf8)) == nil)
      #expect(data.range(of: Data("setup/api-list".utf8)) == nil)
    }
  }
  private func makeFixture(installed: Bool) async throws -> PortMigrationFixture {
    _ = NSApplication.shared
    let paths = AppPaths(
      root: FileManager.default.temporaryDirectory.appendingPathComponent(
        "ZashDockPortMigration-\(UUID().uuidString)"))
    try paths.createDirectories()
    do {
      let probe = paths.root.appendingPathComponent("fixture-probe", isDirectory: true)
      try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
      try Data("<html><body><div id='app'>Port probe</div></body></html>".utf8).write(
        to: probe.appendingPathComponent("index.html"))
      guard installed else { return PortMigrationFixture(paths: paths, webRoot: probe) }
      let archive = storedZIP()
      let zipURL = paths.root.appendingPathComponent("fixture.zip")
      try archive.write(to: zipURL)
      let release = ZashboardRelease(
        tag: "v0.0.5", publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        assetURL: URL(
          string: "https://github.com/Zephyruso/zashboard/releases/download/v0.0.5/dist.zip")!,
        assetSize: Int64(archive.count),
        sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined())
      let store = try VersionStore(root: paths.root)
      let version = try await store.prepare(zip: zipURL, release: release)
      try await store.activate(version)
      let reservation = try await bindFixture(version.directoryURL)
      var configuration = AppConfiguration()
      configuration.port = reservation.port
      reservation.stop()
      try ConfigurationStore(url: paths.configuration).save(configuration)
      return PortMigrationFixture(paths: paths, webRoot: version.directoryURL)
    } catch {
      try? FileManager.default.removeItem(at: paths.root)
      throw error
    }
  }
  private func withFixture(installed: Bool, body: (PortMigrationFixture) async throws -> Void)
    async throws
  {
    let fixture = try await makeFixture(installed: installed)
    do {
      try await body(fixture)
      await fixture.cleanUp()
    } catch {
      await fixture.cleanUp()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func freshApplicationShowsNativeInstallationPhase() async throws {
    try await withFixture(installed: false) { fixture in
      let model = fixture.model()
      await model.start()
      #expect(
        model.phase == .uninstalled && model.currentVersion == nil && model.session == nil
          && model.server == nil && !model.isBusy)
      #expect(!FileManager.default.fileExists(atPath: fixture.paths.legacyStorage.path))
    }
  }
  @Test(.timeLimit(.minutes(1)))
  func runningApplicationTransfersAllBusinessDataBeforeFirstReadAndClearsOldOrigin() async throws {
    try await withFixture(installed: true) { fixture in
      let model = fixture.model()
      await model.start()
      #expect(model.phase == .ready)
      let expected = try expectedPayload()
      try await seed(model, expected)
      let oldPort = model.configuration.port
      let newPort = try await fixture.availablePort(excluding: [model.configuration.port])
      try await model.changePort(to: newPort)
      #expect(
        model.phase == .ready && model.configuration.port == newPort
          && model.server?.port == newPort)
      try await assertSession(model, expected: expected)
      #expect(
        try await model.originStorage.read(origin: origin(oldPort))
          == OriginStoragePayload(localStorage: [:]))
      try assertMetadataOnly(fixture)
      await fixture.shutdown(model)
      let restarted = fixture.model()
      await restarted.start()
      #expect(restarted.configuration.port == newPort)
      try await assertSession(restarted, expected: expected)
    }
  }
  @Test(.timeLimit(.minutes(1)))
  func occupiedTargetRestoresOriginalServiceAndPreservesConfigurationAndWebKitData() async throws {
    try await withFixture(installed: true) { fixture in
      let model = fixture.model()
      await model.start()
      let expected = try expectedPayload()
      try await seed(model, expected)
      let original = model.configuration
      let configurationBytes = try Data(contentsOf: fixture.paths.configuration)
      let blocker = try await fixture.occupy()
      await #expect(throws: (any Error).self) { try await model.changePort(to: blocker.port) }
      #expect(model.phase == .ready && !model.isBusy && model.configuration == original)
      #expect(model.server?.port == original.port)
      #expect(try Data(contentsOf: fixture.paths.configuration) == configurationBytes)
      try await model.originStorage.verify(expected, at: origin(original.port))
      let server = try #require(model.server)
      let (health, response) = try await URLSession.shared.data(from: server.healthcheckURL)
      #expect((response as? HTTPURLResponse)?.statusCode == 200)
      #expect(
        (try JSONSerialization.jsonObject(with: health) as? [String: String])?["nonce"]
          == server.nonce)
    }
  }
  @Test(.timeLimit(.minutes(1)))
  func startupOccupiedOldPortTransfersFromWebKitWithoutSendingAnyHTTPToOccupier() async throws {
    try await withFixture(installed: true) { fixture in
      let first = fixture.model()
      await first.start()
      let expected = try expectedPayload()
      try await seed(first, expected)
      let oldPort = first.configuration.port
      await fixture.shutdown(first)
      let blocker = try MigrationPortSentinel(port: oldPort)
      defer { blocker.stop() }
      let restarted = fixture.model()
      await restarted.start()
      #expect(
        restarted.phase == .unavailable && restarted.configuration.port == oldPort
          && restarted.session == nil && restarted.server == nil)
      let newPort = try await fixture.availablePort(excluding: [oldPort])
      try await restarted.changePort(to: newPort)
      #expect(restarted.phase == .ready && restarted.configuration.port == newPort)
      try await assertSession(restarted, expected: expected)
      try await Task.sleep(for: .milliseconds(100))
      #expect(blocker.connectionCount == 0)
      #expect(
        try await restarted.originStorage.read(origin: origin(oldPort))
          == OriginStoragePayload(localStorage: [:]))
    }
  }
  @Test(.timeLimit(.minutes(1)))
  func staleTargetIsReplacedAndReturningToOldPortKeepsOnlyLatestDataset() async throws {
    try await withFixture(installed: true) { fixture in
      let model = fixture.model()
      await model.start()
      let expected = try expectedPayload()
      try await seed(model, expected)
      let oldPort = model.configuration.port
      let newPort = try await fixture.availablePort(excluding: [model.configuration.port])
      try await model.originStorage.restore(
        OriginStoragePayload(
          localStorage: ["stale": "discard"],
          databases: ["base64": ["old": "discard"], "connection-history": ["old": "discard"]]),
        to: origin(newPort))
      try await model.changePort(to: newPort)
      try await assertSession(model, expected: expected)
      var changed = expected.localStorage
      changed["config/default-theme"] = "dark"
      let latest = OriginStoragePayload(localStorage: changed, databases: expected.databases)
      try await seed(model, latest)
      try await model.changePort(to: oldPort)
      try await assertSession(model, expected: latest)
      #expect(
        try await model.originStorage.read(origin: origin(newPort))
          == OriginStoragePayload(localStorage: [:]))
      #expect(try ConfigurationStore(url: fixture.paths.configuration).load().port == oldPort)
    }
  }
  @Test(.timeLimit(.minutes(1)))
  func configurationCommitFailurePreservesSourceAndRebuildsOriginalService() async throws {
    try await withFixture(installed: true) { fixture in
      let model = fixture.model()
      await model.start()
      let expected = try expectedPayload()
      try await seed(model, expected)
      let original = model.configuration
      let originalBytes = try Data(contentsOf: fixture.paths.configuration)
      let preserved = fixture.paths.root.appendingPathComponent("preserved-configuration.json")
      try FileManager.default.moveItem(at: fixture.paths.configuration, to: preserved)
      try FileManager.default.createDirectory(
        at: fixture.paths.configuration, withIntermediateDirectories: false)
      defer {
        try? FileManager.default.removeItem(at: fixture.paths.configuration)
        try? FileManager.default.moveItem(at: preserved, to: fixture.paths.configuration)
      }
      let target = try await fixture.availablePort(excluding: [original.port])
      await #expect(throws: (any Error).self) { try await model.changePort(to: target) }
      #expect(
        model.configuration == original && model.phase == .ready
          && model.server?.port == original.port)
      #expect(try Data(contentsOf: preserved) == originalBytes)
      try await model.originStorage.verify(expected, at: origin(original.port))
      #expect(
        try await model.originStorage.read(origin: origin(target))
          == OriginStoragePayload(localStorage: [:]))
    }
  }
  @Test(.timeLimit(.minutes(1)))
  func failedRecoveryMirrorLeavesPendingCleanupThenRestartRetriesWithoutStoringRemotes()
    async throws
  {
    try await withFixture(installed: true) { fixture in
      let model = fixture.model()
      await model.start()
      let expected = try expectedPayload()
      try await seed(model, expected)
      let old = model.configuration.port
      let new = try await fixture.availablePort(excluding: [model.configuration.port])
      let mirror = ConfigurationStore(url: fixture.paths.configuration).recoveryCopyURL
      if FileManager.default.fileExists(atPath: mirror.path) {
        try FileManager.default.removeItem(at: mirror)
      }
      try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: false)
      try await model.changePort(to: new)
      #expect(
        model.phase == .ready && model.configuration.port == new
          && model.configuration.pendingOriginCleanup == old)
      try await model.originStorage.verify(expected, at: origin(old))
      try await assertSession(model, expected: expected)
      try FileManager.default.removeItem(at: mirror)
      await fixture.shutdown(model)
      let restarted = fixture.model()
      await restarted.start()
      #expect(
        restarted.phase == .ready && restarted.configuration.port == new
          && restarted.configuration.pendingOriginCleanup == nil)
      #expect(
        try await restarted.originStorage.read(origin: origin(old))
          == OriginStoragePayload(localStorage: [:]))
      try await assertSession(restarted, expected: expected)
      try assertMetadataOnly(fixture)
    }
  }
  @Test(.timeLimit(.minutes(1)))
  func uninstalledPortChangeChecksActualBindingBeforePersisting() async throws {
    try await withFixture(installed: false) { fixture in
      let model = fixture.model()
      await model.start()
      let original = model.configuration
      let blocker = try await fixture.occupy()
      await #expect(throws: (any Error).self) { try await model.changePort(to: blocker.port) }
      #expect(model.configuration == original)
      let port = try await fixture.availablePort(excluding: [original.port, blocker.port])
      try await model.changePort(to: port)
      #expect(
        model.phase == .uninstalled && model.configuration.port == port && model.session == nil
          && model.server == nil)
      #expect(try ConfigurationStore(url: fixture.paths.configuration).load().port == port)
      try assertMetadataOnly(fixture)
    }
  }
  /// Two stored records, with central directory and CRCs, exercise the production ZIP/manifest path.
  private func storedZIP() -> Data {
    let html = """
      <!doctype html><html><head><script>
      \(originFirstReadFixtureScript)
      </script><script src="/assets/app.js"></script></head><body><div id="app"><p>Port migration fixture</p></div></body></html>
      """
    let entries = [
      ("index.html", Data(html.utf8)), ("assets/app.js", Data("window.fixtureReady = true;".utf8)),
    ]
    var output = Data()
    var central = Data()
    for (path, bytes) in entries {
      let name = Data(path.utf8)
      let offset = output.count
      let crc = checksum(bytes)
      output.portLE32(0x0403_4b50)
      output.portLE16(20)
      output.portLE16(0x0800)
      output.portLE16(0)
      output.portLE16(0)
      output.portLE16(0)
      output.portLE32(crc)
      output.portLE32(UInt32(bytes.count))
      output.portLE32(UInt32(bytes.count))
      output.portLE16(UInt16(name.count))
      output.portLE16(0)
      output.append(name)
      output.append(bytes)
      central.portLE32(0x0201_4b50)
      central.portLE16(0x0314)
      central.portLE16(20)
      central.portLE16(0x0800)
      central.portLE16(0)
      central.portLE16(0)
      central.portLE16(0)
      central.portLE32(crc)
      central.portLE32(UInt32(bytes.count))
      central.portLE32(UInt32(bytes.count))
      central.portLE16(UInt16(name.count))
      central.portLE16(0)
      central.portLE16(0)
      central.portLE16(0)
      central.portLE16(0)
      central.portLE32(0x81a4_0000)
      central.portLE32(UInt32(offset))
      central.append(name)
    }
    let offset = output.count
    output.append(central)
    output.portLE32(0x0605_4b50)
    output.portLE16(0)
    output.portLE16(0)
    output.portLE16(UInt16(entries.count))
    output.portLE16(UInt16(entries.count))
    output.portLE32(UInt32(central.count))
    output.portLE32(UInt32(offset))
    output.portLE16(0)
    return output
  }
  private func checksum(_ bytes: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
    }
    return crc ^ 0xffff_ffff
  }
}

extension Data {
  fileprivate mutating func portLE16(_ value: UInt16) {
    append(UInt8(value & 255))
    append(UInt8(value >> 8))
  }
  fileprivate mutating func portLE32(_ value: UInt32) {
    portLE16(UInt16(value & 0xffff))
    portLE16(UInt16(value >> 16))
  }
}
