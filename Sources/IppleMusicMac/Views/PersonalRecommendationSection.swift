import MusicCore
import SwiftUI

struct PersonalRecommendationSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workspaceIsActive) private var workspaceIsActive
    let source: SourceConnection
    let mode: DiscoveryMode
    var onOpenDaily: ([SourceTrack]) -> Void = { _ in }
    var onDailyInvalidated: () -> Void = {}
    @State private var page: SourceDiscovery?
    @State private var failure: String?
    @State private var revision = 0
    @State private var dateKey = QQRecommendationDay.key()
    @State private var preparing = false
    @State private var playingArtwork: RecommendationArtworkSnapshot?
    @State private var previewArtwork: RecommendationArtworkSnapshot?
    private var title: String { mode == .daily ? "每日推荐" : "猜你喜欢" }
    private var identity: String {
        "\(store.user?.id ?? ""):\(source.id):\(source.version):\(revision):\(mode == .daily ? dateKey : "batch"):\(store.mediaCache.token())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: open) {
                    artwork
                }.buttonStyle(.plain).disabled(page == nil || preparing)
                coverControl.padding(12)
            }
            .frame(width: DiscoveryCardMetrics.recommendationWidth, height: DiscoveryCardMetrics.coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Button(action: open) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).disabled(page == nil || preparing)
                .accessibilityIdentifier("discovery.\(mode.rawValue).title")
        }
        .frame(width: DiscoveryCardMetrics.recommendationWidth, alignment: .topLeading)
        .task(id: identity) { await load() }
        .task(id: playingArtworkIdentity) { await updatePlayingArtwork() }
        .task {
            guard mode == .daily else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(max(1, QQRecommendationDay.nextBoundary().timeIntervalSinceNow)))
                    onDailyInvalidated()
                    dateKey = QQRecommendationDay.key()
                } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, mode == .daily {
                let today = QQRecommendationDay.key()
                if today != dateKey {
                    onDailyInvalidated()
                    dateKey = today
                }
            }
        }
    }

    private var playingTrackID: String? {
        guard workspaceIsActive, isCurrent else { return nil }
        return store.player.currentTrack?.bindings.first {
            $0.sourceConnectionID == source.id && $0.confirmed
        }?.sourceTrackID
    }

    private var playingNextTrackID: String? {
        let player = store.player
        guard playingTrackID != nil, let index = player.currentQueueIndex else { return nil }
        let nextIndex = index + 1
        let next =
            player.queue.indices.contains(nextIndex)
            ? player.queue[nextIndex]
            : mode == .daily && player.repeatMode == .all && player.queue.count > 1 ? player.queue.first : nil
        return next?.bindings.first {
            $0.sourceConnectionID == source.id && $0.confirmed
        }?.sourceTrackID
    }

    private var playingArtworkIdentity: String? {
        guard let trackID = playingTrackID else { return nil }
        return
            "\(store.user?.id ?? ""):\(source.id):\(source.version):\(trackID):\(playingNextTrackID ?? ""):\(store.mediaCache.token())"
    }

    private func metadata(for trackID: String?) async -> SourceTrack? {
        guard let trackID else { return nil }
        if let known = playingArtwork?.current.track, known.id == trackID { return known }
        if let known = playingArtwork?.next?.track, known.id == trackID { return known }
        if mode == .guessLike, let cached = store.cachedRadioArtwork(from: source) {
            if cached.current.id == trackID { return cached.current }
            if cached.next?.id == trackID { return cached.next }
        }
        if let known = page?.tracks.first(where: { $0.id == trackID }) { return known }
        return try? await store.api.sourceTrack(id: source.id, resourceID: trackID)
    }

    private func coverImage(for track: SourceTrack?) async -> DecodedCoverBitmap? {
        guard let coverID = track?.coverID, !coverID.isEmpty else { return nil }
        return await store.coverImage(sourceID: source.id, coverID: coverID, maximumPixelSize: 640)
    }

    private func preparedArtwork(
        current: SourceTrack, next: SourceTrack?, movesBackward: Bool = false
    ) async -> RecommendationArtworkSnapshot {
        async let currentImage = coverImage(for: current)
        async let nextImage = coverImage(for: next)
        let (front, back) = await (currentImage, nextImage)
        return RecommendationArtworkSnapshot(
            current: RecommendationArtworkItem(track: current, image: front),
            next: next.map { RecommendationArtworkItem(track: $0, image: back) },
            movesBackward: movesBackward)
    }

    private func updatePlayingArtwork() async {
        guard let requestedIdentity = playingArtworkIdentity, let trackID = playingTrackID else { return }
        let nextID = playingNextTrackID
        let movesBackward = store.player.artworkDirection == .backward
        async let front = metadata(for: trackID)
        async let back = metadata(for: nextID)
        let (current, next) = await (front, back)
        guard let current, current.id == trackID, !Task.isCancelled else { return }
        let nextTrack = next?.id == nextID ? next : nil
        let prepared = await preparedArtwork(current: current, next: nextTrack, movesBackward: movesBackward)
        guard !Task.isCancelled, playingArtworkIdentity == requestedIdentity else { return }
        // Other playback leaves this snapshot intact and never starts artwork requests.
        playingArtwork = prepared
        if mode == .guessLike { store.rememberRadioArtwork(from: source, current: current, next: nextTrack) }
    }

    private var isCurrent: Bool {
        guard let current = store.player.currentTrack else { return false }
        if mode == .guessLike {
            return store.player.isPersonalRadio && current.bindings.contains { $0.sourceConnectionID == source.id }
        }
        guard !store.player.isPersonalRadio, let tracks = page?.tracks, store.player.queue.count == tracks.count else {
            return false
        }
        return zip(store.player.queue, tracks).allSatisfy { item, track in
            item.bindings.contains { $0.sourceConnectionID == source.id && $0.sourceTrackID == track.id }
        }
    }

    private var badge: String {
        guard mode == .daily else { return "为你推荐" }
        let pieces = dateKey.split(separator: "-")
        guard pieces.count == 3, let month = Int(pieces[1]), let day = Int(pieces[2]) else { return "今日精选" }
        return "\(month) 月 \(day) 日"
    }

    private var artwork: some View {
        RecommendationArtworkScene(
            snapshot: mode == .guessLike || isCurrent ? playingArtwork ?? previewArtwork : previewArtwork,
            badge: badge, symbol: mode == .daily ? "calendar" : "sparkles",
            animates: isCurrent, isActive: workspaceIsActive
        )
        .frame(width: DiscoveryCardMetrics.recommendationWidth, height: DiscoveryCardMetrics.coverSize)
        .contentShape(Rectangle())
        .accessibilityLabel(mode == .daily ? "查看每日推荐" : "播放猜你喜欢")
    }

    private var coverControl: some View {
        Button {
            if failure != nil {
                revision += 1
            } else if isCurrent {
                Task { await store.player.togglePlayPause() }
            } else {
                play()
            }
        } label: {
            Group {
                if preparing || page == nil && failure == nil {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(
                        systemName: failure != nil
                            ? "arrow.clockwise" : isCurrent && store.player.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .font(.system(size: 18, weight: .semibold))
                }
            }
            .foregroundStyle(.white).frame(width: 42, height: 42)
            .background {
                Circle().fill(.ultraThinMaterial)
                    .opacity(0.82)
                    .overlay { Circle().fill(.black.opacity(0.22)) }
                    .environment(\.colorScheme, .dark)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(preparing || page == nil && failure == nil)
        .help(failure ?? (isCurrent ? store.player.isPlaying ? "暂停" : "继续播放" : mode == .daily ? "播放全部" : "播放猜你喜欢"))
        .accessibilityLabel(
            failure != nil
                ? "重试" : isCurrent ? store.player.isPlaying ? "暂停" : "继续播放" : mode == .daily ? "播放全部" : "播放猜你喜欢"
        )
        .accessibilityIdentifier("discovery.\(mode.rawValue).play-all")
    }

    private func open() {
        if mode == .daily { prepareDaily(openPage: true) } else { play() }
    }

    private func play() {
        guard page != nil, !preparing else { return }
        if mode == .daily {
            prepareDaily(openPage: false)
            return
        }
        Task {
            preparing = true
            defer { preparing = false }
            await store.playPersonalRadio(from: source)
        }
    }

    private func prepareDaily(openPage: Bool) {
        guard page != nil, !preparing else { return }
        let account = store.user?.id
        let playbackRevision = store.player.playbackRevision
        let wasPlaying = store.player.isPlaying
        Task {
            preparing = true
            defer { preparing = false }
            do {
                let result = try await store.dailyRecommendations(from: source)
                guard account == store.user?.id, !Task.isCancelled else { return }
                page = result
                if openPage {
                    onOpenDaily(result.tracks)
                } else if store.player.playbackRevision == playbackRevision, store.player.isPlaying == wasPlaying {
                    await store.playRecommendations(result.tracks, from: source)
                }
            } catch {
                guard account == store.user?.id, !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }

    private func load() async {
        page = nil
        failure = nil
        let account = store.user?.id
        do {
            let result = try await store.recommendationPreview(from: source, mode: mode)
            try Task.checkCancellation()
            guard account == store.user?.id, source.ownerID == account else { return }
            guard let version = result.sessionVersion, version > 0, !result.tracks.isEmpty else {
                throw MusicAPIError(status: 502, code: "SOURCE_UNAVAILABLE")
            }
            page = result
            if let first = result.tracks.first {
                let prepared = await preparedArtwork(current: first, next: result.tracks.dropFirst().first)
                guard !Task.isCancelled, account == store.user?.id else { return }
                previewArtwork = prepared
            }
            if mode == .guessLike, playingArtwork == nil, let cached = store.cachedRadioArtwork(from: source) {
                let prepared = await preparedArtwork(current: cached.current, next: cached.next)
                guard !Task.isCancelled, account == store.user?.id, playingArtwork == nil else { return }
                playingArtwork = prepared
            }
        } catch {
            guard !Task.isCancelled, account == store.user?.id else { return }
            failure = error.localizedDescription
        }
    }
}

struct DailyRecommendationContent: View {
    @Environment(AppStore.self) private var store
    @Environment(\.workspaceIsActive) private var workspaceIsActive
    let source: SourceConnection
    let tracks: [SourceTrack]
    @State private var preparing = false
    @State private var following = true
    @State private var followRequest = UUID()
    @State private var scrollState = QQCollectionScrollState()

    private var currentRow: Int? {
        store.player.currentSourceRow(in: tracks, sourceID: source.id, kind: .playlist, playlistID: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            PlaylistPage(sourceID: source.id,
                info: PlaylistPageInfo(title: "每日推荐", coverID: tracks.first?.coverID,
                    owner: store.user?.displayName, trackCount: Int64(tracks.count))) {
                Button("播放全部", systemImage: "play.fill") {
                    Task {
                        preparing = true
                        defer { preparing = false }
                        following = true
                        followRequest = UUID()
                        await store.playRecommendations(tracks, from: source)
                    }
                }.disabled(preparing || tracks.isEmpty)
                if preparing { ProgressView().controlSize(.small) }
            } content: {
                QQVirtualTrackList(
                    tracks: tracks, source: source, paginationOffset: tracks.count, store: store,
                    currentRow: currentRow, isPlaying: store.player.isPlaying,
                    loadingRow: store.player.loadingSourceRow(in: tracks, sourceID: source.id, kind: .playlist, playlistID: nil),
                    followingPlayback: following, followRequest: followRequest,
                    scrollState: scrollState, isActive: workspaceIsActive,
                    onManualScroll: { following = false },
                    onPlay: { index in
                        guard tracks.indices.contains(index), tracks[index].isPlayable else { return }
                        following = true
                        followRequest = UUID()
                        Task { await store.importTrack(tracks[index], from: source, play: true) }
                    }, onNearEnd: {}, onFindSimilar: nil)
                .overlay(alignment: .bottom) {
                    if !following, currentRow != nil {
                        PlaybackFollowButton { following = true; followRequest = UUID() }.padding(10)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { scrollState.isActive = workspaceIsActive }
            .onDisappear { scrollState.isActive = false }
            .onChange(of: workspaceIsActive) { _, active in scrollState.isActive = active }
    }
}
