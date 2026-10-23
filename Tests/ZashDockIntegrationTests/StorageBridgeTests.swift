import AppKit
import CryptoKit
import Foundation
import Security
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

private struct BridgeTestKey: StorageSnapshotKeyProviding {
    func encryptionKey(createIfMissing: Bool) throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 0x42, count: 32))
    }
}

@Suite(.serialized)
@MainActor
struct StorageBridgeTests {
    private let remoteUUIDs = ["866e7837-57fd-4b90-886c-50cfc7c4603c", "335d6680-33b4-48fb-9527-343c338381f9"]

    private func officialSnapshot() throws -> [String: String] {
        // The field names/types and storage keys match upstream v3.29.1 Backend and setup.ts.
        let backends: [[String: String]] = [
            ["type": "clash", "protocol": "http", "host": "10.0.0.2", "port": "9090", "secondaryPath": "", "password": "fixture-secret-one", "uuid": remoteUUIDs[0], "label": "LAN fixture"],
            ["type": "clash", "protocol": "http", "host": "vpn.example", "port": "9090", "secondaryPath": "mihomo", "password": "fixture-secret-two", "uuid": remoteUUIDs[1], "label": "VPN fixture"]
        ]
        let data = try JSONEncoder().encode(backends)
        return ["setup/api-list": String(decoding: data, as: UTF8.self), "setup/active-uuid": remoteUUIDs[1],
                "config/default-theme": "light", "config/dark-theme": "dark", "config/auto-theme": "true"]
    }

    private func assertOfficialRemotes(in snapshot: [String: String]) throws {
        let encoded = try #require(snapshot["setup/api-list"])
        let backends = try JSONDecoder().decode([[String: String]].self, from: Data(encoded.utf8))
        #expect(backends.count == 2)
        #expect(backends.map { $0["uuid"] } == remoteUUIDs.map(Optional.some))
        #expect(backends.map { $0["type"] } == ["clash", "clash"])
        #expect(backends.map { $0["protocol"] } == ["http", "http"])
        #expect(backends.map { $0["host"] } == ["10.0.0.2", "vpn.example"])
        #expect(backends.allSatisfy { $0["port"] == "9090" && $0["password"]?.isEmpty == false })
        #expect(snapshot["setup/active-uuid"] == remoteUUIDs[1])
        #expect(snapshot["config/auto-theme"] == "true")
        #expect(snapshot["config/dark-theme"] == "dark")
    }

    private func directory(script: String = "") throws -> URL {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockBridgeTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let html = "<html><body><div id='app'></div><script>window.firstStorage = JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(key => [key, localStorage.getItem(key)])));\(script)</script></body></html>"
        try Data(html.utf8).write(to: root.appendingPathComponent("index.html"))
        return root
    }

    private func page(origin: URL, vault: StorageSnapshotVault, seed: [String: String]?, automaticallyPersists: Bool = true, store: WKWebsiteDataStore? = nil) throws -> (ZashboardStorageBridge, WebPage) {
        let bridge = try ZashboardStorageBridge(origin: origin, vault: vault, snapshot: seed, automaticallyPersists: automaticallyPersists)
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = store ?? .nonPersistent()
        configuration.userContentController = bridge.controller
        configuration.defaultNavigationPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        // The native message validation is also exercised when subframe navigation is allowed.
        return (bridge, WebPage(configuration: configuration))
    }

    private func load(_ page: WebPage, origin: URL) async throws {
        for try await _ in page.load(URLRequest(url: origin)) {}
    }

    private func firstStorage(_ page: WebPage) async throws -> [String: String] {
        let value = try await page.callJavaScript("return window.firstStorage;")
        let string = try #require(value as? String)
        return try JSONDecoder().decode([String: String].self, from: Data(string.utf8))
    }

