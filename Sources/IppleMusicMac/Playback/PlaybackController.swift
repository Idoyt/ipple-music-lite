import AVFoundation
import Foundation
import MediaPlayer
import MusicCore
import Observation

public enum PlaybackRepeatMode: String, CaseIterable, Sendable {
    case off, all, one
}

enum PlaybackMode {
    case sequential, shuffle, repeatOne

    var next: Self {
        switch self {
        case .sequential: .shuffle
        case .shuffle: .repeatOne
        case .repeatOne: .sequential
        }
    }
}

enum PlaybackArtworkDirection: Sendable {
    case forward, backward
}

enum PlaybackQuality: String, CaseIterable, Codable, Sendable {
    case standard = "original"
    case high = "320"
    case lossless = "flac"
}

/// Owns one streaming player. Account/server changes must call stop before replacing the client.
@MainActor
@Observable
public final class PlaybackController {
    public private(set) var queue: [LibraryTrack] = []
    public private(set) var currentTrack: LibraryTrack?
    private(set) var artworkDirection = PlaybackArtworkDirection.forward
    public private(set) var isPlaying = false
    public private(set) var isLoading = false
    // Transport controls reflect the action they will perform, never buffering/preload state.
    var showsPauseControl: Bool { wantsToPlay || isPlaying }
    public private(set) var position: Double = 0
    private var lyricSeekRevision: UInt64 = 0
    public private(set) var duration: Double = 0
    public private(set) var canSeek = false
    private(set) var preferredQuality: PlaybackQuality = .standard
    private var activeQuality: PlaybackQuality?
    private(set) var isChangingQuality = false
    @ObservationIgnored private var qualityRequestID = UUID()
    var playbackQuality: PlaybackQuality { activeQuality ?? preferredQuality }
    @ObservationIgnored private var qualityAvailabilityCache:
        [String: (track: LibraryTrack, checkedAt: Date, values: [PlaybackQuality: Bool])] = [:]
    public private(set) var error: String?
    private(set) var playbackNotice: String?
    public private(set) var isLoadingQQQueue = false
    public private(set) var isPreparingQQQueue = false
    public private(set) var qqQueueError: String?
    public private(set) var qqQueueTotal: Int64 = 0
    public private(set) var isLoadingPersonalRadio = false
    private var radioOrigin: PersonalRadioOrigin?
    public var isPersonalRadio: Bool { radioOrigin != nil }
    @ObservationIgnored private var radioTask: Task<Void, Never>?
    @ObservationIgnored private var radioRequestID = UUID()
    @ObservationIgnored private var radioControlRevision: UInt64 = 0
    public var repeatMode: PlaybackRepeatMode = .off {
        didSet {
            cancelPreload()
            schedulePreload()
            updateNowPlaying()
            saveSession()
        }
    }
    public var shuffleEnabled = false {
        didSet {
            if !restoringSession {
                navigation = currentKey.map { [$0] } ?? []
                navigationIndex = navigation.count - 1
                visited = Set(navigation)
            }
            cancelPreload()
            schedulePreload()
            saveSession()
        }
    }
    var playbackMode: PlaybackMode {
        if repeatMode == .one { return .repeatOne }
        return shuffleEnabled ? .shuffle : .sequential
    }
    public var volume: Double = 0.8 {
        didSet {
            let bounded = volume.isFinite ? min(max(volume, 0), 1) : 0.8
            if volume != bounded { volume = bounded }
            resources.player.volume = Float(bounded)
            saveSession()
        }
    }

    @ObservationIgnored private let client: MusicAPIClient
    @ObservationIgnored private let mediaCache: MediaDiskCache?
    @ObservationIgnored private var cacheSources: [String: String] = [:]
    @ObservationIgnored private var recoveringCachedPlayback = false
    @ObservationIgnored private var audioCacheTask: Task<Void, Never>?
    @ObservationIgnored private var interruptedCacheTask: Task<Void, Never>?
    @ObservationIgnored private let sessionStore: PlaybackSessionStore?
    @ObservationIgnored private var sessionScope: PlaybackSessionScope?
    @ObservationIgnored private var restoringSession = false
    @ObservationIgnored private var hasSessionState = false
    @ObservationIgnored private var lastSessionWrite = Date.distantPast
    @ObservationIgnored private var queueRevision: UInt64 = 0
    @ObservationIgnored private let resources = PlayerResources()
    @ObservationIgnored private var generation: UInt64 = 0
    private var queueKeys: [UUID] = []
    private var currentKey: UUID?
    private var qqQueueOrigin: QQQueueOrigin?
    // Manually inserted tracks have no position in the paginated source collection.
    private var queueSourceOffsets: [Int?]?
    private var nextTrackKey: UUID?
    @ObservationIgnored private var visited = Set<UUID>()
    @ObservationIgnored private var navigation: [UUID] = []
    @ObservationIgnored private var navigationIndex = -1
    private var wantsToPlay = false
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var restoringSeek = false
    @ObservationIgnored private var resourceAllowsSeeking = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private var preloadRequestID = UUID()
    private var preloadKey: UUID?
    @ObservationIgnored private var lastPreloadAttempt = Date.distantPast
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var historyKey = UUID().uuidString
    @ObservationIgnored private var historyRecorded = false
    @ObservationIgnored private var historyPositionMS: Int64?
    @ObservationIgnored private var lastHistoryAttempt = Date.distantPast
    @ObservationIgnored private(set) var nowPlayingPublicationCount = 0
    @ObservationIgnored private var qqQueueTask: Task<Void, Never>?
    @ObservationIgnored private var qqQueueRequest: QQQueueRequest?

    private struct QQQueueRequest {
        var id = UUID()
        var sourceID: String
        var kind: QQLibraryKind
        var playlistID: String?
        var cursor: QQCollectionCursor
        var startIndex: Int?
        var expectedTrackID: String?
        var playbackRevision: UInt64
        var wasPlaying: Bool
        var expectedTotal: Int64?
        var importedCount = 0
    }

    private typealias QQQueueOrigin = PlaybackQueueOrigin

    public init(client: MusicAPIClient, sessionDirectory: URL? = nil, mediaCache: MediaDiskCache? = nil) {
        self.mediaCache = mediaCache
        self.client = client
        self.sessionStore = sessionDirectory.map { PlaybackSessionStore(directory: $0) }
        resources.player.volume = Float(volume)
    }

    public func updateCacheSources(_ sources: [SourceConnection]) {
        if let origin = radioOrigin,
            !sources.contains(where: {
                $0.id == origin.sourceID && $0.version == origin.connectionVersion && $0.enabled && $0.state == "active"
            })
        {
            cancelPersonalRadio()
            wantsToPlay = false
            clearCurrentMedia(cacheInterruption: false)
            currentTrack = nil
            currentKey = nil
            position = 0
            duration = 0
            replaceQueue([])
        }
        let versions = Dictionary(
            sources.map { ($0.id, "\($0.version):\($0.enabled):\($0.state)") }, uniquingKeysWith: { _, last in last })
        if versions != cacheSources {
            audioCacheTask?.cancel()
            audioCacheTask = nil
        }
        cacheSources = versions
    }

    private func audioNamespace(_ track: LibraryTrack, quality: PlaybackQuality) -> [String]? {
        guard mediaCache != nil, let scope = sessionScope else { return nil }
        let bindings = track.bindings.map {
            "\($0.id):\($0.sourceConnectionID):\($0.sourceTrackID):\(cacheSources[$0.sourceConnectionID] ?? "unknown")"
        }.sorted()
        return [
            scope.server.absoluteString, scope.accountID, track.id, String(track.version),
            "\(quality.rawValue)-audio-v1",
        ]
            + bindings
    }

