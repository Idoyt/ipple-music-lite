import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private final class VisibleFixtureWindow: NSWindow {
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
}

@main @MainActor struct Harness {
    static func main() async throws {
        _ = NSApplication.shared
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 3, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, color) in [NSColor.red, .green, .blue].enumerated() {
            let context = CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: [0.05, 0.08, 0.12][index],
            ]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        let bytes = data as Data
        let payload = CommentMediaPayload.decode(bytes, emoji: false)!
        let timing = payload.animation!
        precondition(timing.ends.count == 3 && timing.repetitions == nil)
        precondition(timing.frame(at: 0.06).index == 1 && timing.frame(at: 0.14).index == 2)
        precondition(timing.frame(at: 0.26).index == 0)
        let finite = CommentGIFTiming(durations: [0.05, 0.08, 0.12], repetitions: 1)
        precondition(finite.frame(at: 0.3).finished && finite.frame(at: 0.3).index == 2)
        let decoder = CommentGIFDecoder()
        let cacheID = UUID()
        let frames = await decoder.frames(id: cacheID, payload: payload)!
        let reused = await decoder.frames(id: cacheID, payload: payload)!
        precondition(frames === reused, "a visible/recycled GIF must reuse its decoded cycle")
        precondition(frames.images.count == 3)
        let firstBytes = frames.images.map { Data(($0.dataProvider!.data! as Data).prefix(32)) }
        precondition(Set(firstBytes).count == 3, "GIF decoded the same poster for every frame")
        precondition(frames.images.allSatisfy { max($0.width, $0.height) <= 480 })
        precondition(frames.cost <= CommentGIFDecoder.cycleByteLimit)
        let animation = frames.animation(timing: timing)
        precondition(animation.calculationMode == .discrete && animation.repeatCount == .infinity)
        precondition(animation.keyTimes!.map(\.doubleValue) == [0, 0.2, 0.52, 1])
        precondition(frames.animation(timing: finite).repeatCount == 1)
        // Many distinct images cannot grow the retained decoded cache without a bound.
        for _ in 0..<45 { _ = await decoder.frames(id: UUID(), payload: payload) }
        let cachedBytes = await decoder.cachedBytes
        precondition(cachedBytes <= CommentGIFDecoder.cacheByteLimit)

        let media = QQCommentMedia(payload, emoji: false)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ipple.comment-gif-test.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        precondition(media.copy(to: pasteboard))
        precondition(pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) == bytes)
        precondition(NSImage(data: pasteboard.data(forType: .png)!) != nil)
        let png = pasteboard.data(forType: .png)!
        let staticPayload = CommentMediaPayload.decode(png, emoji: false)!
        precondition(staticPayload.animation == nil)
        precondition(QQCommentMedia(staticPayload, emoji: false).copy(to: pasteboard))
        precondition(pasteboard.data(forType: .png) == png)

        // No visible windows or general pasteboard changes: exercise the native surface in an isolated fixture.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 800))
        scroll.documentView = document
        let surface = CommentMediaSurface(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
        document.addSubview(surface)
        let window = VisibleFixtureWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        surface.configure(media, animate: true)
        precondition(surface.isAnimating)
        for _ in 0..<100 where surface.layer?.animation(forKey: "commentGIF") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(surface.layer?.animation(forKey: "commentGIF") is CAKeyframeAnimation,
                     "visible GIF must be driven by the compositor")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        precondition(!surface.isAnimating, "offscreen GIF kept decoding")
        precondition(surface.layer?.animation(forKey: "commentGIF") == nil)
        scroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        precondition(surface.isAnimating)
        surface.configure(media, animate: false)
        precondition(!surface.isAnimating)
        surface.configure(media, animate: true)
        surface.removeFromSuperview()
        precondition(!surface.isAnimating)
        print("PASS GIF timings/loops/frames, bounded shared cycles and compositor playback, original GIF and PNG copy, visibility and reduced-motion cleanup")
    }
}
