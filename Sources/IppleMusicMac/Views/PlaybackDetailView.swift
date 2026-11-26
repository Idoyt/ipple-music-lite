import AppKit
import MusicCore
import Observation
import SwiftUI

enum PlaybackLyricsContent: Equatable {
    case loading
    case loaded(LyricsTimeline)
    case unavailable
    case failed
}

@MainActor @Observable
final class PlaybackDetailPresentation {
    var isPresented = false
    var standbyPosition = 0.0
}

struct PlaybackDetailContent: Equatable {
    let artwork: PlaybackArtworkSnapshot?
    let lyrics: PlaybackLyricsContent

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.artwork?.identity == rhs.artwork?.identity
            && lhs.artwork?.title == rhs.artwork?.title
            && lhs.artwork?.direction == rhs.artwork?.direction
            && lhs.artwork?.image === rhs.artwork?.image
            && lhs.lyrics == rhs.lyrics
    }
}

/// Keep the prewarmed detail graph at a fixed size and let AppKit handle its visibility.
struct PlaybackDetailHost<Content: View>: NSViewRepresentable {
    var isPresented: Bool
    var snapshot: PlaybackDetailContent
    var onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    final class Coordinator {
        var snapshot: PlaybackDetailContent
        var keyMonitor: Any?

        init(snapshot: PlaybackDetailContent) { self.snapshot = snapshot }
    }

    func makeCoordinator() -> Coordinator { Coordinator(snapshot: snapshot) }

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: content())
        host.sizingOptions = []
        host.isHidden = !isPresented
        let dismiss = onDismiss
        context.coordinator.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak host] event in
            let handled = MainActor.assumeIsolated {
                // Escape belongs to this visible panel in its window, including when a lyric row has focus.
                guard event.keyCode == 53,
                    event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                    let host, !host.isHidden, let window = host.window,
                    event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil
                else { return false }
                dismiss()
                return true
            }
            return handled ? nil : event
        }
        return host
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
        if context.coordinator.snapshot != snapshot {
            context.coordinator.snapshot = snapshot
            view.rootView = content()
        }
        if view.isHidden == isPresented { view.isHidden = !isPresented }
    }

    static func dismantleNSView(_ view: NSHostingView<Content>, coordinator: Coordinator) {
        if let monitor = coordinator.keyMonitor { NSEvent.removeMonitor(monitor) }
        coordinator.keyMonitor = nil
    }
}