    private func resolvePlayback(
        _ track: LibraryTrack, quality: PlaybackQuality, allowsFallback: Bool = true
    ) async throws -> ResolvedPlayback {
        let namespace = audioNamespace(track, quality: quality)
        let resource: MediaResource
        do {
            resource = try await client.resolveLibraryTrack(id: track.id, quality: quality.rawValue)
        } catch let error as MusicAPIError where allowsFallback && quality != .standard && error.code == "NO_PLAYBACK" {
            try Task.checkCancellation()
            return try await resolvePlayback(track, quality: .standard, allowsFallback: false)
        }
        let segments: [AudioCacheSegment]
        if let namespace, let mediaCache {
            segments = (try? await mediaCache.audioSegments(namespace: namespace)) ?? []
        } else {
            segments = []
        }
        return ResolvedPlayback(resource: resource, namespace: namespace, segments: segments, quality: quality)
    }

    private func cacheCurrentSong() {
        guard audioCacheTask == nil, let mediaCache, let resource = resources.mediaResource,
            let namespace = resources.cacheNamespace, duration > 0
        else { return }
        let client = client
        let duration = duration
        let token = mediaCache.token()
        audioCacheTask = Task {
            await client.cacheAudioSegment(
                resource, cache: mediaCache, namespace: namespace,
                slot: .prefix, position: 0, duration: duration, token: token)
        }
    }

    private func cacheInterruptedSong() {
        guard let mediaCache, let resource = resources.mediaResource, let namespace = resources.cacheNamespace,
            duration > 0, position > 0.1, position < duration - 0.5
        else { return }
        interruptedCacheTask?.cancel()
        let client = client
        let duration = duration
        let position = lyricPlaybackPosition()
        let token = mediaCache.token()
        interruptedCacheTask = Task {
            async let prefix: Void = client.cacheAudioSegment(
                resource, cache: mediaCache, namespace: namespace,
                slot: .prefix, position: 0, duration: duration, token: token)
            async let interrupted: Void = client.cacheAudioSegment(
                resource, cache: mediaCache, namespace: namespace,
                slot: .interrupted, position: position, duration: duration, token: token)
            _ = await (prefix, interrupted)
        }
    }

    /// Normal termination can finish the interruption segment; forced termination makes no such guarantee.
    public func prepareForTermination() async {
        pause()
        if let task = interruptedCacheTask {
            let timeout = Task {
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled { task.cancel() }
            }
            await task.value
            timeout.cancel()
        }
        flushSession()
    }

    public func configureSession(serverURL: URL, accountID: String) {
        guard let server = try? MusicAPIClient.validateBaseURL(serverURL) else { return }
        let scope = PlaybackSessionScope(server: server, accountID: accountID)
        if sessionScope != scope {
            if sessionScope != nil { stop() }
            sessionScope = scope
        }
    }

    var cachedAudioBytesRead: Int64 { resources.audioAsset?.cachedBytesRead ?? 0 }

    public var currentQueueIndex: Int? {
        currentKey.flatMap { queueKeys.firstIndex(of: $0) }
    }

    func cyclePlaybackMode() {
        guard !isPersonalRadio else { return }
        let next = playbackMode.next
        let shuffle = next == .shuffle
        let repeatMode: PlaybackRepeatMode = next == .repeatOne ? .one : .off
        if shuffleEnabled != shuffle { shuffleEnabled = shuffle }
        if self.repeatMode != repeatMode { self.repeatMode = repeatMode }
    }

    func selectPlaybackQuality(_ quality: PlaybackQuality) async throws {
        try Task.checkCancellation()
        guard let track = currentTrack, let key = currentKey else { return }
        let requestID = UUID()
        qualityRequestID = requestID
        if activeQuality == quality {
            isChangingQuality = false
            guard preferredQuality != quality else { return }
            preferredQuality = quality
            cancelPreload()
            schedulePreload()
            saveSession()
            return
        }
        let expected = generation
        isChangingQuality = true
        defer { if qualityRequestID == requestID { isChangingQuality = false } }
        let resolved = try await resolvePlayback(track, quality: quality, allowsFallback: false)
        try Task.checkCancellation()
        guard generation == expected, qualityRequestID == requestID else { throw CancellationError() }
        let prepared = PreparedPlayback(resolved: resolved, client: client)
        guard try await prepared.asset.load(.isPlayable) else {
            throw MusicAPIError(status: 422, code: "NO_PLAYBACK")
        }
        try Task.checkCancellation()
        guard generation == expected, qualityRequestID == requestID,
              currentKey == key, let index = currentQueueIndex else { throw CancellationError() }
        preferredQuality = quality
        let resumePosition = lyricPlaybackPosition()
        let autoplay = wantsToPlay || isPlaying
        await play(at: index, startAt: resumePosition, recordNavigation: false, autoplay: autoplay, using: prepared)
    }

