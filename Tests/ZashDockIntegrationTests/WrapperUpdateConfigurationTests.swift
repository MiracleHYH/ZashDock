import Foundation
import Testing
@testable import ZashDock

@MainActor
struct WrapperUpdateConfigurationTests {
    @Test(.enabled(if: Bundle.main.bundleIdentifier == "app.zashdock.mac",
                  "安全配置测试需要 xcodebuild 的实际 App 宿主。"))
    func appBundlePinsSignedRepositoryFeedAndSandboxServices() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["SUFeedURL"] as? String == "https://raw.githubusercontent.com/MiracleHYH/ZashDock/main/appcast.xml")
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUSignedFeedFailureExpirationInterval"] as? Int == 0)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == false)
        let publicKey = try #require(info["SUPublicEDKey"] as? String)
        #expect(Data(base64Encoded: publicKey)?.count == 32)
        #expect(WrapperUpdateController.releasesURL.absoluteString == "https://github.com/MiracleHYH/ZashDock/releases")
        let frameworks = try #require(Bundle.main.privateFrameworksURL)
        #expect(FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework/Versions/B/XPCServices/Installer.xpc").path))
        let version = try #require(info["CFBundleShortVersionString"] as? String)
        let build = try #require(info["CFBundleVersion"] as? String)
        #expect(!version.contains("$("))
        #expect(Int(build) != nil)
        let updater = WrapperUpdateController()
        #expect(updater.versionDescription == "\(version) (\(build))")
        // The real App host must never launch Sparkle network checks or alerts during XCTest.
        updater.start()
        #expect(!updater.hasStarted)
    }
}
