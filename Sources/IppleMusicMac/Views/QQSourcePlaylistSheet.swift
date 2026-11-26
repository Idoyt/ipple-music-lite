import MusicCore
import SwiftUI

struct QQSourcePlaylistSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var source: SourceConnection
    var playlistID: String
    var info: PlaylistPageInfo?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("完成") { dismiss() }
            }.padding(.horizontal, 24).padding(.top, 16)
            QQSourcePlaylistContent(source: source, playlistID: playlistID, client: store.api, info: info,
                onManageSources: { dismiss(); store.selection = .sources })
        }
        .frame(width: 900, height: 660)
    }
}

struct QQSourcePlaylistContent: View {
    var source: SourceConnection
    var info: PlaylistPageInfo?
    var onManageSources: () -> Void
    @State private var collection: QQCollectionState

    init(source: SourceConnection, playlistID: String, client: MusicAPIClient, info: PlaylistPageInfo? = nil,
         onManageSources: @escaping () -> Void) {
        self.source = source
        self.info = info
        self.onManageSources = onManageSources
        let state = QQCollectionState(client: client, sourceID: source.id, kind: .playlist, playlistID: playlistID)
        // Opening a different playlist must not fetch every page looking for an unrelated playing song.
        state.followingPlayback = false
        _collection = State(initialValue: state)
    }

    var body: some View {
        QQCollectionPage(source: source, state: collection, onManageSources: onManageSources, initialInfo: info)
            .onDisappear { collection.cancelPendingRequest() }
    }
}
