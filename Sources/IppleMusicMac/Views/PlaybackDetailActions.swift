import MusicCore
import SwiftUI

struct PlaybackQualityControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let player: PlaybackController
    var isActive = true
    var onVisibilityChange: (Bool) -> Void = { _ in }
    @State private var isPresented = false
    @State private var expansion: CGFloat = 0
    @State private var visibilityRevision = 0
    @State private var availability: [PlaybackQuality: Bool] = [:]
    @State private var failure: String?
    @State private var selectionTask: Task<Void, Never>?
    @State private var pendingQuality: PlaybackQuality?
    @State private var selectionRevision = UUID()

    private let panelWidth: CGFloat = 244
    private let leadingWidth: CGFloat = 252
    private var qualities: [PlaybackQuality] { PlaybackQuality.allCases }
    private var selectedIndex: Int { qualities.firstIndex(of: pendingQuality ?? player.playbackQuality) ?? 0 }
    private var enabled: [Bool] {
        qualities.map { availability[$0] == true }
    }

    var body: some View {
        Button {
            setExpanded(!isPresented)
        } label: {
            Image(systemName: player.playbackQuality.symbol)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .help(failure ?? "音质 · \(player.playbackQuality.title)")
        .accessibilityLabel("音质").accessibilityValue(player.playbackQuality.title)
        .accessibilityIdentifier("player-details.quality")
        .background {
            PlaybackQualityScrollControl(
                isEnabled: isPresented && isActive, expandedLeadingWidth: leadingWidth,
                onDismiss: { setExpanded(false) }
            ) { direction in
                if let index = nextEnabledQualityIndex(from: selectedIndex, direction: direction, enabled: enabled) {
                    select(qualities[index])
                }
            }
        }
        .background(alignment: .trailing) {
            Color.clear.frame(width: 32 + leadingWidth * expansion, height: 36)
                .modifier(PlaybackInlineControlGlass())
                .opacity(expansion)
                .frame(width: 32, alignment: .trailing)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            PlaybackQualitySegments(
                titles: qualities.map(\.shortTitle), selected: selectedIndex, enabled: enabled,
                help: qualities.map { quality in
                    switch availability[quality] {
                    case true: quality.title
                    case false: "这首歌暂不支持\(quality.shortTitle)或当前账号无播放权限"
                    case nil: failure ?? "正在确认\(quality.shortTitle)是否可用"
                    }
                }
            ) { index in
                guard qualities.indices.contains(index) else { return }
                select(qualities[index])
            }
            .padding(.horizontal, 8).frame(width: panelWidth, height: 36)
            .modifier(PlaybackInlineControlReveal(progress: expansion, width: panelWidth))
            .offset(x: -40)
            .allowsHitTesting(isPresented)
            .accessibilityHidden(!isPresented)
        }
        .zIndex(isPresented ? 2 : 0)
        .task(id: isPresented) {
            guard isPresented else { return }
            failure = nil
            do {
                let result = try await player.playbackQualityAvailability()
                try Task.checkCancellation()
                availability = result
                if result.count < qualities.count { failure = "部分音质暂时无法确认，请稍后重新打开。" }
            } catch is CancellationError {
            } catch {
                failure = "暂时无法获取音质，请稍后重新打开。"
            }
        }
        .onChange(of: isActive) { _, active in if !active { setExpanded(false, animated: false) } }
        .onDisappear {
            selectionRevision = UUID()
            selectionTask?.cancel()
            selectionTask = nil
            pendingQuality = nil
            setExpanded(false, animated: false)
        }
    }

    private func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard expanded != isPresented || (!animated && expansion != 0) else { return }
        visibilityRevision &+= 1
        let revision = visibilityRevision
        isPresented = expanded
        if expanded { onVisibilityChange(true) }
        withAnimation(animated && !reduceMotion ? .easeInOut(duration: 0.22) : nil) {
            expansion = expanded ? 1 : 0
        } completion: {
            if revision == visibilityRevision, !isPresented { onVisibilityChange(false) }
        }
    }

    private func select(_ quality: PlaybackQuality) {
        guard availability[quality] == true, quality != pendingQuality else { return }
        if pendingQuality == nil, quality == player.playbackQuality, quality == player.preferredQuality { return }
        selectionTask?.cancel()
        let revision = UUID()
        selectionRevision = revision
        pendingQuality = quality
        failure = nil
        let trackID = player.currentTrack?.id
        selectionTask = Task { @MainActor in
            defer {
                if selectionRevision == revision { pendingQuality = nil; selectionTask = nil }
            }
            do {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                guard player.currentTrack?.id == trackID else { return }
                try await player.selectPlaybackQuality(quality)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, selectionRevision == revision, player.currentTrack?.id == trackID else { return }
                let unavailable = (error as? MusicAPIError)?.code == "NO_PLAYBACK"
                if unavailable {
                    availability[quality] = false
                    player.invalidatePlaybackQualityAvailability()
                }
                failure = unavailable ? "当前音乐源暂未提供这首歌的\(quality.shortTitle)。"
                    : "暂时无法切换音质。\(error.localizedDescription)"
            }
        }
    }
}

extension PlaybackQuality {
    fileprivate var symbol: String {
        switch self {
        case .standard: "waveform"
        case .high: "waveform.badge.plus"
        case .lossless: "waveform.path"
        }
    }

    fileprivate var shortTitle: String {
        switch self {
        case .standard: "标准"
        case .high: "高品质"
        case .lossless: "无损"
        }
    }

    fileprivate var title: String {
        switch self {
        case .standard: "标准 · 128 kbps"
        case .high: "高品质 · 320 kbps"
        case .lossless: "无损 · FLAC"
        }
    }
}
