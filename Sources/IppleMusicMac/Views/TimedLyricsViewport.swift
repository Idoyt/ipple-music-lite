import AppKit
import MusicCore
import QuartzCore
import SwiftUI

struct TimedLyricsViewport: NSViewRepresentable {
    let cues: [LyricCue]
    let activeRow: Int?
    let position: Double
    let isPlaying: Bool
    let clock: (@MainActor () -> Double)?
    let canSeek: Bool
    let centered: Bool
    let following: Bool
    let isPresented: Bool
    let onManualScroll: () -> Void
    let onSeek: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> TimedLyricScrollView { TimedLyricScrollView() }

    func updateNSView(_ view: TimedLyricScrollView, context: Context) {
        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != appearance { view.appearance = NSAppearance(named: appearance) }
        view.configure(self, animated: !reduceMotion)
    }

    static func dismantleNSView(_ view: TimedLyricScrollView, coordinator: ()) {
        view.stopFollowingAnimation()
    }
}

final class TimedLyricScrollView: NSScrollView {
    private struct RowFrame {
        let frame: CGRect
        let originalHeight: CGFloat
    }

    private let document = LyricDocument()
    private let fade = CAGradientLayer()
    private var configuration: TimedLyricsViewport?
    private var metrics: [RowFrame] = []
    private var visibleRows: [Int: NativeLyricRow] = [:]
    private var measuredSize: CGSize = .zero
    private var settingOffset = false
    private var canAnimate = false
    private var animationStart: CGFloat?
    private var manual = false
    private var preparedRowsRect = CGRect.zero
    private let returnClock = LyricReturnClock()

    // The override only interrupts following; AppKit still handles precision and momentum events.
    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = false
        verticalScrollElasticity = .none
        wantsLayer = true
        document.wantsLayer = true
        documentView = document
        document.prepareRows = { [weak self] rect in
            guard let self else { return }
            let nearby = contentView.bounds.insetBy(dx: 0, dy: -measuredSize.height)
            prepareRows(in: rect.intersection(nearby))
        }
        contentView.wantsLayer = true
        contentView.postsBoundsChangedNotifications = true
        layer?.mask = fade
        fade.colors = [CGColor.clear, CGColor.black, CGColor.black, CGColor.clear]
        fade.locations = [0, 0.05, 0.94, 1]
        setAccessibilityIdentifier("player-details.lyrics")
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { nil }

    var displayedOffset: CGFloat {
        let target = contentView.bounds.minY
        guard let layer = document.layer, layer.animation(forKey: "lyric-follow") != nil else { return target }
        if let presentation = layer.presentation() {
            return target - presentation.transform.m42 * layerDirection
        }
        return animationStart ?? target
    }

    // NSClipView uses the document's flippedness. Its backing layer may use the reverse Y axis.
    private var layerDirection: CGFloat { contentView.layer?.isGeometryFlipped == true ? 1 : -1 }

