import AppKit
import MusicCore
import SwiftUI

private final class FixtureWindow: NSWindow {
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
}
@main @MainActor struct Harness {
    static func advance(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.002))) }
    }
    static func table(in view: NSView) -> NSTableView? {
        if let result = view as? NSTableView { return result }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func main() {
        _ = NSApplication.shared
        let baseline = CommandLine.arguments.contains("--baseline")
        let store = AppStore()
        let scrollState = QQCollectionScrollState()
        scrollState.isActive = true
        let tracks = (0..<500).map { SourceTrack(id: "song\($0)", title: "Song \($0)", artists: ["Artist"],
                                                album: "Album \($0 / 10)", durationMS: 180_000, isPlayable: $0 != 2) }
        let source = SourceConnection(id: "fixture", ownerID: "fixture", name: "Fixture", kind: "qq",
                                      baseURL: "local:fixture", enabled: true, state: "active")
        var pageRequests = 0, interruptions = 0
        let view = QQVirtualTrackList(tracks: tracks, source: source, paginationOffset: 500, store: store,
            currentRow: 0, isPlaying: false, loadingRow: nil, followingPlayback: false, followRequest: UUID(),
            scrollState: scrollState, isActive: true, onManualScroll: { interruptions += 1 },
            onPlay: { _ in }, onNearEnd: { pageRequests += 1 }, onFindSimilar: { _ in })
        let host = NSHostingView(rootView: view)
        let window = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        advance(0.2)
        guard let table = table(in: host), let scroll = table.enclosingScrollView,
              let coordinator = table.delegate as? QQVirtualTrackList.Coordinator else { fatalError("list not mounted") }
        precondition(table.numberOfRows == 500)
        if !baseline {
            precondition(type(of: scroll).isCompatibleWithResponsiveScrolling)
            precondition(type(of: table).isCompatibleWithResponsiveScrolling)
            let album = table.delegate!.tableView!(table, viewFor: table.tableColumns[1], row: 0)!
            precondition(album is NSTableCellView && !(album is NSHostingView<AnyView>))
            let disabled = table.delegate!.tableView!(table, viewFor: table.tableColumns[1], row: 2)!
            precondition(disabled.alphaValue == 0.4)
            precondition(!coordinator.tableView(table, shouldSelectRow: 2))
        }
        let first = table.view(atColumn: 0, row: 0, makeIfNecessary: true)!
        coordinator.setHoveredRow(0)
        advance(0.02)
        coordinator.setHoveredRow(1)
        advance(0.02)
        precondition(table.view(atColumn: 0, row: 0, makeIfNecessary: false) === first)
        if !baseline {
            coordinator.animator.scroll(to: 140, in: table, animated: false)
            let selectedOrigin = scroll.contentView.bounds.origin
            var preparing = view
            preparing.followRequest = UUID()
            coordinator.parent = preparing
            coordinator.updateFollowing(previous: view)
            advance(0.10)
            precondition(scroll.contentView.bounds.origin == selectedOrigin, "must not follow the previous song during preparation")
            var playing = preparing
            playing.currentRow = 140
            playing.followingPlayback = true
            coordinator.parent = playing
            coordinator.updateFollowing(previous: preparing)
            advance(0.10)
            precondition(abs(scroll.contentView.bounds.origin.y - selectedOrigin.y) < 1)
            var firstSong = playing
            firstSong.currentRow = 0
            coordinator.parent = firstSong
            coordinator.updateFollowing(previous: playing)
            advance(1.3)
            let header = table.headerView!
            let row = table.rect(ofRow: 0)
            precondition(table.convert(header.bounds, from: header).maxY <= row.minY
                && row.maxY <= table.visibleRect.maxY, "first song must be entirely visible below the header")
            coordinator.parent = view
            coordinator.updateFollowing(previous: firstSong)
        }
        coordinator.animator.scroll(to: 200, in: table, animated: true)
        advance(0.05)
        coordinator.manualScroll()
        precondition(!coordinator.animator.isAnimating && interruptions == 1)
        for _ in 0..<20 { coordinator.manualScroll() }
        precondition(interruptions == 1, "one gesture must not keep invalidating the parent")
        let stopped = scroll.contentView.bounds.origin
        advance(0.05)
        precondition(scroll.contentView.bounds.origin == stopped)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        advance(0.1)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        let began = cpu()
        let start = ProcessInfo.processInfo.systemUptime
        // Identical, bounded scroll + hover workload. No real window is presented.
        for frame in 0..<240 {
            let step = frame % 120
            let y = Double(step < 60 ? step : 120 - step) * 26
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            table.layoutSubtreeIfNeeded()
            coordinator.setHoveredRow(Int(y / 54) + (frame % 2))
            host.displayIfNeeded()
            advance(1.0 / 120)
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let consumed = cpu() - began
        print(String(format: "BENCH cpu_ms=%.1f elapsed_s=%.3f cpu_percent=%.2f", consumed * 1000, elapsed, consumed / elapsed * 100))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.scrollChanged()
        advance(0.03)
        coordinator.scrollChanged()
        precondition(pageRequests == 1, "pagination must be coalesced for the same offset")
        print("PASS responsive scrolling, disabled rows, retained song hosts, immediate manual interruption and coalesced paging")
    }
}