    /// Resolve exact formats through the existing source adapter without downloading audio
    /// or changing playback. Unknown/transient failures remain unknown, not unavailable.
    func playbackQualityAvailability() async throws -> [PlaybackQuality: Bool] {
        guard let track = currentTrack else { return [:] }
        let scope = sessionScope
        if let cached = qualityAvailabilityCache[track.id], cached.track == track,
            Date().timeIntervalSince(cached.checkedAt) < 300 {
            return cached.values
        }
        var values: [PlaybackQuality: Bool] = [:]
        if let activeQuality { values[activeQuality] = true }
        for quality in PlaybackQuality.allCases where values[quality] == nil {
            try Task.checkCancellation()
            do {
                _ = try await client.resolveLibraryTrack(id: track.id, quality: quality.rawValue)
                values[quality] = true
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MusicAPIError where error.code == "NO_PLAYBACK" {
                values[quality] = false
            } catch {
                // A timeout or expired session is not evidence of a missing format.
            }
            try Task.checkCancellation()
            guard currentTrack?.id == track.id, sessionScope == scope else { throw CancellationError() }
        }
        if values.count == PlaybackQuality.allCases.count {
            if qualityAvailabilityCache.count >= 32,
                let oldest = qualityAvailabilityCache.min(by: { $0.value.checkedAt < $1.value.checkedAt })?.key {
                qualityAvailabilityCache.removeValue(forKey: oldest)
            }
            qualityAvailabilityCache[track.id] = (track, Date(), values)
        }
        return values
    }

    func invalidatePlaybackQualityAvailability() {
        if let track = currentTrack { qualityAvailabilityCache.removeValue(forKey: track.id) }
    }

    var artworkPreloadTracks: [LibraryTrack] {
        guard let index = currentQueueIndex else { return [] }
        let wraps = repeatMode == .all && !isPersonalRadio
        let precedingIndex = index > 0 ? index - 1 : wraps ? queueKeys.count - 1 : -1
        let followingIndex = index + 1 < queueKeys.count ? index + 1 : wraps ? 0 : queueKeys.count
        let shuffles = playbackMode == .shuffle && !isPersonalRadio
        let preceding =
            shuffles && navigationIndex > 0
            ? navigation[navigationIndex - 1]
            : queueKeys.indices.contains(precedingIndex) ? queueKeys[precedingIndex] : nil
        let following =
            shuffles && navigationIndex + 1 < navigation.count
            ? navigation[navigationIndex + 1]
            : queueKeys.indices.contains(followingIndex) ? queueKeys[followingIndex] : nil
        var seen: Set<UUID> = [queueKeys[index]]
        return [nextTrackKey, preloadKey, following, preceding].compactMap { key in
            guard let key, seen.insert(key).inserted, let index = queueKeys.firstIndex(of: key) else { return nil }
            return queue[index]
        }
    }

    public func currentSourceQueueIndex(sourceID: String, kind: QQLibraryKind, playlistID: String?) -> Int? {
        guard qqQueueOrigin == QQQueueOrigin(sourceID: sourceID, kind: kind, playlistID: playlistID) else { return nil }
        guard let index = currentQueueIndex else { return nil }
        return queueSourceOffsets?[index]
    }

    /// A source collection marks the playing occurrence, even when the same song appears twice.
    public func currentSourceRow(
        in tracks: [SourceTrack], sourceID: String, kind: QQLibraryKind, playlistID: String?
    ) -> Int? {
        guard let currentTrack else { return nil }
        let ids = Set(currentTrack.bindings.filter { $0.sourceConnectionID == sourceID }.map(\.sourceTrackID))
        if let index = currentSourceQueueIndex(sourceID: sourceID, kind: kind, playlistID: playlistID) {
            guard tracks.indices.contains(index), ids.contains(tracks[index].id) else {
                return nil
            }
            return index
        }
        return tracks.firstIndex { ids.contains($0.id) }
    }

    public func loadingSourceRow(
        in tracks: [SourceTrack], sourceID: String, kind: QQLibraryKind, playlistID: String?
    ) -> Int? {
        if isPreparingQQQueue, let request = qqQueueRequest, request.sourceID == sourceID,
            request.kind == kind, request.playlistID == playlistID, let index = request.startIndex,
            tracks.indices.contains(index),
            request.expectedTrackID == nil || tracks[index].id == request.expectedTrackID
        {
            return index
        }
        guard isLoading else { return nil }
        return currentSourceRow(in: tracks, sourceID: sourceID, kind: kind, playlistID: playlistID)
    }

    /// A prepared source queue must not replace a newer playback request.
    public var playbackRevision: UInt64 { generation }

    public func play(_ track: LibraryTrack, inQueue tracks: [LibraryTrack]? = nil) async {
        if isPersonalRadio {
            cancelPersonalRadio()
            replaceQueue([])
        }
        if let tracks { setQueue(tracks) }
        if let index = queue.firstIndex(where: { $0.id == track.id }) {
            await play(at: index)
        } else {
            enqueue(track)
            await play(at: queue.count - 1)
        }
    }

    /// Selects an occurrence rather than a song ID, preserving duplicate queue entries.
    public func playQueueItem(at index: Int) async {
        await play(at: index)
    }

    public func setQueue(_ tracks: [LibraryTrack]) {
        cancelPersonalRadio()
        cancelQQQueue()
        replaceQueue(tracks)
    }

    private func replaceQueue(_ tracks: [LibraryTrack]) {
        hasSessionState = true
        queueRevision &+= 1
        cancelPreload()
        queue = tracks
        queueKeys = tracks.map { _ in UUID() }
        nextTrackKey = nil
        currentKey = currentTrack.flatMap { track in
            queue.firstIndex(where: { $0.id == track.id }).map { queueKeys[$0] }
        }
        navigation = currentKey.map { [$0] } ?? []
        navigationIndex = navigation.count - 1
        visited = Set(navigation)
        updateNowPlaying()
        saveSession()
    }

    public func enqueue(_ track: LibraryTrack) {
        if isPersonalRadio {
            cancelPersonalRadio()
            replaceQueue(currentTrack.map { [$0] } ?? [])
        }
        hasSessionState = true
        queueRevision &+= 1
        cancelPreload()
        cancelQQQueue()
        queue.append(track)
        queueKeys.append(UUID())
        updateNowPlaying()
        saveSession()
    }

    public func setNextTrack(_ track: LibraryTrack) {
        if isPersonalRadio { cancelPersonalRadio() }
        if isPreparingQQQueue { cancelQQQueue() }
        hasSessionState = true
        queueRevision &+= 1
        cancelPreload()
        let index = (currentQueueIndex ?? -1) + 1
        if queue.indices.contains(index), queue[index].id == track.id {
            nextTrackKey = queueKeys[index]
        } else {
            let key = UUID()
            queue.insert(track, at: index)
            queueKeys.insert(key, at: index)
            queueSourceOffsets?.insert(nil, at: index)
            nextTrackKey = key
        }
        updateNowPlaying()
        schedulePreload()
        saveSession()
    }

    public func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queueRevision &+= 1
        cancelQQQueue()
        cancelPreload()
        let removedKey = queueKeys.remove(at: index)
        if removedKey == nextTrackKey { nextTrackKey = nil }
        queue.remove(at: index)
        visited.remove(removedKey)
        if removedKey == currentKey {
            clearCurrentMedia()
            currentTrack = nil
            currentKey = nil
            position = 0
            duration = 0
            if !queue.isEmpty {
                let nextIndex = min(index, queue.count - 1)
                Task { [weak self] in await self?.play(at: nextIndex) }
            }
        }
        navigation.removeAll { $0 == removedKey }
        navigationIndex = currentKey.flatMap { navigation.lastIndex(of: $0) } ?? -1
        updateNowPlaying()
        saveSession()
    }

    public func moveInQueue(from indexes: IndexSet, to destination: Int) {
        guard indexes.allSatisfy(queue.indices.contains), (0...queue.count).contains(destination) else { return }
        queueRevision &+= 1
        cancelQQQueue()
        cancelPreload()
        let moving = indexes.sorted().map { (queue[$0], queueKeys[$0]) }
        for index in indexes.sorted(by: >) {
            queue.remove(at: index)
            queueKeys.remove(at: index)
        }
        let insertion = min(max(destination - indexes.filter { $0 < destination }.count, 0), queue.count)
        queue.insert(contentsOf: moving.map(\.0), at: insertion)
        queueKeys.insert(contentsOf: moving.map(\.1), at: insertion)
        updateNowPlaying()
        saveSession()
    }

    public func togglePlayPause() async {
        if wantsToPlay || isPlaying { pause() } else { await resume() }
    }

    public func pause() {
        radioControlRevision &+= 1
        wantsToPlay = false
        resources.player.pause()
        position = lyricPlaybackPosition()
        cacheInterruptedSong()
        cancelPreload()
        if qqQueueRequest?.startIndex != nil { cancelQQQueue() }
        isPlaying = false
        isLoading = false
        saveSession()
        updateNowPlaying()
    }

    public func resume() async {
        if isPersonalRadio, duration > 0, position >= duration - 0.2 {
            await nextPersonalRadio()
            return
        }
        if isPersonalRadio { refillPersonalRadioIfNeeded() }
        guard let track = currentTrack else {
            if !queue.isEmpty { await play(at: 0) }
            return
        }
        if let loadTask {
            wantsToPlay = true
            isLoading = true
            await loadTask.value
            return
        }
        if let item = resources.player.currentItem, item.status != .failed {
            wantsToPlay = true
            error = nil
            if duration > 0, position >= duration - 0.05 {
                seek(to: 0)
            }
            if pendingSeek == nil, !restoringSeek { resources.player.play() }
            updateNowPlaying()
        } else {
            let resumePosition = position
            if currentQueueIndex == nil {
                enqueue(track)
                currentKey = queueKeys.last
            }
            if let index = currentQueueIndex {
                await play(at: index, startAt: resumePosition)
            }
        }
    }

