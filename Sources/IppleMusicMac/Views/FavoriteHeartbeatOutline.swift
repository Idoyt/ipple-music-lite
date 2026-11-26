import AppKit
import QuartzCore
import SwiftUI

struct FavoriteSymbolState: Equatable {
    var trackID: String?
    var isFavorite: Bool
    var isAdding: Bool
    var isUpdating: Bool
    var isActive: Bool
    var reduceMotion: Bool
    var usesWhiteOutline = false
}

struct FavoriteAnimatedSymbol: NSViewRepresentable {
    var pointSize: CGFloat
    var state: FavoriteSymbolState

    func makeNSView(context: Context) -> FavoriteHeartbeatSurface { FavoriteHeartbeatSurface() }
    func updateNSView(_ view: FavoriteHeartbeatSurface, context: Context) {
        view.configure(pointSize: pointSize, state: state)
    }
    static func dismantleNSView(_ view: FavoriteHeartbeatSurface, coordinator: ()) { view.stop() }
}

/// SF Symbols supply both silhouettes. Core Animation owns the motion, with no per-frame
/// timers or SwiftUI state updates. Finished animations leave only static layers.
final class FavoriteHeartbeatSurface: NSView {
    private static let red = NSColor(srgbRed: 0.96, green: 0.19, blue: 0.18, alpha: 1)
    private let base = CALayer()
    private let fill = CALayer()
    private let fillColor = CALayer()
    private let crack = CAShapeLayer()
    private let outline = CALayer()
    private let wave = CAGradientLayer()
    private let ripples = [CALayer()]
    private let shards = [CALayer(), CALayer()]
    private let shardColors = [CALayer(), CALayer()]
    private let fragments = (0..<4).map { _ in CALayer() }
    private let sparks = (0..<10).map { _ in CALayer() }
    private var pointSize: CGFloat = 0
    private var state: FavoriteSymbolState?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = false
        for ripple in ripples { layer?.addSublayer(ripple); ripple.opacity = 0 }
        layer?.addSublayer(base)
        layer?.addSublayer(fill)
        fill.addSublayer(fillColor)
        fillColor.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(crack)
        crack.fillColor = nil
        crack.strokeColor = NSColor.white.withAlphaComponent(0.92).cgColor
        crack.lineCap = .round
        crack.lineJoin = .round
        crack.opacity = 0
        crack.strokeEnd = 0
        layer?.addSublayer(outline)
        outline.addSublayer(wave)
        for (index, shard) in shards.enumerated() {
            layer?.addSublayer(shard)
            shard.addSublayer(shardColors[index])
            shardColors[index].opacity = 0
            shard.opacity = 0
        }
        for spark in sparks { layer?.addSublayer(spark); spark.opacity = 0 }
        for fragment in fragments { layer?.addSublayer(fragment); fragment.opacity = 0 }
        wave.type = .conic
        wave.startPoint = CGPoint(x: 0.5, y: 0.5)
        wave.endPoint = CGPoint(x: 0.5, y: 0)
        wave.colors = [0, 0, 0.12, 0.6, 1, 0].map { Self.red.withAlphaComponent($0).cgColor }
        wave.locations = [0, 0.66, 0.75, 0.87, 0.95, 1]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(pointSize: CGFloat, state next: FavoriteSymbolState) {
        let previous = state
        let changedSymbol = self.pointSize != pointSize
        guard changedSymbol || previous != next else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if changedSymbol {
            self.pointSize = pointSize
            let heart = symbol("heart", size: pointSize)
            let solid = symbol("heart.fill", size: pointSize)
            for target in [base, outline] + ripples { target.mask = mask(heart) }
            fill.mask = mask(solid)
            crack.mask = mask(solid)
            crack.lineWidth = max(0.9, pointSize * 0.035)
            for color in shardColors { color.mask = mask(solid) }
            let fragmentShape = symbol("diamond.fill", size: max(3, pointSize * 0.14))
            for fragment in fragments {
                fragment.mask = mask(fragmentShape)
                fragment.backgroundColor = Self.red.cgColor
            }
            fillColor.backgroundColor = Self.red.cgColor
            for target in ripples + shardColors { target.backgroundColor = Self.red.cgColor }
            for (index, spark) in sparks.enumerated() {
                spark.backgroundColor = (index.isMultiple(of: 3)
                    ? NSColor(srgbRed: 1, green: 0.65, blue: 0.15, alpha: 1) : Self.red).cgColor
            }
            needsLayout = true
        }
        state = next
        let sameTrack = previous?.trackID == next.trackID && next.trackID != nil
        let animate = sameTrack && next.isActive && !next.reduceMotion && window != nil
        let added = animate && previous?.isAdding == true && !next.isAdding && next.isFavorite
        let removed = animate && previous?.isFavorite == true && !next.isFavorite
            && (previous?.isUpdating == true || next.isUpdating)
        if !sameTrack || !next.isActive || next.reduceMotion { stop() }
        if !next.isAdding { stopHeartbeat() }
        if !next.isUpdating || next.isAdding || !next.isFavorite { stopRemovalProgress() }
        let outlineColor: NSColor = next.usesWhiteOutline ? .white : .secondaryLabelColor
        base.backgroundColor = (next.isFavorite || next.isAdding ? Self.red : outlineColor).cgColor
        base.opacity = next.isAdding && !next.reduceMotion ? 0.35 : 1
        fill.opacity = next.isFavorite && !next.isAdding ? 1 : 0
        outline.opacity = next.isAdding && !next.reduceMotion ? 1 : 0
        CATransaction.commit()
        if added { celebrate() }
        else if removed { breakHeart() }
        else if next.isUpdating && previous?.isUpdating != true { stopResultAnimations() }
        startHeartbeatIfVisible()
        startRemovalProgressIfVisible()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for target in [base, fill, outline] + ripples + shards {
            target.bounds = CGRect(origin: .zero, size: bounds.size)
            target.position = CGPoint(x: bounds.midX, y: bounds.midY)
            target.mask?.frame = target.bounds
        }
        fillColor.bounds = CGRect(origin: .zero, size: bounds.size)
        fillColor.position = CGPoint(x: bounds.width / 2, y: 0)
        crack.frame = CGRect(origin: .zero, size: bounds.size)
        crack.mask?.frame = crack.bounds
        let seam = CGMutablePath()
        seam.move(to: CGPoint(x: bounds.width * 0.50, y: bounds.height))
        for (x, y) in [(0.43, 0.70), (0.56, 0.49), (0.44, 0.27), (0.5, 0)] {
            seam.addLine(to: CGPoint(x: bounds.width * x, y: bounds.height * y))
        }
        crack.path = seam
        let side = max(bounds.width, bounds.height) * 1.5
        wave.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        wave.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        for (index, color) in shardColors.enumerated() {
            color.frame = CGRect(origin: .zero, size: bounds.size)
            color.mask?.frame = color.bounds
            let cut = CAShapeLayer()
            cut.frame = shards[index].bounds
            cut.path = fracture(left: index == 0)
            shards[index].mask = cut
        }
        for spark in sparks {
            let diameter = max(1.5, pointSize * 0.09)
            spark.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            spark.cornerRadius = diameter / 2
            spark.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        for (index, fragment) in fragments.enumerated() {
            let size = max(2, pointSize * (index.isMultiple(of: 2) ? 0.12 : 0.09))
            fragment.bounds = CGRect(x: 0, y: 0, width: size, height: size * 1.3)
            fragment.mask?.frame = fragment.bounds
            fragment.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
        else { startHeartbeatIfVisible(); startRemovalProgressIfVisible() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let state, !state.isFavorite, !state.isAdding else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            base.backgroundColor = (state.usesWhiteOutline ? NSColor.white : NSColor.secondaryLabelColor).cgColor
        }
    }

    func stop() { stopHeartbeat(); stopResultAnimations() }
    private func stopHeartbeat() {
        wave.removeAllAnimations()
        for ripple in ripples { ripple.removeAllAnimations() }
    }
    private func stopResultAnimations() {
        stopRemovalProgress()
        base.removeAllAnimations()
        fillColor.removeAllAnimations()
        for target in shards + shardColors + sparks + fragments { target.removeAllAnimations() }
    }

    private func stopRemovalProgress() {
        crack.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        crack.opacity = 0
        crack.strokeEnd = 0
        CATransaction.commit()
    }

    private func startRemovalProgressIfVisible() {
        guard let state, state.isUpdating, !state.isAdding, state.isFavorite,
              state.isActive, !state.reduceMotion, window != nil, crack.strokeEnd == 0 else { return }
        // This is request activity, not a fabricated network percentage. Hold short of
        // completion until QQ confirms removal; a failed request clears the seam.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        crack.opacity = 1
        crack.strokeEnd = 0.88
        CATransaction.commit()
        crack.add(keyframes("strokeEnd", values: [0, 0.25, 0.68, 0.88],
            times: [0, 0.25, 0.7, 1], duration: 0.85), forKey: "removal-progress")
    }

    private func startHeartbeatIfVisible() {
        guard let state, state.isAdding, state.isActive, !state.reduceMotion,
              window != nil, wave.animation(forKey: "heartbeat") == nil else { return }
        // One outward pulse every 1.05 seconds. The contour light takes two heartbeats
        // to complete a lap, with a gentle acceleration and recovery on each beat.
        let heartbeatDuration = 1.05
        let lapDuration = heartbeatDuration * 2
        let travel = keyframes("transform.rotation.z",
            values: [0, 0.03, 0.44, 0.50, 0.53, 0.94, 1].map { $0 * .pi * 2 },
            times: [0, 0.10, 0.34, 0.50, 0.60, 0.84, 1], duration: lapDuration)
        let strength = keyframes("opacity", values: [0.45, 1, 0.45, 0.45, 1, 0.45, 0.45],
            times: [0, 0.10, 0.34, 0.50, 0.60, 0.84, 1], duration: lapDuration)
        let beat = group([travel, strength], duration: lapDuration)
        beat.repeatCount = .infinity
        let now = CACurrentMediaTime()
        beat.beginTime = now
        wave.add(beat, forKey: "heartbeat")
        for ripple in ripples {
            let expand = keyframes("transform.scale", values: [1, 1.04, 1.32, 1.38],
                times: [0, 0.18, 0.78, 1], duration: heartbeatDuration)
            let fade = keyframes("opacity", values: [0, 0.36, 0, 0],
                times: [0, 0.18, 0.78, 1], duration: heartbeatDuration)
            let echo = group([expand, fade], duration: heartbeatDuration)
            echo.beginTime = now
            echo.repeatCount = .infinity
            ripple.add(echo, forKey: "heartbeat-ripple")
        }
    }

    private func celebrate() {
        stopResultAnimations()
        layoutSubtreeIfNeeded()
        // AppKit layer coordinates rise from the bottom. The SF Symbol clips this color layer.
        fillColor.add(keyframes("transform.scale.y", values: [0, 0.1, 1],
            times: [0, 0.16, 1], duration: 0.28), forKey: "favorite-fill")
        let now = CACurrentMediaTime()
        for (index, spark) in sparks.enumerated() {
            let angle = Double(index) / Double(sparks.count) * .pi * 2
            let distance = max(14, pointSize * 0.85) * (index.isMultiple(of: 2) ? 1 : 0.8)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let start = CGPoint(x: center.x + cos(angle) * bounds.width * 0.32,
                                y: center.y + sin(angle) * bounds.height * 0.32)
            let end = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            let flight = CABasicAnimation(keyPath: "position")
            flight.fromValue = NSValue(point: start)
            flight.toValue = NSValue(point: end)
            flight.duration = 0.42
            flight.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = keyframes("opacity", values: [0, 1, 0.75, 0], times: [0, 0.12, 0.35, 1], duration: 0.42)
            let size = keyframes("transform.scale", values: [0.5, 1, 0.2], times: [0, 0.2, 1], duration: 0.42)
            let burst = group([flight, fade, size], duration: 0.42)
            burst.beginTime = now + 0.16 + Double(index % 3) * 0.015
            spark.add(burst, forKey: "favorite-spark")
        }
    }

    private func breakHeart() {
        stopResultAnimations()
        layoutSubtreeIfNeeded()
        let duration = 0.96
        let settledAt = 0.28
        let revealAt = (settledAt + 0.20) / duration
        let times: [NSNumber] = [0, NSNumber(value: 0.18 / duration),
            NSNumber(value: settledAt / duration), NSNumber(value: revealAt), 0.91, 1]
        crack.add(keyframes("strokeEnd", values: [0.88, 1], times: [0, 1], duration: 0.14),
                  forKey: "complete-crack")
        crack.add(keyframes("opacity", values: [1, 0], times: [0, 1], duration: 0.18),
                  forKey: "separate-crack")
        // This intact SF heart sits behind the fragments; it rises independently of them.
        let appear = keyframes("opacity", values: [0, 0, 1, 1],
            times: [0, NSNumber(value: revealAt), 0.82, 1], duration: duration)
        let emerge = keyframes("transform.scale", values: [0.62, 0.62, 1.06, 1],
            times: [0, NSNumber(value: revealAt), 0.86, 1], duration: duration)
        let rise = keyframes("transform.translation.y", values: [-max(2, pointSize * 0.12),
            -max(2, pointSize * 0.12), 0, 0], times: [0, NSNumber(value: revealAt), 0.86, 1], duration: duration)
        base.add(group([appear, emerge, rise], duration: duration), forKey: "new-outline-heart")
        for (index, shard) in shards.enumerated() {
            let direction = index == 0 ? -1.0 : 1.0
            let x = direction * max(5, pointSize * 0.3)
            let y = -max(3, pointSize * 0.16)
            let moveX = keyframes("transform.translation.x", values: [0, x * 1.16, x, x, x * 1.45, x * 1.45],
                times: times, duration: duration)
            let moveY = keyframes("transform.translation.y", values: [0, y * 1.1, y, y, y * 2, y * 2],
                times: times, duration: duration)
            let tilt = keyframes("transform.rotation.z", values: [0, direction * -0.28, direction * -0.24,
                direction * -0.24, direction * -0.4, direction * -0.4],
                times: times, duration: duration)
            let fade = keyframes("opacity", values: [1, 1, 0, 0],
                times: [0, NSNumber(value: revealAt), 0.91, 1], duration: duration)
            shard.add(group([moveX, moveY, tilt, fade], duration: duration), forKey: "broken-heart")
            shardColors[index].add(keyframes("opacity", values: [1, 1],
                times: [0, 1], duration: duration), forKey: "solid-shard")
        }
        // A few finite particles settle below the split heart, then disappear as the new heart emerges.
        for (index, fragment) in fragments.enumerated() {
            let x = (Double(index) - 1.5) * max(2.2, pointSize * 0.13)
            let drop = -bounds.height * (index.isMultiple(of: 2) ? 0.82 : 0.72)
            let moveX = keyframes("transform.translation.x", values: [x * 0.2, x, x],
                times: [0, 0.30, 1], duration: duration)
            let moveY = keyframes("transform.translation.y",
                values: [-bounds.height * 0.25, drop, drop + max(1, pointSize * 0.05), drop, drop],
                times: [0, 0.29, 0.37, 0.46, 1], duration: duration)
            let tilt = keyframes("transform.rotation.z", values: [0, (Double(index) - 1.5) * 0.7],
                times: [0, 1], duration: duration)
            let fade = keyframes("opacity", values: [0, 0.8, 0.8, 0, 0],
                times: [0, 0.12, 0.62, 0.90, 1], duration: duration)
            fragment.add(group([moveX, moveY, tilt, fade], duration: duration), forKey: "heart-fragment")
        }
    }

    private func fracture(left: Bool) -> CGPath {
        let path = CGMutablePath()
        let edge: CGFloat = left ? 0 : bounds.width
        path.move(to: CGPoint(x: edge, y: bounds.height))
        for (x, y) in [(0.50, 1.0), (0.43, 0.70), (0.56, 0.49), (0.44, 0.27), (0.5, 0)] {
            path.addLine(to: CGPoint(x: bounds.width * x, y: bounds.height * y))
        }
        path.addLine(to: CGPoint(x: edge, y: 0))
        path.closeSubpath()
        return path
    }

    private func symbol(_ name: String, size: CGFloat) -> CGImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    private func mask(_ image: CGImage?) -> CALayer {
        let mask = CALayer()
        mask.contents = image
        mask.contentsGravity = .resizeAspect
        return mask
    }
    private func keyframes(_ key: String, values: [Double], times: [NSNumber], duration: Double) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.keyTimes = times
        animation.duration = duration
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: values.count - 1)
        return animation
    }
    private func group(_ animations: [CAAnimation], duration: Double) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        return group
    }
}
