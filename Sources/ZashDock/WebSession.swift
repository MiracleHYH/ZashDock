import AppKit
import Observation
import WebKit
import ZashDockCore

@MainActor
struct LocalNavigationPolicy: WebPage.NavigationDeciding {
    let origin: URL
    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port {
            return action.target?.isMainFrame == false ? .cancel : .allow
        }
        if url.scheme == "blob", url.absoluteString.hasPrefix("blob:\(origin.absoluteString)/"), action.source.isMainFrame, action.shouldPerformDownload {
            return .download
        }
        if ["https", "http"].contains(url.scheme?.lowercased() ?? ""), action.source.isMainFrame {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }
}

@MainActor
enum WebCacheController {
    /// Only disposable loopback caches are removed. LocalStorage, IndexedDB, cookies and credentials survive.
    static func clearLoopbackCaches(in dataStore: WKWebsiteDataStore = .default()) async {
        let types: Set<String> = [WKWebsiteDataTypeServiceWorkerRegistrations, WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
        let records = await dataStore.dataRecords(ofTypes: types)
        let localRecords = records.filter { $0.displayName == "127.0.0.1" || $0.displayName.hasPrefix("127.0.0.1:") }
        if !localRecords.isEmpty { await dataStore.removeData(ofTypes: types, for: localRecords) }
    }
}

@MainActor @Observable
final class WebSession {
    let page: WebPage
    let origin: URL
    let storageBridge: ZashboardStorageBridge?
    private let expectedVersion: String?
    private let expectedNonce: String?
    init(origin: URL, storageBridge: ZashboardStorageBridge? = nil, expectedVersion: String? = nil, expectedNonce: String? = nil) {
        self.origin = origin; self.storageBridge = storageBridge
        self.expectedVersion = expectedVersion; self.expectedNonce = expectedNonce
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .default()
        if let storageBridge { configuration.userContentController = storageBridge.controller }
        configuration.defaultNavigationPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        configuration.deviceSensorAuthorization = .init(decision: .deny)
        page = WebPage(configuration: configuration, navigationDecider: LocalNavigationPolicy(origin: origin))
    }
    func loadAndVerify() async throws {
        var request = URLRequest(url: origin)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            if !Task.isCancelled { self?.page.stopLoading() }
        }
        defer { timeout.cancel() }
        for try await _ in page.load(request) { try Task.checkCancellation() }
        let valid = try await page.callJavaScript("""
            if (location.origin !== expected) return false;
            const deadline = Date.now() + 8000;
            while (Date.now() < deadline) {
                const app = document.getElementById('app');
                if (app && (app.childElementCount > 0 || app.textContent.trim().length > 0)) {
                    const response = await fetch('/__zashdock_health', {cache: 'no-store'});
                    if (!response.ok) return false;
                    const health = await response.json();
                    return (!version || health.version === version) && (!nonce || health.nonce === nonce);
                }
                await new Promise(resolve => setTimeout(resolve, 50));
            }
            return false;
            """, arguments: ["expected": "http://127.0.0.1:\(origin.port!)", "version": expectedVersion ?? "", "nonce": expectedNonce ?? ""])
        guard valid as? Bool == true else { throw ZashDockError.verification("Zashboard 未正常渲染，或本地服务版本验证失败。") }
        try await storageBridge?.verifyRestore(page)
    }
    func flush() async throws { if let storageBridge { try await storageBridge.flush(page) } }
    func suspend() async {
        storageBridge?.disableAutomaticPersistence()
        // Unload the old JavaScript context and its sockets before reusing the same Origin for another version.
        storageBridge?.controller.removeAllUserScripts()
        do {
            for try await _ in page.load(simulatedRequest: URLRequest(url: origin.appendingPathComponent("__zashdock_suspended")), responseHTML: "<html><body></body></html>") {}
        } catch { page.stopLoading() }
    }
    func stop() { storageBridge?.disableAutomaticPersistence(); page.stopLoading() }
}
