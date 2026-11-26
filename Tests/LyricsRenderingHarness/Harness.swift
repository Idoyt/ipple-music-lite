import AppKit
import MusicCore
import SwiftUI

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(description: message) }
}
func durationText(_ value: Double) -> String { String(format: "%.3f", value) }

@MainActor @Observable
private final class LyricScrollFixture {
    var position = 200.0
    var isPlaying = false
}

private struct LyricScrollContent: View {
    let fixture: LyricScrollFixture
    let timeline: LyricsTimeline

    var body: some View {
        SynchronizedLyricsView(
            timeline: timeline, position: fixture.position, canSeek: true, centered: true, onSeek: { _ in },
            isPlaying: fixture.isPlaying, playbackClock: { fixture.isPlaying ? fixture.position : 0 }
        )
        .frame(width: 600, height: 320)
    }
}

@main
@MainActor
private struct Harness {
    static func main() throws {
        _ = NSApplication.shared
        let cue = LyricsTimeline(
            lrc: "[00:01]你好 music world",
            lines: [
                SourceLyricLine(
                    text: "你好 music world", startMS: 1000, durationMS: 3400,
                    words: [
                        .init(text: "你", startMS: 1000, durationMS: 600),
                        .init(text: "好", startMS: 1600, durationMS: 800),
                        .init(text: " music", startMS: 2400, durationMS: 1000),
                        .init(text: " world", startMS: 3400, durationMS: 1000),
                    ])
            ]
        ).cues[0]
        let view = WordLyricsView(frame: NSRect(x: 0, y: 0, width: 400, height: 55))
        view.appearance = NSAppearance(named: .darkAqua)
        var sought = -1.0
        func configure(_ time: Double, seek: Bool = true, playing: Bool = false) {
            view.configure(
                cue: cue, endTime: 5, position: time, isPlaying: playing, clock: nil,
                canSeek: seek, centered: true, onSeek: { sought = $0 })
        }
        func render() throws -> NSBitmapImageRep {
            view.updateLayer()
            guard let layer = view.layer,
                let context = CGContext(
                    data: nil, width: Int(view.bounds.width), height: Int(view.bounds.height), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                throw Failure(description: "unable to allocate lyric image")
            }
            layer.render(in: context)
            guard let image = context.makeImage() else { throw Failure(description: "unable to snapshot lyric image") }
            return NSBitmapImageRep(cgImage: image)
        }
        configure(2)
        _ = view.textHeight(width: 400)
        _ = try render()
        let initialRasterizations = view.rasterizationCount
        let actions = view.accessibilityChildren() as! [NSAccessibilityElement]
        let identities = actions.map(ObjectIdentifier.init)
        for frame in 0..<120 {
            configure(1 + Double(frame) / 40)
            _ = try render()
        }
        try require(
            initialRasterizations == 1 && view.rasterizationCount == 1,
            "playback frames rerasterized unchanged glyphs")
        try require(
            (view.accessibilityChildren() as! [NSAccessibilityElement]).map(ObjectIdentifier.init) == identities,
            "playback frames rebuilt word actions")
        print("PASS 120 playback frames reuse one glyph rasterization and stable word actions")

        try require(actions[3].accessibilityPerformPress() && sought == 3.4, "word click lost its exact time")
        sought = -1
        configure(2, seek: false)
        _ = actions[3].accessibilityPerformPress()
        try require(sought == -1, "disabled seeking still invoked playback")
        configure(2)
        try require(actions[1].accessibilityPerformPress() && sought == 1.6, "reenabling seeking lost the action")
        print("PASS cached word actions preserve exact seeking and disabled state")

        _ = try render()
        view.needsDisplay = false
        configure(2)
        try require(!view.needsDisplay && !view.hasAnimatedFill, "paused unchanged lyrics keep scheduling display work")
        print("PASS paused identical progress requests no redraw and holds a static mask")

        let beforeSizeProbe = try render().tiffRepresentation
        _ = view.textHeight(width: 120)
        let afterSizeProbe = try render().tiffRepresentation
        try require(
            beforeSizeProbe != nil && beforeSizeProbe == afterSizeProbe && view.rasterizationCount == 1,
            "a proposed width changed the rendered glyphs before the view actually resized")
        print("PASS proposed widths preserve the visible glyph cache")

        view.setFrameSize(NSSize(width: 120, height: 140))
        _ = view.textHeight(width: 120)
        _ = try render()
        try require(view.rasterizationCount == 2, "resize failed to refresh the glyph cache")
        configure(3)
        _ = try render()
        try require(view.rasterizationCount == 2, "wrapped playback kept invalidating its glyph cache")
        print("PASS width changes rebuild once and wrapped lyrics reuse the new cache")

        configure(4.45)
        let complete = try render().tiffRepresentation
        configure(4.999)
        let held = try render().tiffRepresentation
        configure(5)
        let cleared = try render().tiffRepresentation
        try require(
            complete != nil && held == complete && cleared != complete, "word fill did not hold until the next line")
        print("PASS completed word fill survives the gap and clears exactly at the next line")

        let window = NSWindow(
            contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        configure(1.1, playing: true)
        view.updateLayer()
        let firstWord = view.layer?.sublayers?.last?.mask?.sublayers?.first
        let animation = firstWord?.animation(forKey: "word-fill") as? CABasicAnimation
        try require(
            view.hasAnimatedFill && abs((animation?.duration ?? 0) - 0.5) < 0.01,
            "word fill must animate only the remaining media-clock interval")
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        let earlyWidth = firstWord?.presentation()?.bounds.width ?? 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.14))
        try require(
            (firstWord?.presentation()?.bounds.width ?? 0) > earlyWidth, "compositor did not advance the fill")
        configure(1.25)
        view.updateLayer()
        try require(!view.hasAnimatedFill, "pausing did not remove scheduled word fill")
        window.orderOut(nil)
        print("PASS compositor advances the active word independently and stops on pause")

