import Foundation
import Testing
@testable import ZashDockCore

@Test func configurationCommitsAtomicallyAndRejectsInvalidPort() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(url: directory.appendingPathComponent("configuration.json"))
    #expect(try store.load().port == 9099)
    var value = AppConfiguration()
    value.port = 12345; value.quitAfterLastWindowCloses = true
    try store.save(value)
    #expect(try store.load() == value)
    value.port = 80
    #expect(throws: (any Error).self) { try store.save(value) }
    #expect(try store.load().port == 12345)
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["configuration.json", "configuration.last-valid.json"])
}

@Test func defaultConfigurationEncodingContainsOnlyCurrentPreferences() throws {
    let configuration = AppConfiguration()
    let bytes = try JSONEncoder().encode(configuration)
    let fields = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(Set(fields.keys) == ["port", "quitAfterLastWindowCloses", "legacyStorageImported"])
    #expect(try JSONDecoder().decode(AppConfiguration.self, from: bytes) == configuration)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(url: directory.appendingPathComponent("configuration.json"))
    try store.save(configuration)
    let primary = try Data(contentsOf: store.url), mirror = try Data(contentsOf: store.recoveryCopyURL)
    let saved = try #require(try JSONSerialization.jsonObject(with: primary) as? [String: Any])
    #expect(Set(saved.keys) == Set(fields.keys))
    #expect(primary == mirror)
    #expect(try store.load() == configuration)
}
