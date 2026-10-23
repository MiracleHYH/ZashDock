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
            return .cancel // Blob exports are handled by the bounded native save bridge.
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
    let interactions: WebInteractionCoordinator
    private(set) var runtimeFailure: String?
    var hasRuntimeFailure: Bool { runtimeFailure != nil }
    @ObservationIgnored var onFailure: (@MainActor (String) -> Void)?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var suspensionTask: Task<Void, Never>?
    private var verifiedInitialDocument = false
    private var stopped = false
    private var navigationGeneration = 0
    private var validatingNavigation = false
    private let expectedVersion: String?
    private let expectedNonce: String?
    init(origin: URL, expectedVersion: String? = nil, expectedNonce: String? = nil, dataStore: WKWebsiteDataStore = .default(), panels: any WebPanelDriving = NativeWebPanelDriver()) {
        self.origin = origin
        self.expectedVersion = expectedVersion; self.expectedNonce = expectedNonce
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        let controller = WKUserContentController()
        configuration.userContentController = controller
        interactions = WebInteractionCoordinator(origin: origin, controller: controller, panels: panels)
        configuration.defaultNavigationPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        configuration.deviceSensorAuthorization = .init(decision: .deny)
        page = WebPage(configuration: configuration, navigationDecider: LocalNavigationPolicy(origin: origin), dialogPresenter: interactions)
        let page = page
        navigationTask = Task { @MainActor [weak self] in
            // A policy cancellation terminates an individual sequence; keep observing
            // the next navigation rather than losing all later failure notifications.
            while !Task.isCancelled {
                let events = page.navigations
                do {
                    for try await event in events {
                        guard !Task.isCancelled else { return }
                        self?.observe(event)
                    }
                    return
                } catch {
                    guard !Task.isCancelled, let self, !self.stopped else { return }
                    self.reportNavigationFailure(error)
                    if !Self.ignoresNavigationError(error) { return }
                    if self.validatingNavigation { self.validateNavigationDocument() }
                }
            }
        }
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
        try await verifyDocument()
        verifiedInitialDocument = true
    }
    private func verifyDocument() async throws {
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
    }
    private func observe(_ event: WebPage.NavigationEvent) {
        guard verifiedInitialDocument, !stopped, !hasRuntimeFailure else { return }
        if event == .startedProvisionalNavigation {
            navigationGeneration += 1
            validationTask?.cancel()
            validatingNavigation = true
        } else if event == .finished {
            validateNavigationDocument()
        }
    }
    private func validateNavigationDocument() {
        let generation = navigationGeneration
        validationTask?.cancel()
        validationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.verifyDocument()
                guard !Task.isCancelled, generation == self.navigationGeneration, !self.stopped else { return }
                self.validatingNavigation = false
            } catch {
                guard !Task.isCancelled, generation == self.navigationGeneration else { return }
                self.reportNavigationFailure(error)
            }
        }
    }
    private func reportNavigationFailure(_ error: any Error) {
        guard verifiedInitialDocument, !stopped, !hasRuntimeFailure else { return }
        if Self.ignoresNavigationError(error) { return }
        let message: String
        if case WebPage.NavigationError.webContentProcessTerminated = error {
            message = "网页进程已结束。已保存的数据仍在，请重新载入 Zashboard。"
        } else {
            message = "网页无法继续显示。已保存的数据仍在，请重新载入 Zashboard。"
        }
        runtimeFailure = message
        interactions.stop()
        onFailure?(message)
    }
    static func ignoresNavigationError(_ error: any Error) -> Bool {
        let underlying: any Error
        if case let WebPage.NavigationError.failedProvisionalNavigation(reason) = error { underlying = reason }
        else { underlying = error }
        let cocoa = underlying as NSError
        // A cancelled navigation or one handed to the system browser does not invalidate the local page.
        return (cocoa.domain == NSURLErrorDomain && cocoa.code == NSURLErrorCancelled)
            || (cocoa.domain == "WebKitErrorDomain" && cocoa.code == 102)
    }
    func suspend() async {
        if let suspensionTask { await suspensionTask.value; return }
        stopped = true
        navigationTask?.cancel(); validationTask?.cancel()
        interactions.stop()
        // Unload the old JavaScript context and its sockets before reusing the same Origin for another version.
        // Cleanup must finish even when the operation that requested it has been cancelled.
        let page = page, url = origin.appendingPathComponent("__zashdock_suspended")
        let unloading = Task { @MainActor in
            do {
                for try await _ in page.load(simulatedRequest: URLRequest(url: url), responseHTML: "<html><head><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; base-uri 'none'; form-action 'none'\"></head><body></body></html>") {}
            } catch { page.stopLoading() }
        }
        suspensionTask = unloading
        await unloading.value
    }
    func stop() {
        stopped = true
        navigationTask?.cancel(); validationTask?.cancel()
        interactions.stop(); page.stopLoading()
    }
}
