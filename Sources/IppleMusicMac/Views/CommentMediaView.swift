import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct CommentMediaPayload: Sendable {
    let data: Data
    let typeIdentifier: String
    let poster: CGImage
    let animation: CommentGIFTiming?

    static func decode(_ data: Data, emoji: Bool) -> Self? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              let poster = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: emoji ? 40 : 700,
              ] as CFDictionary) else { return nil }
        var timing: CommentGIFTiming?
        let count = CGImageSourceGetCount(source)
        if !emoji, type == UTType.gif.identifier, count > 1, count <= 2_000 {
            let durations = (0..<count).map { index -> Double in
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                    ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
                return delay.isFinite && delay >= 0.02 ? delay : 0.1
            }
            let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            // GIF's loop extension stores repeats after the first play; zero means infinite.
            let loops = (gif?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue
            timing = CommentGIFTiming(durations: durations, repetitions: loops.map { $0 == 0 ? nil : max(1, $0 + 1) } ?? 1)
        }
        return Self(data: data, typeIdentifier: type, poster: poster, animation: timing)
    }
}

struct CommentGIFTiming: Sendable {
    let ends: [Double]
    let duration: Double
    let repetitions: Int?

    init(durations: [Double], repetitions: Int?) {
        var total = 0.0
        ends = durations.map { total += $0; return total }
        duration = total
        self.repetitions = repetitions
    }

    func frame(at elapsed: Double) -> (index: Int, wait: Double, finished: Bool) {
        if let repetitions, elapsed >= duration * Double(repetitions) {
            return (ends.count - 1, 0, true)
        }
        let position = max(0, elapsed).truncatingRemainder(dividingBy: duration)
        var lower = 0, upper = ends.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if position < ends[middle] { upper = middle } else { lower = middle + 1 }
        }
        return (lower, max(1.0 / 30, ends[lower] - position), false)
    }
}

/// Original encoded bytes and the static poster are shared; animated decoded frames are not retained by rows.
@MainActor final class QQCommentMedia {
    let animationCacheID = UUID()
    let payload: CommentMediaPayload
    let image: NSImage
    var cost: Int { payload.data.count + payload.poster.bytesPerRow * payload.poster.height }

    init(_ payload: CommentMediaPayload, emoji: Bool) {
        self.payload = payload
        image = NSImage(cgImage: payload.poster, size: emoji ? NSSize(width: 20, height: 20)
                        : NSSize(width: payload.poster.width, height: payload.poster.height))
    }

    @discardableResult func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        item.setData(payload.data, forType: NSPasteboard.PasteboardType(payload.typeIdentifier))
        if payload.typeIdentifier != UTType.png.identifier,
            let png = NSBitmapImageRep(cgImage: payload.poster).representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

/// Immutable decoded cycle. Core Animation advances frames without waking SwiftUI or a frame timer.
final class CommentGIFFrames: Sendable {
    let images: [CGImage]
    let keyTimes: [Double]
    let cost: Int

    init(images: [CGImage], keyTimes: [Double]) {
        self.images = images
        self.keyTimes = keyTimes
        cost = images.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    }

    func animation(timing: CommentGIFTiming) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = images + [images.last!]
        animation.keyTimes = (keyTimes + [1]).map { NSNumber(value: $0) }
        animation.calculationMode = .discrete
        animation.duration = timing.duration
        animation.repeatCount = timing.repetitions.map(Float.init) ?? .infinity
        animation.isRemovedOnCompletion = true
        return animation
    }
}

