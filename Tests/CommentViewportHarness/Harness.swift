import AppKit
import MusicCore
import SwiftUI

private struct Failure: Error { let message: String }
@MainActor private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}

@main @MainActor struct Harness {
    static func main() throws {
        _ = NSApplication.shared
        let data = try JSONSerialization.data(withJSONObject: (0..<520).map { index in
            ["id": String(index), "author": "作者 \(index)", "text": String(repeating: "评论内容 mixed text 😀。", count: index % 5 + 1), "likeCount": index] as [String: Any]
        })
        let comments = try JSONDecoder().decode([QQSongComment].self, from: data)
        let view = CommentScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { view.stop(); window.orderOut(nil) }
        var nearEnd = false
        func configure(_ count: Int) {
            view.configure(CommentViewport(comments: Array(comments.prefix(count)), loading: false, failure: nil,
                hasMore: true, onNearEnd: { nearEnd = $0 }, onRetry: {}), animated: false)
        }
        func advance() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        configure(500)
        advance()
        guard let document = view.documentView else { throw Failure(message: "no document") }
        try require(CommentScrollView.isCompatibleWithResponsiveScrolling, "responsive scrolling disabled")
        try require(document.subviews.count > 3 && document.subviews.count < 40, "500 comments were not virtualized")
        try require(document.frame.height > 20_000, "missing estimated offscreen rows")
        try require(document.subviews.allSatisfy { $0.frame.height > 35 }, "invalid measured row height")
        try require(document.subviews.contains { $0.frame.height < 75 }, "rows retained estimated heights instead of measuring short text")
        print("PASS native responsive scrolling, measured row heights and bounded virtualization")
        let created = view.createdRowCount
        for step in 0..<60 {
            view.contentView.scroll(to: CGPoint(x: 0, y: step.isMultiple(of: 2) ? 20 : 0))
            view.reflectScrolledClipView(view.contentView)
        }
        advance()
        try require(view.createdRowCount == created, "small deltas recreated existing comment hosts")
        try require(!nearEnd, "pagination triggered far from the end")
        print("PASS repeated small scrolls reuse hosts without triggering pagination")
        func oscillate() {
            for y in [900.0, 0.0, 900.0, 0.0] {
                view.contentView.scroll(to: CGPoint(x: 0, y: y))
                view.reflectScrolledClipView(view.contentView)
                advance()
            }
        }
        oscillate()
        let warmCreated = view.createdRowCount
        oscillate()
        try require(view.createdRowCount == warmCreated, "backtracking rebuilt recently visible comments")
        print("PASS bounded row cache reuses comments across viewport boundaries")
        view.contentView.scroll(to: CGPoint(x: 0, y: document.frame.height - 600))
        view.reflectScrolledClipView(view.contentView)
        advance()
        try require(nearEnd, "last page did not trigger prefetch")
        let before = view.contentView.bounds.minY
        let anchor = document.subviews.first { $0.frame.minY <= before && $0.frame.maxY > before }
        let inset = anchor.map { before - $0.frame.minY }
        let identifiers = Set(document.subviews.map(ObjectIdentifier.init))
        configure(520)
        advance()
        try require(anchor != nil && anchor?.superview === document, "pagination discarded the reading anchor")
        try require(abs(view.contentView.bounds.minY - anchor!.frame.minY - inset!) < 1,
                    "appending a page jumped the reading position inside the visible comment")
        try require(!identifiers.isDisjoint(with: Set(document.subviews.map(ObjectIdentifier.init))), "pagination replaced all visible hosts")
        try require(document.subviews.count < 40, "pagination retained the full document")
        try require(view.cachedRowCount <= 24, "detached row cache grew without a bound")
        print("PASS paging preserves visible hosts and scroll anchor")
        view.setFrameSize(NSSize(width: 320, height: 600))
        view.layoutSubtreeIfNeeded()
        advance()
        try require(document.subviews.allSatisfy { abs($0.frame.width - view.contentView.bounds.width) < 1 }, "resize retained stale row widths")
        print("PASS width changes reflow visible comments")
        configure(0)
        advance()
        try require(abs(view.contentView.bounds.minY) < 1, "replacing the document retained a stale scroll position")
        try require(document.preparedContentRect.contains(view.contentView.bounds), "empty list leaves unprepared blank content")
        print("PASS empty replacement resets scrolling and prepares the blank viewport")
        var routing = CommentWheelRouting()
        try require(routing.route(inside: true, phase: .began, momentum: []), "gesture did not start in comments")
        try require(routing.route(inside: false, phase: .changed, momentum: []), "gesture lost ownership outside comments")
        try require(routing.route(inside: false, phase: .ended, momentum: []), "finger lift lost ownership")
        try require(routing.route(inside: false, phase: [], momentum: .began), "momentum was dropped")
        try require(routing.route(inside: false, phase: [], momentum: .ended), "last momentum event was dropped")
        try require(!routing.route(inside: false, phase: .began, momentum: []), "stole a lyric gesture")
        try require(!routing.route(inside: true, phase: .changed, momentum: []), "stole a gesture entering comments")
        try require(!routing.route(inside: true, phase: .ended, momentum: []), "stole external finger lift")
        try require(routing.route(inside: true, phase: [], momentum: []), "mouse wheel stopped working")
        print("PASS native gesture ownership and momentum survive crossing between panels")
        view.stop()
        try require(view.cachedRowCount == 0, "stopping the viewport retained cached rows")
        print("Comment viewport regression harness: 7/7 passed")
    }
}
