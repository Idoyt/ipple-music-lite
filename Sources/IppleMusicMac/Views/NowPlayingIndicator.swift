import AppKit
import SwiftUI

struct NowPlayingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workspaceIsActive) private var workspaceIsActive
    var isPlaying: Bool
    var color: Color = Color(nsColor: .controlAccentColor)

    var body: some View {
        NativePlayingSymbol(active: isPlaying && !reduceMotion && workspaceIsActive, tint: NSColor(color))
            .frame(width: 17, height: 18)
            .accessibilityLabel(isPlaying ? "正在播放" : "播放已暂停")
            .accessibilityIdentifier("now-playing.indicator")
    }
}

private struct NativePlayingSymbol: NSViewRepresentable {
    var active: Bool
    var tint: NSColor

    func makeNSView(context: Context) -> NowPlayingSymbolView { NowPlayingSymbolView() }
    func updateNSView(_ view: NowPlayingSymbolView, context: Context) { view.configure(active: active, tint: tint) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NowPlayingSymbolView, context: Context) -> CGSize? {
        CGSize(width: 17, height: 18)
    }
    static func dismantleNSView(_ view: NowPlayingSymbolView, coordinator: ()) { view.stop() }
}

private final class PlayingSymbolVisibilityObservers: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    var observations: [NSKeyValueObservation] = []
    func reset() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
        for observation in observations { observation.invalidate() }
        observations = []
    }
    deinit { reset() }
}

/// AppKit decodes and advances the bundled GIF without entering SwiftUI's layout graph per frame.
/// Each view owns its image representation, so pausing one indicator cannot affect another.
@MainActor
final class NowPlayingSymbolView: NSImageView {
    private static let waveformData: Data? = Bundle.main.url(forResource: "PlayingWaveform", withExtension: "gif")
        .flatMap { try? Data(contentsOf: $0) }
    private let visibilityObservers = PlayingSymbolVisibilityObservers()
    private var requestedAnimation = false
    private(set) var isAnimating = false
    private(set) var animationStarts = 0

    override var intrinsicContentSize: NSSize { NSSize(width: 17, height: 18) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 17, height: 18))
        let waveform =
            Self.waveformData.flatMap(NSImage.init(data:))
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        waveform?.isTemplate = true
        image = waveform
        animates = false
        imageScaling = .scaleProportionallyDown
        imageAlignment = .alignCenter
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemColorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil
        )
    }
    required init?(coder: NSCoder) { nil }

    @objc private func systemColorsChanged() { needsDisplay = true }

    func configure(active: Bool, tint: NSColor) {
        requestedAnimation = active
        if contentTintColor != tint { contentTintColor = tint }
        updateAnimation()
    }

    func stop() {
        requestedAnimation = false
        updateAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeVisibility()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeVisibility()
    }
    override func viewDidHide() {
        super.viewDidHide()
        updateAnimation()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimation()
    }
    override func layout() {
        super.layout()
        updateAnimation()
    }

    private func observeVisibility() {
        visibilityObservers.reset()
        if let window {
            // Ordering an already occluded window out need not change occlusionState.
            // Observe actual visibility as well, so a hidden window never retains the GIF decoder timer.
            visibilityObservers.observations.append(
                window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.updateAnimation() }
                })
            for name in [
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification,
            ] {
                observe(name, object: window)
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observe(name, object: NSApplication.shared)
            }
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observe(NSView.boundsDidChangeNotification, object: clip)
        }
        updateAnimation()
    }

    private func observe(_ name: Notification.Name, object: AnyObject) {
        let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.updateAnimation() }
        }
        visibilityObservers.tokens.append(token)
    }

    private func updateAnimation() {
        let active =
            requestedAnimation && window?.isVisible == true && window?.isMiniaturized != true
            && !NSApplication.shared.isHidden && !isHiddenOrHasHiddenAncestor && visibleRect.intersects(bounds)
        guard active != isAnimating else { return }
        isAnimating = active
        if active { animationStarts += 1 }
        animates = active
    }

}
