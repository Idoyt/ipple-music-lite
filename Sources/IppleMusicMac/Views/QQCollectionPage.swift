import MusicCore
import SwiftUI

struct QQCollectionPage: View {
    @Environment(\.workspaceIsActive) private var workspaceIsActive
    @State private var pageAppeared = false
    @Environment(AppStore.self) private var store
    var source: SourceConnection
    var state: QQCollectionState
    private var kind: QQLibraryKind { state.kind }
    private var playlistID: String? { state.playlistID }
    var onManageSources: () -> Void
    var bottomOverlayClearance: CGFloat = 0
    var playlist: QQPlaylistSummary? = nil
    var initialInfo: PlaylistPageInfo? = nil
    var onOpenPlaylist: ((QQPlaylistSummary) -> Void)? = nil
    @State private var gridRestoreTarget: CGFloat?
    @State private var similarTrack: SourceTrack?

    private var currentRow: Int? {
        store.player.currentSourceRow(in: state.tracks, sourceID: source.id, kind: kind, playlistID: playlistID)
    }
    private var hasCurrentTrack: Bool {
        store.player.currentTrack?.bindings.contains { $0.sourceConnectionID == source.id } == true
    }

    var body: some View {
        Group {
            if kind == .playlists {
                collectionContent
            } else {
                PlaylistPage(sourceID: source.id, info: pageInfo) {
                    Button {
                        if let index = state.tracks.firstIndex(where: \.isPlayable) { play(at: index) }
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .disabled(state.loading || !state.tracks.contains(where: \.isPlayable) || store.player.isPreparingQQQueue)
                    .accessibilityIdentifier("favorites.qq-play-all")
                    Menu {
                        Button("刷新", systemImage: "arrow.clockwise") { state.refresh() }
                            .disabled(state.loading)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden).help("更多歌单操作")
                    .accessibilityLabel("更多歌单操作")
                } content: {
                    collectionContent
                }
            }
        }
        .overlay(alignment: .bottom) {
            if kind != .playlists, !state.followingPlayback, currentRow != nil, workspaceIsActive {
                PlaybackFollowButton {
                    state.followingPlayback = true
                    state.followRequest = UUID()
                }
                .padding(.bottom, bottomOverlayClearance + 10)
            }
        }
    }

    private var pageInfo: PlaylistPageInfo {
        let name = (playlist?.name ?? state.playlist?.name).flatMap { $0.isEmpty ? nil : $0 }
        let coverID: String?
        if kind == .favorites {
            coverID = state.tracks.first?.coverID.flatMap { $0.isEmpty ? nil : $0 }
        } else {
            coverID = initialInfo?.coverID ?? playlist?.coverID ?? state.playlist?.coverID
                ?? state.tracks.first(where: { $0.coverID?.isEmpty == false })?.coverID
        }
        return PlaylistPageInfo(
            title: initialInfo?.title ?? name ?? (kind == .favorites ? "喜欢的歌曲" : "歌单"),
            coverID: coverID,
            owner: initialInfo?.owner ?? (kind == .favorites ? store.user?.displayName : nil),
            tags: initialInfo?.tags ?? [], description: initialInfo?.description,
            trackCount: state.cursor.total,
            coverTrackID: kind == .favorites ? state.tracks.first?.id : initialInfo?.coverTrackID)
    }

    private var collectionContent: some View {
        VStack(spacing: 0) {
            if state.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.tracks.isEmpty && state.playlists.isEmpty, let failure = state.failure {
                ContentUnavailableView {
                    Label(
                        state.needsLogin ? "请重新登录" : "暂时无法读取",
                        systemImage: state.needsLogin
                            ? "person.crop.circle.badge.exclamationmark" : "wifi.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("重试") { state.refresh() }
                    Button("管理音乐账户", action: onManageSources)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if kind == .playlists {
                playlistGrid
            } else if state.tracks.isEmpty {
                if state.cursor.hasMore {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(kind == .favorites ? "还没有喜欢的歌曲" : "歌单中没有可播放的歌曲", systemImage: "music.note")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                QQVirtualTrackList(
                    tracks: state.tracks, source: source, paginationOffset: state.cursor.nextOffset, store: store,
                    currentRow: currentRow,
                    isPlaying: store.player.isPlaying,
                    loadingRow: store.player.loadingSourceRow(
                        in: state.tracks, sourceID: source.id, kind: kind, playlistID: playlistID),
                    followingPlayback: state.followingPlayback && !store.player.isPreparingQQQueue,
                    followRequest: state.followRequest,
                    scrollState: state.trackScroll, isActive: state.isVisible && workspaceIsActive,
                    onManualScroll: { state.followingPlayback = false },
                    onPlay: { play(at: $0) }, onNearEnd: state.requestMore,
                    onFindSimilar: kind == .favorites ? { similarTrack = $0 } : nil
                )
            }
            if state.loadingMore {
                ProgressView().controlSize(.small).frame(height: 26).frame(maxWidth: .infinity)
            } else if let failure = state.failure, !state.tracks.isEmpty || !state.playlists.isEmpty {
                HStack {
                    Text(failure).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("重试", action: state.retryMore).disabled(state.needsLogin)
                    if state.needsLogin { Button("管理音乐账户", action: onManageSources) }
                }.padding(.horizontal, 28).padding(.vertical, 6)
            }
            if let queueError = store.player.qqQueueError {
                HStack {
                    Text(queueError).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("重试加载队列") { store.player.retryQQQueueLoading() }
                }.padding(.horizontal, 28).padding(.vertical, 6)
            }
        }
        .onAppear {
            pageAppeared = true
            if workspaceIsActive { state.activate() }
        }
        .onDisappear {
            pageAppeared = false
            state.deactivate()
        }
        .onChange(of: workspaceIsActive) { _, active in
            guard pageAppeared else { return }
            if active { state.activate() } else { state.deactivate(preservingLayout: true) }
        }
        .onChange(of: state.tracks.count) { _, _ in loadFollowingTarget() }
        .onChange(of: state.followRequest) { _, _ in loadFollowingTarget() }
        .onChange(of: store.player.currentQueueIndex) { _, _ in loadFollowingTarget() }
        .onChange(of: store.player.currentTrack?.id) { _, _ in loadFollowingTarget() }
        .sheet(item: $similarTrack) { QQSimilarSongsView(source: source, track: $0) }
    }

    private var playlistGrid: some View {
        @Bindable var state = state
        let visible = state.playlists.filter { $0.kind != "favorites" }
        return Group {
            if visible.isEmpty && !state.cursor.hasMore {
                ContentUnavailableView("还没有歌单", systemImage: "music.note.list")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 22)],
                        alignment: .leading, spacing: 22
                    ) {
                        ForEach(visible) { playlist in
                            Button {
                                onOpenPlaylist?(playlist)
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    SourceCover(sourceID: source.id, coverID: playlist.coverID, size: 160)
                                    Text(playlist.name).font(.headline).lineLimit(2)
                                    Text("\(playlist.trackCount) 首").font(.caption).foregroundStyle(.secondary)
                                }.frame(width: 160, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityIdentifier("favorites.qq-playlist.\(playlist.id)")
                        }
                        Color.clear.frame(height: 1).onAppear { state.requestMore() }
                    }.padding(28)
                }
                .scrollPosition($state.gridPosition)
                .onAppear {
                    if let origin = state.gridScroll.origin {
                        gridRestoreTarget = origin.y
                        state.gridPosition.scrollTo(y: origin.y)
                    }
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting { gridRestoreTarget = nil }
                }
                .onScrollGeometryChange(for: GridScrollGeometry.self) { geometry in
                    GridScrollGeometry(
                        offset: geometry.contentOffset.y,
                        maximum: max(0, geometry.contentSize.height - geometry.containerSize.height))
                } action: { _, geometry in
                    guard state.gridScroll.isActive else { return }
                    if let target = gridRestoreTarget {
                        let bounded = min(target, geometry.maximum)
                        if abs(geometry.offset - bounded) > 1 {
                            state.gridPosition.scrollTo(y: bounded)
                            return
                        }
                        gridRestoreTarget = nil
                    }
                    state.gridScroll.origin = CGPoint(x: 0, y: max(0, geometry.offset))
                }
            }
        }
    }

    private func loadFollowingTarget() {
        guard state.isVisible, state.followingPlayback, !store.player.isPreparingQQQueue,
            kind != .playlists, hasCurrentTrack, currentRow == nil else {
            return
        }
        state.requestMore()
    }

    private func play(at index: Int) {
        guard state.tracks.indices.contains(index), state.tracks[index].isPlayable,
            let version = state.cursor.sessionVersion else { return }
        state.followingPlayback = true
        state.followRequest = UUID()
        store.player.playQQCollection(
            sourceID: source.id, kind: kind, playlistID: playlistID,
            sessionVersion: version, startIndex: index,
            expectedTrackID: state.tracks[index].id)
    }
}

struct QQSimilarSongsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var source: SourceConnection
    var track: SourceTrack
    @State private var results: [SourceTrack]?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                SourceCover(sourceID: source.id, coverID: track.coverID, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("相似歌曲").font(.title2.bold())
                    Text(track.title).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("完成") { dismiss() }
            }.padding(.horizontal, 24)
            Group {
                if let failure {
                    ContentUnavailableView {
                        Label("无法读取相似歌曲", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("重试") { attempt += 1 }
                    }
                } else if let results {
                    if results.isEmpty {
                        ContentUnavailableView("暂无相似歌曲", systemImage: "music.note")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(results) { result in
                                    SourceTrackRow(track: result, source: source)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView("正在搜索相似歌曲…")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.vertical, 24)
        .frame(width: 720, height: 520)
        .task(id: attempt) {
            failure = nil
            do {
                let songs = try await store.api.qqSimilarSongs(sourceID: source.id, trackID: track.id)
                try Task.checkCancellation()
                results = songs
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}

private struct GridScrollGeometry: Equatable {
    var offset: CGFloat
    var maximum: CGFloat
}
