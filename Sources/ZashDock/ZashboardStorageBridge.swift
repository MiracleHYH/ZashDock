import Foundation
import WebKit
import ZashDockCore

@MainActor
private final class StorageMessageReceiver: NSObject, WKScriptMessageHandler {
    weak var bridge: ZashboardStorageBridge?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        bridge?.receive(message)
    }
}

/// The page has only a bounded data channel. It cannot choose native paths or invoke native actions.
@MainActor
final class ZashboardStorageBridge {
    let controller: WKUserContentController
    let origin: URL
    private(set) var lastError: String?
    var onPersistenceError: (@MainActor (String) -> Void)?
    private let vault: StorageSnapshotVault
    private let seed: [String: String]?
    private let token = UUID().uuidString
    private let stateName = "__zashdockStorageSnapshot"
    private let messageName = "zashdockStorage"
    private var automaticallyPersists: Bool
    private var latestSnapshot: [String: String]?
    private var latestSequence: Int64 = -1
    private var restoredAtDocumentStart = false
    private var persistenceTail: Task<Void, Never>?
    private var lastQueuedSnapshot: [String: String]?
    private var lastPersistedSnapshot: [String: String]?
    private var persistenceFailure: StorageSnapshotError?

    init(origin: URL, vault: StorageSnapshotVault, snapshot: [String: String]?, automaticallyPersists: Bool = true) throws {
        guard origin.scheme == "http", origin.host == "127.0.0.1", let port = origin.port,
              (1024...65535).contains(port), origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, ["", "/"].contains(origin.path) else {
            throw ZashDockError.storage("存储桥接只允许本机静态服务的有效 Origin。")
        }
        if let snapshot { try StorageSnapshotLimits.validate(snapshot) }
        self.origin = origin
        self.vault = vault
        self.seed = snapshot
        self.automaticallyPersists = automaticallyPersists
        self.controller = WKUserContentController()
        let receiver = StorageMessageReceiver()
        receiver.bridge = self
        controller.add(receiver, contentWorld: .page, name: messageName)
        let configuration: [String: Any] = [
            "origin": "http://127.0.0.1:\(port)", "token": token,
            "seed": snapshot.map { $0 as Any } ?? NSNull(), "stateName": stateName,
            "messageName": messageName, "maxBytes": StorageSnapshotLimits.maximumPayloadBytes,
            "maxKeys": StorageSnapshotLimits.maximumKeyCount,
            "maxKeyBytes": StorageSnapshotLimits.maximumKeyBytes,
            "maxValueBytes": StorageSnapshotLimits.maximumValueBytes
        ]
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: data, encoding: .utf8) else { throw StorageSnapshotError.invalidPayload }
        // Parse encoded JSON text, rather than an object literal: a LocalStorage key named __proto__ is data.
        let encodedText = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
        let source = Self.script.replacingOccurrences(of: "/*ZASHDOCK_CONFIGURATION*/null", with: encodedText)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    func enableAutomaticPersistence() { automaticallyPersists = true }
    func disableAutomaticPersistence() { automaticallyPersists = false }

    /// Reads the acknowledgement captured before page scripts ran, not the potentially changed current store.
    func verifyRestore(_ page: WebPage) async throws {
        let value = try await page.callJavaScript(
            "const state = window[stateName]; return state && state.token === token ? state.initialAcknowledgement : null;",
            arguments: ["stateName": stateName, "token": token], contentWorld: .page
        )
        let envelope = try decode(value)
        guard envelope.kind == "restoreAck", envelope.sequence == 0,
              seed == nil || envelope.snapshot == seed else {
            throw ZashDockError.storage("未能验证 Zashboard 初始化前的存储恢复；原配置未被提交。")
        }
        restoredAtDocumentStart = true
        accept(envelope)
    }

