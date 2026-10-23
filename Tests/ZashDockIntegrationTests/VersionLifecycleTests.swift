import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit
import ZashDockCore

@testable import ZashDock

@MainActor
@Suite(.serialized)
struct VersionLifecycleTests {
  private let remoteIDs = [
    "6a60cf33-3a65-45c2-8173-af3ba44fa001", "6a60cf33-3a65-45c2-8173-af3ba44fa002",
  ]
  private func officialStorage() throws -> OriginStoragePayload {
    let backends: [[String: String]] = [
      [
        "type": "clash", "protocol": "http", "host": "10.30.0.2", "port": "9090",
        "secondaryPath": "", "password": "version-fixture-secret-one", "uuid": remoteIDs[0],
        "label": "LAN version fixture",
      ],
      [
        "type": "clash", "protocol": "http", "host": "kernel.vpn.example", "port": "9090",
        "secondaryPath": "mihomo", "password": "version-fixture-secret-two", "uuid": remoteIDs[1],
        "label": "VPN version fixture",
      ],
    ]
    return OriginStoragePayload(
      localStorage: [
        "setup/api-list": String(decoding: try JSONEncoder().encode(backends), as: UTF8.self),
        "setup/active-uuid": remoteIDs[1], "config/default-theme": "light",
        "config/dark-theme": "dark", "config/auto-theme": "true",
      ],
      databases: [
        "base64": ["background-image": "data:image/png;base64,dmVyc2lvbi1maXh0dXJl"],
        "connection-history": [
          "version-fixture-sourceIP": "[{\"key\":\"10.0.0.1\",\"download\":42}]"
        ],
      ])
  }
  private func writeStorage(_ model: AppModel, values: OriginStoragePayload) async throws {
    try await model.originStorage.restore(values, to: try #require(model.session).origin)
  }
  private func assertPage(_ model: AppModel, marker: String, storage: OriginStoragePayload)
    async throws
  {
    #expect(model.phase == .ready)
    let session = try #require(model.session)
    #expect(
      try await session.page.callJavaScript("return window.fixtureVersion;") as? String == marker)
    #expect(
      try await session.page.callJavaScript(
        "return document.getElementById('app').textContent.trim();") as? String == marker)
    let initial = try #require(
      try await session.page.callJavaScript("return window.initialStorageJSON;") as? String)
    let decoded = try JSONDecoder().decode([String: String].self, from: Data(initial.utf8))
    #expect(decoded == storage.localStorage)
    #expect(try await initialBusinessDatabases(session) == storage.databases)
    let backends = try JSONDecoder().decode(
      [[String: String]].self, from: Data(try #require(decoded["setup/api-list"]).utf8))
    #expect(backends.count == 2 && backends.map { $0["uuid"] } == remoteIDs.map(Optional.some))
    #expect(decoded["setup/active-uuid"] == remoteIDs[1])
    try await model.originStorage.verify(storage, at: session.origin)
  }
  private func prepare(
    _ store: VersionStore, paths: AppPaths, tag: String, marker: String, rendered: Bool = true
  ) async throws -> InstalledVersion {
    let bytes = try archive(marker: marker, rendered: rendered)
    let zip = paths.root.appendingPathComponent("fixture-\(tag)-\(UUID().uuidString).zip")
    try bytes.write(to: zip)
    let release = ZashboardRelease(
      tag: tag, publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      assetURL: URL(
        string: "https://github.com/Zephyruso/zashboard/releases/download/\(tag)/dist.zip")!,
      assetSize: Int64(bytes.count),
      sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    return try await store.prepare(zip: zip, release: release)
  }
  private func makeFixture() async throws -> PortMigrationFixture {
    _ = NSApplication.shared
    let paths = AppPaths(
      root: FileManager.default.temporaryDirectory.appendingPathComponent(
        "ZashDockVersionLifecycle-\(UUID().uuidString)"))
    try paths.createDirectories()
    do {
      let store = try VersionStore(root: paths.root)
      let current = try await prepare(store, paths: paths, tag: "v0.6.0", marker: "version-initial")
      try await store.activate(current)
      let listener = try await bindFixture(current.directoryURL)
      var configuration = AppConfiguration()
      configuration.port = listener.port
      listener.stop()
      try ConfigurationStore(url: paths.configuration).save(configuration)
      return PortMigrationFixture(paths: paths, webRoot: current.directoryURL)
    } catch {
      try? FileManager.default.removeItem(at: paths.root)
      throw error
    }
  }
  private func withFixture(
    body: (PortMigrationFixture, AppModel) async throws -> Void
  ) async throws {
    let fixture = try await makeFixture()
    let model = fixture.model()
    await model.start()
    do {
      try await body(fixture, model)
      await fixture.cleanUp()
    } catch {
      await fixture.cleanUp()
      throw error
    }
  }
  private func directoryCount(_ paths: AppPaths) throws -> Int {
    try FileManager.default.contentsOfDirectory(
      at: paths.versions, includingPropertiesForKeys: [.isDirectoryKey]
    ).filter {
      try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }.count
  }

  private func localArchive(_ paths: AppPaths, marker: String, rendered: Bool = true) throws -> URL {
    let url = paths.root.appendingPathComponent("custom-panel-\(UUID()).zip")
    try archive(marker: marker, rendered: rendered).write(to: url)
    return url
  }
  private func install(_ zip: URL, into model: AppModel) async throws {
    model.install(zip: zip)
    let operation = try #require(model.operation)
    await operation.value
    #expect(model.operation == nil && !model.isBusy)
    if let paths = model.paths { #expect(try FileManager.default.contentsOfDirectory(atPath: paths.staging.path).isEmpty) }
  }

  @Test(.timeLimit(.minutes(1)))
  func firstInstallationAcceptsAnUnknownLocalZIPWithoutReleaseMetadata() async throws {
    _ = NSApplication.shared
    let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockLocalFirstInstall-\(UUID())"))
    try paths.createDirectories()
    let probe = paths.root.appendingPathComponent("port-probe", isDirectory: true)
    try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
    try Data("<div id='app'>Port reservation</div>".utf8).write(to: probe.appendingPathComponent("index.html"))
    let reservation = try await bindFixture(probe)
    var configuration = AppConfiguration(); configuration.port = reservation.port
    reservation.stop(); try ConfigurationStore(url: paths.configuration).save(configuration)
    let fixture = PortMigrationFixture(paths: paths, webRoot: probe)
    do {
      let model = fixture.model(); await model.start()
      #expect(model.phase == .uninstalled && model.currentVersion == nil && model.session == nil)
      let zip = try localArchive(paths, marker: "first-local-version")
      try await install(zip, into: model)
      #expect(model.phase == .ready && model.currentVersion?.source == .localArchive)
      #expect(model.currentVersion?.tag == "本地导入" && model.errorMessage == nil)
      #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("official-releases.json").path))
      #expect(try directoryCount(paths) == 1)
      #expect(try await model.session?.page.callJavaScript("return window.fixtureVersion;") as? String == "first-local-version")
      await fixture.cleanUp()
    } catch { await fixture.cleanUp(); throw error }
  }

  @Test(.timeLimit(.minutes(1)))
  func arbitraryLocalZIPInstallsOfflineAndRemovesPreviousResourcesWithoutLosingBusinessData() async throws {
    try await withFixture { fixture, model in
      let oldVersion = try #require(model.currentVersion)
      let oldPort = model.configuration.port
      let expected = try officialStorage()
      try await writeStorage(model, values: expected)
      let zip = try localArchive(fixture.paths, marker: "custom-offline-version")
      // Local import must not read an official-release catalogue or identify a known digest.
      try Data("{invalid catalogue must not be read".utf8).write(to: fixture.paths.root.appendingPathComponent("official-releases.json"))
      let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
      try await install(zip, into: model)
      let current = try #require(model.currentVersion)
      #expect(current.source == .localArchive && current.tag == "本地导入" && current.sha256 == digest)
      #expect(current.id != oldVersion.id)
      #expect(model.errorMessage == nil && model.configuration.port == oldPort)
      #expect(!FileManager.default.fileExists(atPath: oldVersion.directoryURL.path))
      #expect(try directoryCount(fixture.paths) == 1)
      try await assertPage(model, marker: "custom-offline-version", storage: expected)
      #expect(try await model.store?.current() == current)
      await fixture.shutdown(model)
      let reopened = fixture.model(); await reopened.start()
      #expect(reopened.currentVersion == current && reopened.configuration.port == oldPort)
      try await assertPage(reopened, marker: "custom-offline-version", storage: expected)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func eachSuccessfulLocalUpdateKeepsOnlyCurrentResources() async throws {
    try await withFixture { fixture, model in
      let expected = try officialStorage()
      try await writeStorage(model, values: expected)
      let port = model.configuration.port
      for number in 1...3 {
        let oldVersion = try #require(model.currentVersion)
        let marker = "single-current-\(number)"
        try await install(localArchive(fixture.paths, marker: marker), into: model)
        let current = try #require(model.currentVersion)
        #expect(current.source == .localArchive && current.id != oldVersion.id)
        #expect(model.configuration.port == port && model.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: oldVersion.directoryURL.path))
        #expect(try directoryCount(fixture.paths) == 1)
        #expect(try await model.store?.current() == current)
        try await assertPage(model, marker: marker, storage: expected)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func unrenderedLocalCandidateFailsWithoutCommittingOrDeletingWorkingResources() async throws {
    try await withFixture { fixture, model in
      let original = try #require(model.currentVersion)
      let expected = try officialStorage()
      try await writeStorage(model, values: expected)
      let pointer = fixture.paths.root.appendingPathComponent("versions-state.json")
      let pointerBytes = try Data(contentsOf: pointer)
      let configBytes = try Data(contentsOf: fixture.paths.configuration)
      try await install(localArchive(fixture.paths, marker: "never-rendered", rendered: false), into: model)
      #expect(model.phase == .ready && model.currentVersion == original)
      #expect(model.errorMessage != nil)
      #expect(try await model.store?.current() == original)
      #expect(try Data(contentsOf: pointer) == pointerBytes)
      #expect(try Data(contentsOf: fixture.paths.configuration) == configBytes)
      #expect(try directoryCount(fixture.paths) == 1)
      #expect(FileManager.default.fileExists(atPath: original.directoryURL.path))
      try await assertPage(model, marker: "version-initial", storage: expected)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelledLocalCandidateKeepsWorkingResourcesAndLatestWebKitData() async throws {
    try await withFixture { fixture, model in
      let original = try #require(model.currentVersion)
      let expected = try officialStorage()
      try await writeStorage(model, values: expected)
      let pointer = fixture.paths.root.appendingPathComponent("versions-state.json")
      let originalPointer = try Data(contentsOf: pointer)
      model.install(zip: try localArchive(fixture.paths, marker: "cancelled-candidate", rendered: false))
      let operation = try #require(model.operation)
      try await Task.sleep(for: .seconds(2))
      #expect(model.isBusy)
      model.cancel(); await operation.value
      #expect(operation.isCancelled && model.operation == nil && !model.isBusy)
      #expect(model.phase == .ready)
      #expect(model.currentVersion == original)
      #expect(model.errorMessage == nil)
      #expect(model.server?.versionID == original.id)
      #expect(try await model.store?.current() == original)
      #expect(try Data(contentsOf: pointer) == originalPointer)
      #expect(try directoryCount(fixture.paths) == 1)
      try await assertPage(model, marker: "version-initial", storage: expected)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func corruptLocalArchiveCanBeRetriedWithAnyValidOfflineZIP() async throws {
    try await withFixture { fixture, model in
      let original = try #require(model.currentVersion)
      let expected = try officialStorage()
      try await writeStorage(model, values: expected)
      let bad = fixture.paths.root.appendingPathComponent("damaged.zip")
      try Data("not a ZIP".utf8).write(to: bad)
      try await install(bad, into: model)
      #expect(model.currentVersion == original && model.phase == .ready && model.errorMessage != nil)
      #expect(FileManager.default.fileExists(atPath: original.directoryURL.path))
      try await model.originStorage.verify(expected, at: try #require(model.session).origin)
      try await install(localArchive(fixture.paths, marker: "offline-retry"), into: model)
      #expect(model.currentVersion?.source == .localArchive && model.errorMessage == nil)
      #expect(try directoryCount(fixture.paths) == 1)
      try await assertPage(model, marker: "offline-retry", storage: expected)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func loopbackCacheCleanupKeepsLocalStorageAndBlocksPWARegistration() async throws {
    try await withFixture { _, model in
      #expect(model.phase == .ready)
      let session = try #require(model.session)
      let name = "zashdock-stale-panel-\(UUID().uuidString)"
      let marker = "keep-local-storage-\(UUID().uuidString)"
      try await session.page.callJavaScript(
        """
        localStorage.setItem('cache-survival-marker', marker);
        const cache = await caches.open(cacheName);
        await cache.put('/stale-panel.js', new Response('old-version', {headers: {'Content-Type': 'text/javascript'}}));
        """, arguments: ["marker": marker, "cacheName": name])
      #expect(
        try await session.page.callJavaScript(
          "return await caches.has(cacheName);", arguments: ["cacheName": name]) as? Bool == true)
      await WebCacheController.clearLoopbackCaches(in: model.dataStore)
      #expect(
        try await session.page.callJavaScript(
          "return await caches.has(cacheName);", arguments: ["cacheName": name]) as? Bool == false)
      #expect(
        try await session.page.callJavaScript(
          "return localStorage.getItem('cache-survival-marker');") as? String == marker)
      let registration = try await session.page.callJavaScript(
        """
        if (!navigator.serviceWorker) return 'unavailable';
        try { await navigator.serviceWorker.register('/sw.js'); return 'registered'; }
        catch (error) { return 'rejected'; }
        """)
      #expect(registration as? String == "rejected")
      var request = URLRequest(url: session.origin.appendingPathComponent("sw.js"))
      request.setValue("script", forHTTPHeaderField: "Service-Worker")
      let (_, response) = try await URLSession.shared.data(for: request)
      #expect((response as? HTTPURLResponse)?.statusCode == 403)
      #expect(
        try await session.page.callJavaScript(
          "return localStorage.getItem('cache-survival-marker');") as? String == marker)
    }
  }

  private func archive(marker: String, rendered: Bool) throws -> Data {
    let markerJSON = String(decoding: try JSONEncoder().encode(marker), as: UTF8.self)
    let content = rendered ? "<p>\(marker)</p>" : ""
    // A rejected candidate actively changes both storage systems. Its preview must
    // be isolated so restoring the working version still sees the original data.
    let rejectedMutation =
      rendered
      ? ""
      : #"""
      localStorage.clear();localStorage.setItem('failed-candidate','must-not-reach-live-origin');
      (async()=>{
       for(const name of ['base64','connection-history']){
        const db=await new Promise(resolve=>{const request=indexedDB.open(name);request.onsuccess=()=>resolve(request.result);});
        await new Promise(resolve=>{const transaction=db.transaction(name,'readwrite');transaction.objectStore(name).clear();transaction.oncomplete=resolve;});db.close();
       }
      })().catch(()=>{});
      """#
    let html = """
      <!doctype html><html><head><script>
      \(originFirstReadFixtureScript)
      </script><script src="/assets/app.js"></script></head><body><div id="app">\(content)</div></body></html>
      """
    let files = [
      ("index.html", Data(html.utf8)),
      ("assets/app.js", Data("window.fixtureVersion = \(markerJSON);\(rejectedMutation)".utf8)),
      ("sw.js", Data("self.addEventListener('fetch', event => {});".utf8)),
    ]
    var local = Data()
    var central = Data()
    for (path, bytes) in files {
      let name = Data(path.utf8)
      let offset = local.count
      let crc = checksum(bytes)
      local.lifecycleLE32(0x0403_4b50)
      local.lifecycleLE16(20)
      local.lifecycleLE16(0x0800)
      local.lifecycleLE16(0)
      local.lifecycleLE16(0)
      local.lifecycleLE16(0)
      local.lifecycleLE32(crc)
      local.lifecycleLE32(UInt32(bytes.count))
      local.lifecycleLE32(UInt32(bytes.count))
      local.lifecycleLE16(UInt16(name.count))
      local.lifecycleLE16(0)
      local.append(name)
      local.append(bytes)
      central.lifecycleLE32(0x0201_4b50)
      central.lifecycleLE16(0x0314)
      central.lifecycleLE16(20)
      central.lifecycleLE16(0x0800)
      central.lifecycleLE16(0)
      central.lifecycleLE16(0)
      central.lifecycleLE16(0)
      central.lifecycleLE32(crc)
      central.lifecycleLE32(UInt32(bytes.count))
      central.lifecycleLE32(UInt32(bytes.count))
      central.lifecycleLE16(UInt16(name.count))
      central.lifecycleLE16(0)
      central.lifecycleLE16(0)
      central.lifecycleLE16(0)
      central.lifecycleLE16(0)
      central.lifecycleLE32(0x81a4_0000)
      central.lifecycleLE32(UInt32(offset))
      central.append(name)
    }
    let offset = local.count
    local.append(central)
    local.lifecycleLE32(0x0605_4b50)
    local.lifecycleLE16(0)
    local.lifecycleLE16(0)
    local.lifecycleLE16(UInt16(files.count))
    local.lifecycleLE16(UInt16(files.count))
    local.lifecycleLE32(UInt32(central.count))
    local.lifecycleLE32(UInt32(offset))
    local.lifecycleLE16(0)
    return local
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
  fileprivate mutating func lifecycleLE16(_ value: UInt16) {
    append(UInt8(value & 255))
    append(UInt8(value >> 8))
  }
  fileprivate mutating func lifecycleLE32(_ value: UInt32) {
    lifecycleLE16(UInt16(value & 0xffff))
    lifecycleLE16(UInt16(value >> 16))
  }
}
