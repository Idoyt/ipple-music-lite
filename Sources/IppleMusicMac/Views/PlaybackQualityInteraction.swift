import AppKit
import SwiftUI

struct PlaybackQualitySegments: NSViewRepresentable {
    var titles: [String]
    var selected: Int
    var enabled: [Bool]
    var help: [String]
    var onSelection: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let view = NSSegmentedControl(labels: titles, trackingMode: .selectOne,
                                      target: context.coordinator, action: #selector(Coordinator.select(_:)))
        // Match the system segmented tab bar used by Favorites' TabView.
        view.segmentStyle = .automatic
        // The tabs role is declared by the macOS 27 SDK (AppKit 2775).
        #if canImport(AppKit, _version: 2775)
        if #available(macOS 27.0, *) {
            // TabView uses this role: transparent unselected tabs and the system's
            // moving selection indicator, rather than individual value-selection bezels.
            view.role = .tabs
        }
        #endif
        // The enclosing inline control already supplies the glass panel. Do not draw
        // another segmented-control bezel inside it, including on macOS 27's tab role.
        view.cell?.isBordered = false
        if #available(macOS 26.0, *) {
            view.controlSize = .extraLarge
        } else {
            view.controlSize = .large
        }
        view.font = .systemFont(ofSize: 13)
        view.setAccessibilityLabel("音质")
        view.setAccessibilityIdentifier("player-details.quality.segments")
        return view
    }
    func updateNSView(_ view: NSSegmentedControl, context: Context) {
        let size: NSControl.ControlSize
        if #available(macOS 26.0, *) { size = .extraLarge } else { size = .large }
        if view.controlSize != size { view.controlSize = size }
        let font = NSFont.systemFont(ofSize: 13)
        if view.font != font { view.font = font }
        if view.cell?.isBordered == true { view.cell?.isBordered = false }
        context.coordinator.onSelection = onSelection
        context.coordinator.enabled = enabled
        // Reassigning the selection/labels on unrelated playback updates can interrupt
        // AppKit's tab indicator animation. Let the native control own that animation.
        if view.selectedSegment != selected { view.selectedSegment = selected }
        for index in titles.indices {
            if view.label(forSegment: index) != titles[index] { view.setLabel(titles[index], forSegment: index) }
            if view.isEnabled(forSegment: index) != enabled[index] { view.setEnabled(enabled[index], forSegment: index) }
            if view.toolTip(forSegment: index) != help[index] { view.setToolTip(help[index], forSegment: index) }
            if view.width(forSegment: index) != 72 { view.setWidth(72, forSegment: index) }
        }
    }
    @MainActor final class Coordinator: NSObject {
        var enabled: [Bool] = []
        var onSelection: ((Int) -> Void)?
        @objc func select(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard enabled.indices.contains(index), enabled[index] else { return }
            onSelection?(index)
        }
    }
}

struct PlaybackQualityScrollControl: NSViewRepresentable {
    var isEnabled: Bool
    var expandedLeadingWidth: CGFloat
    var onDismiss: () -> Void
    var onStep: (Int) -> Void

    func makeNSView(context: Context) -> PlaybackQualityScrollAnchor { PlaybackQualityScrollAnchor() }
    func updateNSView(_ view: PlaybackQualityScrollAnchor, context: Context) {
        view.expandedLeadingWidth = expandedLeadingWidth
        view.onDismiss = onDismiss
        view.onStep = onStep
        view.isEnabled = isEnabled
    }
    static func dismantleNSView(_ view: PlaybackQualityScrollAnchor, coordinator: ()) {
        view.isEnabled = false
        view.onDismiss = nil
        view.onStep = nil
    }
}

final class PlaybackQualityScrollAnchor: NSView {
    var expandedLeadingWidth: CGFloat = 0
    var onDismiss: (() -> Void)?
    var onStep: ((Int) -> Void)?
    var isEnabled = false { didSet { updateMonitor() } }
    private var monitor: Any?
    private var gesture = QualitySwipeAccumulator()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMonitor()
    }
    private func updateMonitor() {
        guard isEnabled, window != nil else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            gesture = QualitySwipeAccumulator()
            return
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.isEnabled, !self.isHiddenOrHasHiddenAncestor,
                      let window = self.window, event.window === window else { return false }
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return false }
                    self.onDismiss?()
                    return true
                }
                let point = self.convert(event.locationInWindow, from: nil)
                let area = self.bounds.insetBy(dx: 0, dy: -2).union(
                    CGRect(x: -self.expandedLeadingWidth, y: -2,
                           width: self.expandedLeadingWidth, height: self.bounds.height + 4))
                guard event.type == .scrollWheel else {
                    if !area.contains(point) { self.onDismiss?() }
                    return false
                }
                guard area.contains(point) else { return false }
                let step = self.gesture.step(
                    x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                    inverted: event.isDirectionInvertedFromDevice, precise: event.hasPreciseScrollingDeltas,
                    phase: event.phase, momentum: event.momentumPhase, timestamp: event.timestamp)
                if step != 0 { self.onStep?(step) }
                return abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            }
            return handled ? nil : event
        }
    }
}

/// Accumulate finger travel continuously, retaining sub-step movement between events.
/// Reversing direction takes effect immediately; momentum never changes quality.
struct QualitySwipeAccumulator {
    private var accumulated: CGFloat = 0
    private var lastTimestamp: TimeInterval = 0

    mutating func step(x: CGFloat, y: CGFloat, inverted: Bool, precise: Bool,
                       phase: NSEvent.Phase, momentum: NSEvent.Phase, timestamp: TimeInterval) -> Int {
        guard momentum.isEmpty else { return 0 }
        if phase.contains(.began) || phase.contains(.mayBegin)
            || (phase.isEmpty && timestamp - lastTimestamp > 0.18) {
            accumulated = 0
        }
        lastTimestamp = timestamp
        if phase.contains(.ended) || phase.contains(.cancelled) {
            accumulated = 0
            return 0
        }
        guard x.isFinite, y.isFinite, abs(x) > abs(y) else { return 0 }
        let horizontal = -x * (inverted ? -1 : 1)
        if !precise { return horizontal > 0 ? 1 : -1 }
        if accumulated * horizontal < 0 { accumulated = 0 }
        accumulated += horizontal
        let distance: CGFloat = 18
        guard abs(accumulated) >= distance else { return 0 }
        let direction = accumulated > 0 ? 1 : -1
        let steps = Int(min(32, abs(accumulated) / distance))
        accumulated.formTruncatingRemainder(dividingBy: distance)
        return steps * direction
    }
}

func nextEnabledQualityIndex(from selected: Int, direction: Int, enabled: [Bool]) -> Int? {
    guard enabled.indices.contains(selected), direction != 0 else { return nil }
    var index = selected
    let step = direction > 0 ? 1 : -1
    var remaining = direction.magnitude
    // Walk the bounded option list once, skipping unavailable formats and clamping
    // large scroll deltas to the last available option instead of wrapping around.
    while remaining > 0 {
        var next = index + step
        while enabled.indices.contains(next), !enabled[next] { next += step }
        guard enabled.indices.contains(next) else { break }
        index = next
        remaining -= 1
    }
    return index == selected ? nil : index
}
