import AppKit
import MusicCore
import SwiftUI

/// Native scrolling moves already laid-out rows. Only the viewport and bounded overdraw
/// have hosting views; paging and media-size changes do not rebuild the whole list.
struct CommentViewport: NSViewRepresentable {
    let comments: [QQSongComment]
    let loading: Bool
    let failure: String?
    let hasMore: Bool
    let onNearEnd: (Bool) -> Void
    let onRetry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> CommentScrollView { CommentScrollView() }

    func updateNSView(_ view: CommentScrollView, context: Context) {
        view.configure(self, animated: !reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommentScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 600))
    }

    static func dismantleNSView(_ view: CommentScrollView, coordinator: ()) { view.stop() }
}

final class CommentScrollView: NSScrollView {
    private let document = CommentDocument()
    private var configuration: CommentViewport?
    private var rows: [Int: NSView] = [:]
    // A small detached cache avoids rebuilding SwiftUI rows during short scroll reversals.
    private var cachedRows: [Int: NSView] = [:]
    private var cachedOrder: [Int] = []
    private let rowCacheLimit = 24
    private var rowTokens: [Int: UUID] = [:]
    private var heights: [CGFloat] = []
    private var frames: [CGRect] = []
    private var measuredWidth: CGFloat = 0
    private var prepared = CGRect.zero
    private var updating = false
    private var nearEnd: Bool?
    private var pendingMeasurements: [Int: UUID] = [:]
    private var heightTask: Task<Void, Never>?
    private var wheelMonitor: Any?
    private var wheelRouting = CommentWheelRouting()
    private var animated = false
    private var entranceDeadline: CFTimeInterval?
    private var entered = Set<String>()
    private(set) var createdRowCount = 0
    var cachedRowCount: Int { cachedRows.count }

    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        wantsLayer = true
        document.wantsLayer = true
        documentView = document
        contentView.wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        document.setAccessibilityElement(true)
        document.setAccessibilityRole(.list)
        document.setAccessibilityIdentifier("player-details.comments.list")
        document.prepareRows = { [weak self] rect in
            guard let self else { return }
            prepareRows(in: rect.intersection(contentView.bounds.insetBy(dx: 0, dy: -contentView.bounds.height)))
        }
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ next: CommentViewport, animated: Bool) {
        let previous = configuration
        configuration = next
        self.animated = animated
        if previous?.comments != next.comments {
            let oldCount = previous?.comments.count ?? 0
            let appending = next.comments.count >= oldCount && next.comments.starts(with: previous?.comments ?? [])
            if appending {
                // The old footer becomes the first new comment.
                rows.removeValue(forKey: oldCount)?.removeFromSuperview()
                cachedRows.removeValue(forKey: oldCount)
                cachedOrder.removeAll { $0 == oldCount }
                rowTokens[oldCount] = nil
                heights = Array(heights.prefix(oldCount))
                heights.append(contentsOf: repeatElement(100, count: next.comments.count - heights.count))
            } else {
                clearRows()
                heights = Array(repeating: 100, count: next.comments.count)
                entranceDeadline = nil
                entered.removeAll()
                updating = true
                contentView.scroll(to: .zero)
                updating = false
            }
            heights.append(footerHeight)
            rebuildFrames()
            prepared = .zero
            document.setAccessibilityValue("已加载 \(next.comments.count) 条评论")
        } else if previous?.loading != next.loading || previous?.failure != next.failure || previous?.hasMore != next.hasMore {
            rows.removeValue(forKey: next.comments.count)?.removeFromSuperview()
            rowTokens[next.comments.count] = nil
            if !heights.isEmpty { heights[heights.count - 1] = footerHeight }
            rebuildFrames()
            prepared = .zero
        }
        layoutRows()
        updateNearEnd()
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    private var footerHeight: CGFloat { configuration?.failure == nil ? 36 : 72 }

    private func layoutRows() {
        guard !updating, configuration != nil, contentView.bounds.width > 0 else { return }
        let width = contentView.bounds.width
        if abs(width - measuredWidth) > 0.5 {
            let anchor = firstRow(at: contentView.bounds.minY)
            let inset = frames.indices.contains(anchor) ? contentView.bounds.minY - frames[anchor].minY : 0
            measuredWidth = width
            clearRows()
            heights = Array(repeating: 100, count: configuration?.comments.count ?? 0) + [footerHeight]
            rebuildFrames()
            if frames.indices.contains(anchor) {
                updating = true
                contentView.scroll(to: CGPoint(x: 0, y: frames[anchor].minY + inset))
                updating = false
            }
            prepared = .zero
        }
        prepareRows(in: contentView.bounds)
    }

    private func clearRows() {
        heightTask?.cancel()
        heightTask = nil
        pendingMeasurements.removeAll()
        rows.values.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        cachedRows.removeAll()
        cachedOrder.removeAll()
        rowTokens.removeAll()
    }

    private func rebuildFrames() {
        var y: CGFloat = 0
        frames = heights.map { height in
            defer { y += height }
            return CGRect(x: 0, y: y, width: measuredWidth, height: height)
        }
        let wasUpdating = updating
        updating = true
        document.frame.size = CGSize(width: measuredWidth, height: max(y, contentView.bounds.height))
        for (index, host) in rows where frames.indices.contains(index) {
            if host.frame != frames[index] { host.frame = frames[index] }
        }
        updating = wasUpdating
    }

    private func firstRow(at y: CGFloat) -> Int {
        var low = 0
        var high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY <= y { low = mid + 1 } else { high = mid }
        }
        return min(low, max(0, frames.count - 1))
    }

    private func prepareRows(in rect: CGRect) {
        guard !updating, measuredWidth > 0, !frames.isEmpty, !rect.isNull, !rect.isEmpty else { return }
        let required = rect.intersection(document.bounds)
        guard !required.isNull, !required.isEmpty else { return }
        if prepared.contains(required) {
            document.preparedContentRect = prepared
            return
        }
        updating = true
        defer { updating = false }
        let anchor = firstRow(at: contentView.bounds.minY)
        let anchorInset = contentView.bounds.minY - frames[anchor].minY
        // Measuring newly encountered rows can expose further rows. Fill until the requested
        // area is covered, with a hard bound so a large page cannot create unbounded hosts.
        var created = 0
        for _ in 0..<4 {
            let coverage = required.insetBy(dx: 0, dy: -contentView.bounds.height * 0.65).intersection(document.bounds)
            let start = firstRow(at: coverage.minY)
            var changed = false
            for index in start..<frames.count {
                if frames[index].minY > coverage.maxY || created >= 40 { break }
                guard rows[index] == nil else { continue }
                let host: NSView
                if let cached = cachedRows.removeValue(forKey: index) {
                    cachedOrder.removeAll { $0 == index }
                    host = cached
                } else {
                    host = makeRow(index)
                    createdRowCount += 1
                }
                host.frame = frames[index]
                document.addSubview(host)
                rows[index] = host
                created += 1
                let measured = measureHeight(of: host)
                if measured > 0, abs(heights[index] - measured) > 0.5 {
                    heights[index] = measured
                    changed = true
                    rebuildFrames()
                }
            }
            if !changed { break }
        }
        // Maintain the visible text anchor when a prefetched image or row above it changes size.
        if frames.indices.contains(anchor), contentView.bounds.minY > 0 {
            let target = frames[anchor].minY + anchorInset
            contentView.scroll(to: contentView.constrainBoundsRect(
                CGRect(origin: CGPoint(x: 0, y: target), size: contentView.bounds.size)).origin)
        }
        let coverage = contentView.bounds.union(required)
            .insetBy(dx: 0, dy: -contentView.bounds.height * 0.65).intersection(document.bounds)
        for index in Array(rows.keys) where !frames[index].intersects(coverage) {
            guard let row = rows.removeValue(forKey: index) else { continue }
            row.removeFromSuperview()
            if index < (configuration?.comments.count ?? 0) {
                cachedRows[index] = row
                cachedOrder.append(index)
            } else { rowTokens[index] = nil }
        }
        while cachedOrder.count > rowCacheLimit {
            let index = cachedOrder.removeFirst()
            cachedRows.removeValue(forKey: index)
            rowTokens[index] = nil
        }
        let sorted = rows.keys.sorted()
        document.setAccessibilityChildren(sorted.compactMap { rows[$0] })
        if let first = sorted.first, let last = sorted.last {
            let bottom = last == frames.count - 1 ? document.bounds.maxY : frames[last].maxY
            prepared = CGRect(x: 0, y: frames[first].minY, width: measuredWidth,
                              height: bottom - frames[first].minY)
            document.preparedContentRect = prepared
        }
        for index in sorted { animateEntrance(index) }
    }

    private func makeRow(_ index: Int) -> NSView {
        let token = UUID()
        rowTokens[index] = token
        let content: AnyView
        if let configuration, index < configuration.comments.count {
            content = AnyView(PlaybackCommentRow(comment: configuration.comments[index]) { [weak self] in
                self?.scheduleMeasurement(at: index, token: token)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().padding(.horizontal, 16) })
        } else { content = AnyView(footer) }
        let root = content
            .frame(width: measuredWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        host.wantsLayer = true
        return host
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let failure = configuration?.failure {
                Text(failure).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button("重试") { [weak self] in self?.configuration?.onRetry() }
            } else if configuration?.loading == true {
                Text("正在加载评论…").font(.caption).foregroundStyle(.secondary)
            } else if configuration?.comments.isEmpty == true {
                Text("暂无评论").foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).frame(height: footerHeight)
    }

    private func measureHeight(of view: NSView) -> CGFloat {
        guard let host = view as? NSHostingView<AnyView> else { return 0 }
        // Automatic intrinsic-size tracking stays disabled between actual content changes.
        host.sizingOptions = .intrinsicContentSize
        let height = ceil(host.intrinsicContentSize.height)
        host.sizingOptions = []
        return height
    }

    private func scheduleMeasurement(at index: Int, token: UUID) {
        guard rowTokens[index] == token, heights.indices.contains(index) else { return }
        pendingMeasurements[index] = token
        guard heightTask == nil else { return }
        heightTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            heightTask = nil
            let anchor = firstRow(at: contentView.bounds.minY)
            let inset = contentView.bounds.minY - frames[anchor].minY
            let pending = pendingMeasurements
            pendingMeasurements.removeAll()
            var changed = false
            for (index, token) in pending where rowTokens[index] == token && heights.indices.contains(index) {
                guard let host = rows[index] else { continue }
                // Media changes are rare; ordinary scroll events never ask SwiftUI for row geometry.
                host.layoutSubtreeIfNeeded()
                let height = measureHeight(of: host)
                if height > 0, abs(heights[index] - height) > 0.5 {
                    heights[index] = height
                    changed = true
                }
            }
            guard changed else { return }
            updating = true
            rebuildFrames()
            if frames.indices.contains(anchor) {
                contentView.scroll(to: contentView.constrainBoundsRect(CGRect(
                    origin: CGPoint(x: 0, y: frames[anchor].minY + inset), size: contentView.bounds.size)).origin)
            }
            updating = false
            prepared = .zero
            layoutRows()
            updateNearEnd()
        }
    }

    private func animateEntrance(_ index: Int) {
        guard let configuration, index < configuration.comments.count, let host = rows[index] else { return }
        let id = configuration.comments[index].id
        guard entered.insert(id).inserted, host.frame.intersects(contentView.bounds), animated else { return }
        let now = CACurrentMediaTime()
        if entranceDeadline == nil { entranceDeadline = now + 0.4 }
        guard now < (entranceDeadline ?? 0), let layer = host.layer else { return }
        let progress = min(1, max(0, (host.frame.minY - contentView.bounds.minY) / max(1, contentView.bounds.height)))
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = layer.isGeometryFlipped ? 28 : -28
        move.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.22
        group.beginTime = layer.convertTime(now, from: nil) + (1 - progress) * 0.12
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "comment-entrance")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWheelMonitor()
        guard window != nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.routeWheel(event) ?? false }
            return handled ? nil : event
        }
    }

    private func routeWheel(_ event: NSEvent) -> Bool {
        guard event.window === window, window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        // Forward the unmodified precision/phase data; never steal a gesture started in lyrics.
        guard wheelRouting.route(inside: inside, phase: event.phase, momentum: event.momentumPhase) else { return false }
        scrollWheel(with: event)
        return true
    }

    private func removeWheelMonitor() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        wheelRouting = CommentWheelRouting()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY != 0, entranceDeadline != 0 {
            entranceDeadline = 0
            for host in rows.values { host.layer?.removeAnimation(forKey: "comment-entrance") }
        }
        super.scrollWheel(with: event)
    }

    @objc private func scrolled() {
        guard !updating else { return }
        layoutRows()
        updateNearEnd()
    }

    private func updateNearEnd() {
        guard !updating, configuration != nil else { return }
        let next = contentView.bounds.maxY >= document.bounds.height - 240
        guard next != nearEnd else { return }
        nearEnd = next
        Task { @MainActor [weak self] in
            guard let self, nearEnd == next else { return }
            configuration?.onNearEnd(next)
        }
    }

    func stop() {
        removeWheelMonitor()
        heightTask?.cancel()
        heightTask = nil
        document.prepareRows = nil
        rows.values.forEach { $0.layer?.removeAllAnimations() }
        clearRows()
        configuration = nil
    }
}

private final class CommentDocument: NSView {
    var prepareRows: ((CGRect) -> Void)?
    override var isFlipped: Bool { true }
    override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: rect)
        prepareRows?(rect)
    }
}

/// Preserve gesture ownership across the finger-lift to momentum transition.
struct CommentWheelRouting {
    private var ownsGesture: Bool?

    mutating func route(inside: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase) -> Bool {
        if phase.contains(.began) || phase.contains(.mayBegin) { ownsGesture = inside }
        guard !phase.isEmpty || !momentum.isEmpty else {
            ownsGesture = nil
            return inside
        }
        let routed = ownsGesture ?? inside
        ownsGesture = routed
        if phase.contains(.cancelled) || momentum.contains(.ended) || momentum.contains(.cancelled) {
            ownsGesture = nil
        }
        return routed
    }
}
