import AppKit

/// Owns the displayed offset, so cancelling leaves the clip exactly where the user takes over.
@MainActor
final class PlaybackScrollAnimator {
    private let clock = AnimationClock()
    private weak var scrollView: NSScrollView?
    private weak var table: NSTableView?
    private var row = 0
    private var startedAt: TimeInterval = 0
    private var lastTickAt: TimeInterval = 0
    private var velocity: CGFloat = 0
    private var stableFrames = 0
    private var generation = UUID()

    var isAnimating: Bool { clock.timer != nil }

    func scroll(to row: Int, in table: NSTableView, animated: Bool) {
        cancel()
        guard let scroll = table.enclosingScrollView, row >= 0, row < table.numberOfRows,
            scroll.contentView.bounds.height > 0
        else { return }
        self.scrollView = scroll
        self.table = table
        self.row = row
        let destination = destination(in: scroll, table: table)
        let distance = abs(destination.y - scroll.contentView.bounds.origin.y)
        guard animated, distance > 1 else {
            setOrigin(destination, in: scroll)
            return
        }
        startedAt = ProcessInfo.processInfo.systemUptime
        lastTickAt = startedAt
        velocity = 0
        stableFrames = 0
        let expected = generation
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(expected: expected) }
        }
        clock.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        generation = UUID()
        clock.timer?.invalidate()
        clock.timer = nil
        scrollView = nil
        table = nil
    }

    private func tick(expected: UUID) {
        guard generation == expected else { return }
        guard let scroll = scrollView, let table, row < table.numberOfRows else {
            cancel()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let step = min(0.05, max(0, now - lastTickAt))
        lastTickAt = now
        let destination = destination(in: scroll, table: table)
        let current = scroll.contentView.bounds.origin
        // A critically damped spring also follows row-height corrections without endpoint jumps.
        let frequency = 18.0
        let displacement = current.y - destination.y
        let adjustment = (velocity + frequency * displacement) * step
        let decay = exp(-frequency * step)
        let y = destination.y + (displacement + adjustment) * decay
        velocity = (velocity - frequency * adjustment) * decay
        setOrigin(NSPoint(x: current.x, y: y), in: scroll)
        if abs(y - destination.y) < 0.5 && abs(velocity) < 4 {
            stableFrames += 1
        } else {
            stableFrames = 0
        }
        if stableFrames >= 3 {
            setOrigin(destination, in: scroll)
            cancel()
        } else if now - startedAt > 3 {
            cancel()
        }
    }

    private func destination(in scroll: NSScrollView, table: NSTableView) -> NSPoint {
        let clip = scroll.contentView
        var bounds = clip.bounds
        let insets = clip.contentInsets
        let visibleHeight = max(0, bounds.height - insets.top - insets.bottom)
        let rowRect = clip.convert(table.rect(ofRow: row), from: table)
        bounds.origin.y = rowRect.midY - insets.top - visibleHeight / 2
        return clip.constrainBoundsRect(bounds).origin
    }

    private func setOrigin(_ origin: NSPoint, in scroll: NSScrollView) {
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

private final class AnimationClock: @unchecked Sendable {
    var timer: Timer?
    deinit { timer?.invalidate() }
}
