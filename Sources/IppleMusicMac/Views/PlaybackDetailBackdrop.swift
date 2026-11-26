import AppKit
import Observation
import QuartzCore
import SwiftUI

@MainActor @Observable
final class PlaybackBackdropMotion {
    var isExpanded = false
}

struct PlaybackDetailBackdrop: View {
    var artwork: PlaybackArtworkSnapshot?
    var viewport: CGRect
    var cover: CGRect
    var motion: PlaybackBackdropMotion
    var onAnimationEnd: (Bool) -> Void

    var body: some View {
        PlaybackBackdropSurface(
            artwork: artwork, viewport: viewport, cover: cover, isExpanded: motion.isExpanded,
            onAnimationEnd: onAnimationEnd)
    }
}

private struct PlaybackBackdropSurface: NSViewRepresentable {
    var artwork: PlaybackArtworkSnapshot?
    var viewport: CGRect
    var cover: CGRect
    var isExpanded: Bool
    var onAnimationEnd: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> NativePlaybackBackdrop { NativePlaybackBackdrop() }

    func updateNSView(_ view: NativePlaybackBackdrop, context: Context) {
        view.update(
            artwork: artwork, viewport: viewport, cover: cover, expanded: isExpanded, reduceMotion: reduceMotion,
            onAnimationEnd: onAnimationEnd)
    }
}

