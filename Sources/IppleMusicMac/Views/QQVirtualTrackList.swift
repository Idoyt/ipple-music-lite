import AppKit
import MusicCore
import Observation
import SwiftUI

/// AppKit reuses cells; scrolling, rather than SwiftUI cell appearance, drives prefetch.
struct QQVirtualTrackList: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tracks: [SourceTrack]
    var source: SourceConnection?
    private var sourceID: String { source?.id ?? "" }
    var paginationOffset: Int
    var store: AppStore
    var currentRow: Int?
    var isPlaying: Bool
    var loadingRow: Int?
    var followingPlayback: Bool
    var followRequest: UUID
    var scrollState: QQCollectionScrollState
    var isActive: Bool
    var onManualScroll: () -> Void
    var onPlay: (Int) -> Void
    var onNearEnd: () -> Void
    var onFindSimilar: ((SourceTrack) -> Void)?
    var history: [HistoryTrackRow]? = nil

    private var highlightsHover: Bool { onFindSimilar != nil || history != nil }
    private var identifier: String { history == nil ? "favorites.qq" : "favorites.history" }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = QQTrackScrollView()
        let table = QQTrackTableView()
        scroll.wantsLayer = true
        scroll.contentView.wantsLayer = true
        table.wantsLayer = true
        table.setAccessibilityIdentifier(identifier + "-tracks")
        table.rowHeight = 52
        table.usesAutomaticRowHeights = false
        table.usesAlternatingRowBackgroundColors = true
        if highlightsHover { table.selectionHighlightStyle = .none }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = QQBorderlessHeaderView(
            frame: NSRect(x: 0, y: 0, width: 0, height: QQBorderlessHeaderView.height))
        table.cornerView = nil
        var columns = [
            ("song", "歌曲", 440.0), ("album", "专辑", 300.0), ("duration", "时长", 65.0),
        ]
        if history != nil { columns.append(("playedAt", "播放时间", 150)) }
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "song" ? (highlightsHover ? 246 : 200) : id == "album" ? 100 : width
            if id == "duration" || id == "playedAt" { column.maxWidth = width }
            column.resizingMask = id == "song" || id == "album" ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.playSelected)
        scroll.documentView = table
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        let manualScroll: () -> Void = { [weak coordinator = context.coordinator] in coordinator?.manualScroll() }
        scroll.onManualScroll = manualScroll
        table.onManualScroll = manualScroll
        if highlightsHover {
            table.onHoveredRowChange = { [weak coordinator = context.coordinator] in coordinator?.setHoveredRow($0) }
        }
        let scroller = QQTrackScroller()
        scroller.onManualScroll = manualScroll
        scroll.verticalScroller = scroller
        scroll.onScrollActivityChange = { [weak coordinator = context.coordinator] active in
            coordinator?.setScrollInteraction(active)
        }
        scroll.onScroll = { [weak coordinator = context.coordinator] in
            coordinator?.scrollChanged()
        }
        table.reloadData()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let old = context.coordinator.parent
        if !isActive {
            if old.isActive {
                context.coordinator.suspend()
                context.coordinator.updatePlaybackRows(Set([old.currentRow, old.loadingRow].compactMap { $0 }))
            }
            scroll.isHidden = true
            return
        }
        scroll.isHidden = false
        context.coordinator.parent = self
        guard let table = context.coordinator.table else { return }
        if history == nil, old.sourceID == sourceID, tracks.count > old.tracks.count, tracks.starts(with: old.tracks) {
            table.insertRows(at: IndexSet(integersIn: old.tracks.count..<tracks.count), withAnimation: [])
        } else if old.tracks != tracks || old.sourceID != sourceID || old.history != history {
            table.reloadData()
        }
        if old.currentRow != currentRow || old.isPlaying != isPlaying || old.loadingRow != loadingRow || !old.isActive {
            context.coordinator.updatePlaybackRows(
                Set([old.currentRow, currentRow, old.loadingRow, loadingRow].compactMap { $0 }))
        }
        context.coordinator.restorePositionIfNeeded()
        context.coordinator.updateFollowing(previous: old)
        context.coordinator.prefetchIfNeeded()
        if !old.isActive { table.refreshHoveredRow() }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.scrollTask?.cancel()
        coordinator.animator.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: QQVirtualTrackList
        fileprivate weak var table: QQTrackTableView?
        private var hoveredRow: Int?
        private var scrollInteractionActive = false
        var scrollTask: Task<Void, Never>?
        let animator = PlaybackScrollAnimator()
        private var lastFollowedRow: Int?
        private var lastViewportHeight: CGFloat = 0
        private var manuallySuspended = false
        private var restoringPosition: Bool
        private var lastViewportBounds: NSRect?
        private var lastVisibleRowCount = -1
        private var lastPrefetchedOffset: Int?
        private var suppressInitialFollow: Bool
        init(_ parent: QQVirtualTrackList) {
            self.parent = parent
            restoringPosition = parent.scrollState.origin != nil
            suppressInitialFollow = restoringPosition
        }

        func suspend() {
            parent.isActive = false
            scrollInteractionActive = false
            setHoveredRow(nil)
            scrollTask?.cancel()
            animator.cancel()
            lastPrefetchedOffset = nil
            lastViewportBounds = nil
        }

        func scrollChanged() {
            guard parent.isActive, parent.scrollState.isActive, let scroll = table?.enclosingScrollView,
                scroll.window != nil, scroll.contentView.bounds.height > 0
            else { return }
            restorePositionIfNeeded()
            guard !restoringPosition, let clip = table?.enclosingScrollView?.contentView else { return }
            let bounds = clip.bounds
            let count = table?.numberOfRows ?? 0
            guard bounds != lastViewportBounds || count != lastVisibleRowCount else { return }
            lastViewportBounds = bounds
            lastVisibleRowCount = count
            table?.refreshHoveredRow()
            if parent.scrollState.origin != bounds.origin { parent.scrollState.origin = bounds.origin }
            prefetchIfNeeded()
            followIfNeeded()
        }

        func restorePositionIfNeeded() {
            if parent.scrollState.needsRestore {
                restoringPosition = true
                suppressInitialFollow = true
                scrollTask?.cancel()
                animator.cancel()
            }
            guard restoringPosition, parent.scrollState.isActive,
                let origin = parent.scrollState.origin, let table, table.numberOfRows > 0,
                let scroll = table.enclosingScrollView, scroll.window != nil,
                scroll.contentView.bounds.height > 0
            else { return }
            restoringPosition = false
            parent.scrollState.needsRestore = false
            lastFollowedRow = parent.currentRow
            lastViewportHeight = scroll.contentView.bounds.height
            var bounds = scroll.contentView.bounds
            bounds.origin = origin
            let constrained = scroll.contentView.constrainBoundsRect(bounds)
            scroll.contentView.scroll(to: constrained.origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func manualScroll() {
            guard !manuallySuspended || animator.isAnimating || restoringPosition else { return }
            restoringPosition = false
            parent.scrollState.needsRestore = false
            suppressInitialFollow = false
            animator.cancel()
            scrollTask?.cancel()
            guard !manuallySuspended else { return }
            manuallySuspended = true
            parent.onManualScroll()
        }

        func updateFollowing(previous: QQVirtualTrackList) {
            guard parent.isActive else {
                scrollTask?.cancel()
                animator.cancel()
                return
            }
            if previous.isActive, previous.currentRow != parent.currentRow { suppressInitialFollow = false }
            if previous.followRequest != parent.followRequest
                || (!previous.followingPlayback && parent.followingPlayback)
            {
                manuallySuspended = false
                suppressInitialFollow = false
                lastFollowedRow = nil
            }
            if !parent.followingPlayback || parent.currentRow == nil {
                scrollTask?.cancel()
                animator.cancel()
            } else {
                followIfNeeded()
            }
        }

        func followIfNeeded() {
            guard parent.isActive, parent.scrollState.isActive, !restoringPosition, !suppressInitialFollow,
                parent.followingPlayback, !manuallySuspended, let row = parent.currentRow,
                row != lastFollowedRow
                    || abs((table?.enclosingScrollView?.contentView.bounds.height ?? 0) - lastViewportHeight) > 0.5
            else { return }
            scrollTask?.cancel()
            scrollTask = Task { @MainActor [weak self] in
                // Let AppKit finish inserting rows and laying out the viewport first.
                await Task.yield()
                guard let self, !Task.isCancelled, self.parent.scrollState.isActive,
                    self.parent.followingPlayback, !self.manuallySuspended,
                    self.parent.currentRow == row, let table = self.table, row < table.numberOfRows,
                    let scroll = table.enclosingScrollView, scroll.contentView.bounds.height > 0
                else { return }
                self.lastFollowedRow = row
                let clip = scroll.contentView
                self.lastViewportHeight = clip.bounds.height
                self.animator.scroll(to: row, in: table, animated: !self.parent.reduceMotion)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.tracks.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = QQPlaybackRowView()
            updateRow(view, at: row)
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.tracks.indices.contains(row), let id = tableColumn?.identifier else { return nil }
            if id.rawValue != "song" {
                let cell = tableView.makeView(withIdentifier: id, owner: self) as? QQTrackTextCell
                    ?? QQTrackTextCell(frame: .zero)
                cell.identifier = id
                cell.configure(text: textValue(column: id.rawValue, row: row), playable: parent.tracks[row].isPlayable)
                return cell
            }
            let host = tableView.makeView(withIdentifier: id, owner: self) as? QQTrackSongCell
                ?? QQTrackSongCell(rootView: AnyView(EmptyView()))
            host.hover.isHovered = hoveredRow == row
            host.rootView = styledCell(row: row, hover: host.hover)
            // Fixed row/column dimensions are owned by NSTableView, not SwiftUI measurement.
            host.sizingOptions = []
            host.identifier = id
            return host
        }

        private func styledCell(row: Int, hover: QQTrackCellHover) -> AnyView {
            let playable = parent.tracks[row].isPlayable
            return AnyView(
                cellContent(row: row, hover: hover)
                    .opacity(playable ? 1 : 0.4).disabled(!playable).allowsHitTesting(playable))
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            parent.tracks.indices.contains(row) && parent.tracks[row].isPlayable
        }

        private func cellContent(row: Int, hover: QQTrackCellHover) -> AnyView {
            let track = parent.tracks[row]
            let current = parent.currentRow == row
            let history = parent.history?[row]
            let identity = history?.record.id ?? "\(row):" + track.id
            let play = { [parent] in
                guard track.isPlayable else { return }
                if current {
                    Task { await parent.store.player.togglePlayPause() }
                } else {
                    parent.onPlay(row)
                }
            }
            return AnyView(
                HStack(spacing: 12) {
                    QQTrackCoverControl(
                        sourceID: parent.sourceID, coverID: track.coverID, title: track.title,
                        isCurrent: current, isPlaying: parent.isPlaying, isLoading: parent.loadingRow == row,
                        identifier: parent.identifier + "-play.\(row)", action: play,
                        sourceTrackID: history?.qqTrackID
                    )
                    .environment(parent.store).environment(\.workspaceIsActive, parent.isActive).id(
                        parent.sourceID + ":" + identity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).fontWeight(current ? .semibold : .medium).lineLimit(1)
                            .foregroundStyle(current ? Color(nsColor: .controlAccentColor) : Color.primary)
                        Text(track.artists.joined(separator: " / ")).font(.caption)
                            .foregroundStyle(current ? Color(nsColor: .secondaryLabelColor) : Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if track.isPlayable, let source = parent.source,
                        let findSimilar = parent.onFindSimilar, history == nil || history?.qqTrackID != nil
                    {
                        QQTrackHoverActions(hover: hover) { [parent] in
                            QQFavoriteRowActions(
                                track: track, source: source, identifier: parent.identifier + "-action",
                                row: row, historyTrack: history?.track,
                                isPlaying: current && parent.isPlaying, isLoading: parent.loadingRow == row,
                                onPlay: play, onFindSimilar: { findSimilar(track) }
                            )
                            .environment(parent.store)
                            .id(parent.sourceID + ":" + identity)
                        }
                    }
                }.padding(.leading, 28).padding(.trailing, 8))
        }

        private func textValue(column: String, row: Int) -> String {
            let track = parent.tracks[row]
            switch column {
            case "album": return track.album
            case "playedAt": return parent.history?[row].record.playedAt.formatted(date: .numeric, time: .shortened) ?? ""
            default: return durationText(Double(track.durationMS) / 1_000)
            }
        }

        func setScrollInteraction(_ active: Bool) {
            guard scrollInteractionActive != active else { return }
            scrollInteractionActive = active
            if active { setHoveredRow(nil) } else { table?.refreshHoveredRow() }
        }

        func setHoveredRow(_ row: Int?) {
            let row = row.flatMap { index in
                !scrollInteractionActive && parent.isActive && parent.tracks.indices.contains(index) && parent.tracks[index].isPlayable
                    ? index : nil
            }
            guard hoveredRow != row else { return }
            let previous = hoveredRow
            hoveredRow = row
            guard let table, let songColumn = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "song" })
            else { return }
            for index in [previous, row].compactMap({ $0 }) where parent.tracks.indices.contains(index) {
                if let view = table.rowView(atRow: index, makeIfNecessary: false) as? QQPlaybackRowView {
                    view.isHovered = index == row
                }
                if let host = table.view(atColumn: songColumn, row: index, makeIfNecessary: false)
                    as? QQTrackSongCell
                {
                    host.hover.isHovered = index == row
                }
            }
        }

        private func updateRow(_ view: QQPlaybackRowView, at row: Int) {
            view.isCurrent = parent.currentRow == row
            view.isHovered = hoveredRow == row
            view.setAccessibilityIdentifier(parent.identifier + (view.isCurrent ? "-current.\(row)" : "-row.\(row)"))
        }

        func updatePlaybackRows(_ rows: Set<Int>) {
            guard let table else { return }
            for row in rows where parent.tracks.indices.contains(row) {
                if let view = table.rowView(atRow: row, makeIfNecessary: false) as? QQPlaybackRowView {
                    updateRow(view, at: row)
                }
                if let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "song" }),
                   let host = table.view(atColumn: column, row: row, makeIfNecessary: false) as? QQTrackSongCell {
                    host.rootView = styledCell(row: row, hover: host.hover)
                }
            }
        }

        @objc func playSelected() {
            guard let table, parent.tracks.indices.contains(table.clickedRow),
                parent.tracks[table.clickedRow].isPlayable
            else { return }
            parent.onPlay(table.clickedRow)
        }

        func prefetchIfNeeded() {
            guard parent.isActive, parent.scrollState.isActive, !restoringPosition, let table, !parent.tracks.isEmpty
            else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, NSMaxRange(visible) >= parent.tracks.count - 12 else { return }
            // Layout and playback invalidations may report the same viewport repeatedly.
            // The raw offset also advances for empty/filtered pages, so pagination never stalls there.
            guard lastPrefetchedOffset != parent.paginationOffset else { return }
            lastPrefetchedOffset = parent.paginationOffset
            Task { @MainActor [weak self] in self?.parent.onNearEnd() }
        }
    }
}

