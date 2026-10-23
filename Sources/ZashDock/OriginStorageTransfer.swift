import Foundation
import WebKit

/// Transient transfer data. Empty and absent business databases have the same data semantics.
/// This value is never persisted by the wrapper; WebKit remains the everyday source of truth.
struct OriginStoragePayload: Codable, Equatable, Sendable {
    let localStorage: [String: String]
    let databases: [String: [String: String]]
    static let databaseNames = ["base64", "connection-history"]

    init(localStorage: [String: String], databases: [String: [String: String]] = [:]) {
        self.localStorage = localStorage
        var canonical = databases
        for name in Self.databaseNames where canonical[name] == nil { canonical[name] = [:] }
        self.databases = canonical
    }
    private enum CodingKeys: String, CodingKey { case localStorage, databases }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(localStorage: try values.decode([String: String].self, forKey: .localStorage),
                  databases: try values.decode([String: [String: String]].self, forKey: .databases))
    }
}

enum OriginStorageTransferError: LocalizedError, Equatable {
    case invalidOrigin, unsupportedSchema, invalidPayload, quotaExceeded, verificationFailed, busy, timedOut, storageUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidOrigin: "存储迁移仅允许有效的 127.0.0.1 本地 Origin。"
        case .unsupportedSchema: "网页存储结构不受当前版本支持，原数据已保留。"
        case .invalidPayload: "网页存储迁移数据格式无效。"
        case .quotaExceeded: "网页存储超过迁移限额，原数据已保留。"
        case .verificationFailed: "目标 Origin 的存储验证失败。"
        case .busy: "另一项网页存储操作正在进行。"
        case .timedOut: "网页存储操作超时，请关闭其他面板后重试。"
        case .storageUnavailable: "暂时无法访问 WebKit 网页存储，请重试。"
        }
    }
}

@MainActor
private final class BootstrapNavigationPolicy: WebPage.NavigationDeciding {
    let url: URL
    private var initialNavigation = true
    init(url: URL) { self.url = url }
    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        // The single initial request is fulfilled by load(simulatedRequest:), not an HTTP listener.
        // No subsequent main-frame navigation, subframe or download is permitted.
        guard initialNavigation, action.request.url == url, action.target?.isMainFrame != false else { return .cancel }
        initialNavigation = false
        return .allow
    }
}