    private func waitForSnapshot(_ expected: [String: String], vault: StorageSnapshotVault) async throws {
        for _ in 0..<100 {
            if try await vault.load().snapshot == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await vault.load().snapshot == expected)
    }

    @Test(.timeLimit(.minutes(1)))
    func documentStartRestoresTwoRemotesBeforePageInitialization() async throws {
        let root = try directory(script: "localStorage.setItem('defaultTheme', 'system');")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root)
        defer { server.stop() }
        let vault = StorageSnapshotVault(url: root.appendingPathComponent("storage"), keyProvider: BridgeTestKey())
        var seed = try officialSnapshot()
        seed["__proto__"] = "preserve arbitrary storage keys"
        seed["quoted-value"] = "\"; window.injected = true; // </script> \\ \u{2028} \u{2029}"
        let (bridge, page) = try page(origin: server.baseURL, vault: vault, seed: seed)
        try await load(page, origin: server.baseURL)
        try await bridge.verifyRestore(page)
        let initial = try await firstStorage(page)
        #expect(initial == seed)
        try assertOfficialRemotes(in: initial)
        #expect(try await page.callJavaScript("return typeof window.injected === 'undefined';") as? Bool == true)
        var current = seed
        current["defaultTheme"] = "system"
        #expect(try await bridge.flush(page) == current)
        #expect(try await vault.load().snapshot == current)
        try assertOfficialRemotes(in: try #require(try await vault.load().snapshot))
        page.stopLoading()
    }

