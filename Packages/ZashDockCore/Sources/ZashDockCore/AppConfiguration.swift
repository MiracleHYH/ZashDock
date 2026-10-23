import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var port: UInt16 = 9099
    public var maxRollbackVersions: Int = 1
    public var quitAfterLastWindowCloses = false
    /// The old Origin is removed only after the new port has committed and its recovery copy is durable.
    public var pendingOriginCleanup: UInt16?
    /// Compatibility import is performed once; daily website persistence belongs to WebKit.
    public var legacyStorageImported = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case port, maxRollbackVersions, quitAfterLastWindowCloses, pendingOriginCleanup, legacyStorageImported
    }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        port = try fields.decode(UInt16.self, forKey: .port)
        maxRollbackVersions = try fields.decode(Int.self, forKey: .maxRollbackVersions)
        quitAfterLastWindowCloses = try fields.decode(Bool.self, forKey: .quitAfterLastWindowCloses)
        pendingOriginCleanup = try fields.decodeIfPresent(UInt16.self, forKey: .pendingOriginCleanup)
        legacyStorageImported = fields.contains(.legacyStorageImported)
            ? try fields.decode(Bool.self, forKey: .legacyStorageImported) : false
        guard port >= 1024, (0...100).contains(maxRollbackVersions),
              pendingOriginCleanup.map({ $0 >= 1024 && $0 != port }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: fields.codingPath, debugDescription: "Invalid wrapper configuration values."))
        }
    }
}