/// Hover invalidates only the action subtree, keeping cover loading and song text mounted.
@MainActor @Observable private final class QQTrackCellHover {
    var isHovered = false
}

private final class QQTrackSongCell: NSHostingView<AnyView> {
    let hover = QQTrackCellHover()
}

private struct QQTrackHoverActions<Content: View>: View {
    let hover: QQTrackCellHover
    @ViewBuilder var content: () -> Content
    var body: some View {
        if hover.isHovered { content() }
    }
}

/// Static columns do not need a hosting graph, async tasks or SwiftUI layout on reuse.
private final class QQTrackTextCell: NSTableCellView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
    func configure(text: String, playable: Bool) {
        if textField?.stringValue != text { textField?.stringValue = text }
        alphaValue = playable ? 1 : 0.4
    }
}

private struct QQFavoriteRowActions: View {
    @Environment(AppStore.self) private var store
    @State private var changingFavorite = false
    @State private var settingNextTrack = false
    var track: SourceTrack
    var source: SourceConnection
    var identifier: String
    var row: Int
    var historyTrack: LibraryTrack?
    var isPlaying: Bool
    var isLoading: Bool
    var onPlay: () -> Void
    var onFindSimilar: () -> Void

    private var isFavorite: Bool { historyTrack.map { store.isFavorite($0.id) } ?? true }

