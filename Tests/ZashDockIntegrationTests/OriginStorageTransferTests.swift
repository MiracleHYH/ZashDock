import AppKit
import Darwin
import Foundation
import Testing
import WebKit
@testable import ZashDock
import ZashDockCore

private final class TransferOccupiedOriginSentinel: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var count = 0
    var connectionCount: Int { lock.withLock { count } }
    init(port: UInt16) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(descriptor, 8) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
            Darwin.close(descriptor); throw POSIXError(code)
        }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "app.zashdock.test.transfer-sentinel"))
        source.setEventHandler { [weak self] in
            while true {
                let client = Darwin.accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                if let self { self.lock.withLock { self.count += 1 } }
                Darwin.close(client)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }
    func stop() { source.cancel() }
    deinit { source.cancel() }
}

@Suite(.serialized)
@MainActor
struct OriginStorageTransferTests {
    private var fixture: OriginStoragePayload {
        OriginStoragePayload(localStorage: [
            "setup/api-list": #"[{"uuid":"lan-fixture","type":"clash","protocol":"http","host":"10.0.0.2","port":"9090","password":"fictional-one"},{"uuid":"vpn-fixture","type":"clash","protocol":"http","host":"vpn.example","port":"9090","password":"fictional-two"}]"#,
            "setup/active-uuid": "vpn-fixture", "config/default-theme": "light", "__proto__": "arbitrary key",
            "quoted\"key": "\" </script> \\ \u{2028} \u{2029} 中文", "": "empty key"
        ], databases: ["base64": ["background-image": "data:image/png;base64,ZmFrZS1maXh0dXJl", "__proto__": "preserve"],
                       "connection-history": ["lan-fixture-sourceIP": #"[{"key":"10.0.0.1","download":42,"upload":7,"count":1}]"#]])
    }
    private func directory() throws -> URL {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZashDockTransfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html><body><div id='app'>isolated storage transfer fixture</div></body></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        return root
    }
    private func page(store: WKWebsiteDataStore) -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = store
        configuration.defaultNavigationPreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        return WebPage(configuration: configuration)
    }
    private func load(_ page: WebPage, _ origin: URL) async throws {
        for try await _ in page.load(URLRequest(url: origin)) {}
    }
    private func seed(_ value: OriginStoragePayload, page: WebPage) async throws {
        try await page.callJavaScript(#"""
        const snapshot = JSON.parse(snapshotJSON);
        localStorage.clear();
        for (const [key,value] of Object.entries(snapshot.localStorage)) localStorage.setItem(key,value);
        for (const name of ['base64','connection-history']) {
          const db = await new Promise((resolve,reject) => {
            const request = indexedDB.open(name,1);
            request.onupgradeneeded = () => request.result.createObjectStore(name,{keyPath:'key'});
            request.onsuccess = () => resolve(request.result); request.onerror = () => reject(new Error('fixture database open'));
          });
          await new Promise((resolve,reject) => {
            const transaction = db.transaction(name,'readwrite'),store = transaction.objectStore(name);
            store.clear(); for (const [key,value] of Object.entries(snapshot.databases[name])) store.put({key,value});
            transaction.oncomplete = resolve;transaction.onabort = transaction.onerror = () => reject(new Error('fixture database write'));
          }); db.close();
        }
        return true;
        """#, arguments: ["snapshotJSON": String(decoding: try JSONEncoder().encode(value), as: UTF8.self)])
    }

    private func seedGeoIPCaches(page: WebPage, geoIPVersion: Int = 2, earthVersion: Int = 1) async throws {
        try await page.callJavaScript(#"""
        for (const [name,version] of [['zashboard-geoip',geoIPVersion],['zashboard-earth-geoip',earthVersion]]) {
          const db = await new Promise((resolve,reject) => {
            const request=indexedDB.open(name,version);
            request.onupgradeneeded=()=>{
              if(name==='zashboard-geoip') {
                request.result.createObjectStore('manifests');request.result.createObjectStore('chunks');
              } else request.result.createObjectStore('city-database');
            };
            request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(new Error('GeoIP fixture open '+name+': '+request.error?.name));
          });
          await new Promise((resolve,reject)=>{
            const transaction=db.transaction([...db.objectStoreNames],'readwrite');
            const bytes=new Uint8Array([0,17,128,254,255]);
            if(name==='zashboard-geoip') {
              transaction.objectStore('manifests').put({chunkCount:1,chunkSize:262144,generation:'fixture',size:bytes.length,updatedAt:12345},'https://fixture.example/country.mmdb');
              transaction.objectStore('chunks').put(bytes.buffer,['https://fixture.example/country.mmdb','fixture',0]);
            } else transaction.objectStore('city-database').put({blob:new Blob([bytes],{type:'application/octet-stream'}),storedAt:67890},'city');
            transaction.oncomplete=resolve;transaction.onabort=transaction.onerror=event=>reject(new Error('GeoIP fixture write '+name+': '+(event.target.error?.name||transaction.error?.name||event.type)));
          });db.close();
        }return true;
        """#, arguments: ["geoIPVersion": geoIPVersion, "earthVersion": earthVersion])
    }

    private func withPersistentCacheStore(_ body: (WKWebsiteDataStore) async throws -> Void) async throws {
        // GeoIP includes disk-backed Blob records. Use the same persistence mode as the app,
        // with an isolated identifier so no production profile can be read or cleared.
        let identifier = UUID()
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        do {
            try await body(store)
        } catch {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
            throw error
        }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }

    private func geoIPCacheSnapshot(page: WebPage) async throws -> String {
        try #require(try await page.callJavaScript(#"""
        const normalize=async value=>{
          if(value instanceof ArrayBuffer)return {type:'ArrayBuffer',bytes:[...new Uint8Array(value)]};
          if(value instanceof Blob)return {type:'Blob',mime:value.type,bytes:[...new Uint8Array(await value.arrayBuffer())]};
          if(value&&typeof value==='object') {
            const result={};for(const key of Object.keys(value))result[key]=await normalize(value[key]);return result;
          }return value;
        };
        const result=[];
        for(const name of ['zashboard-geoip','zashboard-earth-geoip']) {
          const metadata=(await indexedDB.databases()).find(item=>item.name===name);
          if(!metadata)continue;
          const db=await new Promise((resolve,reject)=>{const request=indexedDB.open(name);request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);});
          const stores=[];
          for(const storeName of [...db.objectStoreNames]) {
            const [keys,values]=await new Promise((resolve,reject)=>{
              const transaction=db.transaction(storeName,'readonly'),store=transaction.objectStore(storeName);
              const keys=store.getAllKeys(),values=store.getAll();
              transaction.oncomplete=()=>resolve([keys.result,values.result]);transaction.onabort=transaction.onerror=()=>reject(transaction.error);
            });
            stores.push([storeName,keys,await Promise.all(values.map(normalize))]);
          }db.close();result.push({name,version:metadata.version,stores});
        }return JSON.stringify(result);
        """#) as? String)
    }

    @Test(.timeLimit(.minutes(1)))
    func verifiedGeoIPCachesStayAtSourceWhileBusinessDataMigratesAndClears() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await bindFixture(root); defer { source.stop() }
        let target = try await bindFixture(root); defer { target.stop() }
        try await withPersistentCacheStore { store in
            let sourcePage = page(store: store); defer { sourcePage.stopLoading() }
            let targetPage = page(store: store); defer { targetPage.stopLoading() }
            try await load(sourcePage, source.baseURL)
            try await seed(fixture, page: sourcePage)
            try await seedGeoIPCaches(page: sourcePage)
            let caches = try await geoIPCacheSnapshot(page: sourcePage)
            #expect(caches.contains("ArrayBuffer") && caches.contains("Blob"))
            let transfer = OriginStorageTransfer(dataStore: store)
            let captured = try await transfer.read(origin: source.baseURL)
            #expect(captured == fixture)
            try await transfer.restore(captured, to: target.baseURL)
            try await transfer.verify(captured, at: source.baseURL)
            try await transfer.verify(captured, at: target.baseURL)
            try await load(targetPage, target.baseURL)
            #expect(try await geoIPCacheSnapshot(page: targetPage) == "[]")
            try await transfer.clear(origin: source.baseURL)
            #expect(try await transfer.read(origin: source.baseURL) == OriginStoragePayload(localStorage: [:]))
            #expect(try await geoIPCacheSnapshot(page: sourcePage) == caches)
            try await transfer.verify(captured, at: target.baseURL)

            // An existing target cache is also outside the business payload and survives replacement.
            try await seedGeoIPCaches(page: targetPage)
            let targetCaches = try await geoIPCacheSnapshot(page: targetPage)
            try await transfer.restore(captured, to: target.baseURL)
            try await transfer.verify(captured, at: target.baseURL)
            #expect(try await geoIPCacheSnapshot(page: targetPage) == targetCaches)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [(1, 1), (3, 1), (2, 2)])
    func unverifiedGeoIPVersionsRejectBeforeChangingBusinessOrCache(versions: (Int, Int)) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root); defer { server.stop() }
        try await withPersistentCacheStore { store in
            let page = page(store: store); defer { page.stopLoading() }
            try await load(page, server.baseURL)
            try await seed(fixture, page: page)
            try await seedGeoIPCaches(page: page, geoIPVersion: versions.0, earthVersion: versions.1)
            let caches = try await geoIPCacheSnapshot(page: page)
            let transfer = OriginStorageTransfer(dataStore: store)
            await #expect(throws: OriginStorageTransferError.unsupportedSchema) { try await transfer.read(origin: server.baseURL) }
            await #expect(throws: OriginStorageTransferError.unsupportedSchema) { try await transfer.restore(OriginStoragePayload(localStorage: [:]), to: server.baseURL) }
            await #expect(throws: OriginStorageTransferError.unsupportedSchema) { try await transfer.verify(fixture, at: server.baseURL) }
            await #expect(throws: OriginStorageTransferError.unsupportedSchema) { try await transfer.clear(origin: server.baseURL) }
            #expect(try await page.callJavaScript("return localStorage.getItem('setup/api-list');") as? String == fixture.localStorage["setup/api-list"])
            #expect(try await geoIPCacheSnapshot(page: page) == caches)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func absentDatabasesRemainAbsentAndNonPersistentRoundTripReplacesTarget() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await bindFixture(root); defer { first.stop() }
        let second = try await bindFixture(root); defer { second.stop() }
        let store = WKWebsiteDataStore.nonPersistent()
        let page = page(store: store); defer { page.stopLoading() }
        try await load(page, first.baseURL)
        let transfer = OriginStorageTransfer(dataStore: store)
        #expect(try await transfer.read(origin: first.baseURL) == OriginStoragePayload(localStorage: [:]))
        #expect(try await page.callJavaScript("return (await indexedDB.databases()).length;") as? Int == 0)
        try await seed(fixture, page: page)
        #expect(try await transfer.read(origin: first.baseURL) == fixture)
        try await load(page, second.baseURL)
        try await seed(OriginStoragePayload(localStorage: ["old": "discard"], databases: ["base64": ["old-image": "discard"], "connection-history": ["old-history": "discard"]]), page: page)
        try await transfer.restore(fixture, to: second.baseURL)
        try await transfer.verify(fixture, at: second.baseURL)
        #expect(try await transfer.read(origin: second.baseURL) == fixture)
        #expect(try await transfer.read(origin: first.baseURL) == fixture)
        try await transfer.clear(origin: first.baseURL)
        #expect(try await transfer.read(origin: first.baseURL) == OriginStoragePayload(localStorage: [:]))
        #expect(try await transfer.read(origin: second.baseURL) == fixture)
    }

    @Test(.timeLimit(.minutes(1)))
    func persistentProfileReopensWithTwoRemotesAndBusinessDatabases() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root); defer { server.stop() }
        let identifier = UUID()
        var store: WKWebsiteDataStore? = WKWebsiteDataStore(forIdentifier: identifier)
        var firstPage: WebPage? = page(store: try #require(store))
        try await load(try #require(firstPage), server.baseURL)
        try await seed(fixture, page: try #require(firstPage))
        firstPage?.stopLoading(); firstPage = nil; store = nil
        let reopened = WKWebsiteDataStore(forIdentifier: identifier)
        let transfer = OriginStorageTransfer(dataStore: reopened)
        try await transfer.verify(fixture, at: server.baseURL)
        await reopened.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    @Test(.timeLimit(.minutes(1)))
    func occupiedOldPortReceivesNoConnectionsDuringReadRestoreVerifyAndClear() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root); defer { server.stop() }
        let old = server.baseURL
        let target = try await bindFixture(root); defer { target.stop() }
        let store = WKWebsiteDataStore.nonPersistent()
        var sourcePage: WebPage? = page(store: store)
        try await load(try #require(sourcePage), old)
        try await seed(fixture, page: try #require(sourcePage))
        sourcePage?.stopLoading(); sourcePage = nil; server.stop()
        let blocker = try TransferOccupiedOriginSentinel(port: UInt16(old.port!)); defer { blocker.stop() }
        let transfer = OriginStorageTransfer(dataStore: store)
        let captured = try await transfer.read(origin: old)
        #expect(captured == fixture)
        try await transfer.restore(captured, to: target.baseURL)
        try await transfer.verify(captured, at: target.baseURL)
        #expect(try await transfer.read(origin: old) == fixture)
        try await transfer.clear(origin: old)
        #expect(try await transfer.read(origin: old) == OriginStoragePayload(localStorage: [:]))
        try await transfer.verify(captured, at: target.baseURL)
        try await Task.sleep(for: .milliseconds(100))
        #expect(blocker.connectionCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func quotasRejectBeforeDeletingSourceOrExistingTarget() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await bindFixture(root); defer { source.stop() }
        let target = try await bindFixture(root); defer { target.stop() }
        let store = WKWebsiteDataStore.nonPersistent()
        let page = page(store: store); defer { page.stopLoading() }
        try await load(page, source.baseURL); try await seed(fixture, page: page)
        let old = OriginStoragePayload(localStorage: ["old": "keep"], databases: ["base64": ["background-image": "keep"]])
        try await load(page, target.baseURL); try await seed(old, page: page)
        let small = OriginStorageTransfer(dataStore: store, limits: .init(localStorageBytes: 16))
        await #expect(throws: OriginStorageTransferError.quotaExceeded) { try await small.read(origin: source.baseURL) }
        await #expect(throws: OriginStorageTransferError.quotaExceeded) { try await small.restore(fixture, to: target.baseURL) }
        let count = OriginStorageTransfer(dataStore: store, limits: .init(databaseRecords: 1))
        await #expect(throws: OriginStorageTransferError.quotaExceeded) { try await count.read(origin: source.baseURL) }
        let normal = OriginStorageTransfer(dataStore: store)
        try await normal.verify(fixture, at: source.baseURL); try await normal.verify(old, at: target.baseURL)
    }

    @Test(.timeLimit(.minutes(1)))
    func unsupportedSchemasRecordsAndUnknownDatabasesFailClosed() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for mode in ["version", "store", "keyPath", "autoIncrement", "index", "record", "unknown"] {
            let server = try await bindFixture(root); defer { server.stop() }
            let store = WKWebsiteDataStore.nonPersistent()
            let page = page(store: store); defer { page.stopLoading() }
            try await load(page, server.baseURL)
            let before = try await page.callJavaScript(#"""
            localStorage.setItem('keep','original');
            const name = mode === 'unknown' ? 'future-database' : 'base64';
            const db = await new Promise((resolve,reject) => {
              const request = indexedDB.open(name,mode === 'version' ? 2 : 1);
              request.onupgradeneeded = () => {
                const store = request.result.createObjectStore(mode === 'store' ? 'other' : name,{keyPath:mode === 'keyPath' ? 'other' : 'key',autoIncrement:mode === 'autoIncrement'});
                if (mode === 'index') store.createIndex('future-index','value');
                store.put(mode === 'record' ? {key:'item',value:{unsupported:true}} : {key:'item',other:'item',value:'original'});
              };
              request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(new Error('fixture create'));
            });
            const snapshot = JSON.stringify({version:db.version,stores:[...db.objectStoreNames]}); db.close(); return snapshot;
            """#, arguments: ["mode": mode]) as? String
            let transfer = OriginStorageTransfer(dataStore: store)
            await #expect(throws: OriginStorageTransferError.unsupportedSchema) { try await transfer.read(origin: server.baseURL) }
            await #expect(throws: OriginStorageTransferError.unsupportedSchema) { try await transfer.restore(fixture, to: server.baseURL) }
            await #expect(throws: OriginStorageTransferError.unsupportedSchema) { try await transfer.clear(origin: server.baseURL) }
            #expect(try await page.callJavaScript("return localStorage.getItem('keep');") as? String == "original")
            let after = try await page.callJavaScript(#"""
            const names = await indexedDB.databases(); const db = await new Promise(resolve => {const request=indexedDB.open(names[0].name);request.onsuccess=()=>resolve(request.result);});
            const snapshot=JSON.stringify({version:db.version,stores:[...db.objectStoreNames]});db.close();return snapshot;
            """#) as? String
            #expect(before == after)
        }
    }

    private func holdTransaction(in page: WebPage) async throws {
        try await page.callJavaScript(#"""
        window.holdDB = await new Promise(resolve => {const request=indexedDB.open('base64');request.onsuccess=()=>resolve(request.result);});
        window.keepLock = true;
        const transaction = holdDB.transaction('base64','readwrite'), store = transaction.objectStore('base64');
        window.lockDone = new Promise(resolve => {transaction.oncomplete=resolve;transaction.onabort=resolve;});
        window.lockReady = new Promise(resolve => {
          const repeat = () => { const request=store.get('background-image'); request.onsuccess=()=>{resolve();if(window.keepLock)repeat();}; };
          repeat();
        });
        await window.lockReady;return true;
        """#)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["localStorage", "base64"])
    func canonicallyEquivalentDistinctKeysFailClosedBeforeAnyMutation(location: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await bindFixture(root); defer { source.stop() }
        let other = try await bindFixture(root); defer { other.stop() }
        let store = WKWebsiteDataStore.nonPersistent()
        let page = page(store: store); defer { page.stopLoading() }
        let transfer = OriginStorageTransfer(dataStore: store)
        try await transfer.restore(fixture, to: other.baseURL)
        try await load(page, source.baseURL)
        try await seed(fixture, page: page)
        // Build the collision in JavaScript. A Swift dictionary cannot represent these two keys.
        try await page.callJavaScript(#"""
            if (target === 'localStorage') {
                localStorage.setItem('\u00e9', 'composed');
                localStorage.setItem('e\u0301', 'decomposed');
            } else {
                const db = await new Promise((resolve,reject) => {
                    const request=indexedDB.open(target);
                    request.onsuccess=()=>resolve(request.result);request.onerror=reject;
                });
                await new Promise((resolve,reject) => {
                    const transaction=db.transaction(target,'readwrite'), store=transaction.objectStore(target);
                    store.put({key:'\u00e9',value:'composed'});store.put({key:'e\u0301',value:'decomposed'});
                    transaction.oncomplete=resolve;transaction.onabort=transaction.onerror=reject;
                });db.close();
            }
            """#, arguments: ["target": location])
        let snapshot = #"""
            const result={localStorage:Object.keys(localStorage).sort().map(key=>[key,localStorage.getItem(key)]),databases:[]};
            for (const name of ['base64','connection-history']) {
                const db=await new Promise((resolve,reject)=>{const request=indexedDB.open(name);request.onsuccess=()=>resolve(request.result);request.onerror=reject;});
                const records=[];
                await new Promise((resolve,reject)=>{
                    const transaction=db.transaction(name,'readonly'),cursor=transaction.objectStore(name).openCursor();
                    cursor.onsuccess=()=>{if(cursor.result){records.push([cursor.result.value.key,cursor.result.value.value]);cursor.result.continue();}};
                    transaction.oncomplete=resolve;transaction.onabort=transaction.onerror=reject;
                });db.close();result.databases.push([name,records]);
            }
            return JSON.stringify(result);
            """#
        let before = try #require(try await page.callJavaScript(snapshot) as? String)
        await #expect(throws: OriginStorageTransferError.unsupportedSchema) { try await transfer.read(origin: source.baseURL) }
        // Here the colliding Origin acts as a restore target. Its existing records must
        // be rejected before either business database or LocalStorage is replaced.
        await #expect(throws: OriginStorageTransferError.unsupportedSchema) { try await transfer.restore(fixture, to: source.baseURL) }
        await #expect(throws: OriginStorageTransferError.unsupportedSchema) { try await transfer.clear(origin: source.baseURL) }
        #expect(try await page.callJavaScript(snapshot) as? String == before)
        try await transfer.verify(fixture, at: other.baseURL)
    }
    private func releaseTransaction(in page: WebPage) async throws {
        try await page.callJavaScript("window.keepLock=false;await window.lockDone;window.holdDB.close();return true;")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationAndTimeoutAbortPendingWorkWithoutLaterDeletingData() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try await bindFixture(root); defer { server.stop() }
        let store = WKWebsiteDataStore.nonPersistent()
        let page = page(store: store); defer { page.stopLoading() }
        try await load(page, server.baseURL); try await seed(fixture, page: page)
        try await holdTransaction(in: page)
        let transfer = OriginStorageTransfer(dataStore: store)
        let restoring = Task { try await transfer.restore(OriginStoragePayload(localStorage: ["replacement":"not committed"]), to: server.baseURL) }
        try await Task.sleep(for: .milliseconds(80))
        await #expect(throws: OriginStorageTransferError.busy) { try await transfer.read(origin: server.baseURL) }
        restoring.cancel()
        await #expect(throws: CancellationError.self) { try await restoring.value }
        try await releaseTransaction(in: page)
        try await Task.sleep(for: .milliseconds(200))
        try await transfer.verify(fixture, at: server.baseURL)
        try await holdTransaction(in: page)
        let quick = OriginStorageTransfer(dataStore: store, timeout: .milliseconds(100))
        await #expect(throws: OriginStorageTransferError.timedOut) { try await quick.read(origin: server.baseURL) }
        try await releaseTransaction(in: page)
        try await Task.sleep(for: .milliseconds(200))
        try await transfer.verify(fixture, at: server.baseURL)
        let preCancelled = Task { try await transfer.clear(origin: server.baseURL) }
        preCancelled.cancel()
        await #expect(throws: CancellationError.self) { try await preCancelled.value }
        try await transfer.verify(fixture, at: server.baseURL)
    }

    @Test
    func nonLoopbackAndInvalidOriginsAreRejected() async throws {
        let transfer = OriginStorageTransfer(dataStore: .nonPersistent())
        for text in ["https://127.0.0.1:9099", "http://localhost:9099", "http://10.0.0.1:9099", "http://127.0.0.1:80", "http://127.0.0.1:9099/path", "http://user@127.0.0.1:9099", "http://127.0.0.1:9099?x=1", "http://127.0.0.1:9099#fragment"] {
            let origin = try #require(URL(string: text))
            await #expect(throws: OriginStorageTransferError.invalidOrigin) { try await transfer.read(origin: origin) }
        }
    }
}