final class NativePlaybackBackdrop: NSView {
    private let panel = CALayer()
    private let artworkStack = CALayer()
    private let sharpArtwork = CALayer()
    private let shading = CAGradientLayer()
    private var displayed: CALayer?
    private var outgoing: CALayer?
    private var artworkID: String?
    private var expanded: Bool?
    private var motionID = UUID()
    private var wipeID = UUID()
    private var viewportSize: CGSize = .zero
    private var coverFrame: CGRect = .zero
    private var blocksInput = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.addSublayer(panel)
        panel.masksToBounds = true
        panel.isGeometryFlipped = true
        panel.backgroundColor = NSColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 1).cgColor
        panel.addSublayer(artworkStack)
        panel.addSublayer(sharpArtwork)
        panel.addSublayer(shading)
        sharpArtwork.contentsGravity = .resizeAspectFill
        shading.colors = [
            CGColor(gray: 0, alpha: 0.66), CGColor(gray: 0, alpha: 0.42), CGColor(gray: 0, alpha: 0.47),
        ]
        shading.locations = [0, 0.52, 1]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        blocksInput && frame.contains(point) ? self : nil
    }

    func update(
        artwork: PlaybackArtworkSnapshot?, viewport: CGRect, cover: CGRect, expanded: Bool, reduceMotion: Bool,
        onAnimationEnd: @escaping (Bool) -> Void
    ) {
        guard !viewport.isEmpty else { return }
        let localCover = cover.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
        let hasCover = !reduceMotion && !localCover.isEmpty
        let destination = CGRect(origin: .zero, size: viewport.size)
        let didResize = viewportSize != viewport.size
        let didMoveCover = coverFrame != localCover
        let wasExpanded = self.expanded
        let changesPresentation = wasExpanded != expanded
        let availableArtworkChanged = artwork != nil && artworkID != artwork?.identity
        guard didResize || changesPresentation || availableArtworkChanged || (!expanded && didMoveCover) else { return }
        let current = wasExpanded == nil ? nil : panel.presentation()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        viewportSize = viewport.size
        coverFrame = localCover
        if didResize { resize(destination) }
        if let artwork, availableArtworkChanged {
            updateArtwork(artwork, size: viewport.size, animated: wasExpanded == true && expanded && !reduceMotion)
        }
        guard changesPresentation || didResize || (!expanded && didMoveCover) else { return }

        self.expanded = expanded
        let zoomsFrom = hasCover ? localCover : destination
        let target = expanded ? destination : zoomsFrom
        let start = expanded ? zoomsFrom : destination
        let targetScale = scale(for: target, in: destination)
        let targetCenter = CGPoint(x: target.midX, y: target.midY)
        let initialPosition = current?.position ?? CGPoint(x: start.midX, y: start.midY)
        let initialScale = current?.transform ?? scale(for: start, in: destination)
        let startsAtCover = expanded && hasCover && panel.animation(forKey: "cover-motion") == nil
        let initialOpacity = startsAtCover ? 1 : current?.opacity ?? 0
        let initialSharp =
            (wasExpanded == nil ? nil : sharpArtwork.presentation()?.opacity)
            ?? (expanded && hasCover ? 1 : 0)
        let duration = hasCover ? 0.26 : 0.12

        panel.removeAnimation(forKey: "cover-motion")
        sharpArtwork.removeAnimation(forKey: "soften")
        panel.position = targetCenter
        panel.transform = targetScale
        panel.opacity = expanded ? 1 : 0
        sharpArtwork.opacity = expanded || !hasCover ? 0 : 1
        guard changesPresentation, expanded || wasExpanded != nil else { return }

        let request = UUID()
        motionID = request
        blocksInput = expanded
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, motionID == request else { return }
                onAnimationEnd(expanded)
            }
        }
        let motion = CAAnimationGroup()
        motion.duration = duration
        motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        motion.animations = [
            property("position", from: initialPosition, to: targetCenter, duration: duration),
            property(
                "transform", from: NSValue(caTransform3D: initialScale), to: NSValue(caTransform3D: targetScale),
                duration: duration),
            property("opacity", from: initialOpacity, to: panel.opacity, duration: duration),
        ]
        panel.add(motion, forKey: "cover-motion")
        if hasCover {
            sharpArtwork.add(
                property("opacity", from: initialSharp, to: sharpArtwork.opacity, duration: duration), forKey: "soften")
        }
    }

    private func resize(_ frame: CGRect) {
        panel.bounds = frame
        artworkStack.frame = frame
        shading.frame = frame
        sharpArtwork.frame = zoomedFrame(frame.size)
        displayed?.frame = frame
        outgoing?.frame = frame
        for item in [displayed, outgoing] {
            item?.sublayers?.first?.frame = zoomedFrame(frame.size)
        }
    }

    private func zoomedFrame(_ size: CGSize) -> CGRect {
        CGRect(x: -size.width * 0.09, y: -size.height * 0.09, width: size.width * 1.18, height: size.height * 1.18)
    }

    private func scale(for rectangle: CGRect, in viewport: CGRect) -> CATransform3D {
        CATransform3DMakeScale(rectangle.width / viewport.width, rectangle.height / viewport.height, 1)
    }

    private func property(_ key: String, from: Any, to: Any, duration: TimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        return animation
    }

    private func updateArtwork(_ artwork: PlaybackArtworkSnapshot, size: CGSize, animated: Bool) {
        artworkID = artwork.identity
        sharpArtwork.contents = artwork.image?.cgImage
        let cover = CALayer()
        cover.frame = CGRect(origin: .zero, size: size)
        let texture = CALayer()
        texture.contents =
            artwork.blurredImage?.cgImage
            ?? sharpArtwork.contents
        texture.contentsGravity = .resizeAspectFill
        texture.frame = zoomedFrame(size)
        cover.addSublayer(texture)
        artworkStack.insertSublayer(cover, at: 0)

        outgoing?.removeFromSuperlayer()
        outgoing = nil
        let previous = displayed
        displayed = cover
        guard let previous, animated else {
            previous?.removeFromSuperlayer()
            return
        }
        outgoing = previous
        let request = UUID()
        wipeID = request

        // Slide the feathered boundary across the outgoing texture, without rebuilding the view.
        let mask = CAGradientLayer()
        let feather: CGFloat = 0.18
        let backward = artwork.direction == .backward
        mask.startPoint = CGPoint(x: backward ? 1 : 0, y: 0.5)
        mask.endPoint = CGPoint(x: backward ? 0 : 1, y: 0.5)
        mask.colors = [CGColor.black, CGColor.black, CGColor.clear]
        mask.locations = [0, NSNumber(value: 1 / (1 + feather)), 1]
        let width = size.width * (1 + feather)
        let start = backward ? -size.width * feather : 0
        let end = backward ? size.width : -width
        mask.anchorPoint = .zero
        mask.bounds = CGRect(x: 0, y: 0, width: width, height: size.height)
        mask.position = CGPoint(x: end, y: 0)
        previous.mask = mask

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, wipeID == request else { return }
                self.outgoing?.removeFromSuperlayer()
                self.outgoing = nil
            }
        }
        let animation = property("position.x", from: start, to: end, duration: 0.5)
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mask.add(animation, forKey: "wipe")
        CATransaction.commit()
    }
}