/// Performs one bounded transfer using a trusted, empty simulated document at the exact Origin.
/// Only the two official v3.29.1 business databases are supported. Source data is never changed
/// by read/restore/verify. The caller invokes clear only after a verified configuration commit.
@MainActor
final class OriginStorageTransfer {
    struct Limits: Equatable, Sendable {
        let localStorageBytes: Int
        let databaseBytes: Int
        let totalBytes: Int
        let localStorageEntries: Int
        let databaseRecords: Int
        let keyBytes: Int
        let stringBytes: Int
        init(localStorageBytes: Int = 8 * 1_024 * 1_024, databaseBytes: Int = 32 * 1_024 * 1_024,
             totalBytes: Int = 64 * 1_024 * 1_024, localStorageEntries: Int = 8_192,
             databaseRecords: Int = 32_768, keyBytes: Int = 64 * 1_024, stringBytes: Int = 32 * 1_024 * 1_024) {
            self.localStorageBytes = localStorageBytes; self.databaseBytes = databaseBytes; self.totalBytes = totalBytes
            self.localStorageEntries = localStorageEntries; self.databaseRecords = databaseRecords
            self.keyBytes = keyBytes; self.stringBytes = stringBytes
        }
        fileprivate var dictionary: [String: Int] {
            ["localStorageBytes": localStorageBytes, "databaseBytes": databaseBytes, "totalBytes": totalBytes,
             "localStorageEntries": localStorageEntries, "databaseRecords": databaseRecords, "keyBytes": keyBytes, "stringBytes": stringBytes]
        }
        fileprivate var valid: Bool { dictionary.values.allSatisfy { $0 > 0 && $0 <= 256 * 1_024 * 1_024 } }
    }
    @MainActor
    private final class Operation {
        let page: WebPage
        let url: URL
        var timedOut = false
        var finished = false
        init(page: WebPage, url: URL) { self.page = page; self.url = url }
        func interrupt() async {
            guard !finished else { return }
            page.stopLoading()
            // Resolves the pending operation, aborts transactions and closes every owned connection.
            _ = try? await page.callJavaScript("globalThis.__zashdockOriginTransferAbort?.();")
            guard !finished else { return }
            do {
                for try await _ in page.load(simulatedRequest: URLRequest(url: url), responseHTML: OriginStorageTransfer.bootstrapHTML) {}
            } catch { page.stopLoading() }
        }
    }
    private let dataStore: WKWebsiteDataStore
    private let limits: Limits
    private let timeout: Duration
    private var active: Operation?
    init(dataStore: WKWebsiteDataStore = .default(), limits: Limits = .init(), timeout: Duration = .seconds(20)) {
        self.dataStore = dataStore; self.limits = limits
        self.timeout = min(max(timeout, .milliseconds(1)), .seconds(120))
    }
    func read(origin: URL) async throws -> OriginStoragePayload {
        guard let result = try await perform("read", origin: origin) else { throw OriginStorageTransferError.storageUnavailable }
        return result
    }
    func restore(_ payload: OriginStoragePayload, to origin: URL) async throws {
        try validate(payload)
        _ = try await perform("restore", origin: origin, payload: payload)
    }
    func verify(_ payload: OriginStoragePayload, at origin: URL) async throws {
        try validate(payload)
        guard try await read(origin: origin) == payload else { throw OriginStorageTransferError.verificationFailed }
    }
    func clear(origin: URL) async throws { _ = try await perform("clear", origin: origin) }
    private func validatedOrigin(_ origin: URL) throws -> URL {
        guard origin.scheme == "http", origin.host == "127.0.0.1", let port = origin.port, (1_024...65_535).contains(port),
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/",
              let canonical = URL(string: "http://127.0.0.1:\(port)") else { throw OriginStorageTransferError.invalidOrigin }
        return canonical
    }
    private func validate(_ payload: OriginStoragePayload) throws {
        guard limits.valid else { throw OriginStorageTransferError.invalidPayload }
        guard Set(payload.databases.keys) == Set(OriginStoragePayload.databaseNames) else { throw OriginStorageTransferError.unsupportedSchema }
        guard payload.localStorage.count <= limits.localStorageEntries else { throw OriginStorageTransferError.quotaExceeded }
        var total = 64
        func bytes(_ text: String, key: Bool) throws -> (Int, Int) {
            let count = text.utf8.count
            guard count <= (key ? limits.keyBytes : limits.stringBytes) else { throw OriginStorageTransferError.quotaExceeded }
            var encoded = count
            for scalar in text.unicodeScalars {
                if scalar.value < 32 { encoded += 5 }
                else if scalar.value == 34 || scalar.value == 92 { encoded += 1 }
            }
            return (count, encoded)
        }
        func check(_ values: [String: String], maximum: Int) throws {
            var subtotal = 0
            for (key, value) in values {
                let left = try bytes(key, key: true), right = try bytes(value, key: false)
                subtotal += left.0 + right.0
                total += left.1 + right.1 + 16
                guard subtotal <= maximum, total <= limits.totalBytes else { throw OriginStorageTransferError.quotaExceeded }
            }
        }
        try check(payload.localStorage, maximum: limits.localStorageBytes)
        for name in OriginStoragePayload.databaseNames {
            let records = payload.databases[name]!
            guard records.count <= limits.databaseRecords else { throw OriginStorageTransferError.quotaExceeded }
            total += 64
            guard total <= limits.totalBytes else { throw OriginStorageTransferError.quotaExceeded }
            try check(records, maximum: limits.databaseBytes)
        }
    }
    private func perform(_ kind: String, origin: URL, payload: OriginStoragePayload? = nil) async throws -> OriginStoragePayload? {
        try Task.checkCancellation()
        let origin = try validatedOrigin(origin)
        guard limits.valid else { throw OriginStorageTransferError.invalidPayload }
        guard active == nil else { throw OriginStorageTransferError.busy }
        let url = origin.appendingPathComponent("__zashdock_origin_transfer")
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        configuration.defaultNavigationPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        configuration.deviceSensorAuthorization = .init(decision: .deny)
        let operation = Operation(page: WebPage(configuration: configuration, navigationDecider: BootstrapNavigationPolicy(url: url)), url: url)
        active = operation
        let expected = "http://127.0.0.1:\(origin.port!)"
        let components = timeout.components
        let milliseconds = max(1, Int(Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15))
        let task = Task { @MainActor in
            for try await _ in operation.page.load(simulatedRequest: URLRequest(url: url), responseHTML: Self.bootstrapHTML) { try Task.checkCancellation() }
            try Task.checkCancellation()
            var arguments: [String: Any] = ["operation": kind, "expectedOrigin": expected, "limits": limits.dictionary, "timeoutMilliseconds": milliseconds]
            if let payload {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                let bytes = try encoder.encode(payload)
                guard bytes.count <= limits.totalBytes else { throw OriginStorageTransferError.quotaExceeded }
                // A JSON string preserves arbitrary keys such as __proto__ across WebKit's argument bridge.
                arguments["payloadJSON"] = String(decoding: bytes, as: UTF8.self)
            } else { arguments["payloadJSON"] = NSNull() }
            let value = try await operation.page.callJavaScript(Self.script, arguments: arguments)
            try Task.checkCancellation()
            guard let string = value as? String else { throw OriginStorageTransferError.storageUnavailable }
            return string
        }
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled, !operation.finished else { return }
            operation.timedOut = true
            task.cancel()
            await operation.interrupt()
        }
        defer { operation.finished = true; timer.cancel(); operation.page.stopLoading(); active = nil }
        do {
            let text = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { @MainActor in await operation.interrupt() }
            }
            try Task.checkCancellation()
            if operation.timedOut { throw OriginStorageTransferError.timedOut }
            guard text.utf8.count <= limits.totalBytes * 2,
                  let response = try? JSONDecoder().decode(Response.self, from: Data(text.utf8)) else { throw OriginStorageTransferError.invalidPayload }
            if response.status == "ok" {
                if let result = response.payload { try validate(result) }
                return response.payload
            }
            switch response.code {
            case "schema": throw OriginStorageTransferError.unsupportedSchema
            case "quota": throw OriginStorageTransferError.quotaExceeded
            case "payload": throw OriginStorageTransferError.invalidPayload
            case "timeout": throw OriginStorageTransferError.timedOut
            case "busy": throw OriginStorageTransferError.busy
            case "cancelled": throw CancellationError()
            default: throw OriginStorageTransferError.storageUnavailable
            }
        } catch {
            if operation.timedOut { throw OriginStorageTransferError.timedOut }
            if Task.isCancelled || task.isCancelled { throw CancellationError() }
            if let error = error as? OriginStorageTransferError { throw error }
            throw OriginStorageTransferError.storageUnavailable
        }
    }
    private struct Response: Decodable { let status: String; let code: String?; let payload: OriginStoragePayload? }
    private static let bootstrapHTML = """
        <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src 'none'; style-src 'none'; font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"></head><body></body></html>
        """
    private static let script = #"""
        const names = ['base64', 'connection-history'];
        const payload = payloadJSON === null ? null : JSON.parse(payloadJSON);
        const connections = new Set(), transactions = new Set();
        let stopped = false, deadline;
        const failure = code => { const error = new Error('Origin transfer failed'); error.transferCode = code; return error; };
        const check = () => { if (stopped) throw failure('cancelled'); };
        let rejectAbort;
        const aborted = new Promise((_, reject) => { rejectAbort = reject; });
        const abort = code => {
          if (stopped) return;
          stopped = true;
          for (const transaction of transactions) { try { transaction.abort(); } catch {} }
          for (const db of connections) db.close();
          rejectAbort(failure(code));
        };
        globalThis.__zashdockOriginTransferAbort = () => abort('cancelled');
        const encoder = new TextEncoder();
        const textSize = (text, key) => {
          if (typeof text !== 'string') throw failure('schema');
          const maximum = key ? limits.keyBytes : limits.stringBytes;
          if (text.length > maximum) throw failure('quota');
          const size = encoder.encode(text).byteLength;
          if (size > maximum) throw failure('quota');
          let encoded = size;
          for (let index = 0; index < text.length; index++) {
            const code = text.charCodeAt(index);
            if (code < 32) encoded += 5;
            else if (code === 34 || code === 92) encoded++;
          }
          return [size, encoded];
        };
        const validate = value => {
          if (!value || typeof value !== 'object' || Array.isArray(value) ||
              Object.keys(value).sort().join('|') !== 'databases|localStorage' ||
              !value.localStorage || !value.databases ||
              Object.keys(value.databases).sort().join('|') !== 'base64|connection-history') throw failure('payload');
          let total = 64;
          const pairs = (items, countLimit, byteLimit) => {
            if (!items || typeof items !== 'object' || Array.isArray(items)) throw failure('payload');
            const keys = Object.keys(items);
            if (keys.length > countLimit) throw failure('quota');
            // JavaScript keys distinguish canonical Unicode spellings; Swift String
            // dictionary keys do not. Refuse a lossy payload before it crosses that bridge.
            const normalizedKeys = new Set();
            let subtotal = 0;
            for (const key of keys) {
              const normalized = key.normalize('NFC');
              if (normalizedKeys.has(normalized)) throw failure('schema');
              normalizedKeys.add(normalized);
              const left = textSize(key, true), right = textSize(items[key], false);
              subtotal += left[0] + right[0]; total += left[1] + right[1] + 16;
              if (subtotal > byteLimit || total > limits.totalBytes) throw failure('quota');
            }
          };
          pairs(value.localStorage, limits.localStorageEntries, limits.localStorageBytes);
          for (const name of names) {
            total += 64;
            if (total > limits.totalBytes) throw failure('quota');
            pairs(value.databases[name], limits.databaseRecords, limits.databaseBytes);
          }
        };
        const list = async () => {
          check();
          if (typeof indexedDB.databases !== 'function') throw failure('schema');
          const all = await indexedDB.databases(); check();
          if (all.some(item => !names.includes(item.name) || item.version !== 1)) throw failure('schema');
          return new Set(all.map(item => item.name));
        };
        const open = (name, create) => new Promise((resolve, reject) => {
          check();
          const request = create ? indexedDB.open(name, 1) : indexedDB.open(name);
          request.onblocked = () => reject(failure('busy'));
          request.onupgradeneeded = event => {
            if (stopped || !create || event.oldVersion > 0) { request.transaction.abort(); return; }
            const transaction = request.transaction;
            transactions.add(transaction);
            transaction.addEventListener('complete', () => transactions.delete(transaction));
            transaction.addEventListener('abort', () => transactions.delete(transaction));
            request.result.createObjectStore(name, {keyPath:'key'});
          };
          request.onerror = () => reject(failure(stopped ? 'cancelled' : 'schema'));
          request.onsuccess = () => {
            const db = request.result;
            if (stopped) { db.close(); reject(failure('cancelled')); return; }
            if (db.version !== 1 || db.objectStoreNames.length !== 1 || !db.objectStoreNames.contains(name)) { db.close(); reject(failure('schema')); return; }
            connections.add(db);
            db.onversionchange = () => { db.close(); connections.delete(db); abort('busy'); };
            resolve(db);
          };
        });
        const transact = (db, name, mode, body) => new Promise((resolve, reject) => {
          check();
          let transaction;
          try { transaction = db.transaction(name, mode); } catch { reject(failure('schema')); return; }
          const store = transaction.objectStore(name);
          if (store.keyPath !== 'key' || store.autoIncrement || store.indexNames.length) { transaction.abort(); reject(failure('schema')); return; }
          transactions.add(transaction);
          transaction.oncomplete = () => { transactions.delete(transaction); try { check(); resolve(); } catch (error) { reject(error); } };
          transaction.onabort = transaction.onerror = () => { transactions.delete(transaction); reject(failure(stopped ? 'cancelled' : 'storage')); };
          try { body(store, transaction, reject); } catch (error) { try { transaction.abort(); } catch {} reject(error); }
        });
        const readAll = async () => {
          const available = await list();
          const value = {localStorage:Object.create(null),databases:Object.create(null)};
          if (localStorage.length > limits.localStorageEntries) throw failure('quota');
          let localBytes = 0;
          for (let index = 0; index < localStorage.length; index++) {
            check(); const key = localStorage.key(index), item = localStorage.getItem(key);
            if (typeof key !== 'string' || typeof item !== 'string') throw failure('busy');
            localBytes += textSize(key,true)[0] + textSize(item,false)[0];
            if (localBytes > limits.localStorageBytes) throw failure('quota');
            value.localStorage[key] = item;
          }
          for (const name of names) {
            const records = Object.create(null); value.databases[name] = records;
            if (!available.has(name)) continue;
            const db = await open(name, false);
            let bytes = 0, count = 0;
            await transact(db, name, 'readonly', (store, transaction, reject) => {
              const cursor = store.openCursor();
              cursor.onerror = () => { try { transaction.abort(); } catch {} reject(failure('storage')); };
              cursor.onsuccess = () => {
                try {
                  check(); const current = cursor.result; if (!current) return;
                  const item = current.value;
                  if (!item || typeof item !== 'object' || Array.isArray(item) ||
                      Object.keys(item).sort().join('|') !== 'key|value' || typeof item.key !== 'string' ||
                      typeof item.value !== 'string' || current.primaryKey !== item.key) throw failure('schema');
                  bytes += textSize(item.key,true)[0] + textSize(item.value,false)[0];
                  if (++count > limits.databaseRecords || bytes > limits.databaseBytes) throw failure('quota');
                  records[item.key] = item.value; current.continue();
                } catch (error) { try { transaction.abort(); } catch {} reject(error); }
              };
            });
            db.close(); connections.delete(db);
          }
          validate(value); return value;
        };
        const replace = async value => {
          validate(value);
          // Validate all pre-existing target schemas/records before the first mutation.
          await readAll(); check();
          let available = await list();
          for (const name of names) {
            const records = value.databases[name], keys = Object.keys(records);
            // Do not create absent empty databases, and never issue an uncancellable deleteDatabase request.
            if (!available.has(name) && keys.length === 0) continue;
            const db = await open(name, !available.has(name));
            await transact(db, name, 'readwrite', store => {
              store.clear();
              for (const key of keys) store.put({key,value:records[key]});
            });
            db.close(); connections.delete(db);
          }
          check(); localStorage.clear();
          for (const key of Object.keys(value.localStorage)) localStorage.setItem(key, value.localStorage[key]);
        };
        const work = async () => {
          if (location.origin !== expectedOrigin || window !== top) throw failure('payload');
          if (operation === 'read') return {status:'ok',payload:await readAll()};
          if (operation === 'restore') { await replace(payload); return {status:'ok'}; }
          if (operation === 'clear') {
            await replace({localStorage:Object.create(null),databases:{base64:{},'connection-history':{}}});
            return {status:'ok'};
          }
          throw failure('payload');
        };
        deadline = setTimeout(() => abort('timeout'), timeoutMilliseconds);
        try { return JSON.stringify(await Promise.race([work(),aborted])); }
        catch (error) { return JSON.stringify({status:'error',code:error.transferCode || 'storage'}); }
        finally {
          clearTimeout(deadline); stopped = true;
          for (const transaction of transactions) { try { transaction.abort(); } catch {} }
          for (const db of connections) db.close();
          delete globalThis.__zashdockOriginTransferAbort;
        }
        """#
}