    func configure(_ next: TimedLyricsViewport, animated: Bool) {
        let previous = configuration
        configuration = next
        canAnimate = animated
        let resumes = manual && next.following && previous?.following == false
        if !next.following {
            settleAnimation()
            manual = true
        }
        if next.following, previous?.following == false { manual = false }
        if previous?.cues != next.cues || previous?.centered != next.centered {
            measuredSize = .zero
            preparedRowsRect = .zero
            for row in visibleRows.values { row.removeFromSuperview() }
            visibleRows.removeAll()
        }
        if layoutRowsIfNeeded() { return }

        let changedPresentation = previous?.isPresented != next.isPresented
        if !manual, resumes || previous?.activeRow != next.activeRow || changedPresentation {
            let visibleMotion = animated && next.isPresented && previous?.isPresented == true
            center(
                next.activeRow ?? 0, animated: visibleMotion && (resumes || next.isPlaying),
                preserveCenteredPosition: changedPresentation,
                fromCurrentPosition: resumes || returnClock.timer != nil)
        }
        if previous?.canSeek != next.canSeek {
            for (index, row) in visibleRows { update(row, at: index) }
        } else {
            if let old = previous?.activeRow, old != next.activeRow, let row = visibleRows[old] {
                update(row, at: old)
            }
            if let active = next.activeRow, let row = visibleRows[active] { update(row, at: active) }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        CATransaction.commit()
        _ = layoutRowsIfNeeded()
    }

    @discardableResult private func layoutRowsIfNeeded() -> Bool {
        let size = contentView.bounds.size
        guard let configuration, size.width > 0, size.height > 0, size != measuredSize else { return false }
        let previousOffset = displayedOffset
        measuredSize = size
        preparedRowsRect = .zero
        stopFollowingAnimation()
        let horizontal = configuration.centered ? 82.0 : 18.0
        let width = max(1, size.width - horizontal * 2)
        let originalStyle = lyricTextAttributes(size: 20, translation: false, centered: configuration.centered)
        let translationStyle = lyricTextAttributes(size: 18, translation: true, centered: configuration.centered)
        var y = size.height / 2
        metrics = configuration.cues.map { cue in
            let original = cue.words.isEmpty ? cue.text : cue.words.map(\.text).joined()
            let originalHeight = textHeight(original, attributes: originalStyle, width: width) + 4
            let translationHeight =
                cue.translation.map {
                    textHeight($0, attributes: translationStyle, width: width) + 6
                } ?? 0
            let height = originalHeight + translationHeight + 20
            let frame = CGRect(x: horizontal, y: y, width: width, height: height)
            y += height + 6
            return RowFrame(frame: frame, originalHeight: originalHeight)
        }
        settingOffset = true
        document.frame.size = CGSize(width: size.width, height: y + size.height / 2)
        settingOffset = false
        if manual {
            move(to: previousOffset, animated: false)
        } else {
            center(configuration.activeRow ?? 0, animated: false)
        }
        return true
    }

    private func textHeight(_ text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat) -> CGFloat {
        ceil(
            (text as NSString).boundingRect(
                with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes
            ).height)
    }

    private func center(
        _ row: Int, animated: Bool, preserveCenteredPosition: Bool = false, fromCurrentPosition: Bool = false
    ) {
        guard metrics.indices.contains(row) else { return }
        let target = metrics[row].frame.midY - measuredSize.height / 2
        if preserveCenteredPosition, document.layer?.animation(forKey: "lyric-follow") == nil,
            abs(target - contentView.bounds.minY) < 0.5
        {
            return
        }
        move(to: target, animated: animated, fromCurrentPosition: fromCurrentPosition)
    }

    private func move(to offset: CGFloat, animated: Bool, fromCurrentPosition: Bool = false) {
        guard let layer = document.layer else { return }
        let before = displayedOffset
        let maxY = max(0, document.frame.height - measuredSize.height)
        let target = min(max(offset, 0), maxY)
        stopFollowingAnimation()
        // Keep the adjacent rows alive while the compositor moves them across the viewport.
        let distance = target - before
        if fromCurrentPosition, animated, window != nil, abs(distance) > 1 {
            returnToCurrentLine(from: before, to: target)
            return
        }
        let from = target - min(max(distance, -measuredSize.height), measuredSize.height)
        let moves = animated && window != nil && abs(distance) > 1
        updateVisibleRows(from: moves ? min(from, target) : target, to: moves ? max(from, target) : target)
        setOffset(target)
        guard moves else { return }

        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = (target - from) * layerDirection
        animation.toValue = 0
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animationStart = from
        layer.add(animation, forKey: "lyric-follow")
    }

    // Every manual return moves the real viewport, including short moves near the
    // document edges where a translated layer can expose a premature clip jump.
    // Keep ordinary playback following on the compositor and prepare visible rows only.
    private func returnToCurrentLine(from start: CGFloat, to target: CGFloat) {
        let started = ProcessInfo.processInfo.systemUptime
        let screens = abs(target - start) / max(1, measuredSize.height)
        let duration = min(0.65, 0.28 + Double(screens) * 0.045)
        setOffset(start)
        updateVisibleRows(from: start, to: start)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.window != nil, !self.manual, self.configuration?.isPresented == true else {
                    self.returnClock.cancel()
                    return
                }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / duration)
                let eased = progress * progress * (3 - 2 * progress)
                let y = start + (target - start) * eased
                self.setOffset(y)
                self.updateVisibleRows(from: y, to: y)
                if progress == 1 { self.returnClock.cancel() }
            }
        }
        returnClock.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopFollowingAnimation() {
        returnClock.cancel()
        document.layer?.removeAnimation(forKey: "lyric-follow")
        animationStart = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopFollowingAnimation() }
    }

    private func setOffset(_ y: CGFloat) {
        settingOffset = true
        contentView.scroll(to: .init(x: 0, y: y))
        reflectScrolledClipView(contentView)
        settingOffset = false
    }

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY != 0 { interruptFollowing() }
        super.scrollWheel(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSApp.currentEvent?.type == .leftMouseDown, frame.contains(point) {
            settleAnimation()
        }
        return super.hitTest(point)
    }

    private func settleAnimation() {
        returnClock.cancel()
        guard let layer = document.layer, layer.animation(forKey: "lyric-follow") != nil else { return }
        let position = displayedOffset
        layer.removeAnimation(forKey: "lyric-follow")
        setOffset(position)
    }

    private func interruptFollowing() {
        settleAnimation()
        guard !manual else { return }
        manual = true
        configuration?.onManualScroll()
    }

    @objc private func boundsChanged() {
        guard !settingOffset, !metrics.isEmpty, contentView.bounds.size == measuredSize else { return }
        let offset = contentView.bounds.minY
        interruptFollowing()
        updateVisibleRows(from: offset, to: offset)
    }

    private func updateVisibleRows(from: CGFloat, to: CGFloat) {
        prepareRows(in: CGRect(x: 0, y: from, width: measuredSize.width, height: to - from + measuredSize.height))
    }

    private func prepareRows(in requested: CGRect) {
        guard !settingOffset, !metrics.isEmpty, measuredSize.height > 0 else { return }
        // Bound AppKit's speculative overdraw. Keep extra rows while manually scrolling so tiny
        // trackpad deltas do not repeatedly create views, measure text and rebuild accessibility.
        let viewport = contentView.bounds
        let limit = manual ? viewport.insetBy(dx: 0, dy: -measuredSize.height) : document.bounds
        let required = requested.intersection(limit).intersection(document.bounds)
        guard !required.isNull, !required.isEmpty else { return }
        if preparedRowsRect.contains(required) {
            document.preparedContentRect = preparedRowsRect
            return
        }
        let padding = manual ? measuredSize.height * 0.75 : min(96, measuredSize.height * 0.18)
        let coverage = required.insetBy(dx: 0, dy: -padding).intersection(document.bounds)
        let minY = coverage.minY
        let maxY = coverage.maxY
        var lower = 0
        var upper = metrics.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if metrics[middle].frame.maxY < minY { lower = middle + 1 } else { upper = middle }
        }
        let visible = (lower..<metrics.count).prefix { metrics[$0].frame.minY <= maxY }
        let previous = Set(visibleRows.keys)
        for index in Array(visibleRows.keys) where !visible.contains(index) {
            visibleRows.removeValue(forKey: index)?.removeFromSuperview()
        }
        for index in visible {
            let metric = metrics[index]
            if let row = visibleRows[index] {
                row.place(in: metric.frame, originalHeight: metric.originalHeight)
                continue
            }
            guard let cue = configuration?.cues[index] else { continue }
            let row = NativeLyricRow(cue: cue)
            row.place(in: metric.frame, originalHeight: metric.originalHeight)
            update(row, at: index)
            document.addSubview(row)
            visibleRows[index] = row
        }
        if previous != Set(visibleRows.keys) {
            document.setAccessibilityChildren(visible.compactMap { visibleRows[$0] })
        }
        preparedRowsRect = coverage
        document.preparedContentRect = coverage
    }

    private func update(_ row: NativeLyricRow, at index: Int) {
        guard let configuration else { return }
        let active = index == configuration.activeRow
        let cues = configuration.cues
        let endTime = cues.indices.contains(index + 1) ? cues[index + 1].time : .infinity
        row.update(
            active: active, position: active ? configuration.position : cues[index].time.nextDown, endTime: endTime,
            playing: active && configuration.isPlaying,
            clock: active && configuration.isPlaying ? configuration.clock : nil,
            canSeek: configuration.canSeek, centered: configuration.centered
        ) { [weak self] time in
            guard let self else { return }
            manual = false
            center(index, animated: canAnimate)
            configuration.onSeek(time)
        }
    }
}

