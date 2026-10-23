import Foundation
import CryptoKit

/// Safe, actionable failures for the official release catalog. Response bodies are never surfaced.
public enum ReleaseCatalogError: LocalizedError, Equatable, Sendable {
    case rateLimited(status: Int, retryAt: Date?)
    case httpStatus(Int)
    case untrustedSource
    case invalidResponse
    case responseTooLarge
    case invalidJSON
    case invalidMetadata

    public var errorDescription: String? {
        switch self {
        case let .rateLimited(status, retryAt):
            if let retryAt {
                let time = retryAt.formatted(date: .abbreviated, time: .standard)
                return "GitHub API 请求次数已达限制（HTTP \(status)）。请在 \(time) 后重试，或导入本地 ZIP。"
            }
            return "GitHub API 暂时限制请求（HTTP \(status)）。请稍后重试，或导入本地 ZIP。"
        case .httpStatus(let status):
            return "GitHub 官方版本查询失败（HTTP \(status)）。请稍后重试。"
        case .untrustedSource:
            return "GitHub 版本响应来源不受信任，或返回了未接受的重定向。"
        case .invalidResponse:
            return "GitHub 版本查询未返回有效的 HTTP 响应。"
        case .responseTooLarge:
            return "GitHub 版本目录超过 8 MiB 安全限制。"
        case .invalidJSON:
            return "GitHub 版本目录格式无效，无法读取官方发行信息。"
        case .invalidMetadata:
            return "官方稳定版缺少可信的 dist.zip、SHA-256 或有效发行元数据。"
        }
    }
}

public struct ZashboardRelease: Codable, Sendable, Identifiable, Equatable {
    public let tag: String
    public let publishedAt: Date
    public let assetURL: URL
    public let assetSize: Int64
    public let sha256: String
    public var id: String { tag }

    public init(tag: String, publishedAt: Date, assetURL: URL, assetSize: Int64, sha256: String) {
        self.tag = tag; self.publishedAt = publishedAt; self.assetURL = assetURL
        self.assetSize = assetSize; self.sha256 = sha256.lowercased()
    }

    public func validate() throws {
        guard !tag.isEmpty, tag.utf8.count <= 100,
              tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }),
              assetSize > 0, assetSize <= SafeZIPExtractor.Limits.standard.maxArchiveBytes,
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              assetURL.scheme == "https", assetURL.host == "github.com", assetURL.user == nil,
              assetURL.password == nil, assetURL.port == nil, assetURL.query == nil, assetURL.fragment == nil,
              assetURL.path == "/Zephyruso/zashboard/releases/download/\(tag)/dist.zip" else {
            throw ZashDockError.verification("版本缺少可信的官方 dist.zip、SHA-256 或有效大小。")
        }
    }
}

public struct DownloadProgress: Sendable, Equatable {
    public let receivedBytes: Int64
    public let totalBytes: Int64
    public var fractionCompleted: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }
    public init(receivedBytes: Int64, totalBytes: Int64) { self.receivedBytes = receivedBytes; self.totalBytes = totalBytes }
}

/// A session never forwards a request, including redirects, outside the explicitly permitted HTTPS hosts.
private final class OfficialRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    enum Kind: Sendable { case api, asset }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return false }
        switch kind {
        case .api:
            return url.host == "api.github.com" && url.path.hasPrefix("/repos/Zephyruso/zashboard/releases")
        case .asset:
            guard let host = url.host, ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host) else { return false }
            return host != "github.com" || (url.path.hasPrefix("/Zephyruso/zashboard/releases/download/") && url.lastPathComponent == "dist.zip")
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(allows) == true ? request : nil)
    }
}

