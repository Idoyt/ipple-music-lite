import AppKit
import MusicCore
import Observation

private struct Failure: Error, CustomStringConvertible { var description: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}

@MainActor @Observable
final class PlaybackController {
    var currentTrack: LibraryTrack?
    var position = 0.0
    var duration = 30.0
    var isPlaying = false
    var isLoading = false
    @ObservationIgnored private var base = 0.0
    @ObservationIgnored private var epoch = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var boundaryTimes: [Double] = []
    @ObservationIgnored private var onBoundary: (@MainActor () -> Void)?
    @ObservationIgnored private var boundaryTask: Task<Void, Never>?

    var lyricClockID: ObjectIdentifier { ObjectIdentifier(self) }
    func lyricPlaybackPosition() -> Double {
        base + (isPlaying ? ProcessInfo.processInfo.systemUptime - epoch : 0)
    }
    func setClock(_ position: Double, playing: Bool) {
        base = position
        epoch = ProcessInfo.processInfo.systemUptime
        self.position = position
        isPlaying = playing
        scheduleBoundaryEvents()
    }
    func observeLyricBoundaries(_ seconds: [Double], onBoundary: @escaping @MainActor () -> Void) -> () -> Void {
        boundaryTimes = seconds
        self.onBoundary = onBoundary
        scheduleBoundaryEvents()
        return { [weak self] in
            self?.boundaryTask?.cancel()
            self?.onBoundary = nil
            self?.boundaryTimes = []
        }
    }
    private func scheduleBoundaryEvents() {
        boundaryTask?.cancel()
        guard isPlaying else { return }
        let positions = boundaryTimes.filter { $0 > base }
        boundaryTask = Task { [weak self] in
            for position in positions {
                guard let self else { return }
                do {
                    try await Task.sleep(for: .seconds(max(0, position - lyricPlaybackPosition())))
                } catch { return }
                onBoundary?()
            }
        }
    }
    func pause() { setClock(lyricPlaybackPosition(), playing: false) }
    func togglePlayPause() async { setClock(lyricPlaybackPosition(), playing: !isPlaying) }
    func previous() async { setClock(0, playing: isPlaying) }
    func next() async { setClock(0, playing: isPlaying) }
}

@MainActor @Observable
final class AppStore {
    let player = PlaybackController()
    var settings = AppSettings()
    var user: User? = User(displayName: "Fixture", id: "owner", role: "user", username: "fixture")
    var sources = [
        SourceConnection(
            id: "qq", ownerID: "owner", name: "QQ", kind: "qq", baseURL: "http://fixture", enabled: true,
            state: "active")
    ]
    @ObservationIgnored var timelines: [String: LyricsTimeline] = [:]
    @ObservationIgnored var calls: [String: Int] = [:]
    func isFavorite(_ id: String) -> Bool { false }
    func isUpdatingFavorite(_ id: String) -> Bool { false }
    func toggleFavorite(_ track: LibraryTrack) async {}
    func refreshQQFavorite(_ track: LibraryTrack) async {}
    func sourceLyricsTimeline(sourceID: String, trackID: String) async throws -> LyricsTimeline {
        calls[trackID, default: 0] += 1
        let result = timelines[trackID] ?? LyricsTimeline(lrc: "")
        if trackID == "slow" { try await Task.sleep(for: .milliseconds(150)) }
        return result
    }
}

@MainActor
func playbackBindings(track: LibraryTrack, sources: [SourceConnection]) -> [LibraryBinding] { track.bindings }
@MainActor
func playbackPresentationIdentity(userID: String?, track: LibraryTrack?, sources: [SourceConnection]) -> String {
    "\(userID ?? ""):\(track?.id ?? "")"
}

@main @MainActor
private struct Harness {
    static func track(_ id: String) -> LibraryTrack {
        LibraryTrack(
            id: id, title: id, album: "",
            bindings: [
                LibraryBinding(id: id, trackID: id, sourceConnectionID: "qq", sourceTrackID: id, confirmed: true)
            ])
    }
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline { throw Failure(description: "timed out waiting for menu-bar presentation") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func main() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let store = AppStore()
        store.timelines["track"] = LyricsTimeline(lrc: "[00:00.100]重复歌词\n[00:00.400]重复歌词\n[00:00.700]最后一句")
        store.player.currentTrack = track("track")
        let controller = MenuBarPlaybackController(store: store, showWindow: {})
        defer { controller.stop() }
        try await wait { store.calls["track"] == 1 }
        store.player.setClock(0, playing: true)
        try await wait { controller.item.state?.lyric?.cueID == 0 }
        let builds = controller.item.button.glyphBuilds
        try await wait { controller.item.state?.lyric?.cueID == 1 }
        try require(controller.item.button.glyphBuilds == builds, "identical repeated lyric rerasterized glyphs")
        try await wait { controller.item.state?.title == "最后一句" }
        try require(
            store.player.position == 0 && store.calls["track"] == 1,
            "boundary updates required a progress tick or fetched lyrics again")
        print(
            "PASS actual controller advances repeated and subsequent cues from media clock without published progress ticks"
        )

        store.player.setClock(0.15, playing: false)
        try await wait { controller.item.state?.lyric?.cueID == 0 && controller.item.state?.isPlaying == false }
        let updates = controller.item.presentationUpdates
        try await Task.sleep(for: .milliseconds(420))
        try require(
            controller.item.presentationUpdates == updates, "paused controller retained a boundary refresh loop")
        store.player.setClock(0.3, playing: true)
        try await wait { controller.item.state?.lyric?.cueID == 1 }
        print(
            "PASS pause cancels scheduled lyric boundaries, backward seek restores the right cue and resume rearms updates"
        )

        store.timelines["slow"] = LyricsTimeline(lrc: "[00:00]迟到旧歌词")
        store.timelines["new"] = LyricsTimeline(lrc: "[00:00]新歌词\n[00:00.400]稍后的句子")
        store.player.setClock(0, playing: false)
        store.player.currentTrack = track("slow")
        try await wait { store.calls["slow"] == 1 }
        store.player.currentTrack = track("new")
        try await wait { controller.item.state?.title == "新歌词" }
        try await Task.sleep(for: .milliseconds(200))
        try require(
            controller.item.state?.title == "新歌词" && store.calls["new"] == 1,
            "late old-track lyrics replaced the new song")
        print("PASS asynchronous lyric completion cannot revive an old song or break subsequent observation")

        store.player.setClock(0, playing: true)
        try await wait { controller.item.state?.isPlaying == true }
        controller.stop()
        let stoppedUpdates = controller.item.presentationUpdates
        try await Task.sleep(for: .milliseconds(500))
        try require(
            controller.item.presentationUpdates == stoppedUpdates, "stopped menu-bar controller retained scheduled work"
        )
        print("PASS stop releases scheduled updates and leaves no recurring refresh")
        print("Menu bar controller regression harness: 4/4 passed")
    }
}
