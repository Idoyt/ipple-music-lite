import MusicCore
import SwiftUI

struct PlayerBar: View {
    @Environment(AppStore.self) private var store
    @State private var editing = false
    @State private var seekPosition = 0.0
    @State private var showLyrics = false
    @State private var showQueue = false

    var body: some View {
        @Bindable var player = store.player
        HStack(spacing: 24) {
            HStack(spacing: 12) {
                TrackArtwork(title: player.currentTrack?.title ?? "", size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(player.currentTrack?.title ?? "选择一首歌曲开始播放").font(.callout.weight(.medium)).lineLimit(1)
                    Text(player.currentTrack?.artists.joined(separator: " / ") ?? "你的音乐").font(.caption)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                if let track = player.currentTrack {
                    Button {
                        Task { await store.toggleFavorite(track) }
                    } label: {
                        Image(systemName: store.favoriteIDs.contains(track.id) ? "heart.fill" : "heart")
                            .foregroundStyle(
                                store.favoriteIDs.contains(track.id) ? PlaybackFavoriteControl.selectedColor : Color.secondary)
                    }.buttonStyle(.plain)
                }
            }.frame(minWidth: 225, maxWidth: 320, alignment: .leading)
            VStack(spacing: 7) {
                HStack(spacing: 24) {
                    Button {
                        player.shuffleEnabled.toggle()
                    } label: {
                        Image(systemName: "shuffle").foregroundStyle(
                            player.shuffleEnabled ? Color(nsColor: .controlAccentColor) : Color.secondary)
                    }.help("随机播放")
                    Button {
                        Task { await player.previous() }
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }.help("上一首")
                    Button {
                        Task { await player.togglePlayPause() }
                    } label: {
                        ZStack {
                            Circle().fill(Color(nsColor: .controlAccentColor))
                            if player.isLoading {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").foregroundStyle(.white)
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }.frame(width: 35, height: 35)
                    }.help(player.isPlaying ? "暂停" : "播放").accessibilityIdentifier("player.toggle")
                    Button {
                        Task { await player.next() }
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }.help("下一首")
                    Button {
                        player.repeatMode = player.repeatMode == .off ? .all : player.repeatMode == .all ? .one : .off
                    } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(
                            player.repeatMode == .off ? Color.secondary : Color(nsColor: .controlAccentColor))
                    }.help("循环模式")
                }.buttonStyle(.plain).disabled(player.currentTrack == nil && player.queue.isEmpty)
                HStack(spacing: 8) {
                    Text(durationText(editing ? seekPosition : player.position)).font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 35)
                    Slider(
                        value: Binding(get: { editing ? seekPosition : player.position }, set: { seekPosition = $0 }),
                        in: 0...max(player.duration, 1),
                        onEditingChanged: { value in
                            if value { seekPosition = player.position }
                            editing = value
                            if !value { player.seek(to: seekPosition) }
                        }
                    ).disabled(!player.canSeek).controlSize(.mini).accessibilityLabel("播放进度")
                    Text(durationText(player.duration)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 35)
                }
                if let error = player.error {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                } else if let notice = player.playbackNotice {
                    Text(notice).font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity)
            HStack(spacing: 13) {
                Button {
                    showLyrics = true
                } label: {
                    Image(systemName: "quote.bubble")
                }.help("歌词").disabled(player.currentTrack == nil)
                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                }.help("播放队列").disabled(player.isPersonalRadio)
                Image(systemName: player.volume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1).frame(width: 75).controlSize(.mini).accessibilityLabel("音量")
            }.buttonStyle(.plain)
        }.padding(.horizontal, 22).padding(.vertical, 14).background(.bar)
            .sheet(isPresented: $showLyrics) { LyricsView() }
            .sheet(isPresented: $showQueue) {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button("完成") { showQueue = false }
                    }.padding(20)
                    QueueView()
                }.frame(width: 820, height: 580)
            }
    }
}

struct QueueView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if store.player.isPersonalRadio {
            ContentUnavailableView("猜你喜欢", systemImage: "sparkles")
        } else {
            VStack(spacing: 0) {
                PageHeader(
                    title: "播放队列", subtitle: "拖动排序，安排接下来的音乐。", symbol: "list.bullet", count: store.player.queue.count)
                if store.player.isLoadingQQQueue {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在加载歌曲…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.horizontal, 28).padding(.bottom, 10)
                } else if let error = store.player.qqQueueError {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("重试加载队列") { store.player.retryQQQueueLoading() }
                    }.padding(.horizontal, 28).padding(.bottom, 10)
                }
                if store.player.queue.isEmpty {
                    ContentUnavailableView("队列还是空的", systemImage: "list.bullet", description: Text("在歌曲上右键选择「加入队列」。"))
                } else {
                    PlaybackFollowingList(currentRow: store.player.currentQueueIndex) {
                        List {
                            ForEach(Array(store.player.queue.enumerated()), id: \.offset) { index, track in
                                HStack(spacing: 14) {
                                    Group {
                                        if store.player.currentQueueIndex == index {
                                            NowPlayingIndicator(isPlaying: store.player.isPlaying)
                                        } else {
                                            Image(systemName: "music.note").foregroundStyle(.secondary)
                                        }
                                    }.frame(width: 20)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.title)
                                            .foregroundStyle(
                                                store.player.currentQueueIndex == index
                                                    ? Color(nsColor: .controlAccentColor) : Color.primary
                                            )
                                            .fontWeight(store.player.currentQueueIndex == index ? .semibold : .regular)
                                        Text(track.artists.joined(separator: " / ")).font(.caption).foregroundStyle(
                                            .secondary)
                                    }
                                    Spacer()
                                    Button {
                                        Task { await store.player.playQueueItem(at: index) }
                                    } label: {
                                        Image(systemName: "play.fill")
                                    }.help("播放")
                                    Button {
                                        store.player.removeFromQueue(at: index)
                                    } label: {
                                        Image(systemName: "xmark")
                                    }.help("移出队列")
                                }.padding(.vertical, 9).buttonStyle(.borderless).id(index)
                            }.onMove { from, to in store.player.moveInQueue(from: from, to: to) }
                        }.listStyle(.inset)
                    }
                }
            }.navigationTitle("播放队列")
        }
    }
}

struct LyricsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.player.currentTrack?.title ?? "歌词").font(.title2.bold())
                    Text(store.player.currentTrack?.artists.joined(separator: " / ") ?? "").foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            if let text {
                ScrollView {
                    Text(text.isEmpty ? "这首歌暂时没有歌词。" : text).font(.system(size: 18)).lineSpacing(14).textSelection(
                        .enabled
                    ).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(30).frame(width: 590, height: 620).task(id: store.player.currentTrack?.id) {
            guard let track = store.player.currentTrack else {
                text = "暂无正在播放的歌曲。"
                return
            }
            for binding in track.bindings {
                if let lyrics = try? await store.sourceLyrics(
                    sourceID: binding.sourceConnectionID, trackID: binding.sourceTrackID), !lyrics.text.isEmpty
                {
                    text = lyrics.text
                    return
                }
            }
            text = "这首歌暂时没有可用歌词。"
        }
    }
}
