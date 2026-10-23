import AppKit
import CryptoKit
import Foundation
import Testing
import ZashDockCore

@testable import ZashDock

@MainActor
@Suite(.serialized)
struct CorruptHistoryIntegrationTests {
  private let remoteIDs = [
    "091184d7-54c7-4663-9824-f81e70f30bca", "c67920af-cc75-4b62-8741-3603429561f0",
  ]

  private func remotes() throws -> OriginStoragePayload {
    let values = remoteIDs.enumerated().map { index, uuid in
      [
        "type": "clash", "protocol": "http",
        "host": index == 0 ? "192.0.2.1" : "kernel.vpn.example",
        "port": "9090", "secondaryPath": "", "password": "corrupt-history-fixture-\(index)",
        "uuid": uuid, "label": "Rollback fixture \(index)",
      ]
    }
    return OriginStoragePayload(
      localStorage: [
        "setup/api-list": String(decoding: try JSONEncoder().encode(values), as: UTF8.self),
        "setup/active-uuid": remoteIDs[1], "config/default-theme": "light",
        "config/auto-theme": "true",
      ],
      databases: [
        "base64": ["background-image": "data:image/png;base64,Y29ycnVwdC1oaXN0b3J5LWZpeHR1cmU="],
        "connection-history": [
          "rollback-fixture-sourceIP": "[{\"key\":\"10.0.0.1\",\"download\":42}]"
        ],
      ])
  }

  @Test(.timeLimit(.minutes(1)))
  func realUpdateSkipsDamagedV2ThenRollsBackToHealthyV1WithoutLosingRemotes() async throws {
    _ = NSApplication.shared
    let paths = AppPaths(
      root: FileManager.default.temporaryDirectory.appendingPathComponent(
        "ZashDockCorruptHistory-\(UUID().uuidString)"))
    try paths.createDirectories()
    let store = try VersionStore(root: paths.root)
    let first = try await prepare(1, store: store, paths: paths)
    try await store.activate(first)
    let reservation = try await bindFixture(first.directoryURL)
    var configuration = AppConfiguration()
    configuration.port = reservation.port
    configuration.maxRollbackVersions = 1
    reservation.stop()
    try ConfigurationStore(url: paths.configuration).save(configuration)
    let expected = try remotes()
    let fixture = PortMigrationFixture(paths: paths, webRoot: first.directoryURL)
    try await OriginStorageTransfer(dataStore: fixture.dataStore).restore(
      expected, to: URL(string: "http://127.0.0.1:\(configuration.port)")!)
    do {
      let model = fixture.model()
      await model.start()
      try await assertPage(model, number: 1, expected: expected)
      let second = try await prepare(2, store: store, paths: paths)
      try await model.switchVersion(second)
      try await assertPage(model, number: 2, expected: expected)
      #expect(model.history == [first])
      // The old page is already loaded. Simulate a damaged v2 resource immediately
      // before committing healthy v3; cleanup must preserve v1 as the sole rollback.
      try Data("damaged former current version".utf8).write(
        to: second.directoryURL.appendingPathComponent("index.html"))
      let third = try await prepare(3, store: store, paths: paths)
      try await model.switchVersion(third)
      try await assertPage(model, number: 3, expected: expected)
      #expect(model.currentVersion == third)
      #expect(model.history == [first])
      #expect(try await store.current() == third)
      #expect(try await store.history() == [first])
      #expect(!FileManager.default.fileExists(atPath: second.directoryURL.path))
      #expect(try await store.validate(first) == first)
      let report = try #require(try await store.lastInvalidHistoryReport())
      #expect(report.invalidHistoryIDs == [second.id])
      #expect(report.retainedHistoryIDs == [first.id])
      #expect(report.plannedRemovalIDs == [second.id])
      try await model.switchVersion(first)
      try await assertPage(model, number: 1, expected: expected)
      #expect(model.history == [third])
      #expect(try await store.lastInvalidHistoryReport() == report)
      #expect(try FileManager.default.contentsOfDirectory(atPath: paths.versions.path).count == 2)
      await fixture.shutdown(model)
      let restarted = fixture.model()
      await restarted.start()
      try await assertPage(restarted, number: 1, expected: expected)
      #expect(restarted.history == [third])
      #expect(try await store.lastInvalidHistoryReport() == report)
      await fixture.cleanUp()
    } catch {
      await fixture.cleanUp()
      throw error
    }
  }

