import MusicCore
import SwiftUI

private enum FavoritesSection: String, CaseIterable {
    case songs = "歌曲"
    case playlists = "歌单"
    case history = "历史"
}

struct FavoritesView: View {
    @Environment(AppStore.self) private var store
    @State private var section = FavoritesSection.songs
    var onManageSources: () -> Void
    var bottomOverlayClearance: CGFloat = 0
    var showsToolbar = true

    private var source: SourceConnection? {
        store.sources.first { $0.kind == "qq" && $0.enabled && $0.state == "active" && $0.ownerID == store.user?.id }
    }

    var body: some View {
        Group {
            if let source {
                QQFavoritesTabs(
                    source: source, client: store.api, section: $section,
                    onManageSources: onManageSources, bottomOverlayClearance: bottomOverlayClearance,
                    showsToolbar: showsToolbar
                )
                .id("\(store.settings.serverURL):\(store.user?.id ?? ""):\(source.id):\(source.version)")
            } else {
                TabView(selection: $section) {
                    Tab(value: FavoritesSection.songs) {
                        loginPrompt("登录后查看收藏的歌曲。")
                    } label: {
                        Text("歌曲")
                    }
                    Tab(value: FavoritesSection.playlists) {
                        loginPrompt("登录后查看收藏的歌单。")
                    } label: {
                        Text("歌单")
                    }
                    Tab(value: FavoritesSection.history) {
                        HistoryView()
                    } label: {
                        Text("历史")
                    }
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("收藏")
    }

    private func loginPrompt(_ message: String) -> some View {
        ContentUnavailableView {
            Label("登录音乐账户", systemImage: "person.crop.circle")
        } description: {
            Text(message)
        } actions: {
            Button("管理音乐账户", action: onManageSources)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QQFavoritesTabs: View {
    @Environment(AppStore.self) private var store
    var source: SourceConnection
    @Binding var section: FavoritesSection
    var onManageSources: () -> Void
    var bottomOverlayClearance: CGFloat
    var showsToolbar: Bool
    @State private var collections: QQFavoritesCollections
    @State private var favoriteRevision = 0

    private var activeCollection: QQCollectionState? {
        switch section {
        case .songs: collections.songs
        case .playlists: collections.selectedPlaylist.flatMap { collections.details[$0.id] } ?? collections.playlists
        case .history: nil
        }
    }

    init(
        source: SourceConnection, client: MusicAPIClient, section: Binding<FavoritesSection>,
        onManageSources: @escaping () -> Void, bottomOverlayClearance: CGFloat, showsToolbar: Bool
    ) {
        self.source = source
        self._section = section
        self.onManageSources = onManageSources
        self.bottomOverlayClearance = bottomOverlayClearance
        self.showsToolbar = showsToolbar
        _collections = State(initialValue: QQFavoritesCollections(client: client, sourceID: source.id))
    }

    var body: some View {
        TabView(selection: $section) {
            Tab(value: FavoritesSection.songs) {
                QQCollectionPage(
                    source: source, state: collections.songs, onManageSources: onManageSources,
                    bottomOverlayClearance: bottomOverlayClearance)
            } label: {
                Text("歌曲")
            }
            Tab(value: FavoritesSection.playlists) {
                QQFavoritePlaylists(
                    source: source, collections: collections, onManageSources: onManageSources,
                    bottomOverlayClearance: bottomOverlayClearance)
            } label: {
                Text("歌单")
            }
            Tab(value: FavoritesSection.history) {
                HistoryView(source: source)
            } label: {
                Text("历史")
            }
        }
        .toolbar {
            if showsToolbar {
                if let activeCollection {
                    collectionToolbar(activeCollection)
                } else {
                    SearchToolbarItem { HistorySearchButton(sourceID: source.id) }
                }
            }
        }
        .onDisappear { collections.cancelPendingRequests() }
        .onAppear { syncFavorites() }
        .onChange(of: store.qqFavoriteRevisions[source.id, default: 0]) { _, _ in syncFavorites() }
    }

    @ToolbarContentBuilder
    private func collectionToolbar(_ activeCollection: QQCollectionState) -> some ToolbarContent {
        SearchToolbarItem {
            FavoritesSearchButton(
                collection: activeCollection, sourceID: source.id,
                onPlay: { index, state in play(at: index, in: state) },
                onOpenPlaylist: {
                    collections.openPlaylist($0)
                    section = .playlists
                }
            )
        }
    }

    private func syncFavorites() {
        let revision = store.qqFavoriteRevisions[source.id, default: 0]
        guard revision != favoriteRevision else { return }
        favoriteRevision = revision
        collections.songs.invalidate()
        collections.playlists.invalidate()
    }

    private func play(at index: Int, in state: QQCollectionState) {
        guard state.tracks.indices.contains(index), state.tracks[index].isPlayable,
            let version = state.cursor.sessionVersion else { return }
        state.followingPlayback = true
        state.followRequest = UUID()
        store.player.playQQCollection(
            sourceID: source.id, kind: state.kind, playlistID: state.playlistID,
            sessionVersion: version, startIndex: index, expectedTrackID: state.tracks[index].id)
    }
}

private struct QQFavoritePlaylists: View {
    var source: SourceConnection
    var collections: QQFavoritesCollections
    var onManageSources: () -> Void
    var bottomOverlayClearance: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if let playlist = collections.selectedPlaylist, let state = collections.details[playlist.id] {
                HStack(spacing: 12) {
                    Button {
                        collections.selectedPlaylist = nil
                    } label: {
                        Label("歌单", systemImage: "chevron.left")
                    }
                    Spacer()
                }.padding(.horizontal, 28).padding(.top, 12)
                QQCollectionPage(
                    source: source, state: state, onManageSources: onManageSources,
                    bottomOverlayClearance: bottomOverlayClearance, playlist: playlist
                )
                .id(playlist.id)
            } else {
                QQCollectionPage(
                    source: source, state: collections.playlists, onManageSources: onManageSources,
                    onOpenPlaylist: { collections.openPlaylist($0) })
            }
        }
    }
}
