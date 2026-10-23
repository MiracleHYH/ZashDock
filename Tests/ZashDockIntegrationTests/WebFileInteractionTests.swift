import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WebKit
@testable import ZashDock
import ZashDockCore

@MainActor
private final class FixtureWebPanels: WebPanelDriving {
    var confirms = true
    var promptText: String? = "native reply"
    var selectedFiles: [URL]?
    var destination: URL?
    var alertMessages: [String] = []
    var confirmMessages: [String] = []
    var promptMessages: [String] = []
    var selectionRequests: [(Bool, Bool)] = []
    var saveNames: [String] = []
    var saveTypes: [UTType?] = []
    var failureCount = 0
    var cancellationCount = 0
    var onConfirm: (() -> Void)?
    var onPrompt: (() -> Void)?
    var onChooseFiles: (() -> Void)?
    var onSave: (() -> Void)?
    var waitsForSaveChoice = false
    var ignoresCancellation = false
    var pendingSave: CheckedContinuation<URL?, Never>?
    func alert(_ message: String) async { alertMessages.append(message) }
    func confirm(_ message: String) async -> Bool { confirmMessages.append(message); onConfirm?(); return confirms }
    func prompt(_ message: String, defaultText: String?) async -> String? { promptMessages.append(message); onPrompt?(); return promptText }
    func chooseFiles(allowsMultipleSelection: Bool, allowsDirectories: Bool) async -> [URL]? {
        selectionRequests.append((allowsMultipleSelection, allowsDirectories)); onChooseFiles?(); return selectedFiles
    }
    func chooseSaveDestination(suggestedName: String, contentType: UTType?) async -> URL? {
        saveNames.append(suggestedName); saveTypes.append(contentType); onSave?()
        if waitsForSaveChoice { return await withCheckedContinuation { pendingSave = $0 } }
        return destination
    }
    func exportFailed() async { failureCount += 1 }
    func cancel() {
        cancellationCount += 1
        if !ignoresCancellation { pendingSave?.resume(returning: nil); pendingSave = nil }
    }
    func completeSaveChoice(_ url: URL?) { pendingSave?.resume(returning: url); pendingSave = nil }
}