  private func assertPage(_ model: AppModel, number: Int, expected: OriginStoragePayload)
    async throws
  {
    #expect(model.phase == .ready)
    let session = try #require(model.session)
    #expect(
      try await session.page.callJavaScript("return window.fixtureVersion;") as? Int == number)
    let encoded = try #require(
      try await session.page.callJavaScript("return window.initialStorageJSON;") as? String)
    let initial = try JSONDecoder().decode([String: String].self, from: Data(encoded.utf8))
    #expect(initial == expected.localStorage)
    let backends = try JSONDecoder().decode(
      [[String: String]].self, from: Data(try #require(initial["setup/api-list"]).utf8))
    #expect(backends.count == 2 && backends.map { $0["uuid"] } == remoteIDs.map(Optional.some))
    #expect(initial["setup/active-uuid"] == remoteIDs[1])
    #expect(try await initialBusinessDatabases(session) == expected.databases)
    try await model.originStorage.verify(expected, at: session.origin)
  }

  private func prepare(_ number: Int, store: VersionStore, paths: AppPaths) async throws
    -> InstalledVersion
  {
    let html =
      "<html><head><script>\(originFirstReadFixtureScript)</script><script src='/assets/app.js'></script></head><body><div id='app'>Version \(number)</div></body></html>"
    let bytes = zip([
      ("index.html", Data(html.utf8)),
      ("assets/app.js", Data("window.fixtureVersion=\(number);".utf8)),
    ])
    let source = paths.root.appendingPathComponent("fixture-\(number).zip")
    try bytes.write(to: source)
    let tag = "v0.95.\(number)"
    let release = ZashboardRelease(
      tag: tag, publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      assetURL: URL(
        string: "https://github.com/Zephyruso/zashboard/releases/download/\(tag)/dist.zip")!,
      assetSize: Int64(bytes.count),
      sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    return try await store.prepare(zip: source, release: release)
  }

  private func zip(_ files: [(String, Data)]) -> Data {
    var output = Data()
    var central = Data()
    for (path, bytes) in files {
      let name = Data(path.utf8)
      let offset = output.count
      var crc: UInt32 = 0xffff_ffff
      for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
      }
      crc ^= 0xffff_ffff
      output.corruptLE32(0x0403_4b50)
      output.corruptLE16(20)
      output.corruptLE16(0x0800)
      output.corruptLE16(0)
      output.corruptLE16(0)
      output.corruptLE16(0)
      output.corruptLE32(crc)
      output.corruptLE32(UInt32(bytes.count))
      output.corruptLE32(UInt32(bytes.count))
      output.corruptLE16(UInt16(name.count))
      output.corruptLE16(0)
      output.append(name)
      output.append(bytes)
      central.corruptLE32(0x0201_4b50)
      central.corruptLE16(0x0314)
      central.corruptLE16(20)
      central.corruptLE16(0x0800)
      central.corruptLE16(0)
      central.corruptLE16(0)
      central.corruptLE16(0)
      central.corruptLE32(crc)
      central.corruptLE32(UInt32(bytes.count))
      central.corruptLE32(UInt32(bytes.count))
      central.corruptLE16(UInt16(name.count))
      central.corruptLE16(0)
      central.corruptLE16(0)
      central.corruptLE16(0)
      central.corruptLE16(0)
      central.corruptLE32(0x81a4_0000)
      central.corruptLE32(UInt32(offset))
      central.append(name)
    }
    let offset = output.count
    output.append(central)
    output.corruptLE32(0x0605_4b50)
    output.corruptLE16(0)
    output.corruptLE16(0)
    output.corruptLE16(UInt16(files.count))
    output.corruptLE16(UInt16(files.count))
    output.corruptLE32(UInt32(central.count))
    output.corruptLE32(UInt32(offset))
    output.corruptLE16(0)
    return output
  }
}

extension Data {
  fileprivate mutating func corruptLE16(_ value: UInt16) {
    append(UInt8(value & 255))
    append(UInt8(value >> 8))
  }
  fileprivate mutating func corruptLE32(_ value: UInt32) {
    corruptLE16(UInt16(value & 0xffff))
    corruptLE16(UInt16(value >> 16))
  }
}
