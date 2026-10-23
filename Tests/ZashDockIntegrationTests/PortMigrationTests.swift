import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

struct PortMigrationKey: StorageSnapshotKeyProviding {
    func encryptionKey(createIfMissing: Bool) throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 0x5a, count: 32))
    }
}

@MainActor
final class PortMigrationFixture {
    let paths: AppPaths
    let webRoot: URL
    private var models: [AppModel] = []
    private var blockers: [LoopbackHTTPServer] = []
    init(paths: AppPaths, webRoot: URL) { self.paths = paths; self.webRoot = webRoot }
    func model() -> AppModel {
        let model = AppModel(paths: paths, keyProvider: PortMigrationKey())
        models.append(model); return model
    }
    func availablePort(excluding: Set<UInt16> = []) async throws -> UInt16 {
        for _ in 0..<30 {
            let reservation = try await bindFixture(webRoot)
            let port = reservation.port; reservation.stop()
            if !excluding.contains(port) { return port }
        }
        throw ZashDockError.server("端口迁移测试无法预留随机端口。")
    }
    func occupy(_ port: UInt16? = nil) async throws -> LoopbackHTTPServer {
        let server: LoopbackHTTPServer
        if let port {
            server = try LoopbackHTTPServer(root: webRoot, port: port, versionID: "port-blocker")
            _ = try await server.start()
        } else { server = try await bindFixture(webRoot) }
        blockers.append(server); return server
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
        try? FileManager.default.removeItem(at: paths.root)
    }
}

@MainActor
@Suite(.serialized)
struct PortMigrationTests {
    private let remoteIDs = ["10a86241-d292-46c1-9017-87da6e6a5a01", "20a86241-d292-46c1-9017-87da6e6a5a02"]

