import AppKit

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(description: message) }
}

@MainActor
private final class Rows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 1_000 }
}

@main
@MainActor
private struct Harness {
    static func advance(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.005))) }
    }

    static func main() throws {
        _ = NSApplication.shared
        let rows = Rows()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 20_000))
        table.headerView = nil
        table.rowHeight = 20
        table.intercellSpacing = .zero
        table.addTableColumn(NSTableColumn(identifier: .init("song")))
        table.dataSource = rows
        scroll.documentView = table
        table.reloadData()
        table.layoutSubtreeIfNeeded()

        let animator = PlaybackScrollAnimator()
        animator.scroll(to: 800, in: table, animated: true)
        try require(scroll.contentView.bounds.origin.y == 0, "animation jumped before its first frame")
        advance(0.10)
        let intermediate = scroll.contentView.bounds.origin.y
        try require(
            intermediate > 0 && intermediate < table.rect(ofRow: 800).minY - 240,
            "animation did not expose intermediate positions")
        animator.cancel()
        let stopped = scroll.contentView.bounds.origin.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: stopped + 80))
        let manual = scroll.contentView.bounds.origin.y
        advance(0.20)
        try require(
            abs(scroll.contentView.bounds.origin.y - manual) < 0.01 && !animator.isAnimating,
            "a cancelled frame moved the user's scroll position")
        print("PASS intermediate frames and immediate handoff preserve manual position")

        animator.scroll(to: 900, in: table, animated: true)
        advance(0.08)
        let retargetStart = scroll.contentView.bounds.origin.y
        animator.scroll(to: 0, in: table, animated: true)
        try require(
            abs(scroll.contentView.bounds.origin.y - retargetStart) < 0.01,
            "retargeting snapped to an old endpoint")
        advance(0.08)
        try require(scroll.contentView.bounds.origin.y < retargetStart, "new target did not replace old movement")
        advance(1.1)
        try require(
            abs(scroll.contentView.bounds.origin.y) < 0.01 && !animator.isAnimating,
            "old animation resumed after retargeting")
        print("PASS a new song retargets from the current displayed offset")

        animator.scroll(to: 500, in: table, animated: false)
        let expected = table.rect(ofRow: 500).midY - scroll.contentView.bounds.height / 2
        try require(
            abs(scroll.contentView.bounds.origin.y - expected) < 0.01 && !animator.isAnimating,
            "reduced motion created an animation")
        print("PASS reduced motion positions without starting a timer")

        animator.scroll(to: 700, in: table, animated: true)
        advance(0.06)
        table.rowHeight = 32
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<1_000))
        table.layoutSubtreeIfNeeded()
        advance(1.3)
        let corrected = table.rect(ofRow: 700).midY - scroll.contentView.bounds.height / 2
        try require(
            abs(scroll.contentView.bounds.origin.y - corrected) < 0.5 && !animator.isAnimating,
            "row-height correction left the current song outside its destination")
        print("PASS changing virtual row heights converge to the corrected destination")

        var temporary: PlaybackScrollAnimator? = PlaybackScrollAnimator()
        weak let released = temporary
        temporary?.scroll(to: 900, in: table, animated: true)
        advance(0.05)
        temporary = nil
        let detached = scroll.contentView.bounds.origin.y
        advance(0.15)
        try require(
            released == nil && abs(scroll.contentView.bounds.origin.y - detached) < 0.01,
            "detached list retained an active animation")
        print("PASS detaching a list releases and stops its animation")
        print("Scroll animation regression harness: 5/5 passed")
    }
}
