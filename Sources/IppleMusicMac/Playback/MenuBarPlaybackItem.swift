import AppKit
import MusicCore

/// The menu bar keeps the most recently started lyric through instrumental gaps.
struct MenuBarLyricTimeline {
    private struct Line {
        var lyric: MenuBarLyricPresentation
    }
    private let lines: [Line]
    var startTimes: [Double] { lines.map(\.lyric.time).filter { $0 > 0 } }

    init(_ timeline: LyricsTimeline?) {
        let cues = timeline?.cues ?? []
        lines = cues.enumerated().compactMap { index, cue in
            let wordTexts = cue.words.map { $0.text.components(separatedBy: .newlines).joined(separator: " ") }
            let fullText =
                cue.words.isEmpty
                ? cue.text.components(separatedBy: .newlines).joined(separator: " ") : wordTexts.joined()
            let text =
                fullText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let nsText = fullText as NSString
            let leading = nsText.rangeOfCharacter(from: .whitespacesAndNewlines.inverted).location
            let visibleRange = NSRange(location: leading == NSNotFound ? 0 : leading, length: (text as NSString).length)
            var offset = 0
            let words = cue.words.enumerated().compactMap { wordIndex, word -> MenuBarLyricWord? in
                let length = (wordTexts[wordIndex] as NSString).length
                let range = NSIntersectionRange(NSRange(location: offset, length: length), visibleRange)
                defer { offset += length }
                guard range.length > 0 else { return nil }
                return MenuBarLyricWord(
                    range: NSRange(location: range.location - visibleRange.location, length: range.length),
                    time: word.time, duration: word.duration)
            }
            let end: Double?
            if words.isEmpty {
                end = cues.indices.contains(index + 1) ? cues[index + 1].time : nil
            } else {
                end =
                    cues.dropFirst(index + 1).first {
                        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }?.time
            }
            return Line(
                lyric: MenuBarLyricPresentation(cueID: cue.id, time: cue.time, endTime: end, text: text, words: words))
        }
    }

    func presentation(at position: Double, duration: Double = 0) -> MenuBarLyricPresentation? {
        guard position.isFinite, position >= 0 else { return nil }
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lines[middle].lyric.time <= position { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return nil }
        var result = lines[lower - 1].lyric
        if result.endTime == nil, duration.isFinite, duration > result.time { result.endTime = duration }
        return result
    }

    func title(at position: Double, trackTitle: String?) -> String {
        presentation(at: position)?.text ?? Self.fallback(trackTitle)
    }

    private static func fallback(_ trackTitle: String?) -> String {
        (trackTitle ?? "Ipple Music").components(separatedBy: .newlines).joined(separator: " ")
    }
}

struct MenuBarPlaybackState: Equatable {
    var title: String
    var isPlaying: Bool
    var isLoading: Bool
    var hasTrack: Bool
    var isFavorite = false
    var isFavoriteUpdating = false
    var lyric: MenuBarLyricPresentation? = nil

    static func title(timeline: LyricsTimeline?, position: Double, trackTitle: String?) -> String {
        MenuBarLyricTimeline(timeline).title(at: position, trackTitle: trackTitle)
    }
}

private enum MenuBarControl: Int, CaseIterable {
    case previous, toggle, next, favorite, open

    var identifier: String {
        switch self {
        case .previous: "menubar.previous"
        case .toggle: "menubar.play-pause"
        case .next: "menubar.next"
        case .favorite: "menubar.favorite"
        case .open: "menubar.open"
        }
    }
}

private final class MenuBarAccessibleButton: NSAccessibilityElement {
    var action: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        guard isAccessibilityEnabled() else { return false }
        action?()
        return true
    }
}

private final class MenuBarResources: @unchecked Sendable {
    var observations: [NSKeyValueObservation] = []
    var notifications: [NSObjectProtocol] = []
    var eventMonitors: [Any] = []
    func removeEventMonitors() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
    }
    deinit {
        for observation in observations { observation.invalidate() }
        for token in notifications { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        removeEventMonitors()
    }
}

