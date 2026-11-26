import AppKit
import QuartzCore
import SwiftUI

/// Resize the lyric layout once, then move its existing backing layers on the compositor.
/// SwiftUI offset interpolation would otherwise drive native view layout on each frame.
struct PlaybackLyricsSlideHost<Content: View>: NSViewRepresentable {
    var identity: String
    var snapshot: PlaybackLyricsContent
    var reservedWidth: CGFloat
    var isPresented: Bool
    var animate: Bool
    @ViewBuilder var content: () -> Content

    final class Coordinator {
        var identity: String
        var snapshot: PlaybackLyricsContent
        init(identity: String, snapshot: PlaybackLyricsContent) {
            self.identity = identity
            self.snapshot = snapshot
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(identity: identity, snapshot: snapshot) }
    func makeNSView(context: Context) -> PlaybackLyricsSlideSurface<Content> {
        PlaybackLyricsSlideSurface(content: content())
    }
    func updateNSView(_ view: PlaybackLyricsSlideSurface<Content>, context: Context) {
        if context.coordinator.identity != identity || context.coordinator.snapshot != snapshot {
            context.coordinator.identity = identity
            context.coordinator.snapshot = snapshot
            view.host.rootView = content()
        }
        view.configure(reservedWidth: reservedWidth, isPresented: isPresented, animate: animate)
    }
    static func dismantleNSView(_ view: PlaybackLyricsSlideSurface<Content>, coordinator: Coordinator) {
        view.stop()
    }
}

final class PlaybackLyricsSlideSurface<Content: View>: NSView {
    let host: NSHostingView<Content>
    private var reservedWidth: CGFloat = 0
    private var presented = false
    private var laidOutSize = CGSize.zero
    private var animationFrom: CGFloat = 0
    private(set) var layoutCount = 0

    init(content: Content) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        wantsLayer = true
        host.wantsLayer = true
        host.sizingOptions = []
        addSubview(host)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    var displayedCenterX: CGFloat {
        guard let layer = host.layer, layer.animation(forKey: "lyrics-comment-slide") != nil else {
            return host.frame.midX
        }
        return host.frame.midX + (layer.presentation()?.transform.m41 ?? animationFrom)
    }

    func configure(reservedWidth: CGFloat, isPresented: Bool, animate: Bool) {
        let changed = self.reservedWidth != reservedWidth
        let visibleMotion = animate && presented && isPresented && changed
        self.reservedWidth = reservedWidth
        presented = isPresented
        placeContent(animated: visibleMotion)
        if !isPresented || !animate { stop() }
    }

    override func layout() {
        super.layout()
        if laidOutSize != bounds.size { placeContent(animated: false) }
    }

    private func placeContent(animated: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let available = max(1, bounds.width - reservedWidth)
        let width = min(780, available)
        let target = CGRect(x: (available - width) / 2, y: 0, width: width, height: bounds.height)
        let stableSize = laidOutSize == bounds.size
        laidOutSize = bounds.size
        guard host.frame != target else { return }
        let startCenter = displayedCenterX
        stop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = target
        host.layoutSubtreeIfNeeded()
        CATransaction.commit()
        layoutCount += 1
        guard animated, stableSize, window != nil, abs(startCenter - target.midX) > 0.5 else { return }
        animationFrom = startCenter - target.midX
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = animationFrom
        slide.toValue = 0
        slide.duration = 0.32
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        host.layer?.add(slide, forKey: "lyrics-comment-slide")
    }

    func stop() {
        host.layer?.removeAnimation(forKey: "lyrics-comment-slide")
        animationFrom = 0
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }
}
