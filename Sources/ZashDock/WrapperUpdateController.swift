import Foundation
import Observation
import Sparkle

/// Keeps the native application's updater independent of the Zashboard resource updater.
@MainActor @Observable
final class WrapperUpdateController {
    static let repositoryURL = URL(string: "https://github.com/MiracleHYH/ZashDock")!
    static let releasesURL = repositoryURL.appendingPathComponent("releases")

    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var hasStarted = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var availabilityObservation: NSKeyValueObservation?
    @ObservationIgnored private var automaticChecksObservation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        availabilityObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let available = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = available
            }
        }
        automaticChecksObservation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let enabled = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.automaticallyChecksForUpdates = enabled
            }
        }
    }

    var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "未知版本"
        let build = info["CFBundleVersion"] as? String ?? "未知构建"
        return "\(version) (\(build))"
    }

    func start() {
        guard !hasStarted,
              NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        hasStarted = true
        controller.startUpdater()
        canCheckForUpdates = controller.updater.canCheckForUpdates
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        guard hasStarted, controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard hasStarted else { return }
        // Sparkle persists the preference and reschedules its update cycle itself.
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }
}
