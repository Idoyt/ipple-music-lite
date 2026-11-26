import MusicCore
import SwiftUI

struct SourceTrackRow: View {
    @Environment(AppStore.self) private var store
    var track: SourceTrack
    var source: SourceConnection
    @State private var importing = false
    private var isCurrent: Bool {
        store.player.currentTrack?.bindings.contains {
            $0.sourceConnectionID == source.id && $0.sourceTrackID == track.id
        } == true
    }
    var body: some View {
        HStack(spacing: 14) {
            SourceCover(sourceID: source.id, coverID: track.coverID, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).lineLimit(1).foregroundStyle(
                    isCurrent ? Color(nsColor: .controlAccentColor) : Color.primary
                )
                .fontWeight(isCurrent ? .semibold : .regular)
                Text(track.artists.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(track.album).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 170, alignment: .leading)
            Text(durationText(Double(track.durationMS) / 1000)).font(.caption).monospacedDigit().foregroundStyle(
                .secondary
            ).frame(width: 48)
            Button {
                if isCurrent {
                    Task { await store.player.togglePlayPause() }
                } else {
                    run(play: true)
                }
            } label: {
                if isCurrent {
                    NowPlayingIndicator(isPlaying: store.player.isPlaying)
                } else {
                    Image(systemName: "play.fill")
                }
            }.help(isCurrent ? (store.player.isPlaying ? "暂停" : "继续播放") : "导入并播放")
            Button {
                run(play: false)
            } label: {
                Image(systemName: "plus.circle")
            }.help("加入资料库")
        }.buttonStyle(.borderless).padding(.horizontal, 26).padding(.vertical, 10).disabled(importing)
    }
    private func run(play: Bool) {
        Task {
            importing = true
            await store.importTrack(track, from: source, play: play)
            importing = false
        }
    }
}

struct SourceCover: View {
    private struct TrackLookup: Equatable {
        let sourceID: String
        let trackID: String
    }

    private struct Request: Equatable {
        let identity: DecodedCoverCache.Identity
        let pixels: Int
        let active: Bool
    }

    @Environment(\.workspaceIsActive) private var workspaceIsActive
    @Environment(AppStore.self) private var store
    var sourceID: String
    var coverID: String?
    var size: CGFloat
    var onLoadingChange: ((Bool) -> Void)? = nil
    var sourceTrackID: String? = nil
    @State private var image: DecodedCoverBitmap?
    @State private var loadedRequest: Request?
    @State private var trackCover: (lookup: TrackLookup, id: String?)?
    private var lookup: TrackLookup? {
        guard coverID == nil, let sourceTrackID else { return nil }
        return TrackLookup(sourceID: sourceID, trackID: sourceTrackID)
    }
    private var resolvedCoverID: String? { coverID ?? (trackCover?.lookup == lookup ? trackCover?.id : nil) }
    private var request: Request {
        Request(
            identity: store.coverIdentity(sourceID: sourceID, coverID: resolvedCoverID ?? ""),
            pixels: min(Int(size * 2), 512), active: workspaceIsActive)
    }
    var body: some View {
        Group {
            if let image {
                Image(decorative: image.cgImage, scale: 1).resizable().scaledToFill()
            } else {
                TrackArtwork(title: "", size: size)
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: max(7, size * 0.07)))
        .task(id: workspaceIsActive ? lookup : nil) {
            guard workspaceIsActive, let lookup, trackCover?.lookup != lookup, let track = try? await store.api.sourceTrack(
                id: lookup.sourceID, resourceID: lookup.trackID), !Task.isCancelled
            else { return }
            trackCover = (lookup, track.coverID)
        }
        .task(id: request) {
            guard workspaceIsActive else {
                onLoadingChange?(false)
                return
            }
            let requested = request
            guard loadedRequest != requested else { return }
            image = nil
            guard let coverID = resolvedCoverID, !coverID.isEmpty else {
                onLoadingChange?(false)
                return
            }
            onLoadingChange?(true)
            defer { if !Task.isCancelled { onLoadingChange?(false) } }
            if let decoded = await store.coverImage(
                sourceID: sourceID, coverID: coverID, maximumPixelSize: requested.pixels, timing: .onDisplay)
            {
                guard !Task.isCancelled else { return }
                image = decoded
                loadedRequest = requested
            }
        }
    }
}

enum SourceDetailSelection: Identifiable {
    case album(String)
    case artist(String)
    case playlist(String)
    var id: String {
        switch self {
        case .album(let id): "album-" + id
        case .artist(let id): "artist-" + id
        case .playlist(let id): "playlist-" + id
        }
    }
}

struct SourceDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var source: SourceConnection
    var selection: SourceDetailSelection
    var playlistInfo: PlaylistPageInfo? = nil
    @State private var title = "正在读取…"
    @State private var tracks: [SourceTrack] = []
    @State private var albums: [SourceAlbum] = []
    @State private var error: String?
    @State private var importing = false
    var body: some View {
        if case .playlist(let id) = selection, source.kind == "qq" {
            QQSourcePlaylistSheet(source: source, playlistID: id, info: playlistInfo)
        } else {
            legacyDetail
        }
    }

    private var legacyDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }
            }
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack {
                    ForEach(tracks) { SourceTrackRow(track: $0, source: source) }
                    ForEach(albums) { album in
                        Button(album.name ?? album.title ?? "专辑") { Task { await loadAlbum(album.id) } }.padding(10)
                    }
                }
            }
            if !tracks.isEmpty {
                Button(importing ? "正在导入…" : "全部加入资料库") {
                    Task {
                        importing = true
                        for track in tracks {
                            await store.importTrack(track, from: source)
                            if store.error != nil { break }
                        }
                        importing = false
                    }
                }.disabled(importing)
            }
        }.padding(24).frame(width: 760, height: 540).task { await load() }
    }
    private func load() async {
        do {
            switch selection {
            case .album(let id): await loadAlbum(id)
            case .artist(let id):
                let artist = try await store.api.sourceArtist(id: source.id, resourceID: id)
                title = artist.name
                albums = artist.albums ?? []
            case .playlist(let id):
                let playlist = try await store.api.sourcePlaylist(id: source.id, resourceID: id)
                title = playlist.name ?? playlist.title ?? "来源歌单"
                tracks = playlist.tracks
            }
        } catch { self.error = error.localizedDescription }
    }
    private func loadAlbum(_ id: String) async {
        do {
            let album = try await store.api.sourceAlbum(id: source.id, resourceID: id)
            title = album.name ?? album.title ?? "专辑"
            tracks = album.tracks ?? []
            albums = []
        } catch { self.error = error.localizedDescription }
    }
}