public actor ReleaseClient {
    private let apiDelegate = OfficialRedirectDelegate(.api)
    private let assetDelegate = OfficialRedirectDelegate(.asset)
    private let apiSession: URLSession
    private let assetSession: URLSession
    public init() {
        self.init(sessionConfiguration: .ephemeral)
    }

    /// A session-local URLProtocol can supply deterministic HTTP responses in tests.
    /// The client still owns both redirect delegates and all response validation.
    init(sessionConfiguration: URLSessionConfiguration) {
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 600
        apiSession = URLSession(configuration: configuration, delegate: apiDelegate, delegateQueue: nil)
        assetSession = URLSession(configuration: configuration, delegate: assetDelegate, delegateQueue: nil)
    }

    public func latest() async throws -> ZashboardRelease {
        let release = try convert(try await request(OfficialRelease.self, suffix: "/latest"))
        try Task.checkCancellation()
        return release
    }

    public func download(_ release: ZashboardRelease, to destination: URL,
                         progress: @Sendable (DownloadProgress) async -> Void = { _ in }) async throws {
        try release.validate(); try Task.checkCancellation()
        var request = URLRequest(url: release.assetURL)
        request.setValue("ZashDock/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await assetSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, assetDelegate.allows(finalURL) else {
            throw ZashDockError.verification("官方下载请求失败或重定向来源不受信任。")
        }
        guard http.expectedContentLength < 0 || http.expectedContentLength == release.assetSize else {
            throw ZashDockError.verification("下载大小与官方元数据不符。")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ZashDockError.storage("下载目标已存在或不可写。")
        }
        let handle = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer { try? handle.close(); if !succeeded { try? FileManager.default.removeItem(at: destination) } }
        var received: Int64 = 0
        var buffer = Data(); buffer.reserveCapacity(65_536)
        var hasher = SHA256()
        await progress(.init(receivedBytes: 0, totalBytes: release.assetSize))
        for try await byte in bytes {
            try Task.checkCancellation()
            received += 1
            guard received <= release.assetSize else { throw ZashDockError.verification("下载数据超过官方声明的大小。") }
            buffer.append(byte)
            if buffer.count == 65_536 {
                try handle.write(contentsOf: buffer); hasher.update(data: buffer); buffer.removeAll(keepingCapacity: true)
                await progress(.init(receivedBytes: received, totalBytes: release.assetSize))
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); hasher.update(data: buffer) }
        guard received == release.assetSize, Self.hex(hasher.finalize()) == release.sha256 else {
            throw ZashDockError.verification("下载损坏：SHA-256 或文件大小与官方发布不匹配。")
        }
        try handle.synchronize(); try Task.checkCancellation()
        succeeded = true
        await progress(.init(receivedBytes: received, totalBytes: release.assetSize))
    }

    public static func digest(of url: URL, maximumBytes: Int64 = SafeZIPExtractor.Limits.standard.maxArchiveBytes) throws -> String {
        guard (0...SafeZIPExtractor.Limits.standard.maxArchiveBytes).contains(maximumBytes) else {
            throw ZashDockError.verification("文件校验大小限制无效。")
        }
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        var consumed: Int64 = 0
        while let data = try handle.read(upToCount: Int(min(1_048_576, maximumBytes - consumed + 1))), !data.isEmpty {
            try Task.checkCancellation(); consumed += Int64(data.count)
            guard consumed <= maximumBytes else { throw ZashDockError.verification("文件在校验期间增长或超过大小限制。") }
            hash.update(data: data)
        }
        return hex(hash.finalize())
    }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private func request<T: Decodable & Sendable>(_ type: T.Type, suffix: String) async throws -> T {
        try Task.checkCancellation()
        let url = URL(string: "https://api.github.com/repos/Zephyruso/zashboard/releases" + suffix)!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ZashDock/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await apiSession.bytes(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ReleaseCatalogError.invalidResponse }
            guard let finalURL = http.url, apiDelegate.allows(finalURL) else { throw ReleaseCatalogError.untrustedSource }
            let now = Date(), retryAt = Self.retryDate(http, now: now)
            if http.statusCode == 429 || (http.statusCode == 403 &&
                (http.value(forHTTPHeaderField: "X-RateLimit-Remaining")?.trimmingCharacters(in: .whitespacesAndNewlines) == "0" ||
                 Self.retryAfter(http, now: now) != nil)) {
                throw ReleaseCatalogError.rateLimited(status: http.statusCode, retryAt: retryAt)
            }
            if (300..<400).contains(http.statusCode) { throw ReleaseCatalogError.untrustedSource }
            guard http.statusCode == 200 else { throw ReleaseCatalogError.httpStatus(http.statusCode) }
            let maximum = 8_388_608
            guard http.expectedContentLength <= maximum else { throw ReleaseCatalogError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximum else { throw ReleaseCatalogError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            do { return try decoder.decode(T.self, from: data) }
            catch { throw ReleaseCatalogError.invalidJSON }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private static func retryAfter(_ response: HTTPURLResponse, now: Date) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), (0...604_800).contains(seconds) else { return nil }
        return now.addingTimeInterval(TimeInterval(seconds))
    }
    private static func retryDate(_ response: HTTPURLResponse, now: Date) -> Date? {
        if let date = retryAfter(response, now: now) { return date }
        guard response.value(forHTTPHeaderField: "X-RateLimit-Remaining")?.trimmingCharacters(in: .whitespacesAndNewlines) == "0",
              let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
              let seconds = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let interval = TimeInterval(seconds)
        guard interval >= now.timeIntervalSince1970, interval - now.timeIntervalSince1970 <= 604_800 else { return nil }
        return Date(timeIntervalSince1970: interval)
    }
    private func convert(_ release: OfficialRelease) throws -> ZashboardRelease {
        guard !release.draft, !release.prerelease,
              let asset = release.assets.first(where: { $0.name == "dist.zip" }), asset.state == "uploaded",
              let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw ReleaseCatalogError.invalidMetadata
        }
        let result = ZashboardRelease(tag: release.tag_name, publishedAt: release.published_at,
                                      assetURL: asset.browser_download_url, assetSize: asset.size,
                                      sha256: String(digest.dropFirst(7)))
        do { try result.validate() } catch { throw ReleaseCatalogError.invalidMetadata }
        return result
    }
    private struct OfficialRelease: Decodable, Sendable {
        let tag_name: String; let published_at: Date; let draft: Bool; let prerelease: Bool; let assets: [Asset]
    }
    private struct Asset: Decodable, Sendable {
        let name: String; let state: String; let size: Int64; let digest: String?; let browser_download_url: URL
    }
}
