import Foundation
import Testing
@testable import ZashDockCore

@Test func configurationCommitsAtomicallyAndRejectsInvalidPort() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(url: directory.appendingPathComponent("configuration.json"))
    #expect(try store.load().port == 9099)
    var value = AppConfiguration()
    value.port = 12345; value.maxRollbackVersions = 3
    try store.save(value)
    #expect(try store.load() == value)
    value.port = 80
    #expect(throws: (any Error).self) { try store.save(value) }
    #expect(try store.load().port == 12345)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["configuration.json"])
}
