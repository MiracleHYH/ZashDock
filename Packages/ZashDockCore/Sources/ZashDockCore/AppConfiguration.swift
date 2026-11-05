import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    /// The legacy Origin is retained until AppModel binds and commits an automatic port.
    public var port: UInt16 = 9099
    /// Missing in older files. Set only after a high-port selection and any Origin transfer commit.
    public var automaticPortSelection = false
    public var quitAfterLastWindowCloses = false
    /// The old Origin is removed only after the new port has committed and its recovery copy is durable.
    public var pendingOriginCleanup: UInt16?
    /// Compatibility import is performed once; daily website persistence belongs to WebKit.
    public var legacyStorageImported = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case port, automaticPortSelection, quitAfterLastWindowCloses, pendingOriginCleanup, legacyStorageImported
    }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        port = try fields.decode(UInt16.self, forKey: .port)
        automaticPortSelection = fields.contains(.automaticPortSelection)
            ? try fields.decode(Bool.self, forKey: .automaticPortSelection) : false
        quitAfterLastWindowCloses = try fields.decode(Bool.self, forKey: .quitAfterLastWindowCloses)
        pendingOriginCleanup = try fields.decodeIfPresent(UInt16.self, forKey: .pendingOriginCleanup)
        legacyStorageImported = fields.contains(.legacyStorageImported)
            ? try fields.decode(Bool.self, forKey: .legacyStorageImported) : false
        guard port >= 1024,
              pendingOriginCleanup.map({ $0 >= 1024 && $0 != port }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: fields.codingPath, debugDescription: "Invalid wrapper configuration values."))
        }
    }
}