    var body: some View {
        HStack(spacing: 3) {
            action(isPlaying ? "暂停" : "播放", symbol: isPlaying ? "pause.fill" : "play.fill", id: "play", onPlay)
                .disabled(isLoading)
            action(
                isFavorite ? "取消收藏" : "收藏", symbol: isFavorite ? "heart.fill" : "heart", id: "favorite",
                color: isFavorite ? .pink : .secondary
            ) {
                changingFavorite = true
                Task {
                    defer { changingFavorite = false }
                    if let historyTrack {
                        await store.toggleFavorite(historyTrack)
                    } else {
                        await store.toggleQQTrackFavorite(track, from: source)
                    }
                }
            }.disabled(changingFavorite || historyTrack.map { store.isUpdatingFavorite($0.id) } == true)
            action("设置为下一曲", symbol: "text.line.first.and.arrowtriangle.forward", id: "next") {
                settingNextTrack = true
                Task {
                    defer { settingNextTrack = false }
                    await store.setQQTrackAsNext(track, from: source)
                }
            }.disabled(settingNextTrack)
            action("搜索相似歌曲", symbol: "magnifyingglass", id: "similar", onFindSimilar)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .task(id: historyTrack?.id) {
            if let historyTrack { await store.refreshQQFavorite(historyTrack) }
        }
    }

    private func action(
        _ title: String, symbol: String, id: String, color: Color = .secondary, _ handler: @escaping () -> Void
    ) -> some View {
        Button(action: handler) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier + ".\(id).\(row)")
    }
}