/// Serial, off-main decoding and a bounded LRU shared by visible/recycled rows.
/// Retaining a cycle avoids repeatedly decompressing every GIF frame on every loop.
actor CommentGIFDecoder {
    static let shared = CommentGIFDecoder()
    static let cycleByteLimit = 16 * 1_024 * 1_024
    static let cacheByteLimit = 32 * 1_024 * 1_024
    private var cached: [UUID: CommentGIFFrames] = [:]
    private var order: [UUID] = []
    private(set) var cachedBytes = 0

    func frames(id: UUID, payload: CommentMediaPayload) -> CommentGIFFrames? {
        guard !Task.isCancelled else { return nil }
        if let frames = cached[id] {
            order.removeAll { $0 == id }
            order.append(id)
            return frames
        }
        guard let timing = payload.animation, timing.duration > 0,
              let source = CGImageSourceCreateWithData(payload.data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        // Preserve source timing, limiting extreme assets to 30 fps / 300 displayed frames.
        let interval = max(1.0 / 30, timing.duration / 300)
        var indices = [0]
        var times = [0.0]
        var lastStart = 0.0
        for index in 1..<timing.ends.count {
            let start = timing.ends[index - 1]
            if start - lastStart >= interval || index == timing.ends.count - 1 {
                indices.append(index)
                times.append(start / timing.duration)
                lastStart = start
            }
        }
        let aspect = Double(min(payload.poster.width, payload.poster.height))
            / Double(max(payload.poster.width, payload.poster.height))
        // Leave room for row alignment in the actual decoded bitmap allocation.
        let pixelLimit = min(480, max(1, Int(sqrt(Double(Self.cycleByteLimit)
            / (Double(indices.count) * 4 * aspect)) * 0.94)))
        var images: [CGImage] = []
        var bytes = 0
        for index in indices {
            guard !Task.isCancelled else { return nil }
            let image = autoreleasepool {
                CGImageSourceCreateThumbnailAtIndex(source, index, [
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelLimit,
                ] as CFDictionary)
            }
            guard let image else { return nil }
            bytes += image.bytesPerRow * image.height
            guard bytes <= Self.cycleByteLimit else { return nil }
            images.append(image)
        }
        guard !Task.isCancelled else { return nil }
        let result = CommentGIFFrames(images: images, keyTimes: times)
        while cachedBytes + result.cost > Self.cacheByteLimit, let oldest = order.first {
            order.removeFirst()
            cachedBytes -= cached.removeValue(forKey: oldest)?.cost ?? 0
        }
        cached[id] = result
        order.append(id)
        cachedBytes += result.cost
        return result
    }
}

struct CommentMediaView: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let media: QQCommentMedia

    func makeNSView(context: Context) -> CommentMediaSurface { CommentMediaSurface() }
    func updateNSView(_ view: CommentMediaSurface, context: Context) {
        view.configure(media, animate: !reduceMotion)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommentMediaSurface, context: Context) -> CGSize? {
        let size = media.image.size
        let scale = min(1, min(proposal.width ?? 350, 350) / max(1, size.width),
                        min(proposal.height ?? 220, 220) / max(1, size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    static func dismantleNSView(_ view: CommentMediaSurface, coordinator: ()) { view.stop() }
}

private final class CommentMediaObservers: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    var observations: [NSKeyValueObservation] = []
    func reset() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }
    deinit { reset() }
}

final class CommentMediaSurface: NSView {
    private var media: QQCommentMedia?
    private var motionAllowed = false
    private var animationTask: Task<Void, Never>?
    private var animationID = UUID()
    private let observers = CommentMediaObservers()
    private(set) var isAnimating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    func configure(_ media: QQCommentMedia, animate: Bool) {
        if self.media !== media {
            stop()
            self.media = media
            setFrameImage(media.payload.poster)
            setAccessibilityLabel(media.payload.animation == nil ? "评论图片" : "GIF 评论图片")
        }
        motionAllowed = animate
        updateAnimation()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "复制图片", action: #selector(copyImage(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        return menu
    }
    @objc func copyImage(_ sender: Any?) { media?.copy() }
    @objc func copy(_ sender: Any?) { copyImage(sender) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            copyImage(nil)
        } else { super.keyDown(with: event) }
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeVisibility() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeVisibility() }
    override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }
    override func layout() { super.layout(); updateAnimation() }

    private func observeVisibility() {
        observers.reset()
        if let window {
            observers.observations.append(window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateAnimation() }
            })
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification] { observe(name, object: window) }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observe(name, object: NSApplication.shared)
            }
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observe(NSView.boundsDidChangeNotification, object: clip)
        }
        updateAnimation()
    }
    private func observe(_ name: Notification.Name, object: AnyObject) {
        observers.tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAnimation() }
        })
    }
    private func updateAnimation() {
        let visible = motionAllowed && window?.isVisible == true && window?.isMiniaturized != true
            && window?.occlusionState.contains(.visible) == true
            && !NSApplication.shared.isHidden && !isHiddenOrHasHiddenAncestor && visibleRect.intersects(bounds)
        guard visible, let media, let timing = media.payload.animation else { stop(); return }
        guard animationTask == nil else { return }
        isAnimating = true
        let id = UUID()
        animationID = id
        animationTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let frames = await CommentGIFDecoder.shared.frames(id: media.animationCacheID, payload: media.payload),
                  !Task.isCancelled, let self, self.animationID == id else { return }
            // A finite GIF reveals its final frame when its animation completes.
            self.setFrameImage(timing.repetitions == nil ? frames.images[0] : frames.images.last!)
            self.layer?.add(frames.animation(timing: timing), forKey: "commentGIF")
            // Keep the completed preparation task as a visibility token. No repeating app-side work.
        }
    }
    private func setFrameImage(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
    func stop() {
        guard animationTask != nil else { return }
        animationID = UUID()
        animationTask?.cancel()
        animationTask = nil
        isAnimating = false
        layer?.removeAnimation(forKey: "commentGIF")
        if let media { setFrameImage(media.payload.poster) }
    }
}
