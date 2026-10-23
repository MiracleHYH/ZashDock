import Foundation
import CryptoKit
import Testing
@testable import ZashDockCore

private struct ZIPItem {
    var path: String
    var data: Data
    var method: UInt16 = 0
    var mode: UInt32 = 0x81a4
    var descriptor = false
    var crcOverride: UInt32?
}
private enum Fixture {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static let index = Data("<!doctype html><html><head><script src=\"assets/app.js\"></script></head><body></body></html>".utf8)
    static func items(_ value: Int = 0, method: UInt16 = 0) -> [ZIPItem] {
        [ZIPItem(path: "index.html", data: index, method: method), ZIPItem(path: "assets/app.js", data: Data("window.version=\(value);".utf8), method: method)]
    }
    static func crc(_ data: Data) -> UInt32 {
        var result: UInt32 = 0xffff_ffff
        for byte in data {
            result ^= UInt32(byte)
            for _ in 0..<8 { result = result & 1 == 1 ? (result >> 1) ^ 0xedb8_8320 : result >> 1 }
        }
        return result ^ 0xffff_ffff
    }
    static func zip(_ items: [ZIPItem]) -> Data {
        var output = Data(), central = Data()
        for item in items {
            let offset = output.count, name = Data(item.path.utf8), checksum = item.crcOverride ?? crc(item.data)
            let flags: UInt16 = item.descriptor ? 0x0808 : 0x0800
            var encoded = item.data
            if item.method == 8 {
                // A final raw DEFLATE stored block exercises zlib without a fixture generator dependency.
                encoded = Data([1]); encoded.le16(UInt16(item.data.count)); encoded.le16(~UInt16(item.data.count)); encoded.append(item.data)
            }
            output.le32(0x04034b50); output.le16(20); output.le16(flags); output.le16(item.method)
            output.le16(0); output.le16(0); output.le32(item.descriptor ? 0 : checksum)
            output.le32(item.descriptor ? 0 : UInt32(encoded.count)); output.le32(item.descriptor ? 0 : UInt32(item.data.count))
            output.le16(UInt16(name.count)); output.le16(0); output.append(name); output.append(encoded)
            if item.descriptor { output.le32(0x08074b50); output.le32(checksum); output.le32(UInt32(encoded.count)); output.le32(UInt32(item.data.count)) }
            central.le32(0x02014b50); central.le16(0x0314); central.le16(20); central.le16(flags); central.le16(item.method)
            central.le16(0); central.le16(0); central.le32(checksum); central.le32(UInt32(encoded.count)); central.le32(UInt32(item.data.count))
            central.le16(UInt16(name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(item.mode << 16); central.le32(UInt32(offset)); central.append(name)
        }
        let centralOffset = output.count
        output.append(central); output.le32(0x06054b50); output.le16(0); output.le16(0)
        output.le16(UInt16(items.count)); output.le16(UInt16(items.count)); output.le32(UInt32(central.count)); output.le32(UInt32(centralOffset)); output.le16(0)
        return output
    }
    static func release(_ zip: Data, number: Int = 1) -> ZashboardRelease {
        ZashboardRelease(tag: "v0.0.\(number)", publishedAt: Date(timeIntervalSince1970: Double(number)),
                         assetURL: URL(string: "https://github.com/Zephyruso/zashboard/releases/download/v0.0.\(number)/dist.zip")!,
                         assetSize: Int64(zip.count), sha256: SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined())
    }
    static func install(_ number: Int, store: VersionStore, root: URL) async throws -> InstalledVersion {
        let bytes = zip(items(number)); let url = root.appendingPathComponent("input-\(number).zip")
        try bytes.write(to: url)
        return try await store.prepare(zip: url, release: release(bytes, number: number))
    }
}
private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(value & 255)); append(UInt8(value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(value & 0xffff)); le16(UInt16(value >> 16)) }
}

@Test func freshStoreHasNoInstallationAndStagingRecovers() async throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let staging = root.appendingPathComponent("staging"); try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: staging.appendingPathComponent("partial.zip"))
    let store = try VersionStore(root: root)
    #expect(try await store.current() == nil)
    #expect(try await store.history().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
}