    private func expectedStorage() throws -> [String: String] {
        let backends: [[String: String]] = [
            ["type": "clash", "protocol": "http", "host": "10.20.0.2", "port": "9090", "secondaryPath": "", "password": "port-fixture-secret-one", "uuid": remoteIDs[0], "label": "LAN migration fixture"],
            ["type": "clash", "protocol": "http", "host": "mihomo.vpn.example", "port": "9090", "secondaryPath": "kernel", "password": "port-fixture-secret-two", "uuid": remoteIDs[1], "label": "VPN migration fixture"]
        ]
        return [
            "setup/api-list": String(decoding: try JSONEncoder().encode(backends), as: UTF8.self),
            "setup/active-uuid": remoteIDs[1], "config/default-theme": "light",
            "config/dark-theme": "dark", "config/auto-theme": "true"
        ]
    }
    private func assertOfficialRemotes(_ values: [String: String]) throws {
        let encoded = try #require(values["setup/api-list"])
        let backends = try JSONDecoder().decode([[String: String]].self, from: Data(encoded.utf8))
        #expect(backends.count == 2)
        #expect(backends.map { $0["uuid"] } == remoteIDs.map(Optional.some))
        #expect(backends.map { $0["type"] } == ["clash", "clash"])
        #expect(backends.map { $0["protocol"] } == ["http", "http"])
        #expect(backends.map { $0["host"] } == ["10.20.0.2", "mihomo.vpn.example"])
        #expect(backends.allSatisfy { $0["port"] == "9090" && $0["password"]?.isEmpty == false })
        #expect(values["setup/active-uuid"] == remoteIDs[1])
        #expect(values["config/dark-theme"] == "dark")
        #expect(values["config/auto-theme"] == "true")
    }
    private func initialStorage(_ session: WebSession) async throws -> [String: String] {
        let string = try #require(try await session.page.callJavaScript("return window.initialStorageJSON;") as? String)
        return try JSONDecoder().decode([String: String].self, from: Data(string.utf8))
    }
    private func currentStorage(_ session: WebSession) async throws -> [String: String] {
        let value = try await session.page.callJavaScript("return JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(key => [key, localStorage.getItem(key)])));")
        let string = try #require(value as? String)
        return try JSONDecoder().decode([String: String].self, from: Data(string.utf8))
    }
    private func writeStorage(_ model: AppModel, values: [String: String]) async throws {
        let session = try #require(model.session)
        try await session.page.callJavaScript("localStorage.clear(); for (const [key, value] of Object.entries(values)) localStorage.setItem(key, value);", arguments: ["values": values])
        try await session.flush()
        let vault = try #require(model.snapshotVault)
        #expect(try await vault.load().snapshot == values)
    }
    private func health(_ server: LoopbackHTTPServer) async throws -> [String: String] {
        let (data, response) = try await URLSession.shared.data(from: server.healthcheckURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    private func makeFixture(installed: Bool) async throws -> PortMigrationFixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockPortMigration-\(UUID().uuidString)")
        let paths = AppPaths(root: root)
        try paths.createDirectories()
        do {
            let probe = root.appendingPathComponent("fixture-probe", isDirectory: true)
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
            try Data("<html><body><div id='app'>Port probe</div><script></script></body></html>".utf8).write(to: probe.appendingPathComponent("index.html"))
            guard installed else { return PortMigrationFixture(paths: paths, webRoot: probe) }
            let archive = storedZIP()
            let zipURL = root.appendingPathComponent("fixture.zip"); try archive.write(to: zipURL)
            let release = ZashboardRelease(tag: "v0.0.5", publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                assetURL: URL(string: "https://github.com/Zephyruso/zashboard/releases/download/v0.0.5/dist.zip")!,
                assetSize: Int64(archive.count), sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined())
            let store = try VersionStore(root: root)
            let version = try await store.prepare(zip: zipURL, release: release)
            try await store.activate(version)
            let reservation = try await bindFixture(version.directoryURL)
            var configuration = AppConfiguration(); configuration.port = reservation.port
            reservation.stop()
            try ConfigurationStore(url: paths.configuration).save(configuration)
            // Every test origin starts from a canonical empty snapshot, regardless of persistent WebKit data.
            try await StorageSnapshotVault(url: paths.snapshot, keyProvider: PortMigrationKey()).save([:])
            return PortMigrationFixture(paths: paths, webRoot: version.directoryURL)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    private func withFixture(installed: Bool, body: (PortMigrationFixture) async throws -> Void) async throws {
        let fixture = try await makeFixture(installed: installed)
        do { try await body(fixture); await fixture.cleanUp() }
        catch { await fixture.cleanUp(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func freshApplicationShowsNativeInstallationPhase() async throws {
        try await withFixture(installed: false) { fixture in
            let model = fixture.model(); await model.start()
            #expect(model.phase == .uninstalled)
            #expect(model.currentVersion == nil)
            #expect(model.session == nil)
            #expect(model.server == nil)
            #expect(!model.isBusy)
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.configuration.path))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func runningApplicationMigratesTwoOfficialRemotesBeforeDocumentInitialization() async throws {
        try await withFixture(installed: true) { fixture in
            let model = fixture.model(); await model.start()
            #expect(model.phase == .ready)
            let expected = try expectedStorage()
            try await writeStorage(model, values: expected)
            let oldPort = model.configuration.port
            let newPort = try await fixture.availablePort(excluding: [oldPort])
            try await model.changePort(to: newPort)
            #expect(model.phase == .ready)
            #expect(model.configuration.port == newPort)
            #expect(model.server?.port == newPort)
            #expect(model.session?.origin.port == Int(newPort))
            #expect(try ConfigurationStore(url: fixture.paths.configuration).load().port == newPort)
            let migrated = try #require(model.session)
            let initial = try await initialStorage(migrated)
            #expect(initial == expected)
            try assertOfficialRemotes(initial)
            #expect(try await currentStorage(migrated) == expected)
            let vault = try #require(model.snapshotVault)
            #expect(try await vault.load().snapshot == expected)
            let encrypted = try Data(contentsOf: fixture.paths.snapshot)
            #expect(encrypted.range(of: Data("port-fixture-secret-one".utf8)) == nil)
            await fixture.shutdown(model)
            let restarted = fixture.model(); await restarted.start()
            #expect(restarted.phase == .ready)
            #expect(restarted.configuration.port == newPort)
            let restartedSession = try #require(restarted.session)
            #expect(try await initialStorage(restartedSession) == expected)
            try assertOfficialRemotes(try await currentStorage(restartedSession))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func occupiedTargetPreservesOriginalConfigurationListenerAndSnapshot() async throws {
        try await withFixture(installed: true) { fixture in
            let model = fixture.model(); await model.start()
            #expect(model.phase == .ready)
            let expected = try expectedStorage()
            try await writeStorage(model, values: expected)
            let originalSession = try #require(model.session), originalServer = try #require(model.server)
            let originalConfiguration = model.configuration
            let configurationBytes = try Data(contentsOf: fixture.paths.configuration)
            let blocker = try await fixture.occupy()
            #expect(blocker.port != originalConfiguration.port)
            await #expect(throws: (any Error).self) { try await model.changePort(to: blocker.port) }
            #expect(model.phase == .ready)
            #expect(!model.isBusy)
            #expect(model.configuration == originalConfiguration)
            #expect(model.server === originalServer)
            #expect(model.session === originalSession)
            #expect(try Data(contentsOf: fixture.paths.configuration) == configurationBytes)
            let vault = try #require(model.snapshotVault)
            #expect(try await vault.load().snapshot == expected)
            #expect(try await currentStorage(originalSession) == expected)
            #expect(try await health(originalServer)["nonce"] == originalServer.nonce)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func originalPortOccupiedBeforeRestartMigratesExclusivelyFromNativeSnapshot() async throws {
        try await withFixture(installed: true) { fixture in
            let first = fixture.model(); await first.start()
            #expect(first.phase == .ready)
            let expected = try expectedStorage()
            try await writeStorage(first, values: expected)
            let oldPort = first.configuration.port
            await fixture.shutdown(first)
            let blocker = try await fixture.occupy(oldPort)
            let restarted = fixture.model(); await restarted.start()
            #expect(restarted.phase == .unavailable)
            #expect(restarted.configuration.port == oldPort)
            #expect(restarted.currentVersion != nil)
            #expect(restarted.session == nil)
            #expect(restarted.server == nil)
            let vault = try #require(restarted.snapshotVault)
            #expect(try await vault.load().snapshot == expected)
            let newPort = try await fixture.availablePort(excluding: [oldPort])
            try await restarted.changePort(to: newPort)
            #expect(restarted.phase == .ready)
            #expect(restarted.configuration.port == newPort)
            #expect(try ConfigurationStore(url: fixture.paths.configuration).load().port == newPort)
            let migrated = try #require(restarted.session)
            #expect(try await initialStorage(migrated) == expected)
            try assertOfficialRemotes(try await currentStorage(migrated))
            #expect(try await vault.load().snapshot == expected)
            #expect(try await health(blocker)["nonce"] == blocker.nonce)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func uninstalledPortChangeChecksActualBindingBeforePersisting() async throws {
        try await withFixture(installed: false) { fixture in
            let model = fixture.model(); await model.start()
            #expect(model.phase == .uninstalled)
            let original = model.configuration
            let blocker = try await fixture.occupy()
            await #expect(throws: (any Error).self) { try await model.changePort(to: blocker.port) }
            #expect(model.configuration == original)
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.configuration.path))
            let newPort = try await fixture.availablePort(excluding: [original.port, blocker.port])
            try await model.changePort(to: newPort)
            #expect(model.phase == .uninstalled)
            #expect(model.configuration.port == newPort)
            #expect(try ConfigurationStore(url: fixture.paths.configuration).load().port == newPort)
            #expect(model.session == nil)
            #expect(model.server == nil)
        }
    }

    /// Two stored records, with central directory and CRCs, exercise the production ZIP/manifest path.
    private func storedZIP() -> Data {
        let html = """
        <!doctype html><html><head><script>
        window.initialStorageJSON = JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(key => [key, localStorage.getItem(key)])));
        </script><script src="/assets/app.js"></script></head><body><div id="app"><p>Port migration fixture</p></div></body></html>
        """
        let entries = [("index.html", Data(html.utf8)), ("assets/app.js", Data("window.fixtureReady = true;".utf8))]
        var output = Data(), central = Data()
        for (path, bytes) in entries {
            let name = Data(path.utf8), offset = output.count, crc = checksum(bytes)
            output.portLE32(0x04034b50); output.portLE16(20); output.portLE16(0x0800); output.portLE16(0)
            output.portLE16(0); output.portLE16(0); output.portLE32(crc)
            output.portLE32(UInt32(bytes.count)); output.portLE32(UInt32(bytes.count)); output.portLE16(UInt16(name.count)); output.portLE16(0)
            output.append(name); output.append(bytes)
            central.portLE32(0x02014b50); central.portLE16(0x0314); central.portLE16(20); central.portLE16(0x0800); central.portLE16(0)
            central.portLE16(0); central.portLE16(0); central.portLE32(crc); central.portLE32(UInt32(bytes.count)); central.portLE32(UInt32(bytes.count))
            central.portLE16(UInt16(name.count)); central.portLE16(0); central.portLE16(0); central.portLE16(0); central.portLE16(0)
            central.portLE32(0x81a4_0000); central.portLE32(UInt32(offset)); central.append(name)
        }
        let offset = output.count
        output.append(central); output.portLE32(0x06054b50); output.portLE16(0); output.portLE16(0)
        output.portLE16(UInt16(entries.count)); output.portLE16(UInt16(entries.count))
        output.portLE32(UInt32(central.count)); output.portLE32(UInt32(offset)); output.portLE16(0)
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

private extension Data {
    mutating func portLE16(_ value: UInt16) { append(UInt8(value & 255)); append(UInt8(value >> 8)) }
    mutating func portLE32(_ value: UInt32) { portLE16(UInt16(value & 0xffff)); portLE16(UInt16(value >> 16)) }
}
