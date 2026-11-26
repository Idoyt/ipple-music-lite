import AppKit
import MusicCore
import SwiftUI

struct SynchronizedLyricsView: View {
    var timeline: LyricsTimeline
    var position: Double
    var canSeek: Bool
    var centered = false
    var onSeek: (Double) -> Void
    var isPlaying = false
    var playbackClock: (@MainActor () -> Double)? = nil
    var playbackClockID: ObjectIdentifier? = nil
    var observeCueStarts: (@MainActor ([Double], @escaping @MainActor () -> Void) -> () -> Void)? = nil
    var isPresented = true
    @State private var following = true
    @State private var boundaryPosition: Double?
    @State private var stopObserving: (() -> Void)?

    private var playbackTime: Double {
        guard isPlaying else { return position }
        // Native cue callbacks invalidate the view between the player's periodic updates.
        let fallback = boundaryPosition ?? position
        return playbackClock?() ?? fallback
    }

    var body: some View {
        if timeline.sungCues.isEmpty {
            if timeline.plainText.isEmpty {
                ContentUnavailableView("这首歌暂时没有歌词", systemImage: "text.quote")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        Text(timeline.plainText).font(.system(size: 20, weight: .medium)).lineSpacing(12)
                        if let translation = timeline.plainTranslation {
                            Text(translation).font(.system(size: 18)).lineSpacing(8).foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled).multilineTextAlignment(centered ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                }
            }
        } else {
            timedLyrics
        }
    }

    private var timedLyrics: some View {
        let time = playbackTime
        let cues = timeline.sungCues
        return TimedLyricsViewport(
            cues: cues, activeRow: timeline.activeSungCueIndex(at: time), position: time, isPlaying: isPlaying,
            clock: playbackClock, canSeek: canSeek, centered: centered, following: following, isPresented: isPresented,
            onManualScroll: { following = false },
            onSeek: {
                following = true
                onSeek($0)
            }
        )
        .onChange(of: playbackClockID, initial: true) { _, _ in
            stopObserving?()
            let starts = cues.map(\.time).filter { $0 > 0 }
            stopObserving = starts.isEmpty ? nil : observeCueStarts?(starts) { boundaryPosition = playbackClock?() }
        }
        .onChange(of: isPresented) { _, shown in
            if !shown { following = true }
        }
        .onDisappear {
            stopObserving?()
            stopObserving = nil
        }
        .overlay(alignment: .bottom) {
            Button {
                following = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "scope").foregroundStyle(.white)
                    Text("回到当前句")
                }.font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 13).padding(.vertical, 9).contentShape(Capsule())
            }
            .buttonStyle(.plain).modifier(LyricFollowGlass())
            .help("恢复自动跟随，不改变播放进度")
            .accessibilityIdentifier("lyrics-follow.resume")
            .padding(10)
            .opacity(following ? 0 : 1)
            .allowsHitTesting(!following)
            .accessibilityHidden(following)
            .animation(.easeInOut(duration: 0.18), value: following)
        }
    }

}

private struct LyricFollowGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}
