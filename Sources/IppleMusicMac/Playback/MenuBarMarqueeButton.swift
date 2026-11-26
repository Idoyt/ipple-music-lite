import AppKit
import QuartzCore

/// Installed as the status item's root view, never as a child of NSStatusBarButton.
/// Core Animation moves one cached glyph mask without application frame callbacks.
@MainActor
final class MenuBarMarqueeButton: NSButton {
    // The app ribbon's filled silhouette, centered for the menu bar.
    private static let appSymbol: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -7.8, y: -0.7))
        path.addCurve(
            to: CGPoint(x: -5.9, y: 0.5),
            control1: CGPoint(x: -7.6, y: 0.1), control2: CGPoint(x: -6.7, y: 0.5))
        path.addCurve(
            to: CGPoint(x: -2.3, y: -1.5),
            control1: CGPoint(x: -4.5, y: 0.5), control2: CGPoint(x: -3.7, y: -1.8))
        path.addCurve(
            to: CGPoint(x: 2.8, y: 4.4),
            control1: CGPoint(x: -0.8, y: 1.1), control2: CGPoint(x: 0.2, y: 4.4))
        path.addCurve(
            to: CGPoint(x: 7.2, y: 1.1),
            control1: CGPoint(x: 5.4, y: 4.4), control2: CGPoint(x: 5.6, y: 1.0))
        path.addCurve(
            to: CGPoint(x: 6.4, y: -0.7),
            control1: CGPoint(x: 8.6, y: 1.3), control2: CGPoint(x: 8.2, y: -0.6))
        path.addCurve(
            to: CGPoint(x: 2.4, y: 1.4),
            control1: CGPoint(x: 4.8, y: -0.8), control2: CGPoint(x: 3.5, y: 1.9))
        path.addCurve(
            to: CGPoint(x: -2.9, y: -4.4),
            control1: CGPoint(x: 1, y: -0.6), control2: CGPoint(x: 0.1, y: -4.4))
        path.addCurve(
            to: CGPoint(x: -7.1, y: -1.4),
            control1: CGPoint(x: -5.4, y: -4.4), control2: CGPoint(x: -5.8, y: -1.2))
        path.addCurve(
            to: CGPoint(x: -7.8, y: -0.7),
            control1: CGPoint(x: -7.6, y: -1.5), control2: CGPoint(x: -8, y: -1.1))
        path.closeSubpath()
        return path
    }()
    private let clip = CALayer()
    private let ink = CALayer()
    private let glyphs = CALayer()
    private let sungInk = CALayer()
    private var marquee: MenuBarLyricMarquee?
    private var lyric: MenuBarLyricPresentation?
    private var scrollPlan: MenuBarLyricScrollPlan?
    private var animationRequested = false
    private var playbackPosition = 0.0
    private var playbackHostTime = CACurrentMediaTime()
    private var playbackAdvancing = false
    private var planNeedsSynchronization = false
    private var paused = true
    private var displayingLyrics = false
    private(set) var transportImage: NSImage?
    private var pressedPoint: NSPoint?
    var onPointerUp: ((NSPoint, NSPoint, NSEvent) -> Void)?
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private(set) var glyphBuilds = 0
    private(set) var renderPasses = 0
    var lyricText: String? { marquee?.text }
    var hasMarquee: Bool { (marquee?.maxOffset ?? 0) > 0 }
    var animationIsRunning: Bool { hasMarquee && !paused }
    var appSymbolRect: NSRect {
        NSRect(x: bounds.maxX - 24, y: bounds.midY - 10, width: 20, height: 20)
    }
    var transportCanvasRect: NSRect { bounds.insetBy(dx: 8, dy: (bounds.height - 18) / 2) }
    var lyricViewportWidth: CGFloat { max(0, floor(appSymbolRect.minX - lyricLeadingEdge - 6)) }
    private var lyricLeadingEdge: CGFloat { bounds.minX + 8 }
    var presentationOffset: CGFloat {
        guard hasMarquee, !(paused && ink.timeOffset == 0) else { return 0 }
        return -(ink.presentation()?.transform.m41 ?? ink.transform.m41)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: frame.width, height: NSStatusBar.system.thickness) }
    override var allowsVibrancy: Bool { true }

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: NSStatusBar.system.thickness))
        isBordered = false
        font = MenuBarLyricMarquee.font
        cell?.lineBreakMode = .byTruncatingTail
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        wantsLayer = true
        clip.masksToBounds = true
        clip.isHidden = true
        ink.mask = glyphs
        // A mask's default .resize gravity can squeeze its full line into the viewport
        // when AppKit lays out a status-item replica. Only the clip may use that width.
        glyphs.contentsGravity = .left
        glyphs.anchorPoint = .zero
        ink.anchorPoint = .zero
        sungInk.anchorPoint = .zero
        sungInk.isHidden = true
        ink.addSublayer(sungInk)
        clip.addSublayer(ink)
        layer?.addSublayer(clip)
    }
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressedPoint = pointerInButton()
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = pressedPoint else { return }
        pressedPoint = nil
        guard let end = pointerInButton(), bounds.contains(end) else { return }
        onPointerUp?(start, end, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        mouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        mouseUp(with: event)
    }

    func pointerInButton() -> NSPoint? {
        guard let window else { return nil }
        // A menu-bar replica can forward a centered event even when it names this window.
        return convert(window.convertPoint(fromScreen: pointerLocation()), from: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        renderPasses += 1
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.labelColor
            if let transportImage, dirtyRect.intersects(transportCanvasRect) {
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                transportImage.draw(
                    in: transportCanvasRect, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
                color.setFill()
                transportCanvasRect.fill(using: .sourceIn)
                context.endTransparencyLayer()
            }
            guard dirtyRect.intersects(appSymbolRect) else { return }
            context.saveGState()
            context.translateBy(x: appSymbolRect.midX, y: appSymbolRect.midY)
            context.scaleBy(x: 1, y: isFlipped ? -1 : 1)
            context.setFillColor(color.cgColor)
            context.addPath(Self.appSymbol)
            context.fillPath()
            context.restoreGState()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateInk()
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = CGRect(
            x: lyricLeadingEdge, y: bounds.midY - 9, width: lyricViewportWidth, height: 18)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard displayingLyrics, let existing = marquee else { return }
        showLyrics(existing.text, reduceMotion: existing.truncatesToViewport, active: !paused, lyric: lyric)
    }

    func showLyrics(_ text: String, reduceMotion: Bool, active: Bool, lyric: MenuBarLyricPresentation? = nil) {
        var refreshSnapshot = transportImage != nil
        transportImage = nil
        displayingLyrics = true
        title = ""
        let width = lyricViewportWidth
        let scale = window?.backingScaleFactor ?? 2
        if marquee?.text != text || marquee?.viewportWidth != width || marquee?.scale != scale
            || marquee?.truncatesToViewport != reduceMotion
        {
            refreshSnapshot = true
            resetMarquee()
            if let new = MenuBarLyricMarquee(
                text: text, viewportWidth: width, scale: scale, truncatesToViewport: reduceMotion)
            {
                marquee = new
                glyphBuilds += 1
                installAnimation(new, lyric: lyric)
            }
        } else if self.lyric != lyric, let marquee {
            refreshSnapshot = true
            installAnimation(marquee, lyric: lyric)
        }
        self.lyric = lyric
        setMarqueeVisible(marquee != nil)
        setAnimationActive(active)
        if refreshSnapshot {
            needsDisplay = true
            layer?.setNeedsDisplay()
            displayIfNeeded()
        }
    }

    func showTransport(_ image: NSImage) {
        displayingLyrics = false
        setAnimationActive(false)
        setMarqueeVisible(false)
        title = ""
        guard transportImage !== image else { return }
        transportImage = image
        needsDisplay = true
        layer?.setNeedsDisplay()
        displayIfNeeded()
    }

    func setAnimationActive(_ active: Bool) {
        animationRequested = active
        if scrollPlan != nil {
            let position = playbackPosition + (playbackAdvancing ? CACurrentMediaTime() - playbackHostTime : 0)
            synchronizeTimedAnimation(position: position, active: active && playbackAdvancing)
            return
        }
        guard hasMarquee, active == paused else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if active {
            let time = ink.timeOffset
            ink.speed = 1
            ink.timeOffset = 0
            ink.beginTime = 0
            ink.beginTime = ink.convertTime(CACurrentMediaTime(), from: nil) - time
        } else {
            let time = ink.convertTime(CACurrentMediaTime(), from: nil)
            ink.speed = 0
            ink.timeOffset = time
        }
        paused = !active
        CATransaction.commit()
    }

    func resetMarquee() {
        ink.removeAllAnimations()
        sungInk.removeAllAnimations()
        glyphs.contents = nil
        marquee = nil
        lyric = nil
        scrollPlan = nil
        planNeedsSynchronization = false
        paused = true
        setMarqueeVisible(false)
    }

    func synchronizePlayback(position: Double, isPlaying: Bool) {
        guard position.isFinite else { return }
        playbackPosition = max(position, 0)
        playbackHostTime = CACurrentMediaTime()
        playbackAdvancing = isPlaying
        guard displayingLyrics, animationRequested || !isPlaying else { return }
        synchronizeTimedAnimation(position: position, active: animationRequested && isPlaying)
    }

    private func synchronizeTimedAnimation(position: Double, active: Bool) {
        guard let plan = scrollPlan else { return }
        let time = min(max(position - plan.cueTime, 0), plan.duration)
        let advancing = active && time < plan.duration
        let wallTime = CACurrentMediaTime()
        let localTime = ink.convertTime(wallTime, from: nil)
        guard planNeedsSynchronization || advancing == paused || abs(localTime - time) > (advancing ? 0.06 : 0.001)
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.beginTime = 0
        if advancing {
            ink.speed = 1
            ink.timeOffset = 0
            ink.beginTime = clip.convertTime(wallTime, from: nil) - time
        } else {
            ink.speed = 0
            ink.timeOffset = time
        }
        paused = !advancing
        planNeedsSynchronization = false
        CATransaction.commit()
    }

    private func installAnimation(_ marquee: MenuBarLyricMarquee, lyric: MenuBarLyricPresentation?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = CGSize(width: CGFloat(marquee.image.width) / marquee.scale, height: 18)
        ink.transform = CATransform3DIdentity
        ink.bounds = CGRect(origin: .zero, size: size)
        // Short lines sit against the trailing edge. Long lines start at the leading edge
        // and retain their natural width for the existing scroll animation.
        let inset = max(0, marquee.viewportWidth - size.width)
        ink.position = CGPoint(x: inset, y: 0)
        glyphs.bounds = CGRect(origin: .zero, size: size)
        glyphs.position = .zero
        glyphs.contents = marquee.image
        glyphs.contentsScale = marquee.scale
        ink.speed = 0
        ink.beginTime = 0
        ink.timeOffset = 0
        ink.removeAllAnimations()
        sungInk.removeAllAnimations()
        scrollPlan = marquee.truncatesToViewport ? nil : lyric.map {
            MenuBarLyricScrollPlan(lyric: $0, marquee: marquee)
        }
        planNeedsSynchronization = scrollPlan != nil
        sungInk.isHidden = scrollPlan == nil
        if let plan = scrollPlan {
            sungInk.bounds = CGRect(origin: .zero, size: size)
            let progress = CAKeyframeAnimation(keyPath: "bounds.size.width")
            progress.beginTime = 1e-9
            progress.values = plan.fillPoints.map(\.offset)
            progress.keyTimes = plan.fillPoints.map { NSNumber(value: $0.time / plan.duration) }
            progress.duration = plan.duration
            progress.calculationMode = .linear
            progress.fillMode = .both
            progress.isRemovedOnCompletion = false
            sungInk.add(progress, forKey: "lyric-fill")
        }
        updateInk()
        // Menu-bar replicas can retain their last snapshot when only sublayer masks change.
        // Invalidate the root once per cue/geometry change; playback frames never redraw it.
        needsDisplay = true
        guard marquee.maxOffset > 0 else {
            paused = true
            needsLayout = true
            CATransaction.commit()
            return
        }
        let hold: Double = 1
        let travel = Double(marquee.maxOffset) / 30 + 0.5
        let duration = 2 * (hold + travel)
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        if let plan = scrollPlan {
            // Zero means "start on commit"; an explicit local origin preserves seeks before commit.
            animation.beginTime = 1e-9
            animation.values = plan.points.map { -$0.offset }
            animation.keyTimes = plan.points.map { NSNumber(value: $0.time / plan.duration) }
            animation.calculationMode = .linear
            animation.duration = plan.duration
            animation.fillMode = .both
        } else {
            animation.values = [0, 0, -marquee.maxOffset, -marquee.maxOffset, 0]
            animation.keyTimes = [
                0, NSNumber(value: hold / duration), NSNumber(value: (hold + travel) / duration),
                NSNumber(value: (2 * hold + travel) / duration), 1,
            ]
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            animation.duration = duration
            animation.repeatCount = .infinity
        }
        animation.isRemovedOnCompletion = false
        ink.add(animation, forKey: "lyric-scroll")
        paused = true
        needsLayout = true
        CATransaction.commit()
    }

    private func setMarqueeVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.isHidden = !visible
        CATransaction.commit()
    }
    private func updateInk() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let color = NSColor.labelColor
            ink.backgroundColor = (sungInk.isHidden ? color : color.withAlphaComponent(0.58)).cgColor
            sungInk.backgroundColor = color.cgColor
            CATransaction.commit()
        }
    }
}