@Test(arguments: [UInt16(0), UInt16(8)]) func validatesStoredAndDeflatedZIP(method: UInt16) throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("input.zip"), target = root.appendingPathComponent("content")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    var items = Fixture.items(method: method); items[0].descriptor = true
    try Fixture.zip(items).write(to: source)
    try SafeZIPExtractor().extract(source, to: target)
    #expect(try Data(contentsOf: target.appendingPathComponent("index.html")) == Fixture.index)
}

@Test(arguments: ["../outside.js", "/outside.js", "a/../../escape.js", "a\\escape.js", "a/%2e%2e/escape.js", "a//b.js", "C:escape.js"])
func rejectsZIPSlip(path: String) throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("input.zip"), target = root.appendingPathComponent("content")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Fixture.zip(Fixture.items() + [ZIPItem(path: path, data: Data([1]))]).write(to: source)
    #expect(throws: (any Error).self) { try SafeZIPExtractor().extract(source, to: target) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
}

@Test func rejectsSymlinkCRCConflictAndCaseCollision() throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    for (index, items) in [
        Fixture.items() + [ZIPItem(path: "link", data: Data("/tmp".utf8), mode: 0xa1ff)],
        [ZIPItem(path: "index.html", data: Fixture.index, crcOverride: 1)] + [Fixture.items()[1]],
        Fixture.items() + [ZIPItem(path: "INDEX.HTML", data: Fixture.index)]
    ].enumerated() {
        let target = root.appendingPathComponent("content\(index)"); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("input\(index).zip"); try Fixture.zip(items).write(to: source)
        #expect(throws: (any Error).self) { try SafeZIPExtractor().extract(source, to: target) }
    }
}

@Test func rejectsTruncationLocalHeaderMismatchAndExpandedLimit() throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let good = Fixture.zip(Fixture.items())
    var mismatch = good; mismatch[30] = 120
    for (index, bytes) in [good.dropLast(1), mismatch].enumerated() {
        let source = root.appendingPathComponent("input\(index).zip"), target = root.appendingPathComponent("target\(index)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true); try Data(bytes).write(to: source)
        #expect(throws: (any Error).self) { try SafeZIPExtractor().extract(source, to: target) }
    }
    var limits = SafeZIPExtractor.Limits(); limits.maxExpandedBytes = 1
    let source = root.appendingPathComponent("limit.zip"), target = root.appendingPathComponent("limit")
    try good.write(to: source); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try SafeZIPExtractor(limits: limits).extract(source, to: target) }
}

@Test(arguments: [0, 1, 3]) func retentionCountsAndRollbackUseActivationOrder(maxHistory: Int) async throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try VersionStore(root: root)
    var installed: [InstalledVersion] = []
    for number in 1...6 {
        let version = try await Fixture.install(number, store: store, root: root)
        installed.append(version); try await store.activate(version); try await store.prune(maxHistory: maxHistory)
        #expect(try await store.current()?.id == version.id)
        #expect(try await store.history().count == min(number - 1, maxHistory))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("versions").path).count == min(number, maxHistory + 1))
    }
    if maxHistory > 0 {
        let previous = try #require(await store.history().first)
        try await store.activate(previous); try await store.prune(maxHistory: maxHistory)
        #expect(try await store.current()?.id == previous.id)
        #expect(try await store.history().first?.id == installed.last?.id)
        #expect(try await store.history().count == maxHistory)
    }
}

@Test func stagingAndFailedUpdatesPreserveCurrentAndUserData() async throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try VersionStore(root: root)
    let first = try await Fixture.install(1, store: store, root: root); try await store.activate(first)
    let snapshot = root.appendingPathComponent("storage.aesgcm"); try Data([1,2,3]).write(to: snapshot)
    let second = try await Fixture.install(2, store: store, root: root)
    #expect(try await store.current() == first)
    #expect(try await store.history().isEmpty)
    let damaged = root.appendingPathComponent("damaged.zip"); try Data([1,2,3]).write(to: damaged)
    let official = Fixture.release(Fixture.zip(Fixture.items(3)), number: 3)
    await #expect(throws: (any Error).self) { try await store.prepare(zip: damaged, release: official) }
    #expect(try await store.current() == first)
    try await store.activate(second); try await store.prune(maxHistory: 0, protecting: [first.id])
    #expect(FileManager.default.fileExists(atPath: first.directoryURL.path))
    try await store.prune(maxHistory: 0)
    #expect(!FileManager.default.fileExists(atPath: first.directoryURL.path))
    #expect(try Data(contentsOf: snapshot) == Data([1,2,3]))
    let reopened = try VersionStore(root: root)
    #expect(try await reopened.current() == second)
}

