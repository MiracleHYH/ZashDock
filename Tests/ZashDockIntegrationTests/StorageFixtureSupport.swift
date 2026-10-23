import AppKit
import CryptoKit
import Foundation
import WebKit
import ZashDockCore

func fixtureOrigin(_ port: UInt16) -> URL { URL(string: "http://127.0.0.1:\(port)")! }

final class FixtureLegacyKeyReader: LegacyStorageKeyReading, @unchecked Sendable {
    private let lock = NSLock()
    private var accesses = 0
    private var unavailable = false
    let byte: UInt8
    init(byte: UInt8 = 0x67, unavailable: Bool = false) { self.byte = byte; self.unavailable = unavailable }
    var accessCount: Int { lock.withLock { accesses } }
    func setUnavailable(_ value: Bool) { lock.withLock { unavailable = value } }
    func readKey() throws -> SymmetricKey {
        let fails = lock.withLock { accesses += 1; return unavailable }
        if fails { throw LegacyWebStorageError.keyUnavailable(-25300) }
        return SymmetricKey(data: Data(repeating: byte, count: 32))
    }
}

func writeLegacyFixture(_ values: [String: String], to url: URL, byte: UInt8 = 0x67) throws {
    let header = Data("ZASHDOCK-SNAPSHOT-1\n".utf8)
    let sealed = try AES.GCM.seal(JSONEncoder().encode(values), using: SymmetricKey(data: Data(repeating: byte, count: 32)), authenticating: header)
    guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
    try (header + combined).write(to: url)
}

func fixtureRemoteStorage() -> [String: String] {
    ["setup/api-list": #"[{"type":"clash","protocol":"http","host":"192.0.2.1","port":"9090","secondaryPath":"","password":"storage-fixture-one","uuid":"storage-one","label":"LAN fixture"},{"type":"clash","protocol":"http","host":"kernel.vpn.example","port":"9090","secondaryPath":"mihomo","password":"storage-fixture-two","uuid":"storage-two","label":"VPN fixture"}]"#,
     "setup/active-uuid": "storage-two", "config/default-theme": "light"]
}

func fixtureBusinessDatabases() -> [String: [String: String]] {
    ["base64": ["background-image": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jr1cAAAAASUVORK5CYII="],
     "connection-history": ["storage-two-sourceIP": #"[{"key":"192.0.2.10","download":1024,"upload":512,"count":2}]"#]]
}

@MainActor
func withStorageAppFixture(_ body: (AppPaths, WKWebsiteDataStore, InstalledVersion) async throws -> Void) async throws {
    _ = NSApplication.shared
    let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockStorageApp-\(UUID().uuidString)"))
    try paths.createDirectories()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let version = try writePersistedInstallation(paths)
    let listener = try await bindFixture(version.directoryURL)
    var configuration = AppConfiguration(); configuration.port = listener.port
    listener.stop(); try ConfigurationStore(url: paths.configuration).save(configuration)
    try await body(paths, .nonPersistent(), version)
}

/// A persisted fixture exercises production manifest/hash/state validation. ZIP validation
/// has separate installer coverage; all page resources and credentials here are fictional.
func writePersistedInstallation(_ paths: AppPaths, tag: String = "v0.92.0") throws -> InstalledVersion {
    let sha = String(repeating: "a", count: 64), id = tag + "-" + String(repeating: "a", count: 16)
    let directory = paths.versions.appendingPathComponent(id, isDirectory: true), content = directory.appendingPathComponent("content", isDirectory: true)
    try FileManager.default.createDirectory(at: content.appendingPathComponent("assets"), withIntermediateDirectories: true)
    let html = "<html><head><script>\(originFirstReadFixtureScript)</script><script src='/assets/app.js'></script></head><body><div id='app'>Recovery</div></body></html>"
    let files = [("assets/app.js", Data("window.ready=true;".utf8)), ("index.html", Data(html.utf8))]
    for (path, data) in files { try data.write(to: content.appendingPathComponent(path)) }
    let manifest: [String: Any] = ["schema": 1, "id": id, "installedAt": "2026-01-01T00:00:00Z",
        "release": ["tag": tag, "publishedAt": "2026-01-01T00:00:00Z", "assetURL": "https://github.com/Zephyruso/zashboard/releases/download/\(tag)/dist.zip", "assetSize": 1, "sha256": sha],
        "files": files.map { path, data in ["path": path, "size": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()] as [String: Any] }]
    try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
    try JSONSerialization.data(withJSONObject: ["schema": 1, "currentID": id, "activationOrder": [id]]).write(to: paths.root.appendingPathComponent("versions-state.json"))
    return InstalledVersion(id: id, tag: tag, sha256: sha, installedAt: Date(timeIntervalSince1970: 1_767_225_600), directoryURL: content)
}

// Test-only provenance for the supplied official fixture. Local import never consults this
// metadata or guesses the release identity; production contains no offline known-hash seed.
let officialV3291FixtureRelease = ZashboardRelease(
    tag: "v3.29.1", publishedAt: Date(timeIntervalSince1970: 1_790_151_447),
    assetURL: URL(string: "https://github.com/Zephyruso/zashboard/releases/download/v3.29.1/dist.zip")!,
    assetSize: 9_570_334,
    sha256: "4f16cce229e223bd07b5a3daccfbfb8bf349d7335572d412959284ab6c9bab50")