    public func next() async {
        if let nextTrackKey, let index = queueKeys.firstIndex(of: nextTrackKey) {
            await play(at: index)
            return
        }
        if isPersonalRadio {
            await nextPersonalRadio()
            return
        }
        if playbackMode == .shuffle || hasQQGap(direction: 1) || (currentQueueIndex ?? -1) + 1 >= queue.count {
            let expected = generation
            let wasPlaying = isPlaying
            await finishLoadingQQQueue()
            guard generation == expected, isPlaying == wasPlaying else { return }
            if let nextTrackKey, let index = queueKeys.firstIndex(of: nextTrackKey) {
                await play(at: index)
                return
            }
            if qqQueueRequest != nil, playbackMode == .shuffle || (currentQueueIndex ?? -1) + 1 >= queue.count {
                pause()
                return
            }
        }
        if playbackMode == .shuffle, navigationIndex + 1 < navigation.count {
            navigationIndex += 1
            if let index = queueKeys.firstIndex(of: navigation[navigationIndex]) {
                await play(at: index, recordNavigation: false)
                return
            }
        }
        guard !queue.isEmpty else { return }
        if playbackMode == .shuffle {
            var candidates = queueKeys.filter { $0 != currentKey && !visited.contains($0) }
            if candidates.isEmpty, repeatMode == .all {
                visited = Set(currentKey.map { [$0] } ?? [])
                candidates = queueKeys.filter { $0 != currentKey }
                if candidates.isEmpty { candidates = queueKeys }
            }
            let selected = preloadKey.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.randomElement()
            if let key = selected, let index = queueKeys.firstIndex(of: key) {
                await play(at: index)
            } else {
                finishQueue()
            }
        } else {
            let nextIndex = (currentQueueIndex ?? -1) + 1
            if queue.indices.contains(nextIndex) {
                await play(at: nextIndex)
            } else if repeatMode == .all {
                await play(at: 0)
            } else {
                finishQueue()
            }
        }
    }

    public func previous() async {
        if isPersonalRadio {
            if let index = currentQueueIndex, index > 0 { await play(at: index - 1, direction: .backward) }
            return
        }
        if hasQQGap(direction: -1) || (repeatMode == .all && currentQueueIndex == 0) {
            let expected = generation
            let wasPlaying = isPlaying
            await finishLoadingQQQueue()
            guard generation == expected, isPlaying == wasPlaying else { return }
        }
        if playbackMode == .shuffle, navigationIndex > 0,
            let prior = navigation[..<navigationIndex].lastIndex(where: { $0 != currentKey && queueKeys.contains($0) }),
            let index = queueKeys.firstIndex(of: navigation[prior])
        {
            navigationIndex = prior
            await play(at: index, recordNavigation: false, direction: .backward)
            return
        }
        if let index = currentQueueIndex, index > 0 {
            await play(at: index - 1, direction: .backward)
        } else if repeatMode == .all, queue.count > 1 {
            await play(at: queue.count - 1, direction: .backward)
        }
    }

    /// Direct media time for the lyric views and menu bar.
    public func lyricPlaybackPosition() -> Double {
        guard resources.player.currentItem != nil, pendingSeek == nil, !restoringSeek else { return position }
        let time = resources.player.currentTime().seconds
        return time.isFinite ? max(time, 0) : position
    }

    var lyricClockID: ObjectIdentifier { ObjectIdentifier(resources.player) }

    /// A view reads the live clock at cue boundaries and after a seek, independent of slider ticks.
    var lyricPresentationPosition: Double {
        _ = lyricSeekRevision
        return lyricPlaybackPosition()
    }

