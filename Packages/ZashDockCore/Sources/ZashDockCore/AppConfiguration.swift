import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var port: UInt16 = 9099
    public var maxRollbackVersions: Int = 1
    public var quitAfterLastWindowCloses = false
    public init() {}
}
