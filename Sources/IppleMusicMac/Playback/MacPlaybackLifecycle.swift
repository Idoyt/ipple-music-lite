import AppKit

@MainActor
final class MacPlaybackLifecycle: NSObject, NSApplicationDelegate {
    weak var player: PlaybackController?
    private var menuBar: MenuBarPlaybackController?
    private var terminating = false

    func installMenuBar(store: AppStore, showWindow: @escaping () -> Void) {
        guard menuBar == nil else { return }
        menuBar = MenuBarPlaybackController(store: store, showWindow: showWindow)
    }

    func applicationWillTerminate(_ notification: Notification) { menuBar?.stop() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let player else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await player.prepareForTermination()
            await LocalQQRuntime.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
