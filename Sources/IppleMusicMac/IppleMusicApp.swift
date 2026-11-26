import AppKit
import MusicCore
import SwiftUI

@main
struct IppleMusicApp: App {
    private static let windowTitle = "Ipple Music"
    @State private var store = AppStore(api: LocalQQRuntime.client())
    @NSApplicationDelegateAdaptor(MacPlaybackLifecycle.self) private var lifecycle
    @Environment(\.openWindow) private var openWindow

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup(Self.windowTitle, id: "main") {
            RootView()
                .environment(store)
                .tint(Color(nsColor: .controlAccentColor))
                .accentColor(Color(nsColor: .controlAccentColor))
                .frame(minWidth: 980, minHeight: 680)
                .background { WindowTopZoom().frame(width: 0, height: 0) }
                .task {
                    lifecycle.player = store.player
                    lifecycle.installMenuBar(store: store) {
                        if let window = NSApplication.shared.windows.first(where: {
                            $0.title == Self.windowTitle && $0.canBecomeMain && !($0 is NSPanel)
                        }) {
                            if window.isMiniaturized { window.deminiaturize(nil) }
                            window.makeKeyAndOrderFront(nil)
                        } else {
                            openWindow(id: "main")
                        }
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                    await store.restoreSessionOnStartup()
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) {
                    _ in
                    if store.player.isPlaying { store.player.pause() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.player.flushSession()
                }
        }
        .defaultSize(width: 1260, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新资料库") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.user == nil)
            }
            CommandMenu("播放") {
                Button(store.player.isPlaying ? "暂停" : "继续播放") { Task { await store.player.togglePlayPause() } }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("下一首") { Task { await store.player.next() } }.keyboardShortcut(.rightArrow, modifiers: .command)
                Button("上一首") { Task { await store.player.previous() } }.keyboardShortcut(
                    .leftArrow, modifiers: .command)
            }
        }
        Settings {
            AccountSettingsView().environment(store).frame(width: 570, height: 560)
                .background { WindowTopZoom().frame(width: 0, height: 0) }
        }
    }
}
