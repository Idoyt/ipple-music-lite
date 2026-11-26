import AppKit
import SwiftUI

struct PlaybackFollowButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "scope").foregroundStyle(.black)
                Text("回到当前播放")
            }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 13).padding(.vertical, 9).contentShape(Capsule())
        }
        .buttonStyle(.plain).modifier(PlaybackFollowGlass())
        .help("恢复列表自动跟随，不改变播放进度")
        .accessibilityIdentifier("playback-follow.resume")
    }
}

private struct PlaybackFollowGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

struct PlaybackFollowingList<Content: View>: View {
    @Environment(\.workspaceIsActive) private var workspaceIsActive
    var currentRow: Int?
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var following = true
    @State private var followRequest = UUID()

    var body: some View {
        content()
            .background(
                ScrollInteractionObserver(
                    currentRow: currentRow, following: following, followRequest: followRequest,
                    animated: !reduceMotion, isActive: workspaceIsActive, onInteraction: { following = false })
            )
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting { following = false }
            }
            .overlay(alignment: .bottomTrailing) {
                if !following, currentRow != nil {
                    PlaybackFollowButton {
                        following = true
                        followRequest = UUID()
                    }.padding(16)
                }
            }
    }
}

/// Table/List on macOS may not emit SwiftUI scroll phases; observe only local input in this list.
private struct ScrollInteractionObserver: NSViewRepresentable {
    var currentRow: Int?
    var following: Bool
    var followRequest: UUID
    var animated: Bool
    var isActive: Bool
    var onInteraction: () -> Void

    func makeNSView(context: Context) -> ScrollInteractionProbe {
        let view = ScrollInteractionProbe()
        view.onInteraction = onInteraction
        view.update(
            row: currentRow, following: following, request: followRequest, animated: animated, isActive: isActive)
        return view
    }

    func updateNSView(_ view: ScrollInteractionProbe, context: Context) {
        view.onInteraction = onInteraction
        view.update(
            row: currentRow, following: following, request: followRequest, animated: animated, isActive: isActive)
    }
    static func dismantleNSView(_ view: ScrollInteractionProbe, coordinator: ()) { view.stop() }
}

private final class ScrollInteractionProbe: NSView {
    var onInteraction: (() -> Void)?
    private var monitor: Any?
    private weak var observedScroll: NSScrollView?
    private let animator = PlaybackScrollAnimator()
    private var scrollTask: Task<Void, Never>?
    private var row: Int?
    private var following = true
    private var request: UUID?
    private var animated = true
    private var isActive = true
    private var manuallySuspended = false
    private var lastFollowedRow: Int?
    private var lastViewportHeight: CGFloat = 0

    func update(row: Int?, following: Bool, request: UUID, animated: Bool, isActive: Bool) {
        self.isActive = isActive
        if self.request != request || (!self.following && following) {
            manuallySuspended = false
            lastFollowedRow = nil
        }
        self.row = row
        self.following = following
        self.request = request
        self.animated = animated
        if !isActive || !following || row == nil {
            scrollTask?.cancel()
            animator.cancel()
        } else {
            followIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        followIfNeeded()
    }

    private func followIfNeeded() {
        guard isActive, window != nil, following, !manuallySuspended, let row,
            let scroll = scrollView(), let table = scroll.documentView as? NSTableView,
            row >= 0, row < table.numberOfRows, scroll.contentView.bounds.height > 0,
            row != lastFollowedRow || abs(scroll.contentView.bounds.height - lastViewportHeight) > 0.5
        else { return }
        scrollTask?.cancel()
        scrollTask = Task { @MainActor [weak self, weak table] in
            await Task.yield()
            guard let self, let table, !Task.isCancelled, self.isActive, self.following, !self.manuallySuspended,
                self.row == row, let scroll = table.enclosingScrollView
            else { return }
            self.lastFollowedRow = row
            self.lastViewportHeight = scroll.contentView.bounds.height
            self.animator.scroll(to: row, in: table, animated: self.animated)
        }
    }

    private func manualInteraction() {
        animator.cancel()
        scrollTask?.cancel()
        manuallySuspended = true
        onInteraction?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
        followIfNeeded()
    }

    func stop() {
        scrollTask?.cancel()
        animator.cancel()
        lastFollowedRow = nil
        lastViewportHeight = 0
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observedScroll = nil
    }

    private func observe(_ event: NSEvent) {
        guard isActive, event.window === window, let scroll = scrollView() else { return }
        switch event.type {
        case .scrollWheel:
            if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0,
                scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
            {
                manualInteraction()
            }
        case .leftMouseDown:
            if let scroller = scroll.verticalScroller,
                scroller.bounds.contains(scroller.convert(event.locationInWindow, from: nil))
            {
                manualInteraction()
            }
        case .keyDown:
            if [123, 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode),
                let focused = window?.firstResponder as? NSView, focused.isDescendant(of: scroll)
            {
                manualInteraction()
            }
        default: break
        }
    }

    private func scrollView() -> NSScrollView? {
        if let observedScroll { return observedScroll }
        var ancestor = superview
        while let parent = ancestor {
            if let found = findScroll(in: parent) {
                observedScroll = found
                return found
            }
            ancestor = parent.superview
        }
        return nil
    }

    private func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTableView { return scroll }
        for child in view.subviews where child !== self {
            if let found = findScroll(in: child) { return found }
        }
        return nil
    }
}