/// The status item owns one root control. Cached glyphs move in Core Animation,
/// avoiding NSStatusBarButton child snapshots and application frame callbacks.
@MainActor
final class MenuBarPlaybackItem: NSObject {
    let button = MenuBarMarqueeButton(width: AppSettings.defaultMenuBarWidth)
    private weak var statusItem: NSStatusItem?
    private let resources = MenuBarResources()
    private var screensSleeping = false
    private var stopped = false
    private let reduceMotion: () -> Bool
    private let pointerLocation: () -> NSPoint
    var isScrolling: Bool { button.animationIsRunning }
    var scrollOffset: CGFloat { button.presentationOffset }
    private var hoverTracking: NSTrackingArea?
    private let actions = MenuBarControl.allCases.map { _ in MenuBarAccessibleButton() }
    private let transportControls: [MenuBarControl] = [.previous, .toggle, .next, .favorite]
    private let transportWidth: CGFloat = 108
    private var transportImages: [Int: NSImage] = [:]
    private(set) var isHovered = false
    private(set) var state: MenuBarPlaybackState?
    private(set) var presentationUpdates = 0
    var onPrevious: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onFavorite: (() -> Void)?
    var onShowWindow: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var playbackPosition: (() -> Double)?

    init(
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }
    ) {
        self.reduceMotion = reduceMotion
        self.pointerLocation = pointerLocation
        super.init()
        for control in MenuBarControl.allCases {
            let action = actions[control.rawValue]
            action.setAccessibilityRole(.button)
            action.setAccessibilityIdentifier(control.identifier)
            action.action = { [weak self] in self?.invoke(control) }
        }
        configure(.init(title: "Ipple Music", isPlaying: false, isLoading: false, hasTrack: false))
    }

    func install(in statusItem: NSStatusItem) {
        self.statusItem = statusItem
        button.frame.size.width = statusItem.length
        statusItem.view = button
        button.font = MenuBarLyricMarquee.font
        button.cell?.lineBreakMode = .byTruncatingTail
        button.target = self
        button.action = #selector(pressed)
        button.pointerLocation = pointerLocation
        button.onPointerUp = { [weak self] start, end, event in
            guard let self, !self.stopped else { return }
            if event.type == .rightMouseUp {
                self.onContextMenu?(event)
                return
            }
            guard let control = self.control(at: start), control == self.control(at: end) else { return }
            self.invoke(control)
        }
        let tracking = NSTrackingArea(
            rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        button.addTrackingArea(tracking)
        hoverTracking = tracking
        // Status-item replicas don't reliably forward custom tracking-area events to their owner.
        // Observe movement as well as tracking callbacks; never poll or consume the input event.
        let movement: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: movement,
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.updatePointerHover() }
                return event
            })
        {
            resources.eventMonitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: movement,
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePointerHover() }
            })
        {
            resources.eventMonitors.append(monitor)
        }
        button.setAccessibilityLabel("Ipple Music 播放控制器")
        resources.observations.append(
            statusItem.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshAnimationState() }
            })
        if let window = button.window {
            resources.observations.append(
                window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.refreshAnimationState() }
                })
        }
        for name in [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
        ] {
            let token = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.screensDidSleepNotification { self.screensSleeping = true }
                    if name == NSWorkspace.screensDidWakeNotification { self.screensSleeping = false }
                    self.updatePointerHover()
                    self.render()
                }
            }
            resources.notifications.append(token)
        }
        render()
        updatePointerHover()
    }

    func stop() {
        stopped = true
        resources.removeEventMonitors()
        if let hoverTracking { button.removeTrackingArea(hoverTracking) }
        hoverTracking = nil
        button.setAnimationActive(false)
        button.resetMarquee()
        button.onPointerUp = nil
    }

    func configure(_ state: MenuBarPlaybackState) {
        guard state != self.state else { return }
        self.state = state
        presentationUpdates += 1
        render()
    }

    func synchronizePlayback(position: Double) {
        button.synchronizePlayback(position: position, isPlaying: state?.isPlaying == true && state?.isLoading == false)
    }

    func setWidth(_ value: Double) {
        guard let statusItem else { return }
        let width = AppSettings.normalizedMenuBarWidth(value)
        guard statusItem.length != width else { return }
        statusItem.length = width
        button.frame.size.width = width
        transportImages.removeAll(keepingCapacity: true)
        button.window?.contentView?.layoutSubtreeIfNeeded()
        render()
    }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        render()
    }

    @objc func mouseEntered(with event: NSEvent) { setHovered(true) }
    @objc func mouseExited(with event: NSEvent) { setHovered(false) }

    private func updatePointerHover() {
        guard !stopped, let point = button.pointerInButton() else { return }
        let inside =
            !screensSleeping && statusItem?.isVisible == true && button.window?.isVisible == true
            && button.bounds.contains(point)
        setHovered(inside)
    }

    func transportRect(at index: Int) -> NSRect {
        return NSRect(
            x: button.appSymbolRect.minX - 4 - transportWidth + CGFloat(index) * 28, y: 0, width: 24,
            height: button.bounds.height)
    }

    private func controlRect(_ control: MenuBarControl) -> NSRect {
        control == .open ? button.appSymbolRect : transportRect(at: control.rawValue)
    }

    private func control(at point: NSPoint) -> MenuBarControl? {
        if controlRect(.open).contains(point) { return .open }
        guard isHovered else { return nil }
        return transportControls.first { controlRect($0).contains(point) }
    }

    private func invoke(_ control: MenuBarControl) {
        guard !stopped, let state, actionEnabled(control, state) else { return }
        switch control {
        case .previous: onPrevious?()
        case .toggle: onToggle?()
        case .next: onNext?()
        case .favorite: onFavorite?()
        case .open: onShowWindow?()
        }
    }

    private func actionEnabled(_ control: MenuBarControl, _ state: MenuBarPlaybackState) -> Bool {
        if control == .open { return true }
        guard state.hasTrack else { return false }
        switch control {
        case .previous, .next: return !state.isLoading
        case .favorite: return !state.isFavoriteUpdating
        case .toggle, .open: return true
        }
    }

    @objc private func pressed() {
        guard !stopped else { return }
        // The system menu-bar replica can send the root action without forwarding mouseDown/mouseUp.
        // Its action has no button index. Resolve the current screen point with the same hit areas.
        guard let point = button.pointerInButton() else { return }
        if let control = control(at: point) { invoke(control) }
    }

    private func render() {
        guard let state else { return }
        button.toolTip = state.title
        button.setAccessibilityValue(state.title)
        if isHovered {
            button.showTransport(transportImage(state))
        } else {
            button.showLyrics(state.title, reduceMotion: reduceMotion(), active: animationAllowed, lyric: state.lyric)
            if let playbackPosition { synchronizePlayback(position: playbackPosition()) }
        }
        let visibleControls = isHovered ? MenuBarControl.allCases : [.open]
        button.setAccessibilityChildren(visibleControls.map { control in
            let action = actions[control.rawValue]
            action.setAccessibilityParent(button)
            action.setAccessibilityLabel(controlLabel(control, state))
            action.setAccessibilityEnabled(actionEnabled(control, state))
            if control == .favorite { action.setAccessibilityValue(state.isFavorite ? "已收藏" : "未收藏") }
            if let window = button.window {
                action.setAccessibilityFrame(window.convertToScreen(button.convert(controlRect(control), to: nil)))
            }
            return action
        })
        refreshAnimationState()
    }

    private func controlLabel(_ control: MenuBarControl, _ state: MenuBarPlaybackState) -> String {
        switch control {
        case .previous: "上一首"
        case .toggle: state.isPlaying || state.isLoading ? "暂停" : "播放"
        case .next: "下一首"
        case .favorite: state.isFavorite ? "取消收藏" : "收藏"
        case .open: "打开 Ipple Music"
        }
    }

    private var animationAllowed: Bool {
        !stopped && !isHovered && !screensSleeping && !reduceMotion()
            && state?.isPlaying == true && state?.isLoading == false
            && statusItem?.isVisible == true && button.window?.isVisible == true
    }

    private func refreshAnimationState() { button.setAnimationActive(animationAllowed) }

    private func transportImage(_ state: MenuBarPlaybackState) -> NSImage {
        let key =
            (state.isPlaying || state.isLoading ? 1 : 0) | (state.hasTrack ? 2 : 0)
            | (state.isLoading ? 4 : 0) | (state.isFavorite ? 8 : 0) | (state.isFavoriteUpdating ? 16 : 0)
        if let cached = transportImages[key] { return cached }
        let canvas = button.transportCanvasRect
        let image = NSImage(size: canvas.size)
        image.lockFocus()
        for control in transportControls {
            let name: String
            switch control {
            case .previous: name = "backward.end"
            case .toggle: name = state.isPlaying || state.isLoading ? "pause" : "play"
            case .next: name = "forward.end"
            case .favorite: name = state.isFavorite ? "heart.fill" : "heart"
            case .open: continue
            }
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            let enabled = actionEnabled(control, state)
            if let symbol {
                let center = controlRect(control).midX - canvas.minX
                symbol.draw(
                    in: Self.fittedSymbolRect(
                        size: symbol.size,
                        box: NSRect(x: center - 8, y: 2, width: 16, height: 14)),
                    from: .zero, operation: .sourceOver, fraction: enabled ? 1 : 0.35)
            }
        }
        image.unlockFocus()
        image.isTemplate = true
        transportImages[key] = image
        return image
    }

    static func fittedSymbolRect(size: NSSize, box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let factor = min(box.width / size.width, box.height / size.height)
        let fitted = NSSize(width: size.width * factor, height: size.height * factor)
        return NSRect(
            x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2,
            width: fitted.width, height: fitted.height)
    }
}