    func observeLyricBoundaries(_ seconds: [Double], onBoundary: @escaping @MainActor () -> Void) -> () -> Void {
        let player = resources.player
        let times = seconds.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 1_000)) }
        let token = player.addBoundaryTimeObserver(forTimes: times, queue: .main) {
            MainActor.assumeIsolated { onBoundary() }
        }
        return { player.removeTimeObserver(token) }
    }

    public func seek(to seconds: Double) {
        guard canSeek, seconds.isFinite, resources.player.currentItem != nil else { return }
        let target = min(max(seconds, 0), max(duration, 0))
        let expected = generation
        resources.player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] completed in
            Task { @MainActor [weak self] in
                guard let self, completed, self.generation == expected else { return }
                self.position = target
                self.lyricSeekRevision &+= 1
                self.saveSession()
                self.updateNowPlaying()
            }
        }
    }

    /// Restores this account's queue and position from its local checkpoint.
    public func restoreLocalSession() async {
        guard !hasSessionState, currentTrack == nil, queue.isEmpty, !isLoadingPersonalRadio, qqQueueRequest == nil,
            let scope = sessionScope, let sessionStore
        else { return }
        let expected = generation
        let revision = queueRevision
        guard let saved = await sessionStore.load(scope: scope), generation == expected, queueRevision == revision,
            sessionScope == scope, !isLoadingPersonalRadio, !Task.isCancelled
        else { return }
        restoreSession(saved)
    }

    private func restoreSession(_ saved: PlaybackSession) {
        restoringSession = true
        hasSessionState = true
        queueRevision &+= 1
        queue = saved.queue
        queueKeys = saved.keys
        currentKey = saved.currentKey
        nextTrackKey = saved.nextTrackKey
        currentTrack = currentQueueIndex.map { queue[$0] }
        duration = currentTrack == nil ? 0 : saved.duration
        position = currentTrack == nil ? 0 : duration > 0 ? min(saved.position, duration) : saved.position
        navigation = saved.navigation
        navigationIndex = saved.navigationIndex
        visited = saved.visited
        repeatMode = PlaybackRepeatMode(rawValue: saved.repeatMode) ?? .off
        shuffleEnabled = saved.shuffle
        preferredQuality = saved.quality ?? .standard
        volume = saved.volume
        qqQueueOrigin = saved.origin
        queueSourceOffsets = saved.sourceOffsets
        qqQueueTotal = saved.sourceTotal
        radioOrigin = saved.radio
        if let continuation = saved.continuation {
            qqQueueRequest = QQQueueRequest(
                sourceID: continuation.origin.sourceID, kind: continuation.origin.kind,
                playlistID: continuation.origin.playlistID, cursor: continuation.cursor,
                playbackRevision: generation, wasPlaying: false,
                expectedTotal: continuation.expectedTotal, importedCount: continuation.importedCount)
        }
        restoringSession = false
        configureRemoteCommands()
        updateNowPlaying()
        retryQQQueueLoading()
    }

    private func saveSession() {
        guard hasSessionState, !restoringSession, let sessionStore, let scope = sessionScope else { return }
        let continuation: PlaybackQueueContinuation? = qqQueueRequest.flatMap { request in
            guard request.startIndex == nil, let total = request.expectedTotal else { return nil }
            return PlaybackQueueContinuation(
                origin: PlaybackQueueOrigin(
                    sourceID: request.sourceID, kind: request.kind, playlistID: request.playlistID),
                cursor: request.cursor, expectedTotal: total, importedCount: request.importedCount)
        }
        let saved = PlaybackSession(
            queue: queue, keys: queueKeys, currentKey: currentKey,
            position: max(position, 0), duration: max(duration, 0), repeatMode: repeatMode.rawValue,
            shuffle: shuffleEnabled, volume: volume, navigation: navigation, navigationIndex: navigationIndex,
            visited: visited,
            origin: qqQueueOrigin, sourceOffsets: queueSourceOffsets, sourceTotal: qqQueueTotal,
            continuation: continuation, radio: radioOrigin, quality: preferredQuality, nextTrackKey: nextTrackKey)
        sessionStore.save(saved, scope: scope)
        lastSessionWrite = Date()
    }

    /// Called before normal application termination; all earlier ordered writes finish before returning.
    public func flushSession() {
        position = lyricPlaybackPosition()
        saveSession()
        sessionStore?.flush()
    }

    /// Login prepares the restored song and its saved position, while keeping playback paused.
    public func prepareCurrentTrack() async {
        guard !wantsToPlay, !isPlaying, !isLoading, loadTask == nil,
            resources.player.currentItem == nil, qqQueueRequest?.startIndex == nil, let index = currentQueueIndex
        else { return }
        await play(at: index, startAt: position, recordNavigation: false, autoplay: false)
    }

    /// Cancels network work and releases the cookie-bearing asset, observers and remote targets.
    /// The account owner must also clear MusicAPIClient cookies when logging out/changing server.
    public func stop() {
        flushSession()
        qualityAvailabilityCache.removeAll()
        sessionScope = nil
        hasSessionState = false
        queueRevision &+= 1
        cancelPersonalRadio()
        cancelQQQueue()
        interruptedCacheTask?.cancel()
        interruptedCacheTask = nil
        clearCurrentMedia(cacheInterruption: false)
        preferredQuality = .standard
        resources.removeRemoteTargets()
        queue = []
        queueKeys = []
        currentKey = nil
        nextTrackKey = nil
        currentTrack = nil
        navigation = []
        navigationIndex = -1
        visited = []
        position = 0
        duration = 0
        error = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// The player owns source pagination so navigating away cannot truncate the queue.
    public func playQQCollection(
        sourceID: String, kind: QQLibraryKind, playlistID: String?, sessionVersion: Int64,
        startIndex: Int = 0, expectedTrackID: String? = nil
    ) {
        guard kind != .playlists, startIndex >= 0 else { return }
        cancelPersonalRadio()
        queueRevision &+= 1
        cancelQQQueue()
        qqQueueRequest = QQQueueRequest(
            sourceID: sourceID, kind: kind, playlistID: playlistID,
            cursor: QQCollectionCursor(limit: 100, sessionVersion: sessionVersion), startIndex: startIndex,
            expectedTrackID: expectedTrackID, playbackRevision: generation, wasPlaying: isPlaying)
        isPreparingQQQueue = true
        retryQQQueueLoading()
    }

    public func retryQQQueueLoading() {
        guard let request = qqQueueRequest, qqQueueTask == nil else { return }
        isPreparingQQQueue = request.startIndex != nil
        isLoadingQQQueue = true
        qqQueueError = nil
        qqQueueTask = Task { [weak self] in await self?.loadQQQueue(id: request.id) }
    }

    private func loadQQQueue(id: UUID) async {
        defer {
            if qqQueueRequest?.id == id || qqQueueRequest == nil {
                qqQueueTask = nil
                isLoadingQQQueue = false
                isPreparingQQQueue = false
            }
        }
        do {
            while var request = qqQueueRequest, request.id == id, request.cursor.hasMore {
                // Only the selected occurrence is canonicalized on the critical playback path.
                if let index = request.startIndex {
                    let selected = try await client.prepareQQPlaybackPage(
                        sourceID: request.sourceID,
                        input: QQImportPageInput(
                            kind: request.kind, playlistID: request.playlistID, offset: index,
                            limit: 1, sessionVersion: request.cursor.sessionVersion!,
                            selectedTrackID: request.expectedTrackID))
                    try Task.checkCancellation()
                    guard qqQueueRequest?.id == id else { return }
                    guard generation == request.playbackRevision, isPlaying == request.wasPlaying else {
                        cancelQQQueue()
                        return
                    }
                    guard selected.offset == index, selected.limit == 1, selected.items.count == 1,
                        selected.total > index, selected.sessionVersion == request.cursor.sessionVersion,
                        request.expectedTrackID == nil
                            || selected.items[0].bindings.contains(where: {
                                $0.sourceConnectionID == request.sourceID && $0.sourceTrackID == request.expectedTrackID
                            })
                    else { throw MusicAPIError(status: 409, code: "VERSION_CONFLICT") }
                    replaceQueue(selected.items)
                    queueSourceOffsets = [index]
                    qqQueueOrigin = QQQueueOrigin(
                        sourceID: request.sourceID, kind: request.kind, playlistID: request.playlistID)
                    request.startIndex = nil
                    request.expectedTotal = selected.total
                    qqQueueTotal = selected.total
                    qqQueueRequest = request
                    isPreparingQQQueue = false
                    await play(at: 0)
                    guard qqQueueRequest?.id == id else { return }
                    continue
                }
                let page = try await client.prepareQQPlaybackPage(
                    sourceID: request.sourceID,
                    input: QQImportPageInput(
                        kind: request.kind, playlistID: request.playlistID, offset: request.cursor.nextOffset,
                        limit: request.cursor.limit, sessionVersion: request.cursor.sessionVersion!))
                try Task.checkCancellation()
                guard qqQueueRequest?.id == id else { return }
                guard request.expectedTotal == page.total else {
                    throw MusicAPIError(status: 409, code: "VERSION_CONFLICT")
                }
                try request.cursor.accept(
                    offset: page.offset, limit: page.limit, total: page.total, hasMore: page.hasMore,
                    sessionVersion: page.sessionVersion, count: page.items.count)
                try mergeQQPage(page, startIndex: request.importedCount)
                request.importedCount += page.items.count
                qqQueueRequest = request
                guard qqQueueRequest?.id == id else { return }
                if !request.cursor.hasMore { qqQueueRequest = nil }
                saveSession()
            }
        } catch {
            guard !Task.isCancelled, qqQueueRequest?.id == id else { return }
            qqQueueError = error.localizedDescription
            if qqQueueRequest?.startIndex != nil { self.error = error.localizedDescription }
        }
    }

    private func mergeQQPage(_ page: QQPlaybackPage, startIndex: Int) throws {
        guard let offsets = queueSourceOffsets else { return }
        typealias Entry = (track: LibraryTrack, key: UUID, offset: Int?)
        var entries: [Int: Entry] = [:]
        var ordered: [Entry] = []
        var insertedAfter: [Int: [Entry]] = [:]
        var precedingOffset: Int?
        for (index, offset) in offsets.enumerated() {
            let entry = (queue[index], queueKeys[index], offset)
            if let offset {
                entries[offset] = entry
                precedingOffset = offset
            } else if let precedingOffset {
                insertedAfter[precedingOffset, default: []].append(entry)
            } else {
                ordered.append(entry)
            }
        }
        for (index, track) in page.items.enumerated() {
            let offset = startIndex + index
            if let existing = entries[offset] {
                guard existing.track.id == track.id else {
                    throw MusicAPIError(status: 409, code: "VERSION_CONFLICT")
                }
            } else {
                entries[offset] = (track, UUID(), offset)
            }
        }
        for (offset, entry) in entries.sorted(by: { $0.key < $1.key }) {
            ordered.append(entry)
            ordered.append(contentsOf: insertedAfter[offset] ?? [])
        }
        queueRevision &+= 1
        queueSourceOffsets = ordered.map(\.offset)
        queue = ordered.map(\.track)
        queueKeys = ordered.map(\.key)
        updateNowPlaying()
        schedulePreload()
    }

    private func hasQQGap(direction: Int) -> Bool {
        guard qqQueueRequest != nil, let offsets = queueSourceOffsets, let index = currentQueueIndex else {
            return false
        }
        let adjacent = index + direction
        if offsets.indices.contains(adjacent), offsets[adjacent] == nil { return false }
        let anchor =
            offsets[index]
            ?? (direction > 0
                ? offsets[..<index].reversed().lazy.compactMap { $0 }.first ?? -1
                : offsets.dropFirst(index + 1).lazy.compactMap { $0 }.first ?? Int(qqQueueTotal))
        let expected = anchor + direction
        guard expected >= 0, Int64(expected) < qqQueueTotal else { return false }
        return !offsets.indices.contains(adjacent) || offsets[adjacent] != expected
    }

    private func finishLoadingQQQueue() async {
        guard qqQueueRequest != nil else { return }
        retryQQQueueLoading()
        await qqQueueTask?.value
    }

    private func cancelQQQueue() {
        qqQueueTask?.cancel()
        qqQueueTask = nil
        qqQueueRequest = nil
        qqQueueOrigin = nil
        queueSourceOffsets = nil
        isLoadingQQQueue = false
        isPreparingQQQueue = false
        qqQueueError = nil
        qqQueueTotal = 0
    }

    public func startPersonalRadio(sourceID: String, connectionVersion: Int64, preview: SourceDiscovery? = nil) async {
        if let origin = radioOrigin, origin.sourceID == sourceID, origin.connectionVersion == connectionVersion {
            await resume()
            return
        }
        cancelPersonalRadio()
        let id = UUID()
        radioRequestID = id
        let expected = generation
        let controlRevision = radioControlRevision
        isLoadingPersonalRadio = true
        let origin = PersonalRadioOrigin(sourceID: sourceID, connectionVersion: connectionVersion, sessionVersion: 0)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.radioRequestID == id {
                    self.radioTask = nil
                    self.isLoadingPersonalRadio = false
                }
            }
            do {
                let (tracks, version) = try await self.personalRadioBatch(origin: origin, preview: preview)
                guard self.radioRequestID == id, self.generation == expected,
                    self.radioControlRevision == controlRevision, !Task.isCancelled
                else { return }
                self.cancelQQQueue()
                self.replaceQueue(tracks)
                var connected = origin
                connected.sessionVersion = version
                self.radioOrigin = connected
                await self.play(at: 0)
            } catch {
                guard self.radioRequestID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
        radioTask = task
        await task.value
        if radioRequestID == id, error == nil { refillPersonalRadioIfNeeded() }
    }

    public func waitForPersonalRadioBatch() async { await radioTask?.value }

    private func personalRadioBatch(origin: PersonalRadioOrigin, preview: SourceDiscovery? = nil) async throws -> (
        [LibraryTrack], Int64
    ) {
        let page: SourceDiscovery
        if let preview {
            page = preview
        } else {
            page = try await client.discoverSource(id: origin.sourceID, mode: .guessLike, limit: 20)
        }
        guard let version = page.sessionVersion, version > 0,
            origin.sessionVersion == 0 || origin.sessionVersion == version,
            !page.tracks.isEmpty, page.tracks.count <= 20, !page.hasMore
        else { throw MusicAPIError(status: 409, code: "VERSION_CONFLICT") }
        let existing = radioOrigin?.id == origin.id ? Set(queue.map(\.id)) : []
        let existingSourceIDs =
            radioOrigin?.id == origin.id
            ? Set(queue.flatMap(\.bindings).filter { $0.sourceConnectionID == origin.sourceID }.map(\.sourceTrackID))
            : []
        let candidates = page.tracks.filter { !existingSourceIDs.contains($0.id) }
        guard !candidates.isEmpty else { throw MusicAPIError(status: 502, code: "SOURCE_UNAVAILABLE") }
        let current = try await client.getSource(id: origin.sourceID)
        guard current.version == origin.connectionVersion, current.enabled, current.state == "active",
            current.kind == "qq",
            sessionScope == nil || current.ownerID == sessionScope?.accountID
        else { throw MusicAPIError(status: 409, code: "VERSION_CONFLICT") }
        let imported = try await client.importSourceQueue(sourceID: origin.sourceID, tracks: candidates)
        try Task.checkCancellation()
        let checked = try await client.getSource(id: origin.sourceID)
        guard checked.version == origin.connectionVersion, checked.enabled, checked.state == "active" else {
            throw MusicAPIError(status: 409, code: "VERSION_CONFLICT")
        }
        let unique = imported.filter { !existing.contains($0.id) }
        guard !unique.isEmpty else { throw MusicAPIError(status: 502, code: "SOURCE_UNAVAILABLE") }
        return (unique, version)
    }

    private func refillPersonalRadioIfNeeded() {
        guard let origin = radioOrigin, let index = currentQueueIndex, index == queue.count - 1, radioTask == nil else {
            return
        }
        let id = radioRequestID
        isLoadingPersonalRadio = true
        radioTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.radioRequestID == id {
                    self.radioTask = nil
                    self.isLoadingPersonalRadio = false
                }
            }
            do {
                let (tracks, _) = try await self.personalRadioBatch(origin: origin)
                guard self.radioRequestID == id, self.radioOrigin?.id == origin.id, !Task.isCancelled,
                    let current = self.currentQueueIndex
                else { return }
                let seen = Set(self.queue.map(\.id))
                let available = max(0, 20 - (self.queue.count - current - 1))
                let appended = Array(tracks.filter { !seen.contains($0.id) }.prefix(available))
                guard !appended.isEmpty else { return }
                self.queue.append(contentsOf: appended)
                self.queueKeys.append(contentsOf: appended.map { _ in UUID() })
                self.queueRevision &+= 1
                self.trimPersonalRadioWindow()
                self.saveSession()
                self.schedulePreload()
            } catch {
                guard self.radioRequestID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func nextPersonalRadio() async {
        guard let index = currentQueueIndex else { return }
        let expected = generation
        let controlRevision = radioControlRevision
        if index == queue.count - 1 {
            refillPersonalRadioIfNeeded()
            await radioTask?.value
        }
        guard isPersonalRadio, generation == expected, radioControlRevision == controlRevision,
            let current = currentQueueIndex
        else { return }
        if queue.indices.contains(current + 1) { await play(at: current + 1) } else { pause() }
    }

    private func trimPersonalRadioWindow() {
        guard let index = currentQueueIndex else { return }
        let lower = max(0, index - 10)
        let upper = min(queue.count, index + 21)
        guard lower > 0 || upper < queue.count else { return }
        queue = Array(queue[lower..<upper])
        queueKeys = Array(queueKeys[lower..<upper])
        let kept = Set(queueKeys)
        visited.formIntersection(kept)
        navigation.removeAll { !kept.contains($0) }
        navigationIndex = currentKey.flatMap { navigation.lastIndex(of: $0) } ?? -1
        queueRevision &+= 1
    }

    private func cancelPersonalRadio() {
        radioRequestID = UUID()
        radioTask?.cancel()
        radioTask = nil
        radioOrigin = nil
        isLoadingPersonalRadio = false
    }

    private func play(
        at index: Int, startAt: Double = 0, recordNavigation: Bool = true, autoplay: Bool = true,
        direction: PlaybackArtworkDirection = .forward, using replacement: PreparedPlayback? = nil
    ) async {
        guard queue.indices.contains(index) else { return }
        let prepared = replacement ?? takePrepared(for: queueKeys[index])
        clearCurrentMedia()
        let expected = generation
        let track = queue[index]
        artworkDirection = direction
        currentTrack = track
        currentKey = queueKeys[index]
        if currentKey == nextTrackKey { nextTrackKey = nil }
        if isPersonalRadio { trimPersonalRadioWindow() }
        if let currentKey {
            visited.insert(currentKey)
            if recordNavigation {
                navigation = Array(navigation.prefix(navigationIndex + 1))
                navigation.append(currentKey)
                if navigation.count > 256 { navigation.removeFirst(navigation.count - 256) }
                navigationIndex = navigation.count - 1
            }
        }
        position = max(startAt, 0)
        duration = max(Double(track.durationMS) / 1_000, 0)
        error = nil
        isLoading = true
        wantsToPlay = autoplay
        pendingSeek = startAt > 0 ? startAt : nil
        historyKey = UUID().uuidString
        historyRecorded = false
        historyPositionMS = nil
        lastHistoryAttempt = .distantPast
        configureRemoteCommands()
        updateNowPlaying()
        saveSession()
        if autoplay, isPersonalRadio { refillPersonalRadioIfNeeded() }
        if let prepared {
            activeQuality = prepared.quality
            resources.player = prepared.player
            resources.asset = prepared.asset
            resources.mediaResource = prepared.resource
            resources.audioAsset = prepared.audioAsset
            resources.cacheNamespace = prepared.cacheNamespace
            resources.player.isMuted = false
            resources.player.volume = Float(volume)
            resourceAllowsSeeking = prepared.canSeek
            installPlayerObservers()
            observeItem(prepared.item, generation: expected)
            return
        }
        installPlayerObservers()
        let quality = preferredQuality
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.resolvePlayback(track, quality: quality)
                guard self.generation == expected, !Task.isCancelled else { return }
                let resource = resolved.resource
                // MusicAPIClient validates same-origin /api/v1/ media routes before constructing this value.
                // Public AVFoundation cookie support keeps credentials out of URLs and custom headers.
                let audioAsset =
                    resource.canSeek
                    ? CachedAudioAsset(resource: resource, segments: resolved.segments, client: self.client) : nil
                let asset =
                    audioAsset?.asset
                    ?? AVURLAsset(
                        url: resource.url,
                        options: [
                            AVURLAssetHTTPCookiesKey: resource.cookies,
                            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
                        ])
                self.resources.asset = asset
                self.resources.mediaResource = resource
                self.resources.audioAsset = audioAsset
                self.resources.cacheNamespace = resolved.namespace
                self.activeQuality = resolved.quality
                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 20
                self.resourceAllowsSeeking = resource.canSeek
                self.resources.player.replaceCurrentItem(with: item)
                self.observeItem(item, generation: expected)
            } catch {
                guard self.generation == expected, !Task.isCancelled else { return }
                self.failPlayback(error)
            }
        }
        loadTask = task
        await task.value
        if generation == expected { loadTask = nil }
    }

    /// Keep only the next occurrence warm, close enough to the end that short-lived URLs remain valid.
    private func schedulePreload() {
        guard isPlaying, duration > 0, duration - position <= 30,
            nextTrackKey != nil || !hasQQGap(direction: 1),
            let currentIndex = currentQueueIndex
        else { return }
        let key: UUID?
        if let nextTrackKey {
            key = nextTrackKey
        } else if playbackMode == .repeatOne && !isPersonalRadio {
            key = currentKey
        } else if playbackMode == .shuffle && !isPersonalRadio && navigationIndex + 1 < navigation.count {
            key = navigation[navigationIndex + 1]
        } else if playbackMode == .shuffle && !isPersonalRadio {
            guard qqQueueRequest == nil else { return }
            var candidates = queueKeys.filter { $0 != currentKey && !visited.contains($0) }
            if candidates.isEmpty, repeatMode == .all {
                candidates = queueKeys.filter { $0 != currentKey }
                if candidates.isEmpty { candidates = queueKeys }
            }
            key = preloadKey.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.randomElement()
        } else if queueKeys.indices.contains(currentIndex + 1) {
            key = queueKeys[currentIndex + 1]
        } else {
            key = repeatMode == .all && qqQueueRequest == nil && !isPersonalRadio ? queueKeys.first : nil
        }
        guard let key, let index = queueKeys.firstIndex(of: key) else { return }
        if preloadKey == key {
            if preloadTask != nil { return }
            if let prepared = resources.prepared, prepared.expiresAt > Date().addingTimeInterval(5),
                prepared.item.status != .failed
            {
                return
            }
            if Date().timeIntervalSince(lastPreloadAttempt) < 10 { return }
        }
        cancelPreload()
        preloadKey = key
        lastPreloadAttempt = Date()
        let requestID = preloadRequestID
        let track = queue[index]
        let quality = preferredQuality
        preloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.preloadRequestID == requestID { self.preloadTask = nil } }
            do {
                let resolved = try await self.resolvePlayback(track, quality: quality)
                try Task.checkCancellation()
                guard self.preloadRequestID == requestID else { return }
                let prepared = PreparedPlayback(resolved: resolved, client: self.client)
                self.resources.prepared = prepared
                prepared.observation = prepared.player.observe(\.status, options: [.initial, .new]) {
                    [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.preloadRequestID == requestID,
                            let prepared = self.resources.prepared, !prepared.didPreroll,
                            prepared.player.status == .readyToPlay
                        else { return }
                        prepared.didPreroll = true
                        prepared.player.preroll(atRate: 1)
                    }
                }
            } catch {
                // Speculation must never interrupt or report an error over the current song.
                if self.preloadRequestID == requestID { self.resources.clearPrepared() }
            }
        }
    }

    private func cancelPreload() {
        preloadRequestID = UUID()
        preloadTask?.cancel()
        preloadTask = nil
        preloadKey = nil
        resources.clearPrepared()
    }

    private func takePrepared(for key: UUID) -> PreparedPlayback? {
        guard preloadKey == key, let prepared = resources.prepared,
            prepared.expiresAt > Date().addingTimeInterval(5), prepared.item.status != .failed
        else { return nil }
        prepared.observation?.invalidate()
        prepared.observation = nil
        prepared.player.cancelPendingPrerolls()
        resources.prepared = nil
        return prepared
    }

    private func clearCurrentMedia(cacheInterruption: Bool = true) {
        qualityRequestID = UUID()
        if cacheInterruption { cacheInterruptedSong() }
        recoveringCachedPlayback = false
        audioCacheTask?.cancel()
        audioCacheTask = nil
        cancelPreload()
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        historyTask?.cancel()
        historyTask = nil
        resources.clearPlayback()
        wantsToPlay = false
        isPlaying = false
        isLoading = false
        isChangingQuality = false
        activeQuality = nil
        playbackNotice = nil
        canSeek = false
        pendingSeek = nil
        restoringSeek = false
        resourceAllowsSeeking = false
    }

    private func installPlayerObservers() {
        resources.timeObserver = resources.player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        resources.playerObservation = resources.player.observe(\.timeControlStatus, options: [.new]) {
            [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updatePlayerState() }
        }
    }

    private func observeItem(_ item: AVPlayerItem, generation expected: UInt64) {
        resources.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                self.updateItemStatus()
            }
        }
        resources.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                self.position = self.duration
                if self.nextTrackKey == nil, !self.isPersonalRadio, self.playbackMode == .repeatOne,
                    let index = self.currentQueueIndex
                {
                    await self.play(at: index, recordNavigation: false)
                } else {
                    await self.next()
                }
            }
        }
        resources.failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                self.failPlayback(nil)
            }
        }
    }

    private func updateItemStatus() {
        guard let item = resources.player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            refreshDuration()
            isLoading = false
            canSeek = resourceAllowsSeeking && duration > 0
            if let target = pendingSeek {
                pendingSeek = nil
                if canSeek {
                    let expected = generation
                    restoringSeek = true
                    resources.player.seek(
                        to: CMTime(seconds: min(target, duration), preferredTimescale: 600), toleranceBefore: .zero,
                        toleranceAfter: .zero
                    ) { [weak self] completed in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == expected else { return }
                            self.restoringSeek = false
                            if completed {
                                self.position = min(target, self.duration)
                                self.lyricSeekRevision &+= 1
                                self.startOrPrebufferCurrentTrack()
                            }
                        }
                    }
                } else {
                    position = 0
                    playbackNotice = "此音源暂不支持从指定位置恢复，将从头播放。"
                    saveSession()
                    startOrPrebufferCurrentTrack()
                }
            } else {
                startOrPrebufferCurrentTrack()
            }
        case .failed:
            failPlayback(nil)
        case .unknown:
            isLoading = wantsToPlay
        @unknown default:
            failPlayback(nil)
        }
        updateNowPlaying()
    }

    private func startOrPrebufferCurrentTrack() {
        if wantsToPlay {
            resources.player.play()
        } else {
            resources.player.preroll(atRate: 1)
        }
    }

    private func updatePlayerState() {
        let wasPlaying = isPlaying
        let playing = resources.player.timeControlStatus == .playing
        let loading = wantsToPlay && resources.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let changed = playing != isPlaying || loading != isLoading
        if isPlaying != playing { isPlaying = playing }
        if isLoading != loading { isLoading = loading }
        if wasPlaying, resources.player.timeControlStatus == .paused {
            position = lyricPlaybackPosition()
            cacheInterruptedSong()
            saveSession()
        }
        if isLoading { cancelPreload() }
        if isPlaying {
            schedulePreload()
            cacheCurrentSong()
        }
        // The system advances elapsed time from playback rate; republishing the full dictionary each tick
        // does unnecessary IPC and also invalidates command/Control Centre observers four times per second.
        if changed { updateNowPlaying() }
    }

    private func tick() {
        schedulePreload()
        guard resources.player.currentItem != nil else { return }
        let seconds = resources.player.currentTime().seconds
        if seconds.isFinite, pendingSeek == nil, !restoringSeek { position = max(seconds, 0) }
        refreshDuration()
        updatePlayerState()
        if Date().timeIntervalSince(lastSessionWrite) >= 5 { saveSession() }
        if isPlaying, position > 0.1 { recordHistoryIfNeeded() }
    }

    private func refreshDuration() {
        if let value = resources.player.currentItem?.duration.seconds, value.isFinite, value > 0, duration != value {
            duration = value
        }
        let seeking = resourceAllowsSeeking && duration > 0 && resources.player.currentItem?.status == .readyToPlay
        if canSeek != seeking { canSeek = seeking }
    }

    private func recordHistoryIfNeeded() {
        guard !historyRecorded, historyTask == nil, Date().timeIntervalSince(lastHistoryAttempt) >= 10,
            let track = currentTrack
        else { return }
        let expected = generation
        let key = historyKey
        if historyPositionMS == nil { historyPositionMS = milliseconds(position) }
        let positionMS = historyPositionMS ?? 0
        lastHistoryAttempt = Date()
        historyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == expected { self.historyTask = nil } }
            do {
                _ = try await self.client.addHistory(trackID: track.id, positionMS: positionMS, idempotencyKey: key)
                guard self.generation == expected, !Task.isCancelled else { return }
                self.historyRecorded = true
            } catch {
                // A later playback tick can retry recording history.
            }
        }
    }

    private func finishQueue() {
        cancelPreload()
        wantsToPlay = false
        resources.player.pause()
        position = lyricPlaybackPosition()
        isPlaying = false
        isLoading = false
        saveSession()
        updateNowPlaying()
    }

    private func failPlayback(_ failure: Error?) {
        if resources.audioAsset != nil, let namespace = resources.cacheNamespace,
            let mediaCache, let index = currentQueueIndex
        {
            guard !recoveringCachedPlayback else { return }
            recoveringCachedPlayback = true
            let expected = generation
            Task { @MainActor [weak self] in
                try? await mediaCache.invalidateAudio(namespace: namespace)
                guard let self, self.generation == expected else { return }
                self.recoveringCachedPlayback = false
                await self.play(at: index, startAt: self.position, recordNavigation: false, autoplay: self.wantsToPlay)
            }
            return
        }
        cacheInterruptedSong()
        cancelPreload()
        wantsToPlay = false
        resources.player.pause()
        isPlaying = false
        isLoading = false
        canSeek = false
        if let failure = failure as? MusicAPIError, failure.status == 401 {
            error = "登录已过期，请重新登录后播放。"
        } else {
            error = "无法播放此歌曲，请检查音源连接和播放权限后重试。"
        }
        updateNowPlaying()
    }

    private func milliseconds(_ seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        return Int64(min(max(seconds * 1_000, 0), Double(Int64.max - 1_024)))
    }

    private func configureRemoteCommands() {
        guard resources.remoteTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        resources.addRemote(center.playCommand) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.resume() }
            return .success
        }
        resources.addRemote(center.pauseCommand) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        resources.addRemote(center.togglePlayPauseCommand) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.togglePlayPause() }
            return .success
        }
        resources.addRemote(center.nextTrackCommand) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.next() }
            return .success
        }
        resources.addRemote(center.previousTrackCommand) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.previous() }
            return .success
        }
        resources.addRemote(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor [weak self] in self?.seek(to: seconds) }
            return .success
        }
    }

    private func updateNowPlaying() {
        nowPlayingPublicationCount += 1
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artists.joined(separator: ", "),
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        let commands = MPRemoteCommandCenter.shared()
        commands.changePlaybackPositionCommand.isEnabled = canSeek
        commands.nextTrackCommand.isEnabled = queue.count > 1 || repeatMode == .all
        commands.previousTrackCommand.isEnabled = !queue.isEmpty
    }
}

