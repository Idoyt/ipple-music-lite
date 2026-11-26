import AppKit
import MusicCore
import Observation

@MainActor
final class MenuBarPlaybackController: NSObject {
    private let store: AppStore
    private let showWindow: () -> Void
    private let statusItem: NSStatusItem
    let item = MenuBarPlaybackItem()
    private var running = true
    private var identity = ""
    private var timeline = MenuBarLyricTimeline(nil)
    private var lyricTask: Task<Void, Never>?
    private var stopObservingBoundaries: (() -> Void)?
    private var boundaryClockID: ObjectIdentifier?
    private var cueStartTimes: [Double] = []
    private var favoriteStateTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var actionID: UUID?
    private var favoriteTasks: [String: Task<Void, Never>] = [:]

    init(store: AppStore, showWindow: @escaping () -> Void) {
        self.store = store
        self.showWindow = showWindow
        statusItem = NSStatusBar.system.statusItem(withLength: store.settings.resolvedMenuBarWidth)
        super.init()
        item.install(in: statusItem)
        item.onPrevious = { [weak self] in self?.perform { await $0.previous() } }
        item.onToggle = { [weak self] in self?.togglePlayback() }
        item.onNext = { [weak self] in self?.perform { await $0.next() } }
        item.onFavorite = { [weak self] in self?.toggleFavorite() }
        item.onShowWindow = { [weak self] in self?.showWindow() }
        item.onContextMenu = { [weak self] event in self?.showMenu(event) }
        item.playbackPosition = { [weak store] in store?.player.lyricPlaybackPosition() ?? 0 }
        observePlayback()
    }

    func stop() {
        guard running else { return }
        running = false
        lyricTask?.cancel()
        stopObservingBoundaries?()
        stopObservingBoundaries = nil
        favoriteStateTask?.cancel()
        actionTask?.cancel()
        for task in favoriteTasks.values { task.cancel() }
        favoriteTasks.removeAll()
        item.stop()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func perform(_ action: @escaping @MainActor (PlaybackController) async -> Void) {
        guard actionTask == nil else { return }
        let id = UUID()
        actionID = id
        actionTask = Task { [weak self] in
            guard let self else { return }
            await action(store.player)
            if actionID == id { actionTask = nil }
        }
    }

    private func togglePlayback() {
        if store.player.isLoading || store.player.isPlaying {
            store.player.pause()
            actionTask?.cancel()
            actionTask = nil
            actionID = nil
        } else {
            perform { await $0.togglePlayPause() }
        }
    }

    private func toggleFavorite() {
        guard running, let track = store.player.currentTrack,
            favoriteTasks[track.id] == nil, !store.isUpdatingFavorite(track.id)
        else { return }
        favoriteTasks[track.id] = Task { [weak self] in
            guard let self else { return }
            defer { favoriteTasks.removeValue(forKey: track.id) }
            await store.toggleFavorite(track)
        }
    }

    private func observePlayback() {
        guard running else { return }
        withObservationTracking {
            let player = store.player
            let currentIdentity = playbackPresentationIdentity(
                userID: store.user?.id, track: player.currentTrack, sources: store.sources)
            if currentIdentity != identity {
                identity = currentIdentity
                timeline = MenuBarLyricTimeline(nil)
                cueStartTimes = []
                stopObservingBoundaries?()
                stopObservingBoundaries = nil
                boundaryClockID = nil
                loadLyrics(track: player.currentTrack, identity: currentIdentity)
                favoriteStateTask?.cancel()
                if let track = player.currentTrack {
                    favoriteStateTask = Task { [weak self] in await self?.store.refreshQQFavorite(track) }
                }
            }
            refreshPresentation()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePlayback() }
        }
    }

    private func refreshPresentation() {
        let player = store.player
        // The direct AVPlayer clock is not observable. Keep the periodic-position dependency explicit.
        _ = player.position
        let position = player.lyricPlaybackPosition()
        let lyric = timeline.presentation(at: position, duration: player.duration)
        item.setWidth(store.settings.resolvedMenuBarWidth)
        item.configure(
            .init(
                title: lyric?.text ?? timeline.title(at: position, trackTitle: player.currentTrack?.title),
                isPlaying: player.isPlaying, isLoading: player.isLoading, hasTrack: player.currentTrack != nil,
                isFavorite: player.currentTrack.map { store.isFavorite($0.id) } ?? false,
                isFavoriteUpdating: player.currentTrack.map { store.isUpdatingFavorite($0.id) } ?? false,
                lyric: lyric))
        item.synchronizePlayback(position: position)
        observeLyricBoundaries()
    }

    private func observeLyricBoundaries() {
        let clockID = store.player.lyricClockID
        guard !cueStartTimes.isEmpty, boundaryClockID != clockID else { return }
        stopObservingBoundaries?()
        boundaryClockID = clockID
        let trackIdentity = identity
        stopObservingBoundaries = store.player.observeLyricBoundaries(cueStartTimes) { [weak self] in
            guard let self, running, identity == trackIdentity, store.player.lyricClockID == clockID else { return }
            refreshPresentation()
        }
    }

    private func loadLyrics(track: LibraryTrack?, identity requestedIdentity: String) {
        lyricTask?.cancel()
        guard let track, store.user != nil else { return }
        let bindings = playbackBindings(track: track, sources: store.sources)
        lyricTask = Task { [weak self] in
            guard let self else { return }
            for binding in bindings {
                do {
                    let parsed = try await store.sourceLyricsTimeline(
                        sourceID: binding.sourceConnectionID, trackID: binding.sourceTrackID)
                    try Task.checkCancellation()
                    guard running, identity == requestedIdentity else { return }
                    if parsed.isTimed || !parsed.plainText.isEmpty {
                        timeline = MenuBarLyricTimeline(parsed)
                        cueStartTimes = timeline.startTimes
                        refreshPresentation()
                        return
                    }
                } catch {
                    if Task.isCancelled || !running || identity != requestedIdentity { return }
                }
            }
        }
    }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "显示 Ipple Music", action: #selector(openMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Ipple Music", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: item.button)
        item.setHovered(false)
    }

    @objc private func openMainWindow() { showWindow() }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}