struct PlaybackDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var artwork: PlaybackArtworkSnapshot?
    var presentation: PlaybackDetailPresentation
    var lyrics: PlaybackLyricsContent
    var onRetryLyrics: () -> Void
    var onClose: () -> Void
    @State private var showQueue = false
    @State private var volumeExpanded = false
    @State private var qualityExpanded = false
    @State private var showComments = false
    @State private var comments = PlaybackCommentsModel()

    private var commentBinding: LibraryBinding? {
        guard let track = store.player.currentTrack else { return nil }
        return playbackBindings(track: track, sources: store.sources).first { binding in
            store.sources.contains { $0.id == binding.sourceConnectionID && $0.kind == "qq" }
        }
    }

    private var identity: String {
        playbackPresentationIdentity(userID: store.user?.id, track: store.player.currentTrack, sources: store.sources)
    }

    var body: some View {
        Group {
            if store.player.currentTrack != nil {
                GeometryReader { geometry in
                    let commentsVisible = showComments && presentation.isPresented && commentBinding != nil
                    let commentWidth = min(400, geometry.size.width * 0.38)
                    let reservedWidth = commentsVisible ? commentWidth + 1 : 0
                    ZStack {
                        PlaybackLyricsSlideHost(
                            identity: identity, snapshot: lyrics, reservedWidth: reservedWidth,
                            isPresented: presentation.isPresented, animate: !reduceMotion
                        ) {
                            PlaybackDetailLyrics(
                                content: lyrics, identity: identity, presentation: presentation, onRetry: onRetryLyrics
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .environment(store)
                            .environment(\.colorScheme, .dark)
                            .tint(Color(nsColor: .controlAccentColor))
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        if commentsVisible, let binding = commentBinding {
                            HStack(spacing: 0) {
                                Divider().frame(width: 1).padding(.vertical, 12)
                                PlaybackCommentsPanel(
                                    model: comments, api: store.api, binding: binding,
                                    trackTitle: store.player.currentTrack?.title ?? "",
                                    identity: identity,
                                    onClose: { showComments = false })
                                    .id(identity)
                                    .frame(width: commentWidth)
                            }
                            .frame(width: commentWidth + 1, height: geometry.size.height)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                }
                .safeAreaInset(edge: .bottom, spacing: 18) {
                    playbackBar.frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView("暂无正在播放的歌曲", systemImage: "music.note")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .tint(Color(nsColor: .controlAccentColor))
        .task(id: "\(identity):\(presentation.isPresented)") {
            comments.prepare(identity: identity)
            if presentation.isPresented, let binding = commentBinding {
                await comments.loadInitial(api: store.api, binding: binding)
            }
        }
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

    private var playbackBar: some View {
        let player = store.player
        return VStack(spacing: 10) {
            ZStack {
                HStack(spacing: 18) {
                    if let track = player.currentTrack {
                        HStack(spacing: 11) {
                            PlaybackArtworkButton(symbol: "chevron.down", action: onClose) {
                                PlaybackArtworkWipe(artwork: artwork) { snapshot in
                                    PlaybackArtworkView(
                                        image: snapshot?.image, title: snapshot?.title ?? track.title, size: 38)
                                }
                            }
                            .help("收起播放详情")
                            .accessibilityLabel("收起播放详情：\(track.title)")
                            .accessibilityIdentifier("player-details.artwork")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    .help(track.title).accessibilityIdentifier("player-details.title")
                                Text(track.artists.isEmpty ? "未知歌手" : track.artists.joined(separator: " / "))
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    .accessibilityIdentifier("player-details.artist")
                            }.frame(width: 142, alignment: .leading)

                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        if player.currentTrack != nil {
                            PlaybackQualityControl(
                                player: player, isActive: presentation.isPresented && !volumeExpanded,
                                onVisibilityChange: { qualityExpanded = $0 }).id(identity)
                                .opacity(volumeExpanded ? 0 : 1)
                                .allowsHitTesting(!volumeExpanded).accessibilityHidden(volumeExpanded)
                            PlaybackCommentsControl(
                                model: comments, isPresented: $showComments, isEnabled: commentBinding != nil)
                                .opacity(volumeExpanded ? 0 : 1)
                                .allowsHitTesting(!volumeExpanded).accessibilityHidden(volumeExpanded)
                        }
                        PlaybackVolumeControl(
                            compact: false, identifier: "player-details", isActive: presentation.isPresented && !qualityExpanded,
                            onVisibilityChange: { volumeExpanded = $0 })
                        if !player.isPersonalRadio {
                            Button {
                                showQueue = true
                            } label: {
                                Image(systemName: "list.bullet").frame(width: 32, height: 32)
                            }
                            .help("播放队列").accessibilityLabel("播放队列")
                            .accessibilityIdentifier("player-details.queue")
                        }
                    }.buttonStyle(.plain).zIndex(1)
                }.zIndex(1)
                VStack(spacing: 4) {
                    HStack(spacing: 18) {
                        playbackModeButton
                        PlaybackTransportControls(compact: false, identifier: "player-details",
                            isActive: presentation.isPresented && !volumeExpanded && !qualityExpanded)
                        PlaybackFavoriteControl(compact: false, identifier: "player-details", detail: presentation)
                    }.buttonStyle(.plain)
                        .opacity(volumeExpanded || qualityExpanded ? 0 : 1)
                        .allowsHitTesting(!volumeExpanded && !qualityExpanded)
                        .accessibilityHidden(volumeExpanded || qualityExpanded)
                    PlaybackProgressView(
                        compact: true, identifier: "player-details.progress", detail: presentation)
                }.frame(width: 280)
            }.frame(height: 80)
            if let error = player.error { Text(error).font(.caption).foregroundStyle(.red) }
            if let notice = player.playbackNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .frame(maxWidth: 800)
        .modifier(PlaybackBarGlass())
    }

    private var playbackModeButton: some View {
        let player = store.player
        let mode = player.playbackMode
        return Button {
            player.cyclePlaybackMode()
        } label: {
            Image(systemName: mode.symbol)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(width: 26, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlaybackModeButtonStyle())
        .accessibilityLabel("播放模式")
        .accessibilityValue(mode.title)
        .accessibilityHint("切换为\(mode.next.title)")
        .accessibilityIdentifier("player-details.playback-mode")
        .help(player.isPersonalRadio ? "猜你喜欢会自动续播" : "当前为\(mode.title)，点按切换为\(mode.next.title)")
        .disabled(player.isPersonalRadio)
    }
}

private struct PlaybackModeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Personal radio disables switching; its symbol should still remain white.
        configuration.label.foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct PlaybackDetailLyrics: View {
    @Environment(AppStore.self) private var store
    let content: PlaybackLyricsContent
    let identity: String
    let presentation: PlaybackDetailPresentation
    let onRetry: () -> Void

    var body: some View {
        let presentationReady = presentation.isPresented
        switch content {
        case .loaded(let timeline):
            let player = store.player
            SynchronizedLyricsView(
                timeline: timeline,
                position: presentationReady ? player.lyricPresentationPosition : presentation.standbyPosition,
                canSeek: player.canSeek, centered: true,
                onSeek: { player.seek(to: $0) }, isPlaying: presentationReady && player.isPlaying,
                playbackClock: { player.lyricPlaybackPosition() },
                playbackClockID: presentationReady ? player.lyricClockID : nil,
                observeCueStarts: presentationReady ? player.observeLyricBoundaries : nil,
                isPresented: presentationReady
            )
            .id(identity)
        case .failed:
            lyricsUnavailable("暂时无法加载歌词")
        case .unavailable:
            lyricsUnavailable("这首歌暂时没有歌词")
        case .loading:
            if presentationReady { LyricsLoadingIndicator().id(identity) }
        }
    }

    private func lyricsUnavailable(_ title: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "text.quote")
        } actions: {
            Button("重试", action: onRetry).accessibilityIdentifier("player-details.lyrics-retry")
        }
    }
}

private struct LyricsLoadingIndicator: View {
    @State private var visible = false

    var body: some View {
        Color.clear.overlay {
            if visible { ProgressView().accessibilityLabel("正在加载歌词") }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { visible = true }
        }
    }
}

extension PlaybackMode {
    fileprivate var title: String {
        switch self {
        case .sequential: "顺序播放"
        case .shuffle: "随机播放"
        case .repeatOne: "单曲循环"
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .sequential: "list.number"
        case .shuffle: "shuffle"
        case .repeatOne: "repeat.1"
        }
    }
}

private struct PlaybackBarGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.10), lineWidth: 0.5))
        }
    }
}