private final class LyricReturnClock: @unchecked Sendable {
    var timer: Timer?
    func cancel() {
        timer?.invalidate()
        timer = nil
    }
    deinit { timer?.invalidate() }
}

private func lyricTextAttributes(size: CGFloat, translation: Bool, centered: Bool) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = centered ? .center : .left
    paragraph.lineSpacing = translation ? 4 : 6
    paragraph.lineBreakMode = .byWordWrapping
    return [
        .font: NSFont.systemFont(ofSize: size, weight: translation ? .medium : .semibold), .paragraphStyle: paragraph,
    ]
}

private final class NativeLyricRow: NSView {
    let cue: LyricCue
    private let wordLine: WordLyricsView?
    private let originalLabel: NativeLyricLabel?
    private let translation: NativeLyricLabel?

    init(cue: LyricCue) {
        self.cue = cue
        wordLine = cue.words.isEmpty ? nil : WordLyricsView()
        originalLabel = cue.words.isEmpty ? NativeLyricLabel(text: cue.text, translation: false) : nil
        translation = cue.translation.map { NativeLyricLabel(text: $0, translation: true) }
        super.init(frame: .zero)
        let identifier = "player-details.lyric.\(cue.id)"
        setAccessibilityIdentifier(identifier)
        if wordLine != nil {
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
        }
        translation?.setAccessibilityIdentifier(identifier + ".translation")
        originalLabel?.setAccessibilityIdentifier(identifier)
        originalLabel?.toolTip = "跳转到 \(durationText(max(cue.time, 0)))"
        let content: [NSView?] = [wordLine, originalLabel, translation]
        for subview in content.compactMap({ $0 }) { addSubview(subview) }
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func place(in frame: CGRect, originalHeight: CGFloat) {
        let height = wordLine?.frame.height ?? originalLabel?.frame.height
        guard self.frame != frame || height != originalHeight else { return }
        self.frame = frame
        let head = CGRect(x: 0, y: 10, width: frame.width, height: originalHeight)
        wordLine?.frame = head
        originalLabel?.frame = head
        translation?.frame = CGRect(
            x: 0, y: head.maxY + 6, width: frame.width, height: frame.height - originalHeight - 26)
    }

    func update(
        active: Bool, position: Double, endTime: Double, playing: Bool, clock: (@MainActor () -> Double)?,
        canSeek: Bool, centered: Bool, onSeek: @escaping (Double) -> Void
    ) {
        wordLine?.configure(
            cue: cue, endTime: endTime, position: position, isPlaying: playing, clock: clock, canSeek: canSeek,
            centered: centered, onSeek: onSeek)
        let time = max(cue.time, 0)
        originalLabel?.configure(centered: centered, active: active, canSeek: canSeek) { onSeek(time) }
        translation?.configure(centered: centered, active: false, canSeek: canSeek) { onSeek(time) }
    }
}

private final class LyricDocument: NSView {
    var prepareRows: ((CGRect) -> Void)?
    override var isFlipped: Bool { true }

