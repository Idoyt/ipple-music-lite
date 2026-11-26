import AppKit
import SwiftUI

@main @MainActor struct Harness {
    static func main() {
        _ = NSApplication.shared
        var gesture = QualitySwipeAccumulator()
        func swipe(_ x: CGFloat, _ y: CGFloat = 0, phase: NSEvent.Phase = .changed,
                   momentum: NSEvent.Phase = [], time: Double = 1) -> Int {
            gesture.step(x: x, y: y, inverted: true, precise: true,
                         phase: phase, momentum: momentum, timestamp: time)
        }
        precondition(swipe(6, phase: .began) == 0)
        precondition(swipe(7) == 0)
        precondition(swipe(7) == 1)
        precondition(swipe(18) == 1, "one gesture must continue advancing without lifting fingers")
        precondition(swipe(36) == 2, "large deltas must advance multiple steps")
        precondition(swipe(-18) == -1, "the same gesture must reverse immediately")
        precondition(swipe(-9) == 0)
        precondition(swipe(-9) == -1, "small events must accumulate smoothly")
        precondition(swipe(0, phase: .ended) == 0)
        precondition(swipe(-30, phase: .began) == -1)
        precondition(swipe(80, momentum: .began) == 0, "momentum must never select")
        precondition(swipe(5, 90, phase: .began) == 0, "vertical scroll must not select")
        precondition(swipe(.infinity, phase: .began) == 0)
        var nonNatural = QualitySwipeAccumulator()
        precondition(nonNatural.step(x: -30, y: 0, inverted: false, precise: true,
                                     phase: .began, momentum: [], timestamp: 1) == 1)
        precondition(nextEnabledQualityIndex(from: 0, direction: 1, enabled: [true, false, true]) == 2)
        precondition(nextEnabledQualityIndex(from: 2, direction: -1, enabled: [true, false, true]) == 0)
        precondition(nextEnabledQualityIndex(from: 0, direction: -1, enabled: [true, true, true]) == nil)
        precondition(nextEnabledQualityIndex(from: 0, direction: 1, enabled: [true, false, false]) == nil)
        precondition(nextEnabledQualityIndex(from: 0, direction: 2, enabled: [true, true, true]) == 2)
        precondition(nextEnabledQualityIndex(from: 2, direction: -2, enabled: [true, true, true]) == 0)
        precondition(nextEnabledQualityIndex(from: 0, direction: 20, enabled: [true, false, true]) == 2)
        precondition(nextEnabledQualityIndex(from: 2, direction: 20, enabled: [true, true, true]) == nil)
        precondition(nextEnabledQualityIndex(from: 2, direction: -1, enabled: [true, true, true]) == 1)

        var selected = -1
        let host = NSHostingView(rootView: PlaybackQualitySegments(
            titles: ["标准", "高品质", "无损"], selected: 0, enabled: [true, false, true],
            help: ["128", "不可用", "FLAC"], onSelection: { selected = $0 }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 244, height: 36),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        func find(_ view: NSView) -> NSSegmentedControl? {
            (view as? NSSegmentedControl) ?? view.subviews.lazy.compactMap { find($0) }.first
        }
        let segments = find(host)!
        precondition(segments.segmentCount == 3 && segments.selectedSegment == 0)
        precondition(segments.segmentStyle == .automatic)
        precondition(segments.cell?.isBordered == false, "segments must not draw a second background inside the glass panel")
        if #available(macOS 27.0, *) { precondition(segments.role == .tabs) }
        if #available(macOS 26.0, *) { precondition(segments.controlSize == .extraLarge) }
        precondition(segments.font?.pointSize == 13)
        precondition(segments.isEnabled(forSegment: 0) && !segments.isEnabled(forSegment: 1))
        segments.selectedSegment = 1
        _ = segments.sendAction(segments.action, to: segments.target)
        precondition(selected == -1, "disabled native segment must not call playback")
        segments.selectedSegment = 2
        _ = segments.sendAction(segments.action, to: segments.target)
        precondition(selected == 2)
        print("PASS continuous/reversing gestures, multi-step deltas, endpoint clamping, disabled skipping, borderless native tabs")
    }
}