@Test func detectsInstallationCorruptionAndCanStageRepair() async throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try VersionStore(root: root)
    let first = try await Fixture.install(1, store: store, root: root); try await store.activate(first)
    try Data("corrupt".utf8).write(to: first.directoryURL.appendingPathComponent("index.html"))
    await #expect(throws: (any Error).self) { try await store.current() }
    let repaired = try await Fixture.install(1, store: store, root: root)
    #expect(repaired.id != first.id)
    try await store.activate(repaired)
    #expect(try await store.current() == repaired)
}

@Test func rejectsUntrustedReleaseAndUnknownOfflineZIP() async throws {
    try ZashboardRelease.offlineSeed.validate()
    let release = ZashboardRelease(tag: "v1", publishedAt: Date(), assetURL: URL(string: "https://example.com/dist.zip")!, assetSize: 1, sha256: String(repeating: "a", count: 64))
    #expect(throws: (any Error).self) { try release.validate() }
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("unofficial.zip"); try Fixture.zip(Fixture.items()).write(to: source)
    let client = ReleaseClient()
    await #expect(throws: (any Error).self) { try await client.identifyLocalZIP(source) }
    let catalog = try await client.catalogForLocalImport()
    #expect(catalog.contains(.offlineSeed))
}

@Test func cancelledPreparationDoesNotActivateOrLeakStaging() async throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try VersionStore(root: root)
    let bytes = Fixture.zip(Fixture.items()), source = root.appendingPathComponent("input.zip")
    try bytes.write(to: source)
    let task = Task { try await store.prepare(zip: source, release: Fixture.release(bytes)) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await store.current() == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ZASHDOCK_LIVE_INSTALL_TEST"] == "1"))
func officialLiveDownloadAndPrepare() async throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let client = ReleaseClient(catalogURL: root.appendingPathComponent("catalog.json"))
    let release = try await client.latest()
    try release.validate()
    let archive = root.appendingPathComponent("official.zip")
    try await client.download(release, to: archive)
    #expect(try await client.identifyLocalZIP(archive) == release)
    let store = try VersionStore(root: root)
    let installed = try await store.prepare(zip: archive, release: release)
    #expect(installed.tag == release.tag)
    #expect(FileManager.default.fileExists(atPath: installed.directoryURL.appendingPathComponent("index.html").path))
    #expect(try await store.current() == nil)
    try await store.activate(installed)
    #expect(try await store.current() == installed)
    print("Official release verified: \(release.tag), bytes=\(release.assetSize), SHA-256=\(release.sha256)")
}

@MainActor @Test func managerLocalImportFailureRetryAndCommit() async throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try VersionStore(root: root)
    let bytes = Fixture.zip(Fixture.items()), official = Fixture.release(bytes)
    let catalogURL = root.appendingPathComponent("catalog.json")
    try AtomicFile.encode([official], to: catalogURL)
    let client = ReleaseClient(catalogURL: catalogURL)
    let manager = ZashboardUpdateManager(store: store, client: client, downloadDirectory: root.appendingPathComponent("staging"))
    let invalid = root.appendingPathComponent("invalid.zip"); try Data([1,2,3]).write(to: invalid)
    await #expect(throws: (any Error).self) { try await manager.stageLocalZIP(invalid) }
    #expect(!manager.isBusy); #expect(manager.lastError != nil)
    let valid = root.appendingPathComponent("valid.zip"); try bytes.write(to: valid)
    let candidate = try await manager.stageLocalZIP(valid)
    #expect(manager.lastError == nil); #expect(!manager.isBusy)
    #expect(try await store.current() == nil)
    try await manager.commit(version: candidate, maxHistory: 1)
    #expect(try await store.current() == candidate)
}