    override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: rect)
        prepareRows?(rect)
    }
}

private final class NativeLyricLabel: NSView {
    private let text: String
    private let translation: Bool
    private var centered = true
    private var active = false
    private var canSeek = false
    private var action: (() -> Void)?

    init(text: String, translation: Bool) {
        self.text = text
        self.translation = translation
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func configure(centered: Bool, active: Bool, canSeek: Bool, action: @escaping () -> Void) {
        if self.centered != centered || self.active != active { needsDisplay = true }
        if self.canSeek != canSeek {
            setAccessibilityEnabled(canSeek)
            window?.invalidateCursorRects(for: self)
        }
        self.centered = centered
        self.active = active
        self.canSeek = canSeek
        self.action = action
    }

    override func draw(_ dirtyRect: NSRect) {
        var attributes = lyricTextAttributes(size: translation ? 18 : 20, translation: translation, centered: centered)
        attributes[.foregroundColor] =
            active
            ? NSColor.controlAccentColor
            : NSColor.labelColor.withAlphaComponent(translation ? 0.48 : centered ? 0.62 : 0.42)
        (text as NSString).draw(
            with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { _ = accessibilityPerformPress() }

    override func accessibilityPerformPress() -> Bool {
        guard canSeek else { return false }
        action?()
        return true
    }

    override func resetCursorRects() {
        if canSeek { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