private final class QQBorderlessHeaderView: NSTableHeaderView {
    static let topPadding: CGFloat = 8
    static let height: CGFloat = 28 + topPadding

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let tableView else { return }
        for (index, column) in tableView.tableColumns.enumerated() {
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            var titleRect = rect.insetBy(dx: 10, dy: 0)
            titleRect.size.height = max(0, titleRect.height - Self.topPadding)
            if isFlipped { titleRect.origin.y += Self.topPadding }
            column.headerCell.drawInterior(withFrame: titleRect, in: self)
        }
    }
}

private final class QQPlaybackRowView: NSTableRowView {
    var isCurrent = false { didSet { if oldValue != isCurrent { needsDisplay = true } } }
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemColorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    @objc private func systemColorsChanged() { needsDisplay = true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isHovered {
            drawHighlight(NSColor.labelColor.withAlphaComponent(0.10))
        } else if isCurrent {
            drawCurrentBackground()
        } else {
            super.drawBackground(in: dirtyRect)
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        if isCurrent { drawCurrentBackground() } else { super.drawSelection(in: dirtyRect) }
    }

    private func drawCurrentBackground() {
        let highlighted = isSelected && selectionHighlightStyle != .none
        drawHighlight(NSColor.controlAccentColor.withAlphaComponent(highlighted ? 0.16 : 0.08))
    }

    private func drawHighlight(_ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

private final class QQTrackScrollView: NSScrollView {
    // The overrides only report scrolling; AppKit still owns wheel deltas and momentum.
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
    var onScroll: (() -> Void)?
    var onManualScroll: (() -> Void)?
    var onScrollActivityChange: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollStarted),
            name: NSScrollView.willStartLiveScrollNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollEnded),
            name: NSScrollView.didEndLiveScrollNotification, object: self)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func scrollStarted() { onScrollActivityChange?(true) }
    @objc private func scrollEnded() { onScrollActivityChange?(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onScrollActivityChange?(false) }
    }
    override func layout() {
        super.layout()
        onScroll?()
    }
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 { onManualScroll?() }
        super.scrollWheel(with: event)
    }
    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        onScroll?()
    }
}

private final class QQTrackScroller: NSScroller {
    var onManualScroll: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onManualScroll?()
        super.mouseDown(with: event)
    }
}

private final class QQTrackTableView: NSTableView {
    var onManualScroll: (() -> Void)?
    var onHoveredRowChange: ((Int?) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard onHoveredRowChange != nil else { return }
        let area = NSTrackingArea(
            rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea == hoverArea { refreshHoveredRow(at: event.locationInWindow) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        refreshHoveredRow(at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea == hoverArea { onHoveredRowChange?(nil) }
    }

    func refreshHoveredRow(at location: NSPoint? = nil) {
        guard let onHoveredRowChange, let window, window.isKeyWindow else { return }
        let point = convert(location ?? window.mouseLocationOutsideOfEventStream, from: nil)
        let row = visibleRect.contains(point) ? row(at: point) : -1
        onHoveredRowChange(row >= 0 ? row : nil)
    }

    override func keyDown(with event: NSEvent) {
        // Arrow keys, Home/End and Page Up/Down are deliberate list navigation.
        if [123, 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode) { onManualScroll?() }
        super.keyDown(with: event)
    }
}
