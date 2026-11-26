import AppKit
import SwiftUI

/// Save the actual frame, including its screen position, rather than entering a full-screen Space.
struct WindowTopZoomState {
    private var restoredFrame: NSRect?
    private var expandedFrame: NSRect?

    mutating func toggle(current: NSRect, visibleFrame: NSRect) -> NSRect {
        if let restoredFrame, let expandedFrame, Self.matches(current, expandedFrame) {
            self.restoredFrame = nil
            self.expandedFrame = nil
            return restoredFrame
        }
        // A manual move/resize becomes the new frame to restore next time.
        restoredFrame = current
        expandedFrame = visibleFrame
        return visibleFrame
    }

    private static func matches(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1 && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }
}

/// Attached once per window, so changing pages does not reset its original frame.
struct WindowTopZoom: NSViewRepresentable {
    final class AttachmentView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor final class Coordinator {
        private weak var window: NSWindow?
        private var monitor: Any?
        private var zoom = WindowTopZoomState()
        private var suppressMouseUp = false

        func attach(_ window: NSWindow?) {
            guard self.window !== window else { return }
            stop()
            self.window = window
            zoom = WindowTopZoomState()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            window = nil
            suppressMouseUp = false
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            if event.type == .leftMouseUp {
                let handled = suppressMouseUp
                suppressMouseUp = false
                return handled
            }
            suppressMouseUp = false
            guard event.clickCount == 2, window.styleMask.contains(.resizable),
                !window.styleMask.contains(.fullScreen), !window.isSheet,
                window.attachedSheet == nil, NSApp.modalWindow == nil,
                let screen = window.screen
            else { return false }

            // Include the native toolbar/titlebar and the compact hidden-titlebar strip.
            let topHeight = max(28, window.frame.height - window.contentLayoutRect.maxY)
            guard event.locationInWindow.y >= window.frame.height - topHeight,
                event.locationInWindow.y <= window.frame.height
            else { return false }

            // Leave traffic lights, toolbar buttons and editable fields to their normal actions.
            var hit = window.contentView?.superview?.hitTest(event.locationInWindow)
            while let view = hit {
                if view is NSControl || view is NSTextView { return false }
                hit = view.superview
            }
            let target = zoom.toggle(current: window.frame, visibleFrame: screen.visibleFrame)
            window.setFrame(target, display: true, animate: true)
            // Prevent AppKit from also executing the user's system titlebar double-click action.
            suppressMouseUp = true
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.attach(view.window)
    }

    static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) {
        view.onWindowChanged = nil
        coordinator.stop()
    }
}
