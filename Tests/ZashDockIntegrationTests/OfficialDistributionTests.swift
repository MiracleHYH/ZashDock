import AppKit
import Foundation
import CryptoKit
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

@Suite(.serialized)
@MainActor
struct OfficialDistributionTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["ZASHDOCK_OFFICIAL_ZIP"]?.isEmpty == false,
                 "未设置 ZASHDOCK_OFFICIAL_ZIP，跳过真实官方 ZIP 首次离线安装取消与重试验收。"),
        .timeLimit(.minutes(1))
    )
    func firstInstallCancellationAndOfflineRetryUseRealOfficialZIP() async throws {
        _ = NSApplication.shared
        let archivePath = try #require(ProcessInfo.processInfo.environment["ZASHDOCK_OFFICIAL_ZIP"])
        let archive = URL(fileURLWithPath: archivePath)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockOfficialFirstInstall-\(UUID().uuidString)")
        let fixture = OfficialDistributionFixture(paths: AppPaths(root: root))
        do {
            try fixture.paths.createDirectories()
            let probe = root.appendingPathComponent("port-probe", isDirectory: true)
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
            try Data("<html><body><div id='app'>Port reservation</div></body></html>".utf8)
                .write(to: probe.appendingPathComponent("index.html"))
            let reservation = try await bindFixture(probe)
            fixture.reservations.append(reservation)
            var configuration = AppConfiguration()
            configuration.port = reservation.port
            try ConfigurationStore(url: fixture.paths.configuration).save(configuration)
            // Clear only this reserved test Origin without loading any old webpage or seeding the
            // persistent profile before exercising the first real installation.
            do {
                var webConfiguration = WebPage.Configuration()
                webConfiguration.websiteDataStore = fixture.dataStore
                let emptyOrigin = WebPage(configuration: webConfiguration)
                for try await _ in emptyOrigin.load(simulatedRequest: URLRequest(url: reservation.baseURL), responseHTML: "<html><body></body></html>") {}
                try await emptyOrigin.callJavaScript("localStorage.clear();")
                emptyOrigin.stopLoading()
            }
            reservation.stop()

            let model = fixture.model()
            await model.start()
            #expect(model.phase == .uninstalled)
            #expect(model.currentVersion == nil)
            #expect(model.session == nil)
            #expect(model.server == nil)
            #expect(model.errorMessage == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent("storage.aesgcm").path))

            // There is deliberately no await between the button's install action and cancel. The
            // child Task cannot run on this MainActor until after its cancellation is requested.
            model.install(zip: archive)
            let cancelledOperation = try #require(model.operation)
            model.cancel()
            await cancelledOperation.value
            #expect(model.phase == .uninstalled)
            #expect(model.currentVersion == nil)
            #expect(model.session == nil)
            #expect(model.server == nil)
            #expect(model.operation == nil)
            #expect(!model.isBusy)
            #expect(model.errorMessage == nil)
            let store = try #require(model.store)
            #expect(try await store.current() == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.versions.path).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.staging.path).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent("storage.aesgcm").path))

            // Retry through the same AppModel entry point used by the native import button. This
            // validates and extracts the real ZIP, loads official JavaScript, then commits it.
            model.install(zip: archive)
            let retryOperation = try #require(model.operation)
            await retryOperation.value
            #expect(model.phase == .ready)
            #expect(model.currentVersion?.tag == "本地导入" && model.currentVersion?.source == .localArchive)
            #expect(model.currentVersion?.sha256 == officialV3291FixtureRelease.sha256)
            #expect(try await store.current() == model.currentVersion)
            #expect(model.configuration.port == configuration.port)
            #expect(model.operation == nil)
            #expect(!model.isBusy)
            #expect(model.errorMessage == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent("storage.aesgcm").path))
            let session = try #require(model.session)
            let result = try await session.page.callJavaScript("""
                const app = document.getElementById('app');
                const encoded = localStorage.getItem('setup/api-list');
                const remotes = encoded ? JSON.parse(encoded) : [];
                const noNativeBridge = typeof window.__zashdockStorageSnapshot === "undefined";
                return {
                    rendered: !!app && app.childElementCount > 0,
                    remoteCount: remotes.length,
                    noNativeBridge,
                    noActiveRemote: !localStorage.getItem('setup/active-uuid')
                };
                """)
            let state = try #require(result as? [String: Any])
            #expect(state["rendered"] as? Bool == true)
            #expect((state["remoteCount"] as? NSNumber)?.intValue == 0)
            #expect(state["noNativeBridge"] as? Bool == true)
            #expect(state["noActiveRemote"] as? Bool == true)
            await fixture.shutdown(model)
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["ZASHDOCK_OFFICIAL_ZIP"]?.isEmpty == false,
                 "未设置 ZASHDOCK_OFFICIAL_ZIP，跳过真实官方 v3.29.1 dist.zip 验收；fixture 测试不能替代此测试。"),
        .timeLimit(.minutes(1))
    )
    func officialDistributionRendersAndPreservesTwoRemotesAcrossRestartAndPortMigration() async throws {
        _ = NSApplication.shared
        let archivePath = try #require(ProcessInfo.processInfo.environment["ZASHDOCK_OFFICIAL_ZIP"])
        let archive = URL(fileURLWithPath: archivePath)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockOfficialDistribution-\(UUID().uuidString)")
        let fixture = OfficialDistributionFixture(paths: AppPaths(root: root))
        do {
            try fixture.paths.createDirectories()
            let store = try VersionStore(root: root)
            // This exercises the real bounded copy, ZIP parser and manifest checks for a local archive.
            let version = try await store.prepareLocalZIP(archive)
            #expect(version.tag == "本地导入" && version.source == .localArchive)
            #expect(version.sha256 == officialV3291FixtureRelease.sha256)
            try await store.activate(version)

            // Reserve a genuinely bound random port before saving it; do not guess that a port is free.
            let reservation = try await bindFixture(version.directoryURL)
            fixture.reservations.append(reservation)
            var configuration = AppConfiguration()
            configuration.port = reservation.port
            try ConfigurationStore(url: fixture.paths.configuration).save(configuration)

            let firstMihomo = try await MockMihomoServer.bind(allowing: reservation.baseURL, excluding: reservation.port)
            fixture.mihomoServers.append(firstMihomo)
            let secondMihomo = try await MockMihomoServer.bind(allowing: reservation.baseURL, excluding: reservation.port)
            fixture.mihomoServers.append(secondMihomo)
            #expect(firstMihomo.port != secondMihomo.port)
            let expected = try expectedStorage(firstPort: firstMihomo.port, secondPort: secondMihomo.port)
            let transfer = OriginStorageTransfer(dataStore: fixture.dataStore)
            try await transfer.restore(OriginStoragePayload(localStorage: expected), to: reservation.baseURL)
            reservation.stop()

            let original = fixture.model()
            await original.start()
            try await assertOfficialState(original, expected: expected)
            #expect(original.configuration.port == configuration.port)
            try assertStorage(try await transfer.read(origin: reservation.baseURL).localStorage, expected: expected)
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent("storage.aesgcm").path))

            await fixture.shutdown(original)
            let restarted = fixture.model()
            await restarted.start()
            try await assertOfficialState(restarted, expected: expected)
            #expect(restarted.configuration.port == configuration.port)

            let nextReservation = try await bindFixture(version.directoryURL)
            fixture.reservations.append(nextReservation)
            let newPort = nextReservation.port
            #expect(newPort != configuration.port)
            #expect(newPort != firstMihomo.port && newPort != secondMihomo.port)
            nextReservation.stop()
            try await restarted.changePort(to: newPort)
            try await assertOfficialState(restarted, expected: expected)
            #expect(restarted.configuration.port == newPort)
            #expect(restarted.session?.origin.port == Int(newPort))
            #expect(try ConfigurationStore(url: fixture.paths.configuration).load().port == newPort)
            let migratedSnapshot = try await transfer.read(origin: URL(string: "http://127.0.0.1:\(newPort)")!).localStorage
            try assertStorage(migratedSnapshot, expected: expected)

            // A second restart proves both the port commit and the persistent WebKit profile survive.
            await fixture.shutdown(restarted)
            let restartedAtNewPort = fixture.model()
            await restartedAtNewPort.start()
            #expect(restartedAtNewPort.configuration.port == newPort)
            try await assertOfficialState(restartedAtNewPort, expected: expected)
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    private struct Remote: Codable, Equatable {
        let type: String
        let `protocol`: String
        let host: String
        let port: String
        let secondaryPath: String
        let password: String
        let uuid: String
        let label: String
        let disableUpgradeCore: Bool
        let disableTunMode: Bool
    }

    private func expectedStorage(firstPort: UInt16, secondPort: UInt16) throws -> [String: String] {
        let remotes = [
            Remote(type: "clash", protocol: "http", host: "127.0.0.1", port: String(firstPort), secondaryPath: "",
                   password: MockMihomoServer.fixtureToken, uuid: "28e1fccd-e3fa-4fa7-b3ab-71e4eaef6001", label: "Official fixture one",
                   disableUpgradeCore: true, disableTunMode: true),
            Remote(type: "clash", protocol: "http", host: "127.0.0.1", port: String(secondPort), secondaryPath: "",
                   password: MockMihomoServer.fixtureToken, uuid: "28e1fccd-e3fa-4fa7-b3ab-71e4eaef6002", label: "Official fixture two",
                   disableUpgradeCore: true, disableTunMode: true)
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return [
            "setup/api-list": String(decoding: try encoder.encode(remotes), as: UTF8.self),
            "setup/active-uuid": remotes[1].uuid,
            "config/default-theme": "light", "config/dark-theme": "dark", "config/auto-theme": "true",
            "config/check-upgrade-core": "false", "config/auto-upgrade-core": "false", "config/auto-upgrade": "false",
            "config/auto-ip-check": "false", "config/auto-connection-check": "false",
            "config/auto-import-settings": "false", "config/auto-sync-settings": "false",
            "zashdock-test/official-distribution": "all LocalStorage keys must survive"
        ]
    }

    private struct PageState: Decodable {
        let origin: String
        let renderedChildren: Int
        let hasNativeBridge: Bool
        let currentSnapshot: [String: String]
        let health: [String: String]
    }

    private func assertOfficialState(_ model: AppModel, expected: [String: String]) async throws {
        #expect(model.phase == .ready)
        #expect(model.currentVersion?.tag == "本地导入" && model.currentVersion?.source == .localArchive)
        #expect(model.currentVersion?.sha256 == officialV3291FixtureRelease.sha256)
        #expect(model.errorMessage == nil)
        let session = try #require(model.session)
        let value = try await session.page.callJavaScript("""
            const app = document.getElementById('app');
            const hasNativeBridge = typeof window.__zashdockStorageSnapshot !== "undefined";
            const response = await fetch('/__zashdock_health', {cache: 'no-store'});
            if (!response.ok) throw new Error('official fixture health check failed');
            return JSON.stringify({
                origin: location.origin,
                renderedChildren: app ? app.childElementCount : 0,
                hasNativeBridge,
                currentSnapshot: Object.fromEntries(Object.keys(localStorage).map(key => [key, localStorage.getItem(key)])),
                health: await response.json()
            });
            """)
        let json = try #require(value as? String)
        let state = try JSONDecoder().decode(PageState.self, from: Data(json.utf8))
        #expect(state.renderedChildren > 0) // Official dist/index.html starts with an empty #app.
        #expect(state.origin == session.origin.absoluteString)
        #expect(state.health["version"] == model.currentVersion?.id)
        #expect(state.health["nonce"] == model.server?.nonce)
        #expect(!state.hasNativeBridge)
        try assertStorage(state.currentSnapshot, expected: expected)
    }

    private func assertStorage(_ snapshot: [String: String], expected: [String: String]) throws {
        let actualJSON = try #require(snapshot["setup/api-list"])
        let expectedJSON = try #require(expected["setup/api-list"])
        let actualRemotes = try JSONDecoder().decode([Remote].self, from: Data(actualJSON.utf8))
        let expectedRemotes = try JSONDecoder().decode([Remote].self, from: Data(expectedJSON.utf8))
        #expect(actualRemotes.count == 2)
        #expect(actualRemotes == expectedRemotes)
        #expect(actualRemotes.allSatisfy { $0.host == "127.0.0.1" && $0.protocol == "http" })
        for (key, value) in expected where key != "setup/api-list" { #expect(snapshot[key] == value) }
        // Upstream may add cache/settings keys; their existence is not a loss of the seeded values.
    }
}

@MainActor
private final class OfficialDistributionFixture {
    let paths: AppPaths
    let dataStore = WKWebsiteDataStore(forIdentifier: UUID())
    var reservations: [LoopbackHTTPServer] = []
    var mihomoServers: [MockMihomoServer] = []
    private var models: [AppModel] = []
    init(paths: AppPaths) { self.paths = paths }
    func model() -> AppModel {
        let model = AppModel(paths: paths, dataStore: dataStore)
        models.append(model); return model
    }
    func shutdown(_ model: AppModel) async {
        #expect(await model.prepareToQuit())
        await model.session?.suspend()
        model.session = nil; model.server = nil
        models.removeAll { $0 === model }
    }
    func cleanUp() async {
        for model in Array(models.reversed()) { await shutdown(model) }
        for reservation in reservations { reservation.stop() }
        for mihomo in mihomoServers { mihomo.stop() }
        reservations.removeAll(); mihomoServers.removeAll()
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? FileManager.default.removeItem(at: paths.root)
    }
}
