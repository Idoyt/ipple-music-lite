import MusicCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    var title: String
    var subtitle: String
    var tracks: [LibraryTrack]
    var symbol: String
    var showsHeader = true
    @State private var filter = ""

    private var filtered: [LibraryTrack] {
        guard !filter.isEmpty else { return tracks }
        return tracks.filter {
            ($0.title + " " + $0.artists.joined(separator: " ") + " " + $0.album).localizedStandardContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { PageHeader(title: title, subtitle: subtitle, symbol: symbol, count: tracks.count) }
            HStack(spacing: 12) {
                Button {
                    if let first = filtered.first { Task { await store.player.play(first, inQueue: filtered) } }
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).disabled(filtered.isEmpty)
                Button {
                    for track in filtered { store.player.enqueue(track) }
                    store.notice = "已加入播放队列"
                } label: {
                    Label("加入队列", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .disabled(filtered.isEmpty)
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索歌曲、艺人或专辑", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 245)
                    .accessibilityIdentifier("library.search")
            }.padding(.horizontal, 28).padding(.bottom, 18)
            Divider()
            if store.isLoading && tracks.isEmpty {
                ProgressView("正在读取资料库…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView {
                    Label("把喜欢的音乐带进来", systemImage: symbol)
                } description: {
                    Text("连接音乐源，搜索并导入歌曲。资料库与收藏将独立保存。")
                } actions: {
                    Button("连接音乐源") { store.selection = .sources }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                TrackTable(tracks: filtered)
            }
        }.navigationTitle(title)
    }
}

struct TrackTable: View {
    @Environment(AppStore.self) private var store
    var tracks: [LibraryTrack]
    @State private var selected: String?
    @State private var editing: LibraryTrack?
    @State private var deleting: LibraryTrack?

    var body: some View {
        PlaybackFollowingList(currentRow: tracks.firstIndex { $0.id == store.player.currentTrack?.id }) {
            Table(tracks, selection: $selected) {
                TableColumn("") { track in
                    Button {
                        Task { await store.toggleFavorite(track) }
                    } label: {
                        Image(systemName: store.favoriteIDs.contains(track.id) ? "heart.fill" : "heart")
                            .foregroundStyle(
                                store.favoriteIDs.contains(track.id) ? PlaybackFavoriteControl.selectedColor : Color.secondary)
                    }.buttonStyle(.plain).help(store.favoriteIDs.contains(track.id) ? "取消喜欢" : "喜欢这首歌")
                }.width(25)
                TableColumn("歌曲") { track in
                    HStack(spacing: 12) {
                        TrackArtwork(title: track.title, size: 35)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).fontWeight(
                                store.player.currentTrack?.id == track.id ? .semibold : .regular
                            )
                            .lineLimit(1)
                            .foregroundStyle(
                                store.player.currentTrack?.id == track.id
                                    ? Color(nsColor: .controlAccentColor) : Color.primary)
                            Text(track.artists.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if store.player.currentTrack?.id == track.id {
                            NowPlayingIndicator(isPlaying: store.player.isPlaying)
                        }
                    }.padding(.vertical, 5).id(track.id)
                }.width(min: 220, ideal: 330)
                TableColumn("专辑") { track in
                    Text(track.album.isEmpty ? "—" : track.album).foregroundStyle(.secondary).lineLimit(1)
                }.width(min: 100, ideal: 170)
                TableColumn("来源") { track in
                    let connected = track.bindings.compactMap { binding in
                        store.sources.first {
                            $0.id == binding.sourceConnectionID && $0.enabled && $0.state == "active"
                        }
                    }
                    let source = connected.first(where: { $0.kind == "subsonic" }) ?? connected.first
                    Label(
                        source?.name ?? "待匹配", systemImage: source?.kind == "subsonic" ? "externaldrive" : "music.note"
                    )
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.width(min: 90, ideal: 130)
                TableColumn("时长") { track in
                    Text(durationText(Double(track.durationMS) / 1000)).monospacedDigit().foregroundStyle(.secondary)
                }.width(52)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let track = tracks.first(where: { $0.id == id }) {
                    Button("立即播放") { Task { await store.player.play(track, inQueue: tracks) } }
                    Button("加入队列") { store.player.enqueue(track) }
                    Button(store.favoriteIDs.contains(track.id) ? "取消喜欢" : "喜欢") {
                        Task { await store.toggleFavorite(track) }
                    }
                    Menu("加入歌单") {
                        ForEach(store.playlists) { playlist in
                            Button(playlist.name) { Task { await store.add(track, to: playlist) } }
                        }
                    }.disabled(store.playlists.isEmpty)
                    Divider()
                    Button("编辑歌曲资料…") { editing = track }
                    Button("从资料库移除…", role: .destructive) { deleting = track }
                }
            } primaryAction: { ids in
                if let id = ids.first, let track = tracks.first(where: { $0.id == id }) {
                    Task { await store.player.play(track, inQueue: tracks) }
                }
            }
            .accessibilityIdentifier("library.tracks")
            .sheet(item: $editing) { TrackEditForm(track: $0) }
            .confirmationDialog(
                "从资料库移除这首歌？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                if let track = deleting {
                    Button("移除「\(track.title)」", role: .destructive) {
                        Task {
                            await store.perform {
                                try await store.api.deleteLibraryTrack(id: track.id, version: track.version)
                                if store.player.currentTrack?.id == track.id { store.player.stop() }
                                await store.refresh()
                            }
                        }
                        deleting = nil
                    }
                }
            } message: {
                Text("这会移除本机资料库中的歌曲及其歌单条目，QQ 音乐中的歌曲保持不变。")
            }
        }
    }
}

struct TrackEditForm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var track: LibraryTrack
    @State private var title = ""
    @State private var artists = ""
    @State private var album = ""
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            Text("编辑歌曲资料").font(.title2.bold())
            Form {
                TextField("歌曲名称", text: $title)
                TextField("艺人（用 / 分隔）", text: $artists)
                TextField("专辑", text: $album)
            }.textFieldStyle(.roundedBorder)
            Text("只更新你的个人资料，不会修改来源曲库。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(
                    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }.padding(28).frame(width: 460).onAppear {
            title = track.title
            artists = track.artists.joined(separator: " / ")
            album = track.album
        }
    }
    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let names = artists.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter
            { !$0.isEmpty }
            _ = try await store.api.updateLibraryTrack(
                id: track.id,
                patch: LibraryTrackPatch(version: track.version, title: title, artists: names, album: album))
            await store.refresh()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct TrackArtwork: View {
    var title: String
    var size: CGFloat = 46
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.19).fill(Color(nsColor: .controlAccentColor).opacity(0.10))
            Image(systemName: "music.note").font(.system(size: size * 0.37, weight: .light)).foregroundStyle(
                Color(nsColor: .controlAccentColor).opacity(0.7))
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct PlaylistForm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("新建歌单").font(.title2.bold())
            TextField("歌单名称", text: $name).textFieldStyle(.roundedBorder)
            TextField("描述（可选）", text: $description).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("创建") {
                    Task {
                        saving = true
                        await store.createPlaylist(name: name, description: description)
                        saving = false
                        if store.error == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }.padding(28).frame(width: 400)
    }
}