@MainActor @Test func managerCancellationCoversCatalogIdentification() async throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try VersionStore(root: root)
    var items = Fixture.items(); items[1].data = Data(repeating: 65, count: 8 * 1_024 * 1_024)
    let bytes = Fixture.zip(items), catalog = root.appendingPathComponent("catalog.json")
    try AtomicFile.encode([Fixture.release(bytes)], to: catalog)
    let client = ReleaseClient(catalogURL: catalog)
    let manager = ZashboardUpdateManager(store: store, client: client, downloadDirectory: root.appendingPathComponent("staging"))
    let valid = root.appendingPathComponent("valid.zip"); try bytes.write(to: valid)
    let task = Task { try await manager.stageLocalZIP(valid) }
    while !manager.isBusy { await Task.yield() }
    manager.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!manager.isBusy)
    #expect(try await store.current() == nil)
}

@Test func discardOnlyRemovesUncommittedCandidate() async throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try VersionStore(root: root)
    let first = try await Fixture.install(1, store: store, root: root); try await store.activate(first)
    let candidate = try await Fixture.install(2, store: store, root: root)
    try await store.discardPrepared(first)
    #expect(try await store.current() == first)
    try await store.discardPrepared(candidate)
    #expect(!FileManager.default.fileExists(atPath: candidate.directoryURL.path))
    #expect(try await store.history().isEmpty)
}

@Test func corruptedCatalogDoesNotDisableOfficialOfflineSeed() async throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let catalog = root.appendingPathComponent("catalog.json")
    try Data("{truncated".utf8).write(to: catalog)
    let client = ReleaseClient(catalogURL: catalog)
    #expect(try await client.catalogForLocalImport().contains(.offlineSeed))
    let bad = ZashboardRelease(tag: "bad", publishedAt: Date(), assetURL: URL(string: "https://attacker.example/dist.zip")!, assetSize: 1, sha256: "bad")
    try AtomicFile.encode([bad], to: catalog)
    #expect(try await client.catalogForLocalImport() == [.offlineSeed])
}

@Test func boundedZIPCopyRejectsReplacementGrowthAndSymlinks() throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Fixture.zip(Fixture.items()), source = root.appendingPathComponent("source.zip")
    let target = root.appendingPathComponent("staged.zip")
    try bytes.write(to: source)
    let replaced = try BoundedZIPInput(url: source, expectedSize: Int64(bytes.count))
    try FileManager.default.removeItem(at: source); try bytes.write(to: source)
    #expect(throws: (any Error).self) { try replaced.copy(to: target) }
    #expect(!FileManager.default.fileExists(atPath: target.path))
    let grown = try BoundedZIPInput(url: source, expectedSize: Int64(bytes.count))
    let handle = try FileHandle(forWritingTo: source)
    try handle.seekToEnd(); try handle.write(contentsOf: Data([1])); try handle.close()
    #expect(throws: (any Error).self) { try grown.copy(to: target) }
    #expect(!FileManager.default.fileExists(atPath: target.path))
    let symlink = root.appendingPathComponent("symlink.zip")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
    #expect(throws: (any Error).self) { try BoundedZIPInput(url: symlink, expectedSize: Int64(bytes.count + 1)) }
}

@Test func boundedZIPCopyRejectsOversizeBeforeWritingAndCopiesValidInput() throws {
    let root = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let huge = root.appendingPathComponent("huge.zip")
    FileManager.default.createFile(atPath: huge.path, contents: nil)
    let handle = try FileHandle(forWritingTo: huge)
    try handle.truncate(atOffset: UInt64(SafeZIPExtractor.Limits.standard.maxArchiveBytes + 1)); try handle.close()
    #expect(throws: (any Error).self) { try BoundedZIPInput(url: huge, expectedSize: 1) }
    let bytes = Fixture.zip(Fixture.items()), source = root.appendingPathComponent("valid.zip"), target = root.appendingPathComponent("staged.zip")
    try bytes.write(to: source)
    try BoundedZIPInput(url: source, expectedSize: Int64(bytes.count)).copy(to: target)
    #expect(try Data(contentsOf: target) == bytes)
    #expect(throws: (any Error).self) { try ReleaseClient.digest(of: source, maximumBytes: Int64(bytes.count - 1)) }
}
