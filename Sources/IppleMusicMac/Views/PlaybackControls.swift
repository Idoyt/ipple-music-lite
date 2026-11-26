import AppKit
import SwiftUI

struct PlaybackFavoriteControl: View {
    @Environment(AppStore.self) private var store
    @Environment(\.workspaceIsActive) private var workspaceIsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact = true
    var identifier = "compact-player"
    var detail: PlaybackDetailPresentation?
    static let selectedColor = Color(red: 0.96, green: 0.19, blue: 0.18)

    private var isFavorite: Bool {
        store.player.currentTrack.map { store.isFavorite($0.id) } ?? false
    }
    private var isUpdating: Bool {
        store.player.currentTrack.map { store.isUpdatingFavorite($0.id) } ?? false
    }
    private var isAdding: Bool {
        store.player.currentTrack.map { store.isAddingFavorite($0.id) } ?? false
    }
    private var label: String { isAdding ? "正在收藏" : isFavorite ? "取消收藏" : "收藏歌曲" }

    var body: some View {
        Button {
            guard let track = store.player.currentTrack else { return }
            Task { await store.toggleFavorite(track) }
        } label: {
            Image(systemName: "heart")
                .font(.system(size: compact ? 13 : 16))
                .hidden()
                .overlay {
                    FavoriteAnimatedSymbol(
                        pointSize: compact ? 13 : 16,
                        state: FavoriteSymbolState(
                            trackID: store.player.currentTrack?.id,
                            isFavorite: isFavorite, isAdding: isAdding, isUpdating: isUpdating,
                            isActive: detail?.isPresented ?? workspaceIsActive, reduceMotion: reduceMotion,
                            usesWhiteOutline: !compact)
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            .frame(width: compact ? 28 : 26, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(store.player.currentTrack == nil || isUpdating)
        .help(label).accessibilityLabel(label)
        .accessibilityValue(isAdding ? "等待确认" : isFavorite ? "已收藏" : "未收藏")
        .accessibilityIdentifier(identifier + ".favorite")
    }
}

struct PlaybackVolumeControl: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact = true
    var identifier = "compact-player"
    var isActive = true
    var onVisibilityChange: (Bool) -> Void = { _ in }
    @State private var showingVolume = false
    @State private var expansion: CGFloat = 0
    @State private var visibilityRevision = 0

    private var symbol: String {
        if store.player.volume == 0 { return "speaker.slash.fill" }
        if store.player.volume < 1.0 / 3 { return "speaker.wave.1.fill" }
        if store.player.volume < 2.0 / 3 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        @Bindable var player = store.player
        Button {
            setExpanded(!showingVolume)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: compact ? 13 : 14))
                .contentTransition(reduceMotion ? .identity : .opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: symbol)
                .scaleEffect(showingVolume && !reduceMotion ? 1.08 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: showingVolume)
                .frame(width: compact ? 28 : 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("音量").accessibilityLabel("音量")
        .accessibilityValue("\(Int(player.volume * 100))%")
        .accessibilityIdentifier(identifier + ".volume")
        .background {
            VolumeScrollControl(
                isEnabled: showingVolume && isActive, expandedLeadingWidth: 198,
                onDismiss: { setExpanded(false) }
            ) { adjustment in
                let volume = min(1, max(0, player.volume + adjustment))
                if volume != player.volume { player.volume = volume }
            }
        }
        .background(alignment: .trailing) {
            Color.clear
                .frame(width: (compact ? 28 : 32) + 198 * expansion, height: 36)
                .modifier(PlaybackInlineControlGlass())
                .opacity(expansion)
                .frame(width: compact ? 28 : 32, alignment: .trailing)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 10) {
                Slider(value: $player.volume, in: 0...1).accessibilityLabel("音量")
                    .controlSize(.small)
                    .accessibilityIdentifier(identifier + ".volume-slider")
                Text("\(Int(player.volume * 100))%")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 12).frame(width: 190, height: 36)
            .background { Color.clear.contentShape(Rectangle()).onTapGesture {} }
            .modifier(PlaybackInlineControlReveal(progress: expansion, width: 190))
            .offset(x: -(compact ? 36 : 40))
            .allowsHitTesting(showingVolume)
            .accessibilityHidden(!showingVolume)
        }
        .zIndex(1)
        .onChange(of: isActive) { _, active in if !active { setExpanded(false, animated: false) } }
        .onDisappear { setExpanded(false, animated: false) }
    }

    private func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard expanded != showingVolume || (!animated && expansion != 0) else { return }
        // Hide covered controls before the first expansion frame; restore them only after closing.
        visibilityRevision &+= 1
        let revision = visibilityRevision
        showingVolume = expanded
        if expanded { onVisibilityChange(true) }
        withAnimation(animated && !reduceMotion ? .easeInOut(duration: 0.22) : nil) {
            expansion = expanded ? 1 : 0
        } completion: {
            if revision == visibilityRevision, !showingVolume { onVisibilityChange(false) }
        }
    }

}

struct PlaybackInlineControlGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

struct PlaybackInlineControlReveal: ViewModifier, Animatable {
    nonisolated var progress: CGFloat
    var width: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // Slide out from the icon, clipping at its left edge without scaling the slider or text.
        content.offset(x: width * (1 - progress)).clipped()
    }
}