/// AVFoundation observers must be removed from the player that created them.
/// Mutation is confined to PlaybackController's main actor; deinit performs thread-safe teardown.
private final class PlayerResources: @unchecked Sendable {
    var player = AVPlayer()
    var prepared: PreparedPlayback?
    var mediaResource: MediaResource?
    var audioAsset: CachedAudioAsset?
    var cacheNamespace: [String]?
    var asset: AVURLAsset?
    var timeObserver: Any?
    var playerObservation: NSKeyValueObservation?
    var itemObservation: NSKeyValueObservation?
    var endObserver: NSObjectProtocol?
    var failureObserver: NSObjectProtocol?
    var remoteTargets: [(MPRemoteCommand, Any)] = []

    func clearPrepared() {
        prepared?.observation?.invalidate()
        prepared?.player.cancelPendingPrerolls()
        prepared?.player.pause()
        prepared?.asset.cancelLoading()
        prepared?.player.replaceCurrentItem(with: nil)
        prepared = nil
    }

    func clearPlayback() {
        itemObservation?.invalidate()
        itemObservation = nil
        playerObservation?.invalidate()
        playerObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.pause()
        asset?.cancelLoading()
        asset = nil
        player.replaceCurrentItem(with: nil)
        mediaResource = nil
        audioAsset?.cancel()
        audioAsset = nil
        cacheNamespace = nil
    }

