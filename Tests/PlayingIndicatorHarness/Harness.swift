import AppKit
import Darwin
import SwiftUI

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(description: message) }
}

private final class MeasurementCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
private struct MeasurementProbe: Layout {
    var counter: MeasurementCount
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        counter.increment()
        return subviews.first?.sizeThatFits(proposal) ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

@MainActor private final class CountingHost: NSHostingView<AnyView> {
    var layouts = 0
    override func layout() {
        layouts += 1
        super.layout()
    }
}

@main @MainActor private enum Harness {
    static func advance(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.005))) }
    }
    static func symbol(in view: NSView) -> NowPlayingSymbolView? {
        if let symbol = view as? NowPlayingSymbolView { return symbol }
        for child in view.subviews { if let result = symbol(in: child) { return result } }
        return nil
    }
    static func representation(_ view: NowPlayingSymbolView) throws -> NSBitmapImageRep {
        guard let bitmap = view.image?.representations.first as? NSBitmapImageRep else {
            throw Failure(description: "missing bundled GIF bitmap representation")
        }
        return bitmap
    }
    static func frames(_ bitmap: NSBitmapImageRep, over seconds: Double) -> Set<Int> {
        var result: Set<Int> = []
        let end = Date().addingTimeInterval(seconds)
        repeat {
            result.insert((bitmap.value(forProperty: .currentFrame) as? NSNumber)?.intValue ?? -1)
            advance(0.03)
        } while Date() < end
        return result
    }
    static func processCPUTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func benchmark(_ content: AnyView, in window: NSWindow) -> (Double, Int, Int) {
        let measurements = MeasurementCount()
        let host = CountingHost(rootView: AnyView(MeasurementProbe(counter: measurements) { content }))
        host.sizingOptions = []
        window.contentView = host
        advance(0.3)
        let startLayouts = host.layouts
        let startMeasurements = measurements.value
        let start = processCPUTime()
        advance(2)
        return ((processCPUTime() - start) * 50, host.layouts - startLayouts, measurements.value - startMeasurements)
    }
    static func main() throws {
        _ = NSApplication.shared
        let measurements = MeasurementCount()
        let host = CountingHost(
            rootView: AnyView(MeasurementProbe(counter: measurements) { NowPlayingIndicator(isPlaying: true) }))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 30, y: 30, width: 160, height: 60), styleMask: .borderless, backing: .buffered,
            defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        advance(0.3)
        guard let symbol = symbol(in: host) else { throw Failure(description: "missing native GIF view") }
        try require(symbol.image != nil && symbol.isAnimating && symbol.animates, "visible playing GIF did not animate")
        let bitmap = try representation(symbol)
        try require(
            (bitmap.value(forProperty: .frameCount) as? NSNumber)?.intValue == 48,
            "bundled waveform GIF frame count changed")
        let frameDuration = (bitmap.value(forProperty: .currentFrameDuration) as? NSNumber)?.doubleValue ?? 0
        try require(abs(frameDuration - 0.04) < 0.001, "waveform GIF must play at 25fps")
        try require(bitmap.hasAlpha, "waveform GIF lost transparency")
        try require(frames(bitmap, over: 0.4).count > 1, "GIF frames did not advance")
        let layouts = host.layouts
        let starts = symbol.animationStarts
        let measured = measurements.value
        advance(1.5)
        try require(symbol.isAnimating && symbol.animationStarts == starts, "steady animation restarted")
        try require(host.layouts == layouts, "animation frames kept relaying out the SwiftUI host")
        try require(measurements.value == measured, "animation frames kept measuring the SwiftUI layout")
        print("PASS transparent 48-frame GIF advances at 25fps without hosting layout, size measurement or restarts")
        for _ in 0..<120 { symbol.configure(active: true, tint: .blue) }
        try require(symbol.animationStarts == starts, "progress updates restarted the symbol effect")
        symbol.configure(active: false, tint: .blue)
        try require(!symbol.isAnimating && !symbol.animates, "pause retained GIF animation")
        try require(frames(bitmap, over: 0.25).count == 1, "paused GIF kept advancing frames")
        let peer = NowPlayingSymbolView()
        peer.frame.origin = NSPoint(x: 80, y: 20)
        host.addSubview(peer)
        peer.configure(active: true, tint: .white)
        let peerBitmap = try representation(peer)
        try require(peer.image !== symbol.image, "indicators shared mutable animation image")
        try require(frames(peerBitmap, over: 0.3).count > 1, "playing peer GIF did not advance")
        try require(frames(bitmap, over: 0.25).count == 1, "playing peer advanced the paused GIF")
        peer.removeFromSuperview()
        symbol.configure(active: true, tint: .blue)
        symbol.isHidden = true
        try require(!symbol.isAnimating, "hidden symbol kept animating")
        symbol.isHidden = false
        try require(symbol.isAnimating, "visible playing symbol failed to resume")
        print(
            "PASS independent GIF frames, repeated configuration, pause, hide and unhide preserve animation lifecycle")
        host.rootView = AnyView(NowPlayingIndicator(isPlaying: false))
        advance(0.1)
        try require(Self.symbol(in: host)?.isAnimating == false, "paused SwiftUI indicator retained animation")
        host.rootView = AnyView(NowPlayingIndicator(isPlaying: true).environment(\.workspaceIsActive, false))
        advance(0.1)
        try require(Self.symbol(in: host)?.isAnimating == false, "covered workspace retained symbol animation")
        print("PASS SwiftUI pause and suspended workspace stop native animation")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 160, height: 60))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 500))
        let clipped = NowPlayingSymbolView()
        clipped.frame.origin = .zero
        document.addSubview(clipped)
        scroll.documentView = document
        window.contentView = scroll
        clipped.configure(active: true, tint: .blue)
        advance(0.1)
        // The document is unflipped; move the clip to expose the first symbol explicitly.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        advance(0.05)
        try require(clipped.isAnimating, "visible scroll-cell symbol did not animate")
        window.orderOut(nil)
        advance(0.05)
        try require(!clipped.isAnimating, "hidden window retained the symbol animation")
        window.orderBack(nil)
        advance(0.05)
        try require(clipped.isAnimating, "reopening the window failed to resume the visible symbol")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        advance(0.05)
        try require(!clipped.isAnimating, "offscreen scroll-cell symbol kept animating")
        clipped.removeFromSuperview()
        try require(!clipped.isAnimating, "removed symbol retained animation")
        print("PASS scrolling the cover out of view and recycling its view stop animation")
        print("Playing indicator regression harness: 4/4 passed")
        let native = benchmark(AnyView(NowPlayingIndicator(isPlaying: true)), in: window)
        print(
            String(
                format: "2-second isolated GIF waveform: %.2f%% CPU (%d layouts, %d measurements)", native.0, native.1,
                native.2))
    }
}