        try smoothScrolling()
        try fullDistanceReturn()
        try nearStartReturn()
        print("Lyrics rendering regression harness: 13/13 passed")
    }

    static func smoothScrolling() throws {
        func advance(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func findScrollView(in view: NSView) -> TimedLyricScrollView? {
            (view as? TimedLyricScrollView) ?? view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
        }
        let rows = 0..<60
        let lyrics = rows.map { row in
            let time = row * 5
            return String(
                format: "[%02d:%02d]Line %d\n[%02d:%02d]", time / 60, time % 60, row, (time + 2) / 60, (time + 2) % 60)
        }.joined(separator: "\n")
        let translations = rows.filter { $0.isMultiple(of: 3) }.map { row in
            let time = row * 5
            return String(format: "[%02d:%02d]Translation %d", time / 60, time % 60, row)
        }.joined(separator: "\n")
        let words = rows.filter { $0.isMultiple(of: 2) }.map { row in
            let text = "Line \(row)"
            let time = Int64(row) * 5_000
            return SourceLyricLine(
                text: text, startMS: time, durationMS: 1_000,
                words: [.init(text: text, startMS: time, durationMS: 1_000)])
        }
        let fixture = LyricScrollFixture()
        let content = NSHostingView(
            rootView: LyricScrollContent(
                fixture: fixture, timeline: LyricsTimeline(lrc: lyrics, translation: translations, lines: words)))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 320), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = content
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        advance(0.05)
        guard let scroll = findScrollView(in: content) else {
            throw Failure(description: "lyric scroll view was not installed")
        }
        try require(TimedLyricScrollView.isCompatibleWithResponsiveScrolling,
                    "custom wheel handling disabled AppKit responsive scrolling")
        print("PASS precision scrolling retains AppKit responsive scrolling")
        let firstOffset = scroll.contentView.bounds.origin.y
        advance(0.55)
        let before = scroll.contentView.bounds.origin.y
        try require(
            firstOffset > 1_000 && abs(firstOffset - before) < 2,
            "restored lyrics first appeared away from the current row: \(firstOffset) to \(before)")
        print("PASS paused lyrics open at the saved line without scrolling from the beginning")
        fixture.position = 203
        advance(0.2)
        try require(abs(scroll.contentView.bounds.origin.y - before) < 1, "empty marker moved the lyric viewport")
        fixture.isPlaying = true
        fixture.position = 205
        var samples: [CGFloat] = []
        for _ in 0..<35 {
            advance(0.016)
            samples.append(scroll.displayedOffset)
        }
        let after = scroll.contentView.bounds.origin.y
        let lower = min(before, after) + 2
        let upper = max(before, after) - 2
        try require(upper > lower, "next sung line did not move the viewport")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try require(
                samples.filter { $0 > lower && $0 < upper }.count > 2,
                "next line jumped instead of showing intermediate offsets: \(before) to \(after)")
            print("PASS native compositor follows the next sung line across blank markers with intermediate offsets")
        } else {
            print("PASS native viewport follows the next sung line across blank markers with Reduce Motion enabled")
        }

        guard let document = scroll.documentView else { throw Failure(description: "missing lyric document") }
        let viewport = scroll.contentView.bounds
        document.prepareContent(in: viewport.insetBy(dx: 0, dy: -viewport.height * 0.5))
        let retained = document.subviews.map(ObjectIdentifier.init)
        for delta in [8.0, 16.0, 24.0, 8.0, 0.0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: viewport.minY + delta))
            scroll.reflectScrolledClipView(scroll.contentView)
            advance(0.01)
            try require(document.preparedContentRect.contains(scroll.contentView.bounds),
                        "precision scrolling exposed unprepared lyric rows")
        }
        try require(Set(retained).isSubset(of: Set(document.subviews.map(ObjectIdentifier.init))),
                    "small forward/reverse deltas repeatedly recycled lyric rows")
        try require(document.subviews.count < 30, "scroll overdraw rendered the entire lyric document")
        print("PASS small forward/reverse scrolls reuse bounded, prepared lyric rows")
    }

    static func fullDistanceReturn() throws {
        let lyrics = (0..<120).map { row in
            String(format: "[%02d:%02d]Return test line %d", row * 5 / 60, row * 5 % 60, row)
        }.joined(separator: "\n")
        let cues = LyricsTimeline(lrc: lyrics).sungCues
        let scroll = TimedLyricScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        func configure(following: Bool, animated: Bool = true) {
            scroll.configure(TimedLyricsViewport(
                cues: cues, activeRow: 45, position: 225, isPlaying: false, clock: nil,
                canSeek: true, centered: true, following: following, isPresented: true,
                onManualScroll: {}, onSeek: { _ in }), animated: animated)
        }
        func advance(_ interval: Double) { RunLoop.main.run(until: Date().addingTimeInterval(interval)) }
        configure(following: true)
        scroll.layoutSubtreeIfNeeded()
        let target = scroll.contentView.bounds.minY
        for delta: CGFloat in [-1_400, 1_400] {
            configure(following: false)
            let start = target + delta
            scroll.contentView.scroll(to: NSPoint(x: 0, y: start))
            scroll.reflectScrolledClipView(scroll.contentView)
            advance(0.02)
            configure(following: true)
            try require(abs(scroll.displayedOffset - start) < 0.5,
                        "return jumped from the actual viewport to a point near its destination")
            var previous = start
            var intermediate = 0
            for _ in 0..<48 {
                advance(0.016)
                let current = scroll.displayedOffset
                try require((current - previous) * -delta >= -0.5, "return moved in the wrong direction")
                if abs(current - start) > 1 && abs(current - target) > 1 { intermediate += 1 }
                try require((scroll.documentView?.subviews.count ?? 0) < 30,
                            "long return instantiated all intervening lyric rows")
                previous = current
            }
            try require(intermediate > 5 && abs(previous - target) < 0.5,
                        "return failed to travel smoothly all the way to the current lyric")
        }
        configure(following: false)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target - 1_400))
        configure(following: true)
        advance(0.08)
        configure(following: false)
        let stopped = scroll.displayedOffset
        advance(0.3)
        try require(abs(scroll.displayedOffset - stopped) < 0.5, "manual takeover did not stop the return")
        configure(following: true, animated: false)
        try require(abs(scroll.displayedOffset - target) < 0.5, "Reduce Motion must position immediately")
        scroll.stopFollowingAnimation()
        print("PASS full-distance returns move both directions from the actual offset, retain bounded rows, and cancel")
    }

    static func nearStartReturn() throws {
        let cues = LyricsTimeline(lrc: (0..<60).map { row in
            String(format: "[%02d:%02d]Opening line %d", row * 5 / 60, row * 5 % 60, row)
        }.joined(separator: "\n")).sungCues
        let scroll = TimedLyricScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        func configure(_ row: Int, following: Bool, animated: Bool = true) {
            scroll.configure(TimedLyricsViewport(
                cues: cues, activeRow: row, position: Double(row * 5), isPlaying: false, clock: nil,
                canSeek: true, centered: true, following: following, isPresented: true,
                onManualScroll: {}, onSeek: { _ in }), animated: animated)
        }
        func advance(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        for row in 0..<4 {
            configure(row, following: true, animated: false)
            scroll.layoutSubtreeIfNeeded()
            let target = scroll.contentView.bounds.minY
            for start in [CGFloat(0), target + 90, target + 1_400] {
                configure(row, following: false)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: start))
                advance(0.01)
                configure(row, following: true)
                try require(abs(scroll.contentView.bounds.minY - start) < 0.5,
                            "opening-line return moved the clip before the first animation frame")
                try require(scroll.documentView?.layer?.animation(forKey: "lyric-follow") == nil,
                            "manual return near the document edge used a translated document")
                var previous = start
                var intermediate = 0
                for _ in 0..<44 {
                    advance(0.016)
                    let current = scroll.contentView.bounds.minY
                    try require(current >= min(start, target) - 0.5 && current <= max(start, target) + 0.5,
                                "opening-line return jumped past either endpoint")
                    try require((current - previous) * (target - start) >= -0.5,
                                "opening-line return reversed direction")
                    if abs(current - start) > 0.5 && abs(current - target) > 0.5 { intermediate += 1 }
                    previous = current
                }
                try require(intermediate > 3 && abs(previous - target) < 0.5,
                            "opening-line return did not smoothly reach its target")
            }
        }
        scroll.stopFollowingAnimation()
        print("PASS opening four lines return smoothly from above/below without a clip jump or boundary overshoot")
    }
}