    func addRemote(
        _ command: MPRemoteCommand, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        remoteTargets.append((command, command.addTarget(handler: handler)))
    }

    func removeRemoteTargets() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets = []
    }

    deinit {
        clearPrepared()
        clearPlayback()
        removeRemoteTargets()
    }
}

private struct ResolvedPlayback {
    let resource: MediaResource
    let namespace: [String]?
    let segments: [AudioCacheSegment]
    let quality: PlaybackQuality
}

/// A paused standby player retains its own buffered item when promoted to the active player.
private final class PreparedPlayback: @unchecked Sendable {
    let resource: MediaResource
    let quality: PlaybackQuality
    let cacheNamespace: [String]?
    let audioAsset: CachedAudioAsset?
    let asset: AVURLAsset
    let item: AVPlayerItem
    let player: AVPlayer
    let canSeek: Bool
    let expiresAt: Date
    var observation: NSKeyValueObservation?
    var didPreroll = false

    init(resolved: ResolvedPlayback, client: MusicAPIClient) {
        let resource = resolved.resource
        self.resource = resource
        quality = resolved.quality
        cacheNamespace = resolved.namespace
        audioAsset =
            resource.canSeek ? CachedAudioAsset(resource: resource, segments: resolved.segments, client: client) : nil
        asset =
            audioAsset?.asset
            ?? AVURLAsset(
                url: resource.url,
                options: [
                    AVURLAssetHTTPCookiesKey: resource.cookies,
                    AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
                ])
        item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 20
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        canSeek = resource.canSeek
        expiresAt = resource.expiresAt ?? Date().addingTimeInterval(60)
    }
}