    /// Always captures current data, waits for earlier queued saves, then durably saves the newest accepted revision.
    @discardableResult
    func flush(_ page: WebPage) async throws -> [String: String] {
        try await verifyRestore(page)
        await persistenceTail?.value
        let value = try await page.callJavaScript(
            "const state = window[stateName]; return state && state.token === token ? state.capture() : null;",
            arguments: ["stateName": stateName, "token": token], contentWorld: .page
        )
        let envelope = try decode(value)
        guard envelope.kind == "snapshot" else { throw StorageSnapshotError.invalidPayload }
        accept(envelope)
        guard let snapshot = latestSnapshot else { throw StorageSnapshotError.invalidPayload }
        // Explicit flush is permitted for a candidate only after it is enabled, preventing accidental migration commits.
        guard automaticallyPersists else { return snapshot }
        while true {
            try Task.checkCancellation()
            // A newer message can arrive during each disk write. Drain it before reporting durable success.
            guard let newest = latestSnapshot else { throw StorageSnapshotError.invalidPayload }
            enqueue(newest, force: true)
            await persistenceTail?.value
            if let persistenceFailure { throw persistenceFailure }
            if lastPersistedSnapshot == latestSnapshot { return latestSnapshot ?? snapshot }
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        let frame = message.frameInfo
        let securityOrigin = frame.securityOrigin
        guard message.name == messageName, message.world == .page, frame.isMainFrame,
              securityOrigin.protocol == "http", securityOrigin.host == "127.0.0.1",
              securityOrigin.port == origin.port else { return }
        do {
            let envelope = try decode(message.body)
            if envelope.kind == "restoreAck" {
                guard envelope.sequence == 0, seed == nil || envelope.snapshot == seed else { throw StorageSnapshotError.invalidPayload }
                restoredAtDocumentStart = true
            }
            guard restoredAtDocumentStart else { throw StorageSnapshotError.invalidPayload }
            accept(envelope)
        } catch { report(error) }
    }

    private struct Envelope {
        let kind: String
        let sequence: Int64
        let snapshot: [String: String]
    }

    private func decode(_ value: Any?) throws -> Envelope {
        guard let body = value as? [String: Any],
              Set(body.keys) == Set(["schema", "token", "kind", "sequence", "snapshot"]),
              body["token"] as? String == token,
              let schema = body["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              let kind = body["kind"] as? String,
              let revision = body["sequence"] as? NSNumber, CFGetTypeID(revision) != CFBooleanGetTypeID(),
              revision.doubleValue >= 0, revision.doubleValue <= 9_007_199_254_740_991,
              revision.doubleValue.rounded(.towardZero) == revision.doubleValue,
              let snapshot = body["snapshot"] as? [String: String] else { throw StorageSnapshotError.invalidPayload }
        try StorageSnapshotLimits.validate(snapshot)
        guard JSONSerialization.isValidJSONObject(body),
              try JSONSerialization.data(withJSONObject: body).count <= StorageSnapshotLimits.maximumPayloadBytes else {
            throw StorageSnapshotError.payloadTooLarge
        }
        if kind == "limitExceeded" { throw StorageSnapshotError.payloadTooLarge }
        guard kind == "restoreAck" || kind == "snapshot" else { throw StorageSnapshotError.invalidPayload }
        return Envelope(kind: kind, sequence: revision.int64Value, snapshot: snapshot)
    }

    private func accept(_ envelope: Envelope) {
        guard envelope.sequence >= latestSequence else { return }
        latestSequence = envelope.sequence
        latestSnapshot = envelope.snapshot
        if automaticallyPersists { enqueue(envelope.snapshot) }
    }

    private func enqueue(_ snapshot: [String: String], force: Bool = false) {
        guard force || snapshot != lastQueuedSnapshot else { return }
        lastQueuedSnapshot = snapshot
        let previous = persistenceTail
        let vault = vault
        persistenceTail = Task { [weak self] in
            await previous?.value
            do {
                let recovery = try await vault.saveReportingRecovery(snapshot)
                self?.lastPersistedSnapshot = snapshot
                self?.persistenceFailure = nil
                self?.lastError = recovery?.explanation
                if let recovery { self?.onPersistenceError?(recovery.explanation) }
            } catch {
                self?.persistenceFailure = error as? StorageSnapshotError ?? .fileIO
                self?.report(error)
            }
        }
    }

    private func report(_ error: any Error) {
        // Never include a JavaScript body, key, value, backend URL or Secret in the error.
        let description = (error as? StorageSnapshotError)?.errorDescription ?? "网页存储同步失败，已有加密快照未被清除。"
        lastError = description
        onPersistenceError?(description)
    }

    private static let script = #"""
    (() => {
        "use strict";
        const configuration = JSON.parse(/*ZASHDOCK_CONFIGURATION*/null);
        if (window !== window.top || location.origin !== configuration.origin) return;
        const encoder = new TextEncoder();
        let sequence = 0;
        let lastSerialized = null;
        const state = { token: configuration.token, initialAcknowledgement: null, capture: null };
        Object.defineProperty(window, configuration.stateName, { value: state, configurable: false, writable: false });
        const read = () => {
            if (localStorage.length > configuration.maxKeys) throw new RangeError("storage limit");
            const values = Object.create(null);
            let bytes = 0;
            const keys = [];
            for (let index = 0; index < localStorage.length; index++) keys.push(localStorage.key(index));
            keys.sort();
            for (const key of keys) {
                const value = localStorage.getItem(key);
                if (typeof key !== "string" || typeof value !== "string") throw new TypeError("storage format");
                const keyBytes = encoder.encode(key).length, valueBytes = encoder.encode(value).length;
                bytes += keyBytes + valueBytes;
                if (keyBytes > configuration.maxKeyBytes || valueBytes > configuration.maxValueBytes || bytes > configuration.maxBytes) throw new RangeError("storage limit");
                values[key] = value;
            }
            return values;
        };
        const envelope = (kind, snapshot, revision) => ({ schema: 1, token: configuration.token, kind, sequence: revision, snapshot });
        const failure = kind => {
            try { window.webkit.messageHandlers[configuration.messageName].postMessage(envelope(kind, {}, ++sequence)); } catch (_) {}
        };
        const bounded = value => {
            if (encoder.encode(JSON.stringify(value)).length > configuration.maxBytes) throw new RangeError("storage limit");
            return value;
        };
        const capture = () => bounded(envelope("snapshot", read(), ++sequence));
        state.capture = capture;
        const publish = () => {
            try {
                const snapshot = read(), serialized = JSON.stringify(snapshot);
                if (serialized === lastSerialized) return;
                const message = bounded(envelope("snapshot", snapshot, ++sequence));
                lastSerialized = serialized;
                window.webkit.messageHandlers[configuration.messageName].postMessage(message);
            } catch (error) { failure(error instanceof RangeError ? "limitExceeded" : "captureFailed"); }
        };
        try {
            if (configuration.seed !== null) {
                localStorage.clear();
                for (const [key, value] of Object.entries(configuration.seed)) localStorage.setItem(key, value);
            }
            const snapshot = read();
            lastSerialized = JSON.stringify(snapshot);
            state.initialAcknowledgement = bounded(envelope("restoreAck", snapshot, 0));
            Object.freeze(snapshot);
            Object.freeze(state.initialAcknowledgement);
            window.webkit.messageHandlers[configuration.messageName].postMessage(state.initialAcknowledgement);
        } catch (error) {
            failure(error instanceof RangeError ? "limitExceeded" : "restoreFailed");
            return;
        }
        for (const method of ["setItem", "removeItem", "clear"]) {
            const original = Storage.prototype[method];
            Storage.prototype[method] = function (...arguments_) {
                const result = Reflect.apply(original, this, arguments_);
                if (this === localStorage) publish();
                return result;
            };
        }
        window.addEventListener("storage", publish);
        window.addEventListener("pagehide", publish);
        window.setInterval(publish, 250);
    })();
    """#
}