struct PlaybackProgressView: View {
    @Environment(\.workspaceIsActive) private var workspaceIsActive
    @Environment(AppStore.self) private var store
    var compact = true
    var identifier = "compact-player.progress"
    var detail: PlaybackDetailPresentation?
    @State private var editing = false
    @State private var seekPosition = 0.0
    @State private var seekingTrackID: String?

    private var position: Double {
        let active = detail?.isPresented ?? workspaceIsActive
        let current = active ? store.player.position : detail?.standbyPosition ?? 0
        return min(max(editing ? seekPosition : current, 0), max(store.player.duration, 1))
    }

    var body: some View {
        progress(store.player)
    }

    private func progress(_ player: PlaybackController) -> some View {
        VStack(spacing: compact ? 0 : 3) {
            HStack {
                Text(durationText(position))
                Spacer()
                Text(durationText(player.duration))
            }
            .font(.system(size: compact ? 9 : 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            .accessibilityHidden(true)
            Slider(
                value: Binding(get: { position }, set: { seekPosition = $0 }),
                in: 0...max(player.duration, 1),
                onEditingChanged: { value in
                    if value {
                        seekingTrackID = player.currentTrack?.id
                        seekPosition = player.position
                    }
                    editing = value
                    if !value, seekingTrackID == player.currentTrack?.id { player.seek(to: seekPosition) }
                }
            )
            .controlSize(compact ? .mini : .regular).disabled(!player.canSeek)
            .tint(Color(nsColor: .controlAccentColor))
            .accentColor(Color(nsColor: .controlAccentColor))
            .environment(\.controlActiveState, .key)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(durationText(position)) / \(durationText(player.duration))")
            .accessibilityIdentifier(identifier)
        }
        .help(player.currentTrack?.title ?? "播放进度")
        .onChange(of: player.currentTrack?.id) { _, _ in
            editing = false
            seekingTrackID = nil
            seekPosition = 0
        }
    }
}

struct PlaybackTransportControls: View {
    @Environment(\.workspaceIsActive) private var workspaceIsActive
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact = true
    var identifier = "compact-player"
    var isActive = true

    private var toggleLabel: String {
        if store.player.error != nil { return "重试播放" }
        return store.player.showsPauseControl ? "暂停" : "继续播放"
    }

    var body: some View {
        let player = store.player
        HStack(spacing: compact ? 2 : 16) {
            Button {
                Task { await player.previous() }
            } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: compact ? 28 : 42, height: compact ? 32 : 46)
                    .contentShape(Rectangle())
            }
            .help("上一首").accessibilityLabel("上一首").accessibilityIdentifier(identifier + ".previous")
            Button {
                Task { await player.togglePlayPause() }
            } label: {
                ZStack {
                    Circle().fill(Color(nsColor: .controlAccentColor).opacity(0.10))
                    if player.error != nil {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    } else {
                        PlaybackToggleSymbol(isPlaying: player.showsPauseControl,
                            pointSize: compact ? 13 : 20, animate: !reduceMotion,
                            isActive: isActive && (!compact || workspaceIsActive))
                            .frame(width: compact ? 18 : 28, height: compact ? 18 : 28)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }.frame(width: compact ? 30 : 50, height: compact ? 30 : 50)
            }
            .help(player.error ?? toggleLabel).accessibilityLabel(toggleLabel).accessibilityIdentifier(
                identifier + ".toggle")
            Button {
                Task { await player.next() }
            } label: {
                Image(systemName: "forward.end.fill")
                    .frame(width: compact ? 28 : 42, height: compact ? 32 : 46)
                    .contentShape(Rectangle())
            }
            .help("下一首").accessibilityLabel("下一首").accessibilityIdentifier(identifier + ".next")
        }
        .buttonStyle(.plain).font(.system(size: compact ? 13 : 20, weight: .semibold))
        .disabled(player.currentTrack == nil)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}
