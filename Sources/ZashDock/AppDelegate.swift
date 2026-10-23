import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var reopenWindow: (() -> Void)?
    private var terminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        model?.configuration.quitAfterLastWindowCloses ?? false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopenWindow?() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let model else { return terminating ? .terminateCancel : .terminateNow }
        terminating = true
        Task {
            let saved = await model.prepareToQuit()
            terminating = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}
