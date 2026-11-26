import AppKit
import MusicCore
import QuartzCore

private final class WordPressElement: NSAccessibilityElement {
    var action: (() -> Void)?
    var frameProvider: (() -> NSRect)?
    override func accessibilityFrame() -> NSRect { frameProvider?() ?? super.accessibilityFrame() }
    override func accessibilityPerformPress() -> Bool {
        guard let action else { return false }
        action()
        return true
    }
}

/// Native text layout preserves wrapping, kerning and Unicode ranges while allowing exact glyph hit testing.
final class WordLyricsView: NSView {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
    private var cue: LyricCue?
    private var centered = false
    private var position = 0.0
    private var isPlaying = false
    private var endTime = Double.infinity
    private var playbackClock: (@MainActor () -> Double)?
    private let baseInk = CALayer()
    private let accentClip = CALayer()
    private let accentInk = CALayer()
    private let glyphMask = CALayer()
    private let fillMask = CALayer()
    private var needsFillUpdate = true
    private(set) var rasterizationCount = 0
    var hasAnimatedFill: Bool { fillMask.sublayers?.contains { $0.animation(forKey: "word-fill") != nil } ?? false }
    private var canSeek = false
    private var onSeek: ((Double) -> Void)?
    private var ranges: [NSRange] = []
    private var fragments: [[NSRect]] = []
    private var elements: [WordPressElement]?
    private var layoutWidth: CGFloat = 0
    private var measuredHeights: [CGFloat: CGFloat] = [:]

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        wantsLayer = true
        layer?.addSublayer(baseInk)
        layer?.addSublayer(accentClip)
        accentClip.addSublayer(accentInk)
        accentClip.mask = fillMask
        accentInk.mask = glyphMask
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemColorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        cue: LyricCue, endTime: Double, position: Double, isPlaying: Bool, clock: (@MainActor () -> Double)?,
        canSeek: Bool, centered: Bool, onSeek: @escaping (Double) -> Void
    ) {
        let changed = self.cue != cue || self.centered != centered
        let seekingChanged = self.canSeek != canSeek
        let time = clock?() ?? position
        if changed || self.position != time || self.isPlaying != isPlaying || self.endTime != endTime {
            needsFillUpdate = true
            needsDisplay = true
        }
        self.cue = cue
        self.position = time
        self.centered = centered
        self.endTime = endTime
        self.isPlaying = isPlaying
        self.playbackClock = clock
        self.canSeek = canSeek
        self.onSeek = onSeek
        if changed {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = centered ? .center : .left
            paragraph.lineSpacing = 6
            paragraph.lineBreakMode = .byWordWrapping
            let text = cue.words.map(\.text).joined()
            storage.setAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .paragraphStyle: paragraph,
                        .foregroundColor: NSColor.labelColor.withAlphaComponent(0.62),
                    ]))
            var offset = 0
            ranges = cue.words.map { word in
                let length = (word.text as NSString).length
                defer { offset += length }
                return NSRange(location: offset, length: length)
            }
            elements = nil
            layoutWidth = 0
            measuredHeights.removeAll(keepingCapacity: true)
            invalidateInk()
        }
        if changed || seekingChanged {
            for element in elements ?? [] { element.setAccessibilityEnabled(canSeek) }
            window?.invalidateCursorRects(for: self)
        }
    }

    func textHeight(width: CGFloat) -> CGFloat {
        if let height = measuredHeights[width] { return height }
        prepareTextLayout(width: width)
        let height = ceil(manager.usedRect(for: container).height) + 4
        if measuredHeights.count >= 4 { measuredHeights.removeAll(keepingCapacity: true) }
        measuredHeights[width] = height
        return height
    }

    private func prepareTextLayout(width: CGFloat) {
        let width = max(1, width)
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
    }

    private func updateLayout(width: CGFloat) {
        guard abs(layoutWidth - width) > 0.25 || fragments.count != ranges.count else { return }
        layoutWidth = width
        invalidateInk()
        prepareTextLayout(width: width)
        fragments = ranges.map { range in
            var rects: [NSRect] = []
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateLineFragments(forGlyphRange: glyphs) { [manager, container] _, _, _, lineRange, _ in
                let intersection = NSIntersectionRange(glyphs, lineRange)
                if intersection.length > 0 {
                    rects.append(
                        manager.boundingRect(forGlyphRange: intersection, in: container).offsetBy(dx: 0, dy: 2))
                }
            }
            return rects
        }
    }

    override func layout() {
        super.layout()
        updateLayout(width: bounds.width)
    }

    override func accessibilityChildren() -> [Any]? {
        if let elements { return elements }
        guard let cue else { return [] }
        let children = cue.words.enumerated().compactMap { index, word -> WordPressElement? in
            guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let element = WordPressElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(word.text)
            element.setAccessibilityIdentifier("player-details.lyric.\(cue.id).word.\(index)")
            element.setAccessibilityHelp("跳转到 \(durationText(max(word.time, 0)))")
            element.setAccessibilityParent(self)
            element.setAccessibilityEnabled(canSeek)
            element.frameProvider = { [weak self] in self?.screenFrame(for: index) ?? .zero }
            element.action = { [weak self] in
                guard let self, self.canSeek, let cue = self.cue, cue.words.indices.contains(index) else { return }
                self.onSeek?(max(cue.words[index].time, 0))
            }
            return element
        }
        elements = children
        return children
    }

    private func screenFrame(for index: Int) -> NSRect {
        guard let window else { return .zero }
        updateLayout(width: bounds.width)
        guard fragments.indices.contains(index) else { return .zero }
        let rect = fragments[index].reduce(NSRect.null) { $0.union($1) }
        return rect.isNull ? .zero : window.convertToScreen(convert(rect, to: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsFillUpdate = true
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateInk()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateInk()
    }

    @objc private func systemColorsChanged() { invalidateInk() }

    private func invalidateInk() {
        baseInk.contents = nil
        glyphMask.contents = nil
        needsFillUpdate = true
        needsDisplay = true
    }

    private func updateFill(_ cue: LyricCue, at time: Double) {
        fillMask.sublayers = nil
        guard time >= cue.time, time < endTime else { return }
        let animates = isPlaying && window != nil
        let start = CACurrentMediaTime()
        for (word, pieces) in zip(cue.words, fragments) {
            let total = pieces.reduce(0) { $0 + $1.width }
            guard total > 0 else { continue }
            var elapsed = word.time
            for piece in pieces {
                let portion = word.duration * piece.width / total
                let duration = max(portion, 0.001)
                let fraction = portion > 0 ? min(1, max(0, (time - elapsed) / portion)) : (time >= elapsed ? 1 : 0)
                if fraction > 0 || (animates && elapsed < endTime) {
                    let box = CALayer()
                    box.anchorPoint = .zero
                    box.position = piece.origin
                    box.backgroundColor = CGColor(gray: 1, alpha: 1)
                    let end = min(elapsed + duration, endTime)
                    let remaining = end - max(elapsed, time)
                    let completes = animates && elapsed < endTime && fraction < 1 && time < end
                    let width = completes ? piece.width * min(1, (end - elapsed) / duration) : piece.width * fraction
                    box.bounds = CGRect(x: 0, y: 0, width: width, height: piece.height)
                    fillMask.addSublayer(box)
                    if completes {
                        let fill = CABasicAnimation(keyPath: "bounds.size.width")
                        fill.fromValue = piece.width * fraction
                        fill.toValue = width
                        fill.beginTime = box.convertTime(start + max(0, elapsed - time), from: nil)
                        fill.duration = remaining
                        fill.timingFunction = CAMediaTimingFunction(name: .linear)
                        fill.fillMode = .backwards
                        box.add(fill, forKey: "word-fill")
                    }
                }
                elapsed += portion
            }
        }
    }

    private func rasterize(color: NSColor, size: NSSize) -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        guard
            let context = CGContext(
                data: nil, width: max(1, Int(ceil(size.width * scale))),
                height: max(1, Int(ceil(size.height * scale))), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: storage.length))
        manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: NSPoint(x: 0, y: 2))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        updateLayout(width: bounds.width)
        guard let cue, bounds.width > 0, storage.length > 0 else { return }
        if baseInk.contents == nil {
            prepareTextLayout(width: bounds.width)
            let size = NSSize(width: bounds.width, height: ceil(manager.usedRect(for: container).height) + 4)
            let frame = NSRect(origin: .zero, size: size)
            baseInk.frame = frame
            baseInk.opacity = centered ? 0.62 : 0.42
            accentClip.frame = frame
            accentInk.frame = frame
            glyphMask.frame = frame
            fillMask.frame = frame
            let glyphs = rasterize(color: NSColor.labelColor.withAlphaComponent(1), size: size)
            baseInk.contents = glyphs
            glyphMask.contents = glyphs
            accentInk.backgroundColor = NSColor.controlAccentColor.cgColor
            rasterizationCount += 1
        }
        guard needsFillUpdate else { return }
        needsFillUpdate = false
        let time = playbackClock?() ?? position
        updateFill(cue, at: time)
    }

    override func mouseDown(with event: NSEvent) {
        guard canSeek, let cue, !cue.words.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let index = fragments.firstIndex(where: { $0.contains { $0.contains(point) } }) {
            onSeek?(max(cue.words[index].time, 0))
        } else {
            onSeek?(max(cue.time, 0))
        }
    }

    override func resetCursorRects() {
        if canSeek { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