@Suite(.serialized)
@MainActor
struct WebFileInteractionTests {
    private func fixture(_ script: String = "") throws -> URL {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockFileTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let html = """
        <!doctype html><html><head><style>html,body{margin:0;width:100%;height:100%}button{position:absolute;inset:0;width:100%;height:100%}</style></head><body>
        <div id="app">文件交互 fixture</div><button id="action">执行</button><script>\(script)</script></body></html>
        """
        try Data(html.utf8).write(to: root.appendingPathComponent("index.html"))
        return root
    }
    private func wait(_ page: WebPage, expression: String) async throws {
        for _ in 0..<100 {
            if try await page.callJavaScript("return Boolean(\(expression));") as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let state = try await page.callJavaScript("return JSON.stringify({status:window.exportStatus,trusted:window.lastClickWasTrusted,subframe:window.subframeExportStatus,files:window.chosenFiles});")
        print("Timed out waiting for", expression, state as Any)
        #expect(try await page.callJavaScript("return Boolean(\(expression));") as? Bool == true)
    }
    private func host(_ page: WebPage) -> NSWindow {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WebView(page).frame(width: 420, height: 300))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }
    /// Delivered through AppKit to WebKit, producing a trusted DOM click; no page protocol test bypass exists.
    private func click(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(500))
        let point = NSPoint(x: 210, y: 150)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            if let target = window.contentView?.hitTest(point) {
                if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
            }
        }
    }
    private let exportScript = """
    window.exportStatus = '';
    addEventListener('zashdock-export-result', event => { window.exportStatus = event.detail; });
    window.exportSettings = () => {
      const blob = new Blob([JSON.stringify({'config/theme':'dark','config/label':'中文导出'}, null, 2)], {type:'application/json'});
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a'); a.href = url; a.download = 'zashboard-settings'; a.click(); URL.revokeObjectURL(url);
    };
    document.getElementById('action').onclick = event => { window.lastClickWasTrusted = event.isTrusted; window.exportSettings(); };
    """

    @Test(.timeLimit(.minutes(1)))
    func realWebPageRoutesAlertConfirmAndPromptAndCancellation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root); defer { server.stop() }
        let panels = FixtureWebPanels()
        let session = WebSession(origin: server.baseURL, dataStore: .nonPersistent(), panels: panels); defer { session.stop() }
        try await session.loadAndVerify()
        try await session.page.callJavaScript("alert('notice'); window.confirmed = confirm('continue?'); window.reply = prompt('name?', 'default');")
        #expect(panels.alertMessages == ["notice"])
        #expect(panels.confirmMessages == ["continue?"])
        #expect(panels.promptMessages == ["name?"])
        #expect(try await session.page.callJavaScript("return window.confirmed;") as? Bool == true)
        #expect(try await session.page.callJavaScript("return window.reply;") as? String == "native reply")
        panels.confirms = false; panels.promptText = nil
        #expect(try await session.page.callJavaScript("return confirm('cancel');") as? Bool == false)
        #expect(try await session.page.callJavaScript("return prompt('cancel');") is NSNull)
    }

    @Test(.timeLimit(.minutes(1)))
    func officialBlobClickImmediateRevokeSavesBytesAndCancellationDoesNotOverwrite() async throws {
        let root = try fixture(exportScript)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root); defer { server.stop() }
        let panels = FixtureWebPanels()
        let saved = root.appendingPathComponent("chosen.json")
        panels.destination = saved
        let session = WebSession(origin: server.baseURL, dataStore: .nonPersistent(), panels: panels); defer { session.stop() }
        let window = host(session.page); defer { window.close() }
        try await session.loadAndVerify()
        try await click(window)
        try await wait(session.page, expression: "window.exportStatus === 'saved'")
        #expect(try await session.page.callJavaScript("return window.lastClickWasTrusted;") as? Bool == true)
        let bytes = try Data(contentsOf: saved)
        let settings = try JSONDecoder().decode([String: String].self, from: bytes)
        #expect(settings == ["config/theme": "dark", "config/label": "中文导出"])
        #expect(panels.saveNames == ["zashboard-settings.json"])
        #expect(panels.saveTypes.first! == .json)
        // A fresh user click permits another export, but cancelling its save panel preserves the previous file.
        panels.destination = nil
        try await session.page.callJavaScript("window.exportStatus = '';")
        try await click(window)
        try await wait(session.page, expression: "window.exportStatus === 'cancelled'")
        #expect(try Data(contentsOf: saved) == bytes)
        #expect(panels.saveNames.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func backForwardDocumentCannotReuseAnotherDocumentsTrustedClick() async throws {
        let root = try fixture(exportScript + "\nwindow.fixtureContextID=crypto.randomUUID(); window.fixturePersisted=false; addEventListener('pageshow',event=>window.fixturePersisted=event.persisted);")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("index.html"), to: root.appendingPathComponent("next.html"))
        let server = try await bindFixture(root); defer { server.stop() }
        let panels = FixtureWebPanels(); panels.destination = root.appendingPathComponent("chosen.json")
        let session = WebSession(origin: server.baseURL, dataStore: .nonPersistent(), panels: panels); defer { session.stop() }
        let window = host(session.page); defer { window.close() }
        try await session.loadAndVerify()
        let firstItem = try #require(session.page.backForwardList.currentItem)
        let firstContext = try #require(try await session.page.callJavaScript("return fixtureContextID;") as? String)
        for try await _ in session.page.load(URLRequest(url: server.baseURL.appendingPathComponent("next.html"))) {}
        try await session.page.callJavaScript("document.getElementById('action').onclick=event=>window.clickedWasTrusted=event.isTrusted;")
        try await click(window)
        try await wait(session.page, expression: "window.clickedWasTrusted === true")
        for try await _ in session.page.load(firstItem) {}
        let currentContext = try await session.page.callJavaScript("return fixtureContextID;") as? String
        let persisted = try await session.page.callJavaScript("return fixturePersisted;") as? Bool == true
        print("Export gesture back-forward reused JS context: \(currentContext == firstContext), pageshow.persisted: \(persisted)")
        try await session.page.callJavaScript("window.exportStatus=''; window.exportSettings();")
        try await wait(session.page, expression: "window.exportStatus === 'rejected'")
        #expect(panels.saveNames.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: panels.destination!.path))
        // Revoking the old document's authorization does not disable a fresh real click.
        try await click(window)
        try await wait(session.page, expression: "window.exportStatus === 'saved'")
        #expect(panels.saveNames.count == 1)
        #expect(FileManager.default.fileExists(atPath: panels.destination!.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func navigatingWhileSaveWaitsCancelsPanelAndRejectsEvenALateChosenDestination() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("index.html"), to: root.appendingPathComponent("next.html"))
        let server = try await bindFixture(root); defer { server.stop() }
        let panels = FixtureWebPanels()
        panels.waitsForSaveChoice = true
        panels.ignoresCancellation = true // Model a choice racing with the native cancellation.
        let destination = root.appendingPathComponent("stale-document.json")
        let original = Data("keep the existing file".utf8); try original.write(to: destination)
        let session = WebSession(origin: server.baseURL, dataStore: .nonPersistent(), panels: panels); defer { session.stop() }
        let window = host(session.page); defer { window.close() }
        try await session.loadAndVerify()
        try await session.page.callJavaScript("document.getElementById('action').onclick=event=>window.clickedWasTrusted=event.isTrusted;")
        try await click(window)
        try await wait(session.page, expression: "window.clickedWasTrusted === true")
        // The real isolated-world click authorizes the same bounded request used by Blob exports.
        // Keeping the native result lets the test await completion after the old JS context freezes.
        let exporting = Task { @MainActor in
            await session.interactions.receiveExport(["schema": 1, "filename": "stale-document.json", "mime": "application/json", "base64": "e30="], trustedFrame: true)
        }
        defer { panels.completeSaveChoice(nil) }
        for _ in 0..<100 {
            if panels.pendingSave != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(panels.pendingSave != nil)
        for try await _ in session.page.load(URLRequest(url: server.baseURL.appendingPathComponent("next.html"))) {}
        #expect(panels.cancellationCount >= 1)
        panels.completeSaveChoice(destination)
        #expect(await exporting.value == .cancelled)
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test(.timeLimit(.minutes(1)))
    func changedDocumentCancelsConfirmPromptAndFileSelectionReplies() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.json"); try Data("{}".utf8).write(to: selected)
        let server = try await bindFixture(root); defer { server.stop() }
        let panels = FixtureWebPanels()
        let session = WebSession(origin: server.baseURL, dataStore: .nonPersistent(), panels: panels); defer { session.stop() }
        try await session.loadAndVerify()
        let documentChanged: () -> Void = { [weak interactions = session.interactions] in
            interactions?.receiveGesture(["schema": 1, "kind": "document"], trustedFrame: true)
        }
        panels.onConfirm = documentChanged
        #expect(try await session.page.callJavaScript("return confirm('old document');") as? Bool == false)
        panels.onPrompt = documentChanged
        #expect(try await session.page.callJavaScript("return prompt('old document');") is NSNull)
        panels.selectedFiles = [selected]; panels.onChooseFiles = documentChanged
        #expect(await session.interactions.chooseFiles(allowsMultipleSelection: false, allowsDirectories: false) == .cancel)
        #expect(panels.cancellationCount == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func syntheticClicksAndForeignOrSubframeMessagesCannotOpenSavePanel() async throws {
        let root = try fixture(exportScript)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root); defer { server.stop() }
        let panels = FixtureWebPanels(); panels.destination = root.appendingPathComponent("must-not-exist.json")
        let session = WebSession(origin: server.baseURL, dataStore: .nonPersistent(), panels: panels); defer { session.stop() }
        try await session.loadAndVerify()
        try await session.page.callJavaScript("document.getElementById('action').click();")
        try await wait(session.page, expression: "window.exportStatus === 'rejected'")
        #expect(panels.saveNames.isEmpty)
        #expect(try await session.page.callJavaScript("return typeof window.webkit.messageHandlers.zashdockExportGesture;") as? String == "undefined")
        // Use a separate unrestricted navigation fixture so the child really executes. Production denies its navigation.
        let controller = WKUserContentController()
        let interactions = WebInteractionCoordinator(origin: server.baseURL, controller: controller, panels: panels)
        defer { interactions.stop() }
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        configuration.defaultNavigationPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        let page = WebPage(configuration: configuration, dialogPresenter: interactions)
        defer { page.stopLoading() }
        let window = host(page); defer { window.close() }
        for try await _ in page.load(URLRequest(url: server.baseURL)) {}
        try await page.callJavaScript("""
        document.getElementById('action').onclick = () => {
          const frame = document.createElement('iframe');
          frame.srcdoc = '<script>window.webkit.messageHandlers.zashdockExport.postMessage({schema:1,filename:"forged.json",mime:"application/json",base64:"e30="}).then(result => parent.subframeExportStatus = result.status);<' + '/script>';
          document.body.appendChild(frame);
        };
        """)
        try await click(window)
        try await wait(page, expression: "window.subframeExportStatus === 'rejected'")
        #expect(panels.saveNames.isEmpty)
        let foreignRoot = try fixture(); defer { try? FileManager.default.removeItem(at: foreignRoot) }
        let foreignServer = try await bindFixture(foreignRoot); defer { foreignServer.stop() }
        for try await _ in page.load(URLRequest(url: foreignServer.baseURL)) {}
        #expect(try await page.callJavaScript("return confirm('foreign frame');") as? Bool == false)
        let foreignResult = try await page.callJavaScript("return await window.webkit.messageHandlers.zashdockExport.postMessage({schema:1,filename:'forged.json',mime:'application/json',base64:'e30='});") as? [String: String]
        #expect(foreignResult?["status"] == "rejected")
        #expect(panels.confirmMessages.isEmpty)
        #expect(panels.saveNames.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: panels.destination!.path))
        #expect(!session.interactions.trusts(isMainFrame: true, url: URL(string: "https://example.com"), scheme: "https", host: "example.com", port: 443))
        #expect(!session.interactions.trusts(isMainFrame: false, url: server.baseURL, scheme: "http", host: "127.0.0.1", port: server.baseURL.port!))
    }

    @Test(.timeLimit(.minutes(1)))
    func realFileInputSelectsJSONAndImageAndCancellation() async throws {
        let script = """
        const input = document.createElement('input'); input.type = 'file'; input.multiple = true; input.accept = 'application/json,image/*'; input.hidden = true;
        document.body.appendChild(input);
        input.onchange = async () => { window.chosenFiles = await Promise.all([...input.files].map(async file => ({name:file.name,text:await file.text()}))); };
        document.getElementById('action').onclick = () => input.click();
        """
        let root = try fixture(script); defer { try? FileManager.default.removeItem(at: root) }
        let json = root.appendingPathComponent("import.json"), image = root.appendingPathComponent("background.png")
        try Data("{\"config/theme\":\"light\"}".utf8).write(to: json)
        // A valid one-pixel PNG, not a mislabeled string fixture.
        try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jr1cAAAAASUVORK5CYII=")).write(to: image)
        let server = try await bindFixture(root); defer { server.stop() }
        let panels = FixtureWebPanels(); panels.selectedFiles = [json, image]
        let session = WebSession(origin: server.baseURL, dataStore: .nonPersistent(), panels: panels); defer { session.stop() }
        let window = host(session.page); defer { window.close() }
        try await session.loadAndVerify(); try await click(window)
        try await wait(session.page, expression: "window.chosenFiles?.length === 2")
        #expect(panels.selectionRequests.count == 1)
        #expect(panels.selectionRequests.first?.0 == true)
        #expect(panels.selectionRequests.first?.1 == false)
        #expect(try await session.page.callJavaScript("return chosenFiles[0].text;") as? String == "{\"config/theme\":\"light\"}")
        #expect(try await session.page.callJavaScript("return chosenFiles[1].name;") as? String == "background.png")
        panels.selectedFiles = nil
        #expect(await session.interactions.chooseFiles(allowsMultipleSelection: false, allowsDirectories: false) == .cancel)
        panels.selectedFiles = [root]
        #expect(await session.interactions.chooseFiles(allowsMultipleSelection: false, allowsDirectories: false) == .cancel)
        panels.selectedFiles = [URL(string: "https://example.com/file.json")!]
        #expect(await session.interactions.chooseFiles(allowsMultipleSelection: false, allowsDirectories: false) == .cancel)
    }

    @Test
    func malformedAndOversizedExportPayloadsAreRejected() throws {
        let valid: [String: Any] = ["schema": 1, "filename": "settings", "mime": "application/json", "base64": "e30="]
        #expect(WebExportPayload(valid)?.data == Data("{}".utf8))
        for (key, value) in [("schema", true as Any), ("filename", "../escape.json"), ("filename", ".hidden"), ("filename", "x\\y"), ("filename", "x\ny"), ("mime", "text/html"), ("base64", "invalid!")] {
            var malformed = valid; malformed[key] = value
            #expect(WebExportPayload(malformed) == nil)
        }
        var withPath = valid; withPath["path"] = "/tmp/arbitrary"
        #expect(WebExportPayload(withPath) == nil)
        var tooLarge = valid; tooLarge["base64"] = Data(repeating: 0x41, count: WebExportPayload.maximumBytes + 1).base64EncodedString()
        #expect(WebExportPayload(tooLarge) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppingWhileConfirmIsPresentedCancelsTheAnswer() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root); defer { server.stop() }
        let panels = FixtureWebPanels()
        let session = WebSession(origin: server.baseURL, dataStore: .nonPersistent(), panels: panels)
        defer { session.stop() }
        try await session.loadAndVerify()
        panels.onConfirm = { [weak interactions = session.interactions] in interactions?.stop() }
        #expect(try await session.page.callJavaScript("return confirm('stop while open');") as? Bool == false)
        #expect(panels.cancellationCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func writeFailureIsReportedAndStoppingDuringSaveCannotWrite() async throws {
        let root = try fixture(exportScript); defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root); defer { server.stop() }
        let panels = FixtureWebPanels()
        panels.destination = root.appendingPathComponent("missing-parent/export.json")
        let session = WebSession(origin: server.baseURL, dataStore: .nonPersistent(), panels: panels)
        defer { session.stop() }
        let window = host(session.page); defer { window.close() }
        try await session.loadAndVerify(); try await click(window)
        try await wait(session.page, expression: "window.exportStatus === 'failed'")
        #expect(panels.failureCount == 1)
        #expect(!FileManager.default.fileExists(atPath: panels.destination!.path))
        let cancelledDestination = root.appendingPathComponent("cancelled.json")
        panels.destination = cancelledDestination
        panels.onSave = { [weak interactions = session.interactions] in interactions?.stop() }
        try await session.page.callJavaScript("window.exportStatus = '';")
        try await click(window)
        try await wait(session.page, expression: "window.exportStatus === 'cancelled'")
        #expect(!FileManager.default.fileExists(atPath: cancelledDestination.path))
        #expect(panels.cancellationCount == 1)
    }
}
