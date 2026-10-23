import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

/// UI is injectable so regression tests exercise real bytes without opening panels.
@MainActor
protocol WebPanelDriving: AnyObject {
    func alert(_ message: String) async
    func confirm(_ message: String) async -> Bool
    func prompt(_ message: String, defaultText: String?) async -> String?
    func chooseFiles(allowsMultipleSelection: Bool, allowsDirectories: Bool) async -> [URL]?
    func chooseSaveDestination(suggestedName: String, contentType: UTType?) async -> URL?
    func exportFailed() async
    func cancel()
}

@MainActor
final class NativeWebPanelDriver: WebPanelDriving {
    private var activePanel: NSSavePanel?
    private var activeAlert: NSAlert?

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        activeAlert = alert
        defer { activeAlert = nil }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
    private func makeAlert(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Zashboard"
        alert.informativeText = String(message.prefix(8_192))
        return alert
    }
    func alert(_ message: String) async {
        let alert = makeAlert(message)
        alert.addButton(withTitle: "好")
        _ = await present(alert)
    }
    func confirm(_ message: String) async -> Bool {
        let alert = makeAlert(message)
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        return await present(alert) == .alertFirstButtonReturn
    }
    func prompt(_ message: String, defaultText: String?) async -> String? {
        let alert = makeAlert(message)
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        return await present(alert) == .alertFirstButtonReturn ? input.stringValue : nil
    }
    private func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        activePanel = panel
        defer { activePanel = nil }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await panel.beginSheetModal(for: window)
        }
        return await panel.begin()
    }
    func chooseFiles(allowsMultipleSelection: Bool, allowsDirectories: Bool) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "为 Zashboard 选择文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowsDirectories
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.resolvesAliases = true
        // macOS 26 WKOpenPanelParameters exposes selection/directory flags, but no accept-type list.
        // The HTML accept attribute is a selection hint, not authorization to access other files.
        return await present(panel) == .OK ? panel.urls : nil
    }
    func chooseSaveDestination(suggestedName: String, contentType: UTType?) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出 Zashboard 文件"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let contentType { panel.allowedContentTypes = [contentType] }
        return await present(panel) == .OK ? panel.url : nil
    }
    func exportFailed() async { await alert("文件导出失败。请确认保存位置可写后重试。") }
    func cancel() {
        activePanel?.cancel(nil)
        if let alert = activeAlert {
            if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
            else { NSApp.abortModal(); alert.window.orderOut(nil) }
        }
    }
}

/// The request is limited to bytes and a suggested basename. Only a native panel supplies a destination URL.
struct WebExportPayload {
    static let maximumBytes = 16 * 1_024 * 1_024
    let data: Data
    let suggestedName: String
    let contentType: UTType?

    init?(_ body: Any) {
        guard let fields = body as? [String: Any], Set(fields.keys) == ["schema", "filename", "mime", "base64"],
              let schema = fields["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema == 1,
              let name = fields["filename"] as? String, !name.isEmpty, name.utf8.count <= 128,
              !name.hasPrefix("."), !name.contains("/"), !name.contains(":"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let mime = fields["mime"] as? String,
              ["application/json", "text/plain", "text/csv", "text/yaml", "application/yaml", "application/octet-stream", "image/png", "image/jpeg", "image/webp", "image/gif", "image/svg+xml"].contains(mime),
              let encoded = fields["base64"] as? String, encoded.utf8.count <= ((Self.maximumBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: encoded), data.count <= Self.maximumBytes else { return nil }
        self.data = data
        let type = UTType(mimeType: mime)
        self.contentType = type
        if URL(fileURLWithPath: name).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension {
            suggestedName = "\(name).\(ext)"
        } else { suggestedName = name }
    }
}

@MainActor
private final class ExportMessageReceiver: NSObject, WKScriptMessageHandlerWithReply {
    weak var coordinator: WebInteractionCoordinator?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let coordinator else { replyHandler(["status": "rejected"], nil); return }
        Task { @MainActor in
            let result = await coordinator.receiveExport(message.body, trustedFrame: coordinator.trusts(message.frameInfo))
            replyHandler(["status": result.rawValue], nil)
        }
    }
}

@MainActor
private final class ExportGestureReceiver: NSObject, WKScriptMessageHandler {
    weak var coordinator: WebInteractionCoordinator?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        coordinator?.receiveGesture(message.body, trustedFrame: coordinator?.trusts(message.frameInfo) == true)
    }
}

/// Owns dialog lifetimes, read scopes and the bounded Blob export channel for one WebPage.
@MainActor
final class WebInteractionCoordinator: WebPage.DialogPresenting {
    enum ExportResult: String { case saved, cancelled, rejected, failed }
    private let origin: URL
    private let controller: WKUserContentController
    private let panels: any WebPanelDriving
    private let exportReceiver = ExportMessageReceiver()
    private let gestureReceiver = ExportGestureReceiver()
    private let gestureWorld = WKContentWorld.world(name: "ZashDock.ExportGesture")
    private var gestureDeadline: ContinuousClock.Instant?
    private var documentGeneration: UInt64 = 0
    private var busy = false
    private var stopped = false
    private var fileScopes: [URL] = []

