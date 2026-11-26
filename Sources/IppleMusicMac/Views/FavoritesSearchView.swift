import MusicCore
import SwiftUI

struct FavoritesSearchView: View {
    var state: QQCollectionState
    var sourceID: String
    var query: String
    var onPlay: (Int) -> Void
    var onOpenPlaylist: (QQPlaylistSummary) -> Void

    private var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trackIndices: [Int] { state.matchingTrackIndices(text) }
    private var playlists: [QQPlaylistSummary] { state.matchingPlaylists(text) }
    private var hasResults: Bool { state.kind == .playlists ? !playlists.isEmpty : !trackIndices.isEmpty }
    private var readingMore: Bool { !text.isEmpty && state.cursor.hasMore && state.failure == nil }

    var body: some View {
        VStack(spacing: 0) {
            if text.isEmpty {
                Image(systemName: "magnifyingglass").font(.system(size: 30)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasResults {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if state.kind == .playlists {
                            ForEach(playlists) { playlist in
                                Button {
                                    selectPlaylist(playlist)
                                } label: {
                                    HStack(spacing: 10) {
                                        SourceCover(sourceID: sourceID, coverID: playlist.coverID, size: 36)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(playlist.name).lineLimit(1)
                                            Text("\(playlist.trackCount) 首").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("favorites.search.playlist.\(playlist.id)")
                            }
                        } else {
                            ForEach(trackIndices, id: \.self) { index in
                                let track = state.tracks[index]
                                Button {
                                    selectTrack(index)
                                } label: {
                                    FavoritesSearchTrackLabel(track: track, sourceID: sourceID)
                                }
                                .buttonStyle(.plain).help("播放 \(track.title)")
                                .disabled(!track.isPlayable).opacity(track.isPlayable ? 1 : 0.6)
                                .accessibilityIdentifier("favorites.search.track.\(index)")
                            }
                        }
                    }
                }
            } else if readingMore {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.failure == nil {
                ContentUnavailableView.search(text: text)
            } else {
                Spacer()
            }
            if readingMore, hasResults {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在搜索更多内容…").font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            if !text.isEmpty, let failure = state.failure {
                HStack {
                    Text(failure).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("重试") { state.retryMore() }.disabled(state.needsLogin)
                }.padding(14)
            }
        }
        .padding(.vertical, 8)
        .onAppear { state.setSearching(!text.isEmpty) }
        .onChange(of: text) { _, value in state.setSearching(!value.isEmpty) }
        .onDisappear { state.setSearching(false) }
    }

    private func selectPlaylist(_ playlist: QQPlaylistSummary) {
        state.setSearching(false)
        onOpenPlaylist(playlist)
    }

    private func selectTrack(_ index: Int) {
        guard state.tracks.indices.contains(index), state.tracks[index].isPlayable else { return }
        state.setSearching(false)
        onPlay(index)
    }
}

struct FavoritesSearchTrackLabel: View {
    var track: SourceTrack
    var sourceID: String
    var sourceTrackID: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            SourceCover(sourceID: sourceID, coverID: track.coverID, size: 36, sourceTrackID: sourceTrackID)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).lineLimit(1)
                Text(track.artists.joined(separator: " / "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

struct FavoritesSearchButton: View {
    @Environment(AppStore.self) private var store
    var collection: QQCollectionState
    var sourceID: String
    var onPlay: (Int, QQCollectionState) -> Void
    var onOpenPlaylist: (QQPlaylistSummary) -> Void
    @State private var isExpanded = false
    @State private var query = ""

    var body: some View {
        ExpandingSearchControl(query: $query, isExpanded: $isExpanded,
            placeholder: collection.kind == .playlists ? "搜索歌单" : "歌曲、歌手或专辑",
            identifier: "favorites.search", onSubmit: openFirstResult) {
            FavoritesSearchView(state: collection, sourceID: sourceID, query: query,
                onPlay: { index in close(); onPlay(index, collection) },
                onOpenPlaylist: { playlist in close(); onOpenPlaylist(playlist) })
                .environment(store)
        }
        .onChange(of: ObjectIdentifier(collection)) { _, _ in close(); query = "" }
        .onChange(of: isExpanded) { _, expanded in if !expanded { collection.setSearching(false) } }
    }

    private func close() { isExpanded = false; collection.setSearching(false) }

    private func openFirstResult() {
        if collection.kind == .playlists {
            guard let playlist = collection.matchingPlaylists(query).first else { return }
            close()
            onOpenPlaylist(playlist)
        } else {
            guard let index = collection.matchingTrackIndices(query).first(where: { collection.tracks[$0].isPlayable }) else { return }
            close()
            onPlay(index, collection)
        }
    }
}