struct PlaylistDetailView: View {
    @Environment(AppStore.self) private var store
    var playlistID: String
    @State private var editing = false
    @State private var name = ""
    @State private var description = ""

    var body: some View {
        Group {
            if let playlist = store.activePlaylist, playlist.id == playlistID {
                VStack(spacing: 0) {
                    PageHeader(
                        title: playlist.name,
                        subtitle: playlist.description.isEmpty ? "每一次重复出现，也是一份独立的喜欢。" : playlist.description,
                        symbol: "music.note.list", count: playlist.entries.count)
                    HStack {
                        Button {
                            let queue = playlist.entries.compactMap { store.trackByID[$0.trackID] }
                            if let first = queue.first { Task { await store.player.play(first, inQueue: queue) } }
                        } label: {
                            Label("播放歌单", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent).disabled(playlist.entries.isEmpty)
                        Button("编辑歌单") {
                            name = playlist.name
                            description = playlist.description
                            editing = true
                        }
                        Spacer()
                        Text("使用箭头调整顺序").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 28).padding(.bottom, 18)
                    Divider()
                    if playlist.entries.isEmpty {
                        ContentUnavailableView(
                            "歌单还是空的", systemImage: "music.note.list", description: Text("在歌曲上点击右键，选择「加入歌单」。"))
                    } else {
                        List(Array(playlist.entries.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 14) {
                                Text("\(index + 1)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(
                                    width: 24)
                                if let track = store.trackByID[entry.trackID] {
                                    TrackArtwork(title: track.title, size: 36)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.title)
                                            .foregroundStyle(
                                                store.player.currentTrack?.id == track.id
                                                    ? Color(nsColor: .controlAccentColor) : Color.primary)

                                        Text(track.artists.joined(separator: " / ")).font(.caption).foregroundStyle(
                                            .secondary)
                                    }
                                    if store.player.currentTrack?.id == track.id {
                                        NowPlayingIndicator(isPlaying: store.player.isPlaying)
                                    }
                                    Spacer()
                                    Button {
                                        let queue = playlist.entries.compactMap { store.trackByID[$0.trackID] }
                                        let occurrence = playlist.entries.prefix(index).compactMap {
                                            store.trackByID[$0.trackID]
                                        }.count
                                        store.player.setQueue(queue)
                                        Task { await store.player.playQueueItem(at: occurrence) }
                                    } label: {
                                        Image(systemName: "play.fill")
                                    }.help("播放")
                                } else {
                                    Text("歌曲已移除").foregroundStyle(.secondary)
                                    Spacer()
                                }
                                Button {
                                    reorder(playlist, index, -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }.disabled(index == 0).help("上移")
                                Button {
                                    reorder(playlist, index, 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }.disabled(index == playlist.entries.count - 1).help("下移")
                                Button(role: .destructive) {
                                    Task {
                                        await store.perform {
                                            _ = try await store.api.deletePlaylistEntry(
                                                playlistID: playlist.id, entryID: entry.id, version: playlist.version)
                                            await store.loadPlaylist(playlist.id)
                                        }
                                    }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }.help("从歌单移除")
                            }.buttonStyle(.borderless).padding(.vertical, 7)
                        }.listStyle(.inset)
                    }
                }
                .sheet(isPresented: $editing) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("编辑歌单").font(.title2.bold())
                        TextField("名称", text: $name)
                        TextField("描述", text: $description)
                        HStack {
                            Spacer()
                            Button("取消") { editing = false }
                            Button("保存") {
                                Task {
                                    await store.perform {
                                        _ = try await store.api.updatePlaylist(
                                            id: playlist.id,
                                            patch: PlaylistPatch(
                                                version: playlist.version, name: name, description: description))
                                        await store.refresh()
                                        editing = false
                                    }
                                }
                            }.buttonStyle(.borderedProminent).disabled(name.isEmpty)
                        }
                    }.textFieldStyle(.roundedBorder).padding(28).frame(width: 410)
                }
            } else {
                ProgressView("正在读取歌单…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.task { await store.loadPlaylist(playlistID) }.navigationTitle(store.activePlaylist?.name ?? "歌单")
    }

    private func reorder(_ playlist: LibraryPlaylist, _ index: Int, _ direction: Int) {
        var ids = playlist.entries.map(\.id)
        ids.swapAt(index, index + direction)
        Task {
            await store.perform {
                _ = try await store.api.reorderPlaylistEntries(
                    playlistID: playlist.id, entryIDs: ids, version: playlist.version)
                await store.loadPlaylist(playlist.id)
            }
        }
    }
}