    init(origin: URL, controller: WKUserContentController, panels: any WebPanelDriving = NativeWebPanelDriver()) {
        precondition(origin.scheme == "http" && origin.host == "127.0.0.1" && origin.port != nil)
        self.origin = origin; self.controller = controller; self.panels = panels
        exportReceiver.coordinator = self; gestureReceiver.coordinator = self
        controller.addScriptMessageHandler(exportReceiver, contentWorld: .page, name: "zashdockExport")
        controller.add(gestureReceiver, contentWorld: gestureWorld, name: "zashdockExportGesture")
        controller.addUserScript(WKUserScript(source: Self.gestureScript(origin: origin), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: gestureWorld))
        controller.addUserScript(WKUserScript(source: Self.exportScript(origin: origin), injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    func trusts(_ frame: WebPage.FrameInfo) -> Bool {
        trusts(isMainFrame: frame.isMainFrame, url: frame.request.url, scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host, port: frame.securityOrigin.port)
    }
    fileprivate func trusts(_ frame: WKFrameInfo) -> Bool {
        trusts(isMainFrame: frame.isMainFrame, url: frame.request.url, scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host, port: frame.securityOrigin.port)
    }
    func trusts(isMainFrame: Bool, url: URL?, scheme: String, host: String, port: Int) -> Bool {
        !stopped && isMainFrame && scheme == "http" && host == "127.0.0.1" && port == origin.port &&
        url?.scheme == origin.scheme && url?.host == origin.host && url?.port == origin.port
    }
    func handleJavaScriptAlert(message: String, initiatedBy frame: WebPage.FrameInfo) async {
        guard trusts(frame), !busy else { return }
        busy = true; defer { busy = false }
        await panels.alert(message)
    }
    func handleJavaScriptConfirm(message: String, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptConfirmResult {
        guard trusts(frame), !busy else { return .cancel }
        busy = true; defer { busy = false }
        let generation = documentGeneration
        let accepted = await panels.confirm(message)
        return !stopped && generation == documentGeneration && accepted ? .ok : .cancel
    }
    func handleJavaScriptPrompt(message: String, defaultText: String?, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptPromptResult {
        guard trusts(frame), !busy else { return .cancel }
        busy = true; defer { busy = false }
        let generation = documentGeneration
        guard let text = await panels.prompt(message, defaultText: defaultText), !stopped,
              generation == documentGeneration else { return .cancel }
        return .ok(text)
    }
    func handleFileInputPrompt(parameters: WKOpenPanelParameters, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.FileInputPromptResult {
        guard trusts(frame) else { return .cancel }
        return await chooseFiles(allowsMultipleSelection: parameters.allowsMultipleSelection, allowsDirectories: parameters.allowsDirectories)
    }
    func chooseFiles(allowsMultipleSelection: Bool, allowsDirectories: Bool) async -> WebPage.FileInputPromptResult {
        guard !busy, !stopped else { return .cancel }
        busy = true; defer { busy = false }
        let generation = documentGeneration
        guard let urls = await panels.chooseFiles(allowsMultipleSelection: allowsMultipleSelection, allowsDirectories: allowsDirectories), !stopped,
              generation == documentGeneration,
              !urls.isEmpty, allowsMultipleSelection || urls.count == 1, urls.allSatisfy({ $0.isFileURL }) else { return .cancel }
        let newlyScoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        var accepted = false
        defer { if !accepted { for url in newlyScoped { url.stopAccessingSecurityScopedResource() } } }
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]),
                  values.isRegularFile == true || (allowsDirectories && values.isDirectory == true) else { return .cancel }
        }
        for url in fileScopes { url.stopAccessingSecurityScopedResource() }
        fileScopes = newlyScoped
        accepted = true
        return .selected(urls)
    }
    /// Called only by a handler registered in an isolated content world. The page cannot mint a trusted click.
    func receiveGesture(_ body: Any, trustedFrame: Bool) {
        guard trustedFrame, let fields = body as? [String: Any], Set(fields.keys) == ["schema", "kind"],
              let schema = fields["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema == 1,
              let kind = fields["kind"] as? String else { return }
        if kind == "document" {
            documentGeneration &+= 1
            gestureDeadline = nil
            // A native sheet belongs to the document that requested it. Navigation and
            // BFCache activation must revoke both a pending choice and its late reply.
            if busy { panels.cancel() }
        }
        else if kind == "click", !busy { gestureDeadline = .now.advanced(by: .seconds(3)) }
    }
    func receiveExport(_ body: Any, trustedFrame: Bool) async -> ExportResult {
        guard trustedFrame, !stopped, !busy, let deadline = gestureDeadline, .now <= deadline else { return .rejected }
        gestureDeadline = nil // A malformed request also consumes the one-use authorization.
        guard let payload = WebExportPayload(body) else { return .rejected }
        busy = true; defer { busy = false }
        let generation = documentGeneration
        guard let destination = await panels.chooseSaveDestination(suggestedName: payload.suggestedName, contentType: payload.contentType), !stopped,
              generation == documentGeneration else { return .cancelled }
        guard destination.isFileURL else { return .rejected }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            try payload.data.write(to: destination, options: .atomic)
            return .saved
        } catch {
            await panels.exportFailed()
            return .failed
        }
    }
    isolated deinit { stop() }
    func stop() {
        guard !stopped else { return }
        stopped = true; gestureDeadline = nil
        controller.removeScriptMessageHandler(forName: "zashdockExport", contentWorld: .page)
        controller.removeScriptMessageHandler(forName: "zashdockExportGesture", contentWorld: gestureWorld)
        panels.cancel()
        for url in fileScopes { url.stopAccessingSecurityScopedResource() }
        fileScopes.removeAll()
    }

    private static func encodedOrigin(_ origin: URL) -> String {
        // A loopback origin cannot contain script delimiters; JSON encoding keeps this invariant explicit.
        let data = try! JSONSerialization.data(withJSONObject: ["http://127.0.0.1:\(origin.port!)"])
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }
    private static func gestureScript(origin: URL) -> String {
        """
        (() => {
          if (window !== top || location.origin !== \(encodedOrigin(origin))) return;
          const post = kind => { try { window.webkit.messageHandlers.zashdockExportGesture.postMessage({schema:1,kind}); } catch (_) {} };
          post('document');
          addEventListener('pagehide', () => post('document'));
          addEventListener('pageshow', event => { if (event.persisted) post('document'); });
          addEventListener('click', event => { if (event.isTrusted) post('click'); }, true);
        })();
        """
    }
    private static func exportScript(origin: URL) -> String {
        """
        (() => {
          if (window !== top || location.origin !== \(encodedOrigin(origin))) return;
          const blobs = new Map();
          const create = URL.createObjectURL.bind(URL), revoke = URL.revokeObjectURL.bind(URL);
          URL.createObjectURL = value => {
            const url = create(value);
            if (value instanceof Blob && value.size <= \(WebExportPayload.maximumBytes) && blobs.size < 32) blobs.set(url, value);
            return url;
          };
          URL.revokeObjectURL = url => { blobs.delete(String(url)); return revoke(url); };
          const report = status => dispatchEvent(new CustomEvent('zashdock-export-result', {detail: status}));
          const exportAnchor = anchor => {
            if (!anchor.hasAttribute('download') || !anchor.href.startsWith('blob:' + location.origin + '/')) return false;
            const blob = blobs.get(anchor.href); // retain bytes before the official helper immediately revokes its URL
            if (!blob) { report('rejected'); return true; }
            const filename = anchor.download || 'zashboard-export';
            (async () => {
              const bytes = new Uint8Array(await blob.arrayBuffer());
              let binary = '';
              for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
              const result = await window.webkit.messageHandlers.zashdockExport.postMessage({schema:1,filename,mime:blob.type || 'application/octet-stream',base64:btoa(binary)});
              report(result.status);
            })().catch(() => report('failed'));
            return true;
          };
          const click = HTMLAnchorElement.prototype.click;
          HTMLAnchorElement.prototype.click = function() { if (!exportAnchor(this)) return click.call(this); };
          addEventListener('click', event => {
            const anchor = event.target instanceof Element ? event.target.closest('a[download]') : null;
            if (anchor && exportAnchor(anchor)) event.preventDefault();
          }, true);
        })();
        """
    }
}
