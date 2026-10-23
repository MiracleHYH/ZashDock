import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

@MainActor
@Suite(.serialized)
struct VersionLifecycleTests {
    private let remoteIDs = ["6a60cf33-3a65-45c2-8173-af3ba44fa001", "6a60cf33-3a65-45c2-8173-af3ba44fa002"]
    private func officialStorage() throws -> [String: String] {
        let backends: [[String: String]] = [
            ["type": "clash", "protocol": "http", "host": "10.30.0.2", "port": "9090", "secondaryPath": "", "password": "version-fixture-secret-one", "uuid": remoteIDs[0], "label": "LAN version fixture"],
            ["type": "clash", "protocol": "http", "host": "kernel.vpn.example", "port": "9090", "secondaryPath": "mihomo", "password": "version-fixture-secret-two", "uuid": remoteIDs[1], "label": "VPN version fixture"]
        ]
        return ["setup/api-list": String(decoding: try JSONEncoder().encode(backends), as: UTF8.self),
                "setup/active-uuid": remoteIDs[1], "config/default-theme": "light",
                "config/dark-theme": "dark", "config/auto-theme": "true"]
    }
    private func writeStorage(_ model: AppModel, values: [String: String]) async throws {
        let session = try #require(model.session)
        try await session.page.callJavaScript("localStorage.clear(); for (const [key, value] of Object.entries(values)) localStorage.setItem(key, value);", arguments: ["values": values])
        try await session.flush()
        let vault = try #require(model.snapshotVault)
        #expect(try await vault.load().snapshot == values)
    }
    private func assertPage(_ model: AppModel, marker: String, storage: [String: String]) async throws {
        #expect(model.phase == .ready)
        let session = try #require(model.session)
        #expect(try await session.page.callJavaScript("return window.fixtureVersion;") as? String == marker)
        #expect(try await session.page.callJavaScript("return document.getElementById('app').textContent.trim();") as? String == marker)
        let initial = try #require(try await session.page.callJavaScript("return window.initialStorageJSON;") as? String)
        #expect(try JSONDecoder().decode([String: String].self, from: Data(initial.utf8)) == storage)
        let current = try #require(try await session.page.callJavaScript("return JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(key => [key, localStorage.getItem(key)])));") as? String)
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(current.utf8))
        #expect(decoded == storage)
        let encodedRemotes = try #require(decoded["setup/api-list"])
        let backends = try JSONDecoder().decode([[String: String]].self, from: Data(encodedRemotes.utf8))
        #expect(backends.count == 2)
        #expect(backends.map { $0["uuid"] } == remoteIDs.map(Optional.some))
        #expect(backends.map { $0["host"] } == ["10.30.0.2", "kernel.vpn.example"])
        #expect(decoded["setup/active-uuid"] == remoteIDs[1])
        #expect(decoded["config/auto-theme"] == "true")
        #expect(decoded["config/dark-theme"] == "dark")
        let vault = try #require(model.snapshotVault)
        #expect(try await vault.load().snapshot == storage)
    }
    private func prepare(_ store: VersionStore, paths: AppPaths, tag: String, marker: String, rendered: Bool = true) async throws -> InstalledVersion {
        let bytes = try archive(marker: marker, rendered: rendered)
        let zip = paths.root.appendingPathComponent("fixture-\(tag)-\(UUID().uuidString).zip")
        try bytes.write(to: zip)
        let release = ZashboardRelease(tag: tag, publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            assetURL: URL(string: "https://github.com/Zephyruso/zashboard/releases/download/\(tag)/dist.zip")!,
            assetSize: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        return try await store.prepare(zip: zip, release: release)
    }
    private func makeFixture(maxHistory: Int) async throws -> PortMigrationFixture {
        _ = NSApplication.shared
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockVersionLifecycle-\(UUID().uuidString)"))
        try paths.createDirectories()
        do {
            let store = try VersionStore(root: paths.root)
            let current = try await prepare(store, paths: paths, tag: "v0.6.0", marker: "version-initial")
            try await store.activate(current)
            let listener = try await bindFixture(current.directoryURL)
            var configuration = AppConfiguration()
            configuration.port = listener.port; configuration.maxRollbackVersions = maxHistory
            listener.stop()
            try ConfigurationStore(url: paths.configuration).save(configuration)
            try await StorageSnapshotVault(url: paths.snapshot, keyProvider: PortMigrationKey()).save([:])
            return PortMigrationFixture(paths: paths, webRoot: current.directoryURL)
        } catch { try? FileManager.default.removeItem(at: paths.root); throw error }
    }
    private func withFixture(maxHistory: Int = 1, body: (PortMigrationFixture, AppModel) async throws -> Void) async throws {
        let fixture = try await makeFixture(maxHistory: maxHistory)
        let model = fixture.model(); await model.start()
        do { try await body(fixture, model); await fixture.cleanUp() }
        catch { await fixture.cleanUp(); throw error }
    }
    private func directoryCount(_ paths: AppPaths) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: paths.versions, includingPropertiesForKeys: [.isDirectoryKey]).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.count
    }

    @Test(.timeLimit(.minutes(1)))
    func updateAndRollbackAtSameOriginRenderCorrectVersionAndKeepOfficialRemotes() async throws {
        try await withFixture { fixture, model in
            #expect(model.phase == .ready)
            let oldVersion = try #require(model.currentVersion), oldPort = model.configuration.port
            let expected = try officialStorage()
            try await writeStorage(model, values: expected)
            let store = try #require(model.store)
            let newer = try await prepare(store, paths: fixture.paths, tag: "v0.6.1", marker: "version-new")
            try await model.switchVersion(newer)
            #expect(model.currentVersion == newer)
            #expect(model.configuration.port == oldPort)
            #expect(model.session?.origin.port == Int(oldPort))
            #expect(model.history.map(\.id) == [oldVersion.id])
            try await assertPage(model, marker: "version-new", storage: expected)
            #expect(try await store.current() == newer)
            try await model.switchVersion(oldVersion)
            #expect(model.currentVersion == oldVersion)
            #expect(model.configuration.port == oldPort)
            #expect(model.history.map(\.id) == [newer.id])
            #expect(try directoryCount(fixture.paths) == 2)
            try await assertPage(model, marker: "version-initial", storage: expected)
            #expect(try await store.current() == oldVersion)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, 1, 3])
    func successfulVersionTransactionsEnforceCurrentPlusNHistory(maxHistory: Int) async throws {
        try await withFixture(maxHistory: maxHistory) { fixture, model in
            #expect(model.phase == .ready)
            let store = try #require(model.store)
            let expected = try officialStorage()
            try await writeStorage(model, values: expected)
            let port = model.configuration.port
            var markers = [try #require(model.currentVersion).id: "version-initial"]
            for number in 1...5 {
                let marker = "retention-\(number)"
                let candidate = try await prepare(store, paths: fixture.paths, tag: "v0.7.\(number)", marker: marker)
                markers[candidate.id] = marker
                try await model.switchVersion(candidate)
                #expect(model.currentVersion == candidate)
                #expect(model.configuration.port == port)
                #expect(model.history.count == min(number, maxHistory))
                #expect(model.history.count + 1 <= maxHistory + 1)
                #expect(try directoryCount(fixture.paths) == min(number + 1, maxHistory + 1))
                #expect(try await store.history().map(\.id) == model.history.map(\.id))
                try await assertPage(model, marker: marker, storage: expected)
            }
            if maxHistory > 0 {
                let previousCurrent = try #require(model.currentVersion)
                let rollback = try #require(model.history.last)
                try await model.switchVersion(rollback)
                #expect(model.currentVersion == rollback)
                #expect(model.history.first?.id == previousCurrent.id)
                #expect(model.history.count == maxHistory)
                #expect(try directoryCount(fixture.paths) == maxHistory + 1)
                try await assertPage(model, marker: try #require(markers[rollback.id]), storage: expected)
            } else { #expect(model.history.isEmpty) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func unrenderedCandidateFailsAndRestoresPriorVersionWithoutCommitting() async throws {
        try await withFixture { fixture, model in
            #expect(model.phase == .ready)
            let store = try #require(model.store)
            let expected = try officialStorage()
            try await writeStorage(model, values: expected)
            // Establish a real historical version so failure must preserve the full activation order.
            let good = try await prepare(store, paths: fixture.paths, tag: "v0.8.1", marker: "known-good")
            try await model.switchVersion(good)
            let originalPort = model.configuration.port, originalHistory = model.history
            let pointer = fixture.paths.root.appendingPathComponent("versions-state.json")
            let pointerBytes = try Data(contentsOf: pointer)
            let configBytes = try Data(contentsOf: fixture.paths.configuration)
            let broken = try await prepare(store, paths: fixture.paths, tag: "v0.8.2", marker: "never-rendered", rendered: false)
            let failing = Task { try await model.switchVersion(broken) }
            defer { failing.cancel() }
            while !model.isBusy { await Task.yield() }
            await #expect(throws: (any Error).self) { try await model.switchVersion(good) }
            await #expect(throws: (any Error).self) { try await failing.value }
            #expect(model.phase == .ready)
            #expect(!model.isBusy)
            #expect(model.currentVersion == good)
            #expect(model.configuration.port == originalPort)
            #expect(model.server?.port == originalPort)
            #expect(model.history == originalHistory)
            #expect(try await store.current() == good)
            #expect(try await store.history() == originalHistory)
            #expect(try Data(contentsOf: pointer) == pointerBytes)
            #expect(try Data(contentsOf: fixture.paths.configuration) == configBytes)
            try await assertPage(model, marker: "known-good", storage: expected)
            try await store.discardPrepared(broken)
            #expect(try directoryCount(fixture.paths) == originalHistory.count + 1)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledCandidateVerificationStillRestoresWorkingVersionAndSnapshot() async throws {
        try await withFixture { fixture, model in
            #expect(model.phase == .ready)
            let store = try #require(model.store)
            let expected = try officialStorage()
            try await writeStorage(model, values: expected)
            let good = try await prepare(store, paths: fixture.paths, tag: "v0.9.1", marker: "cancel-safe-version")
            try await model.switchVersion(good)
            let oldPort = model.configuration.port, oldHistory = model.history
            let pointer = fixture.paths.root.appendingPathComponent("versions-state.json")
            let originalPointer = try Data(contentsOf: pointer)
            let broken = try await prepare(store, paths: fixture.paths, tag: "v0.9.2", marker: "cancelled-candidate", rendered: false)
            let switching = Task { try await model.switchVersion(broken) }
            defer { switching.cancel() }
            while !model.isBusy { await Task.yield() }
            try await Task.sleep(for: .seconds(2))
            #expect(model.isBusy)
            switching.cancel()
            await #expect(throws: (any Error).self) { try await switching.value }
            #expect(switching.isCancelled)
            #expect(model.phase == .ready)
            #expect(!model.isBusy)
            #expect(model.currentVersion == good)
            #expect(model.configuration.port == oldPort)
            #expect(model.server?.port == oldPort)
            #expect(model.server?.versionID == good.id)
            #expect(model.history == oldHistory)
            #expect(try await store.current() == good)
            #expect(try await store.history() == oldHistory)
            #expect(try Data(contentsOf: pointer) == originalPointer)
            try await assertPage(model, marker: "cancel-safe-version", storage: expected)
            try await store.discardPrepared(broken)
            #expect(try directoryCount(fixture.paths) == oldHistory.count + 1)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func loopbackCacheCleanupKeepsLocalStorageAndBlocksPWARegistration() async throws {
        try await withFixture { _, model in
            #expect(model.phase == .ready)
            let session = try #require(model.session)
            let name = "zashdock-stale-panel-\(UUID().uuidString)"
            let marker = "keep-local-storage-\(UUID().uuidString)"
            try await session.page.callJavaScript("""
                localStorage.setItem('cache-survival-marker', marker);
                const cache = await caches.open(cacheName);
                await cache.put('/stale-panel.js', new Response('old-version', {headers: {'Content-Type': 'text/javascript'}}));
                """, arguments: ["marker": marker, "cacheName": name])
            #expect(try await session.page.callJavaScript("return await caches.has(cacheName);", arguments: ["cacheName": name]) as? Bool == true)
            await WebCacheController.clearLoopbackCaches()
            #expect(try await session.page.callJavaScript("return await caches.has(cacheName);", arguments: ["cacheName": name]) as? Bool == false)
            #expect(try await session.page.callJavaScript("return localStorage.getItem('cache-survival-marker');") as? String == marker)
            let registration = try await session.page.callJavaScript("""
                if (!navigator.serviceWorker) return 'unavailable';
                try { await navigator.serviceWorker.register('/sw.js'); return 'registered'; }
                catch (error) { return 'rejected'; }
                """)
            #expect(registration as? String == "rejected")
            var request = URLRequest(url: session.origin.appendingPathComponent("sw.js"))
            request.setValue("script", forHTTPHeaderField: "Service-Worker")
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 403)
            #expect(try await session.page.callJavaScript("return localStorage.getItem('cache-survival-marker');") as? String == marker)
        }
    }

    private func archive(marker: String, rendered: Bool) throws -> Data {
        let markerJSON = String(decoding: try JSONEncoder().encode(marker), as: UTF8.self)
        let content = rendered ? "<p>\(marker)</p>" : ""
        let html = """
        <!doctype html><html><head><script>
        window.initialStorageJSON = JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(key => [key, localStorage.getItem(key)])));
        </script><script src="/assets/app.js"></script></head><body><div id="app">\(content)</div></body></html>
        """
        let files = [("index.html", Data(html.utf8)), ("assets/app.js", Data("window.fixtureVersion = \(markerJSON);".utf8)),
                     ("sw.js", Data("self.addEventListener('fetch', event => {});".utf8))]
        var local = Data(), central = Data()
        for (path, bytes) in files {
            let name = Data(path.utf8), offset = local.count, crc = checksum(bytes)
            local.lifecycleLE32(0x04034b50); local.lifecycleLE16(20); local.lifecycleLE16(0x0800); local.lifecycleLE16(0)
            local.lifecycleLE16(0); local.lifecycleLE16(0); local.lifecycleLE32(crc)
            local.lifecycleLE32(UInt32(bytes.count)); local.lifecycleLE32(UInt32(bytes.count)); local.lifecycleLE16(UInt16(name.count)); local.lifecycleLE16(0)
            local.append(name); local.append(bytes)
            central.lifecycleLE32(0x02014b50); central.lifecycleLE16(0x0314); central.lifecycleLE16(20); central.lifecycleLE16(0x0800); central.lifecycleLE16(0)
            central.lifecycleLE16(0); central.lifecycleLE16(0); central.lifecycleLE32(crc); central.lifecycleLE32(UInt32(bytes.count)); central.lifecycleLE32(UInt32(bytes.count))
            central.lifecycleLE16(UInt16(name.count)); central.lifecycleLE16(0); central.lifecycleLE16(0); central.lifecycleLE16(0); central.lifecycleLE16(0)
            central.lifecycleLE32(0x81a4_0000); central.lifecycleLE32(UInt32(offset)); central.append(name)
        }
        let offset = local.count
        local.append(central); local.lifecycleLE32(0x06054b50); local.lifecycleLE16(0); local.lifecycleLE16(0)
        local.lifecycleLE16(UInt16(files.count)); local.lifecycleLE16(UInt16(files.count)); local.lifecycleLE32(UInt32(central.count)); local.lifecycleLE32(UInt32(offset)); local.lifecycleLE16(0)
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

private extension Data {
    mutating func lifecycleLE16(_ value: UInt16) { append(UInt8(value & 255)); append(UInt8(value >> 8)) }
    mutating func lifecycleLE32(_ value: UInt32) { lifecycleLE16(UInt16(value & 0xffff)); lifecycleLE16(UInt16(value >> 16)) }
}