    @Test(.timeLimit(.minutes(1)))
    func hooksPollingAndRapidWritesPersistLatestDataIncludingClear() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root)
        defer { server.stop() }
        let vault = StorageSnapshotVault(url: root.appendingPathComponent("storage"), keyProvider: BridgeTestKey())
        let (bridge, page) = try page(origin: server.baseURL, vault: vault, seed: [:])
        try await load(page, origin: server.baseURL)
        try await bridge.verifyRestore(page)
        try await page.callJavaScript("localStorage.setItem('remoteA', 'one'); localStorage.setItem('remoteB', 'two');")
        try await waitForSnapshot(["remoteA": "one", "remoteB": "two"], vault: vault)
        try await page.callJavaScript("localStorage.directProperty = 'polling';")
        try await waitForSnapshot(["remoteA": "one", "remoteB": "two", "directProperty": "polling"], vault: vault)
        try await page.callJavaScript("for (let index = 0; index < 40; index++) localStorage.setItem('sequence', String(index)); localStorage.removeItem('remoteA');")
        let newest = ["remoteB": "two", "directProperty": "polling", "sequence": "39"]
        #expect(try await bridge.flush(page) == newest)
        #expect(try await vault.load().snapshot == newest)
        try await page.callJavaScript("localStorage.clear();")
        #expect(try await bridge.flush(page).isEmpty)
        #expect(try await vault.load().snapshot == [:])
        page.stopLoading()
    }

    @Test(.timeLimit(.minutes(1)))
    func nilSeedKeepsExistingOriginWhileEmptySeedClearsIt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root)
        defer { server.stop() }
        let vault = StorageSnapshotVault(url: root.appendingPathComponent("storage"), keyProvider: BridgeTestKey())
        let store = WKWebsiteDataStore.nonPersistent()
        let old = ["remoteA": "one", "remoteB": "two"]
        let (firstBridge, firstPage) = try page(origin: server.baseURL, vault: vault, seed: old, store: store)
        try await load(firstPage, origin: server.baseURL)
        try await firstBridge.flush(firstPage)
        firstBridge.disableAutomaticPersistence()
        let (adoptingBridge, adoptingPage) = try page(origin: server.baseURL, vault: vault, seed: nil, store: store)
        try await load(adoptingPage, origin: server.baseURL)
        try await adoptingBridge.verifyRestore(adoptingPage)
        #expect(try await firstStorage(adoptingPage) == old)
        #expect(try await adoptingBridge.flush(adoptingPage) == old)
        adoptingBridge.disableAutomaticPersistence()
        let (clearingBridge, clearingPage) = try page(origin: server.baseURL, vault: vault, seed: [:], store: store)
        try await load(clearingPage, origin: server.baseURL)
        try await clearingBridge.verifyRestore(clearingPage)
        #expect(try await firstStorage(clearingPage) == [:])
        #expect(try await clearingBridge.flush(clearingPage).isEmpty)
        #expect(try await vault.load().snapshot == [:])
        firstPage.stopLoading(); adoptingPage.stopLoading(); clearingPage.stopLoading()
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeSnapshotRestartsAtNewOriginWithoutAccessingOldPort() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstServer = try await bindFixture(root)
        defer { firstServer.stop() }
        let vaultURL = root.appendingPathComponent("storage")
        let vault = StorageSnapshotVault(url: vaultURL, keyProvider: BridgeTestKey())
        let (oldBridge, oldPage) = try page(origin: firstServer.baseURL, vault: vault, seed: [:])
        try await load(oldPage, origin: firstServer.baseURL)
        let official = try officialSnapshot()
        try await oldPage.callJavaScript("for (const [key, value] of Object.entries(values)) localStorage.setItem(key, value);", arguments: ["values": official])
        let expected = try await oldBridge.flush(oldPage)
        try assertOfficialRemotes(in: expected)
        oldBridge.disableAutomaticPersistence()
        oldPage.stopLoading()
        // The old port remains bound: the replacement must rely exclusively on the encrypted snapshot.
        let newServer = try await bindFixture(root)
        defer { newServer.stop() }
        #expect(firstServer.baseURL.port != newServer.baseURL.port)
        let recreatedVault = StorageSnapshotVault(url: vaultURL, keyProvider: BridgeTestKey())
        let saved = try await recreatedVault.load()
        let (newBridge, newPage) = try page(origin: newServer.baseURL, vault: recreatedVault, seed: saved.snapshot)
        try await load(newPage, origin: newServer.baseURL)
        try await newBridge.verifyRestore(newPage)
        let restored = try await firstStorage(newPage)
        #expect(restored == expected)
        try assertOfficialRemotes(in: restored)
        let flushed = try await newBridge.flush(newPage)
        #expect(flushed == expected)
        try assertOfficialRemotes(in: flushed)
        newPage.stopLoading()
    }

    @Test(.timeLimit(.minutes(1)))
    func candidateCannotReplaceCanonicalSnapshotBeforeCommit() async throws {
        let root = try directory(script: "localStorage.setItem('newDefault', 'updated');")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root)
        defer { server.stop() }
        let vault = StorageSnapshotVault(url: root.appendingPathComponent("storage"), keyProvider: BridgeTestKey())
        let original = ["remoteA": "one", "remoteB": "two"]
        try await vault.save(original)
        let (candidate, page) = try page(origin: server.baseURL, vault: vault, seed: original, automaticallyPersists: false)
        try await load(page, origin: server.baseURL)
        try await candidate.verifyRestore(page)
        try await page.callJavaScript("localStorage.setItem('selected', 'remoteB');")
        var changed = original
        changed["selected"] = "remoteB"
        changed["newDefault"] = "updated"
        #expect(try await candidate.flush(page) == changed)
        #expect(try await vault.load().snapshot == original)
        candidate.enableAutomaticPersistence()
        #expect(try await candidate.flush(page) == changed)
        #expect(try await vault.load().snapshot == changed)
        page.stopLoading()
    }

    @Test(.timeLimit(.minutes(1)))
    func messagesFromSubframesAndMalformedSchemasCannotChangeNativeSnapshot() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root)
        defer { server.stop() }
        let vault = StorageSnapshotVault(url: root.appendingPathComponent("storage"), keyProvider: BridgeTestKey())
        let original = ["remoteA": "one", "remoteB": "two"]
        let (bridge, page) = try page(origin: server.baseURL, vault: vault, seed: original)
        try await load(page, origin: server.baseURL)
        try await bridge.flush(page)
        try await page.callJavaScript(#"""
        const token = window.__zashdockStorageSnapshot.token;
        const child = document.createElement('iframe');
        child.srcdoc = '<script>window.webkit.messageHandlers.zashdockStorage.postMessage(' + JSON.stringify({schema:1,token,kind:'snapshot',sequence:999999,snapshot:{stolen:'subframe'}}) + ');<\/script>';
        document.body.appendChild(child);
        window.webkit.messageHandlers.zashdockStorage.postMessage({schema:1,token,kind:'snapshot',sequence:999998,snapshot:{command:'forbidden'},path:'/tmp/forbidden'});
        window.webkit.messageHandlers.zashdockStorage.postMessage({schema:1,token:'invalid',kind:'snapshot',sequence:999997,snapshot:{stolen:'token'}});
        """#)
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await vault.load().snapshot == original)
        #expect(try await bridge.flush(page) == original)
        page.stopLoading()
    }

    @Test(.timeLimit(.minutes(1)))
    func mainFrameOnDifferentOriginCannotSubmitEvenWithKnownToken() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root)
        defer { server.stop() }
        let vault = StorageSnapshotVault(url: root.appendingPathComponent("storage"), keyProvider: BridgeTestKey())
        let original = try officialSnapshot()
        let (bridge, page) = try page(origin: server.baseURL, vault: vault, seed: original)
        try await load(page, origin: server.baseURL)
        try await bridge.flush(page)
        let token = try #require(try await page.callJavaScript("return window.__zashdockStorageSnapshot.token;") as? String)
        let forged: [String: Any] = ["schema": 1, "token": token, "kind": "snapshot", "sequence": 999999, "snapshot": ["foreign": "denied"]]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: forged), as: UTF8.self)
        let foreignRoot = try directory(script: "window.webkit.messageHandlers.zashdockStorage.postMessage(\(encoded));")
        defer { try? FileManager.default.removeItem(at: foreignRoot) }
        let foreignServer = try await bindFixture(foreignRoot)
        defer { foreignServer.stop() }
        try await load(page, origin: foreignServer.baseURL)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await vault.load().snapshot == original)
        await #expect(throws: (any Error).self) { try await bridge.flush(page) }
        #expect(try await vault.load().snapshot == original)
        page.stopLoading()
    }

    @Test(.timeLimit(.minutes(1)))
    func testScopedKeychainRoundTripAndEncryptedVaultInHostedApplication() async throws {
        _ = NSApplication.shared
        // Exercise the production factory/attributes with an isolated item, never the user's persistent key.
        let service = "app.zashdock.mac.storage.integration-test.\(UUID().uuidString)"
        let account = "test-primary"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        defer {
            let status = SecItemDelete(query as CFDictionary)
            #expect(status == errSecSuccess || status == errSecItemNotFound)
        }
        let provider = KeychainSnapshotKeyProvider(service: service, account: account)
        let createdOrExisting = try provider.encryptionKey(createIfMissing: true)
        let fetchedAgain = try provider.encryptionKey(createIfMissing: false)
        let sameKey = createdOrExisting.withUnsafeBytes { left in
            fetchedAgain.withUnsafeBytes { right in left.elementsEqual(right) }
        }
        // Only the boolean reaches the test diagnostics, never key bytes or configuration values.
        #expect(sameKey)
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test-keychain-storage.aesgcm")
        let snapshot = try officialSnapshot()
        try await StorageSnapshotVault(url: url, keyProvider: provider).save(snapshot)
        let loaded = try await StorageSnapshotVault(url: url, keyProvider: provider).load()
        let sameSnapshot = loaded.snapshot == snapshot
        #expect(sameSnapshot)
        #expect(loaded.recovery == nil)
    }
}
