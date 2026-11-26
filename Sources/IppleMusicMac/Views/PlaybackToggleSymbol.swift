import AppKit
import QuartzCore
import SwiftUI

struct PlaybackToggleSymbol: NSViewRepresentable {
    var isPlaying: Bool
    var pointSize: CGFloat
    var animate: Bool
    var isActive = true

    func makeNSView(context: Context) -> PlaybackToggleSurface { PlaybackToggleSurface() }
    func updateNSView(_ view: PlaybackToggleSurface, context: Context) {
        view.update(isPlaying: isPlaying, pointSize: pointSize, animate: animate, isActive: isActive)
    }
    static func dismantleNSView(_ view: PlaybackToggleSurface, coordinator: ()) { view.stop() }
}

/// One persistent layer renders both the morph and its resting SF Symbol contour.
/// There is no opacity crossfade or renderer handoff at either endpoint.
final class PlaybackToggleSurface: NSView {
    private let symbolLayer = CAShapeLayer()
    private var symbols: [Bool: NSImage] = [:]
    private var inkBounds: [Bool: [CGRect]] = [:]
    private var contours: [Bool: [[CGPoint]]] = [:]
    private var pointSize: CGFloat = 0
    private var showingPause: Bool?
    private var laidOutSize = CGSize.zero
    private var motionEnabled = false
    private var active = true
    private var morphDeadline: CFTimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Both halves belong to one nonzero-filled path, avoiding a translucent seam.
        symbolLayer.fillRule = .nonZero
        layer?.addSublayer(symbolLayer)
        updateTint()
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(isPlaying: Bool, pointSize: CGFloat, animate: Bool, isActive: Bool = true) {
        let previous = showingPause
        let motionChanged = motionEnabled != animate || active != isActive
        motionEnabled = animate
        active = isActive
        let resized = self.pointSize != pointSize
        if resized {
            self.pointSize = pointSize
            for (pause, name) in [(true, "pause.fill"), (false, "play.fill")] {
                let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
                symbols[pause] = symbol
                if let image = symbol.flatMap({ symbolMask($0) }) {
                    inkBounds[pause] = measuredBounds(image, split: pause)
                    contours[pause] = measuredContours(image, pause: pause)
                }
            }
        }
        let changed = previous != isPlaying
        guard changed || resized || motionChanged else { return }
        layoutSubtreeIfNeeded()
        let now = layer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()
        let interrupted = now < morphDeadline
        let visiblePath = symbolLayer.presentation()?.path ?? symbolLayer.path
        showingPause = isPlaying
        let shouldAnimate = animate && isActive && !resized && previous != nil && changed
            && window != nil && !bounds.isEmpty
        stop()
        let target = shape(progress: isPlaying ? 0 : 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.frame = bounds
        symbolLayer.path = target
        CATransaction.commit()
        let duration = shouldAnimate ? 0.20 : 0
        if shouldAnimate, let visiblePath {
            let morph = CAKeyframeAnimation(keyPath: "path")
            let samples = 24
            if !interrupted {
                let from = previous == true ? 0.0 : 1.0
                let to = isPlaying ? 0.0 : 1.0
                morph.values = (0...samples).map { step in
                    shape(progress: from + (to - from) * easedProgress(Double(step) / Double(samples)))
                }
            } else {
                // Reverse from the visible contour without jumping to either endpoint.
                let sourcePoints = vertices(visiblePath), targetPoints = vertices(target)
                morph.values = (0...samples).map { step in
                    interpolatedShape(from: sourcePoints, to: targetPoints,
                                      progress: easedProgress(Double(step) / Double(samples)))
                }
            }
            morph.keyTimes = (0...samples).map { NSNumber(value: Double($0) / Double(samples)) }
            morph.duration = duration
            morph.beginTime = now
            morph.calculationMode = .linear
            symbolLayer.add(morph, forKey: "playback-morph")
            morphDeadline = now + duration
        }
    }

    override func layout() {
        super.layout()
        guard laidOutSize != bounds.size, let showingPause else { return }
        laidOutSize = bounds.size
        stop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.frame = bounds
        symbolLayer.path = shape(progress: showingPause ? 0 : 1)
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
        let scale = window?.backingScaleFactor ?? 2
        symbolLayer.contentsScale = scale
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }
    func stop() {
        morphDeadline = 0
        symbolLayer.removeAllAnimations()
    }

    private func updateTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let color = NSColor.controlAccentColor.cgColor
            symbolLayer.fillColor = color
            CATransaction.commit()
        }
    }
    private func symbolRect(pause: Bool) -> CGRect {
        let size = symbols[pause]?.size ?? CGSize(width: pointSize, height: pointSize)
        let scale = min(1, bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
    private func shape(progress: Double) -> CGPath {
        let path = CGMutablePath()
        for index in 0..<2 { path.addPath(morphShape(progress: progress, index: index)) }
        return path
    }

    private func easedProgress(_ elapsed: Double) -> Double {
        let remaining = 1 - min(1, max(0, elapsed))
        return 1 - remaining * remaining * remaining
    }

    private func vertices(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: points.append(element.pointee.points[0])
            default: break
            }
        }
        return points
    }

    private func interpolatedShape(from: [CGPoint], to: [CGPoint], progress: Double) -> CGPath {
        guard from.count == to.count else { return shape(progress: showingPause == true ? 0 : 1) }
        let path = CGMutablePath()
        for index in from.indices {
            let point = progress <= 0 ? from[index] : progress >= 1 ? to[index] :
                CGPoint(x: from[index].x + (to[index].x - from[index].x) * progress,
                        y: from[index].y + (to[index].y - from[index].y) * progress)
            if index % 192 == 0 { path.move(to: point) } else { path.addLine(to: point) }
            if index % 192 == 191 { path.closeSubpath() }
        }
        return path
    }

    private func morphShape(progress: Double, index: Int) -> CGPath {
        func smooth(_ value: Double) -> CGFloat {
            let t = min(1, max(0, value))
            return CGFloat(t * t * t * (t * (t * 6 - 15) + 10))
        }
        let widen = smooth(progress / 0.58)
        let slope = smooth((progress - 0.22) / 0.78)
        let pause = paintedRect(pause: true, index: index)
        let play = paintedRect(pause: false, index: 0)
        guard let startContour = contours[true]?[index],
              let endContour = contours[false]?[index] else { return CGMutablePath() }
        let pauseFrame = symbolRect(pause: true)
        let playFrame = symbolRect(pause: false)
        let left = index == 0 ? play.minX : play.midX
        let right = index == 0 ? play.midX : play.maxX
        let path = CGMutablePath()
        for vertex in startContour.indices {
            let source = startContour[vertex]
            let target = endContour[vertex]
            let start = CGPoint(x: pauseFrame.minX + source.x * pauseFrame.width,
                                y: pauseFrame.minY + source.y * pauseFrame.height)
            let merged = CGPoint(x: left + (start.x - pause.minX) / max(pause.width, 0.001) * (right - left),
                                 y: start.y)
            let final = CGPoint(x: playFrame.minX + target.x * playFrame.width,
                                y: playFrame.minY + target.y * playFrame.height)
            let point = CGPoint(x: start.x + (merged.x - start.x) * widen + (final.x - merged.x) * slope,
                                y: start.y + (final.y - merged.y) * slope)
            if vertex == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func paintedRect(pause: Bool, index: Int) -> CGRect {
        let frame = symbolRect(pause: pause)
        let rect = inkBounds[pause]?[index] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height,
                      width: rect.width * frame.width, height: rect.height * frame.height)
    }

    // Oversample the original vector-backed SF Symbol only when its point size changes.
    // Its contour is used at rest as well as at both morph endpoints.
    private func symbolMask(_ symbol: NSImage) -> CGImage? {
        let scale: CGFloat = 8
        let width = Int(ceil(symbol.size.width * scale))
        let height = Int(ceil(symbol.size.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(width) / symbol.size.width, y: CGFloat(height) / symbol.size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(in: CGRect(origin: .zero, size: symbol.size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private func measuredContours(_ image: CGImage, pause: Bool) -> [[CGPoint]] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func alpha(_ point: CGPoint) -> CGFloat {
            let x = point.x * CGFloat(width) - 0.5, y = (1 - point.y) * CGFloat(height) - 0.5
            let ix = Int(floor(x)), iy = Int(floor(y))
            let fx = x - CGFloat(ix), fy = y - CGFloat(iy)
            func value(_ x: Int, _ y: Int) -> CGFloat {
                guard x >= 0, x < width, y >= 0, y < height else { return 0 }
                return CGFloat(pixels[(y * width + x) * 4 + 3]) / 255
            }
            return (value(ix, iy) * (1 - fx) + value(ix + 1, iy) * fx) * (1 - fy)
                + (value(ix, iy + 1) * (1 - fx) + value(ix + 1, iy + 1) * fx) * fy
        }
        let rectangles = inkBounds[pause] ?? []
        return (0..<2).map { half in
            let ink = rectangles[pause ? half : 0]
            var clip = CGRect(x: 0, y: 0, width: 1, height: 1)
            let center: CGPoint
            if pause {
                clip = CGRect(x: half == 0 ? 0 : 0.5, y: 0, width: 0.5, height: 1)
                center = CGPoint(x: ink.midX, y: ink.midY)
            } else {
                // A tiny overlap prevents an antialiased internal seam; it never changes
                // the external silhouette, which always comes from the original mask.
                let overlap = 0.25 / CGFloat(width)
                clip = CGRect(x: half == 0 ? 0 : ink.midX - overlap, y: 0,
                              width: half == 0 ? ink.midX + overlap : 1 - ink.midX + overlap, height: 1)
                center = CGPoint(x: ink.minX + ink.width * (half == 0 ? 0.25 : 0.75), y: ink.midY)
            }
            // Both symbols are convex within each half. Ray sampling preserves a fixed
            // path topology while retaining the system's rounded tips instead of inventing radii.
            return (0..<192).map { vertex in
                let angle = CGFloat(vertex) / 192 * 2 * .pi
                let direction = CGPoint(x: cos(angle), y: sin(angle))
                var lower: CGFloat = 0, upper: CGFloat = 2
                for _ in 0..<20 {
                    let distance = (lower + upper) / 2
                    let point = CGPoint(x: center.x + direction.x * distance,
                                        y: center.y + direction.y * distance)
                    if clip.contains(point), alpha(point) >= 0.5 { lower = distance } else { upper = distance }
                }
                return CGPoint(x: center.x + direction.x * lower, y: center.y + direction.y * lower)
            }
        }
    }

    private func measuredBounds(_ image: CGImage, split: Bool) -> [CGRect] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return (0..<(split ? 2 : 1)).map { section in
            let lower = split && section == 1 ? width / 2 : 0
            let upper = split && section == 0 ? width / 2 : width
            var minX = upper, minY = height, maxX = lower, maxY = 0
            if rendered {
                for y in 0..<height {
                    for x in lower..<upper where pixels[(y * width + x) * 4 + 3] >= 128 {
                        minX = min(minX, x); maxX = max(maxX, x + 1)
                        minY = min(minY, y); maxY = max(maxY, y + 1)
                    }
                }
            }
            guard minX < maxX, minY < maxY else {
                return CGRect(x: Double(lower) / Double(width), y: 0,
                              width: Double(upper - lower) / Double(width), height: 1)
            }
            return CGRect(x: Double(minX) / Double(width), y: Double(height - maxY) / Double(height),
                          width: Double(maxX - minX) / Double(width), height: Double(maxY - minY) / Double(height))
        }
    }
}
