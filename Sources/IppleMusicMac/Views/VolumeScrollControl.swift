import AppKit
import SwiftUI

/// Observe the expanded volume control, leaving button clicks and slider dragging native.
struct VolumeScrollControl: NSViewRepresentable {
    var isEnabled: Bool
    var expandedLeadingWidth: CGFloat
    var onDismiss: () -> Void
    var onAdjustment: (Double) -> Void

    func makeNSView(context: Context) -> VolumeScrollAnchor { VolumeScrollAnchor() }

    func updateNSView(_ view: VolumeScrollAnchor, context: Context) {
        view.onAdjustment = onAdjustment
        view.expandedLeadingWidth = expandedLeadingWidth
        view.onDismiss = onDismiss
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: VolumeScrollAnchor, coordinator: ()) {
        view.isEnabled = false
        view.onAdjustment = nil
        view.onDismiss = nil
    }
}

final class VolumeScrollAnchor: NSView {
    var onAdjustment: ((Double) -> Void)?
    var onDismiss: (() -> Void)?
    var expandedLeadingWidth: CGFloat = 0
    var isEnabled = false {
        didSet { updateMonitor() }
    }
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMonitor()
    }

    private func updateMonitor() {
        guard isEnabled, window != nil else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            return
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.isEnabled, !self.isHiddenOrHasHiddenAncestor,
                    let window = self.window, event.window === window
                else { return false }
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return false }
                    self.onDismiss?()
                    return true
                }
                let point = self.convert(event.locationInWindow, from: nil)
                if event.type != .scrollWheel {
                    let expanded = self.bounds.insetBy(dx: 0, dy: -2)
                        .union(CGRect(x: -self.expandedLeadingWidth, y: -2,
                                      width: self.expandedLeadingWidth, height: self.bounds.height + 4))
                    if !expanded.contains(point) { self.onDismiss?() }
                    return false
                }
                guard self.visibleRect.contains(point) else { return false }
                // Stop with the fingers; momentum must not keep changing the volume.
                guard event.momentumPhase.isEmpty else { return true }
                let adjustment = volumeScrollAdjustment(
                    x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                    inverted: event.isDirectionInvertedFromDevice, precise: event.hasPreciseScrollingDeltas)
                if adjustment != 0 { self.onAdjustment?(adjustment) }
                return true
            }
            return handled ? nil : event
        }
    }
}

func volumeScrollAdjustment(x: CGFloat, y: CGFloat, inverted: Bool, precise: Bool) -> Double {
    // Normalize natural scrolling, then use the dominant axis so diagonal swipes don't double the speed.
    let direction: CGFloat = inverted ? -1 : 1
    let delta = (abs(y) >= abs(x) ? y : -x) * direction
    guard delta.isFinite else { return 0 }
    return Double(delta) * (precise ? 0.0025 : 0.025)
}
