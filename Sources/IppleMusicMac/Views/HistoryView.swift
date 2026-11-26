import MusicCore
import SwiftUI

struct HistoryTrackRow: Equatable, Identifiable {
    var record: PlayHistoryRecord
    var track: LibraryTrack?
    var qqTrackID: String?
    var id: String { record.id }
    var sourceTrack: SourceTrack {
        SourceTrack(
            id: qqTrackID ?? record.trackID, title: track?.title ?? "已移除的歌曲", artists: track?.artists ?? [],
            album: track?.album ?? "", durationMS: track?.durationMS ?? 0, isPlayable: track != nil)
    }

    @MainActor
    static func load(from store: AppStore, sourceID: String?) -> [Self] {
        let tracks = store.trackByID
        return store.history.sorted { $0.playedAt > $1.playedAt }.map { record in
            let track = tracks[record.trackID]
            let qqTrackID = track?.bindings.first { $0.sourceConnectionID == sourceID && $0.confirmed }?.sourceTrackID
            return Self(record: record, track: track, qqTrackID: qqTrackID)
        }
    }
}

struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.workspaceIsActive) private var workspaceIsActive
    @State private var scroll = QQCollectionScrollState()
    @State private var similarTrack: SourceTrack?
    var source: SourceConnection?

    var body: some View {
        let rows = HistoryTrackRow.load(from: store, sourceID: source?.id)
        let tracks = rows.compactMap(\.track)
        let info = PlaylistPageInfo(
            title: "听歌历史", coverID: nil, owner: store.user?.displayName, trackCount: Int64(rows.count),
            coverTrackID: rows.first(where: { $0.qqTrackID != nil })?.qqTrackID)
        PlaylistPage(sourceID: source?.id ?? "", info: info) {
            Button {
                if let first = tracks.first { Task { await store.player.play(first, inQueue: tracks) } }
            } label: {
                Label("播放全部", systemImage: "play.fill")
            }
            .disabled(tracks.isEmpty)
            .accessibilityIdentifier("favorites.history-play-all")
            Menu {
                Button("刷新", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    .disabled(store.isLoading)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden).help("更多历史操作")
            .accessibilityLabel("更多历史操作")
        } content: {
            if rows.isEmpty {
                if store.isLoading && store.lastSync == nil {
                    ProgressView("正在读取听歌历史…")
                } else {
                    ContentUnavailableView(
                        "还没有听歌记录", systemImage: "clock",
                        description: Text("播放歌曲后，这里会显示你的听歌记录。"))
                }
            } else {
                trackList(rows)
            }
        }
        .task { await store.synchronize() }
        .onAppear { scroll.isActive = workspaceIsActive }
        .onDisappear { scroll.isActive = false }
        .onChange(of: workspaceIsActive) { _, active in scroll.isActive = active }
        .sheet(item: $similarTrack) { track in
            if let source { QQSimilarSongsView(source: source, track: track) }
        }
    }

    private func trackList(_ rows: [HistoryTrackRow]) -> some View {
        let currentID = store.player.currentTrack?.id
        let currentRow = rows.firstIndex { $0.track != nil && $0.track?.id == currentID }
        return QQVirtualTrackList(
            tracks: rows.map(\.sourceTrack), source: source, paginationOffset: rows.count, store: store,
            currentRow: currentRow, isPlaying: store.player.isPlaying,
            loadingRow: store.player.isLoading ? currentRow : nil,
            followingPlayback: false, followRequest: Self.followRequest, scrollState: scroll,
            isActive: workspaceIsActive,
            onManualScroll: {},
            onPlay: { index in
                if let track = rows[index].track { Task { await store.player.play(track) } }
            }, onNearEnd: {}, onFindSimilar: { similarTrack = $0 }, history: rows)
    }

    private static let followRequest = UUID()
}

struct HistorySearchButton: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var isExpanded = false
    var sourceID: String

    private var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [HistoryTrackRow] {
        guard !text.isEmpty else { return [] }
        return HistoryTrackRow.load(from: store, sourceID: sourceID).filter { row in
            guard let track = row.track else { return false }
            return ([track.title, track.album] + track.artists).contains { $0.localizedStandardContains(text) }
        }
    }

    var body: some View {
        ExpandingSearchControl(
            query: $query, isExpanded: $isExpanded, placeholder: "搜索听歌历史",
            identifier: "favorites.history.search", onSubmit: playFirstMatch
        ) {
            let rows = matches
            Group {
                if text.isEmpty {
                    Image(systemName: "magnifyingglass").font(.system(size: 30)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    ContentUnavailableView.search(text: text)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                Button {
                                    play(row)
                                } label: {
                                    FavoritesSearchTrackLabel(
                                        track: row.sourceTrack, sourceID: sourceID, sourceTrackID: row.qqTrackID)
                                }
                                .buttonStyle(.plain)
                                .help("播放 \(row.sourceTrack.title)")
                                .accessibilityIdentifier("favorites.history.search.track.\(row.id)")
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func playFirstMatch() {
        if let first = matches.first { play(first) }
    }

    private func play(_ row: HistoryTrackRow) {
        guard let track = row.track else { return }
        isExpanded = false
        Task { await store.player.play(track) }
    }
}
