import AppKit
import MusicCore
import SwiftUI

struct RecommendationArtworkItem {
    var track: SourceTrack
    var image: DecodedCoverBitmap?
}

struct RecommendationArtworkSnapshot {
    var current: RecommendationArtworkItem
    var next: RecommendationArtworkItem?
    var movesBackward = false
    var identity: String {
        [
            current.track.id, current.track.coverID ?? "", String(current.image != nil),
            next?.track.id ?? "", next?.track.coverID ?? "", String(next?.image != nil),
        ].joined(separator: ":")
    }
}

/// One progress value drives the background and the current, incoming, and rear cards.
/// All images are prepared before a transition; rendering never performs I/O or decoding.
struct RecommendationArtworkScene: View {
    var snapshot: RecommendationArtworkSnapshot?
    var badge: String
    var symbol: String
    var animates: Bool
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var displayed: RecommendationArtworkSnapshot?
    @State private var previous: RecommendationArtworkSnapshot?
    @State private var pending: RecommendationArtworkSnapshot?
    @State private var progress = 1.0
    @State private var transitionTask: Task<Void, Never>?
    private let duration = 0.44
    private let width = DiscoveryCardMetrics.recommendationWidth
    private let height = DiscoveryCardMetrics.coverSize
    private var movesBackward: Bool { previous != nil && displayed?.movesBackward == true }
    private var replacesRearAfterReverse: Bool {
        movesBackward && previous?.current.track.id != displayed?.next?.track.id
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.1)
            ZStack {
                if let previous {
                    background(previous.current)
                        .modifier(
                            RecommendationMotion(
                                progress: progress, role: .outgoingBackground, backward: movesBackward))
                }
                background(displayed?.current)
                    .modifier(
                        RecommendationMotion(
                            progress: previous == nil ? 1 : progress, role: .incomingBackground, backward: movesBackward
                        ))
            }
            LinearGradient(
                colors: [.black.opacity(0.65), .black.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
            HStack {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: symbol).font(.system(size: 30, weight: .medium))
                    Text(badge).font(.callout.weight(.semibold))
                }.foregroundStyle(.white)
                Spacer()
                ZStack {
                    card(movesBackward ? previous?.next : displayed?.next)
                        .modifier(
                            RecommendationMotion(
                                progress: previous == nil ? 1 : progress, role: .newRearCard, backward: movesBackward))
                    if replacesRearAfterReverse {
                        card(displayed?.next)
                            .modifier(RecommendationMotion(progress: progress, role: .replacementRearCard))
                    }
                    if let previous {
                        card(previous.current)
                            .modifier(
                                RecommendationMotion(
                                    progress: progress, role: .outgoingCard, backward: movesBackward,
                                    replacesRear: replacesRearAfterReverse))
                    }
                    card(displayed?.current)
                        .modifier(
                            RecommendationMotion(
                                progress: previous == nil ? 1 : progress, role: .promotedCard, backward: movesBackward))
                }
                .frame(width: 140, height: 122)
                .shadow(color: .black.opacity(0.24), radius: 10, y: 5)
            }.padding(20)
        }
        .frame(width: width, height: height).clipped()
        .accessibilityHidden(true)
        .onAppear { accept(snapshot) }
        .onChange(of: snapshot?.identity) { _, _ in accept(snapshot) }
        .onChange(of: isActive) { _, active in if !active { settle(snapshot) } }
        .onChange(of: animates) { _, active in if !active { settle(snapshot) } }
        .onChange(of: reduceMotion) { _, reduced in if reduced { settle(snapshot) } }
        .onDisappear {
            transitionTask?.cancel()
            transitionTask = nil
        }
    }

    private func image(_ item: RecommendationArtworkItem?, size: CGFloat) -> some View {
        Group {
            if let image = item?.image {
                Image(decorative: image.cgImage, scale: 1).resizable().scaledToFill()
            } else {
                TrackArtwork(title: item?.track.title ?? "", size: size)
            }
        }.frame(width: size, height: size).clipped()
    }

    private func background(_ item: RecommendationArtworkItem?) -> some View {
        image(item, size: width).frame(width: width, height: height).clipped()
    }

    private func card(_ item: RecommendationArtworkItem?) -> some View {
        Color.clear
            .frame(width: 92, height: 92)
            .modifier(RecommendationCoverGlass())
            .frame(width: 92, height: 92)
            .overlay {
                image(item, size: 92)
                    .opacity(reduceTransparency ? 1 : 0.94)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.20), .clear, .white.opacity(0.04)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.65), .white.opacity(0.08), .white.opacity(0.28)],
                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            }
    }

    private func settle(_ snapshot: RecommendationArtworkSnapshot?) {
        transitionTask?.cancel()
        transitionTask = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayed = snapshot
            previous = nil
            pending = nil
            progress = 1
        }
    }

    private func accept(_ snapshot: RecommendationArtworkSnapshot?) {
        guard let snapshot else { return }
        guard animates, isActive, !reduceMotion, displayed != nil else {
            settle(snapshot)
            return
        }
        // Refreshing only the upcoming song must not rotate the current background.
        if displayed?.current.track.id == snapshot.current.track.id {
            if transitionTask != nil { pending = snapshot } else { settle(snapshot) }
            return
        }
        // Coalesce rapid skips rather than resetting an in-flight rotation to its start.
        if transitionTask != nil {
            pending = snapshot
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            previous = displayed
            displayed = snapshot
            progress = 0
        }
        transitionTask = Task { @MainActor in
            do {
                // Commit the starting geometry before changing its single animation phase.
                try await Task.sleep(for: .milliseconds(16))
                withAnimation(.timingCurve(0.2, 0.48, 0.34, 1, duration: duration)) {
                    progress = 1
                }
                try await Task.sleep(for: .seconds(duration))
                try Task.checkCancellation()
                var cleanup = Transaction(animation: nil)
                cleanup.disablesAnimations = true
                withTransaction(cleanup) { previous = nil }
                transitionTask = nil
                let next = pending
                pending = nil
                if let next { accept(next) }
            } catch {}
        }
    }
}

private struct RecommendationCoverGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.clear, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// Only these small image layers are evaluated during the finite transition.
/// The shared phase also changes card depth midway through promotion.
struct RecommendationMotion: AnimatableModifier {
    enum Role {
        case outgoingBackground, incomingBackground, outgoingCard, promotedCard, newRearCard, replacementRearCard
    }
    nonisolated var progress: Double
    var role: Role
    var backward = false
    var replacesRear = false
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        let pose = pose(p)
        content
            .scaleEffect(pose.scale)
            .rotationEffect(.degrees(pose.angle), anchor: pose.anchor)
            .offset(x: pose.x, y: pose.y)
            .opacity(pose.opacity)
            .zIndex(pose.depth)
    }

    typealias Pose = (
        x: Double, y: Double, angle: Double, scale: Double, opacity: Double, depth: Double, anchor: UnitPoint
    )

    func pose(_ p: Double) -> Pose {
        if role == .replacementRearCard {
            var pose = forwardPose(1, role: .newRearCard)
            pose.opacity = replacementProgress(at: p)
            return pose
        }
        guard backward else { return forwardPose(p, role: role) }
        switch role {
        case .outgoingBackground:
            var pose = forwardPose(1 - p, role: .incomingBackground)
            pose.depth = 1
            return pose
        case .incomingBackground:
            return forwardPose(1 - p, role: .outgoingBackground)
        case .outgoingCard:
            var pose = forwardPose(1 - p, role: .promotedCard)
            if replacesRear { pose.opacity = 1 - replacementProgress(at: p) }
            return pose
        case .promotedCard:
            return forwardPose(1 - p, role: .outgoingCard)
        case .newRearCard, .replacementRearCard:
            return forwardPose(1 - p, role: .newRearCard)
        }
    }

    private func replacementProgress(at p: Double) -> Double {
        min(1, max(0, (p - 0.7) / 0.3))
    }

    private func forwardPose(_ p: Double, role: Role) -> Pose {
        switch role {
        case .outgoingBackground:
            (
                -DiscoveryCardMetrics.recommendationWidth * 0.9 * p, DiscoveryCardMetrics.coverSize * 0.9 * p, -32 * p,
                1, 1 - p * 0.3, 0, .bottomLeading
            )
        case .incomingBackground:
            (
                DiscoveryCardMetrics.recommendationWidth * 0.9 * (1 - p),
                -DiscoveryCardMetrics.coverSize * 0.9 * (1 - p), 32 * (1 - p), 1, 1, 0, .topTrailing
            )
        case .outgoingCard:
            (
                -17 - 91 * p, 5 + 78 * p, -9 - 49 * p, 1 - 0.1 * p,
                1 - max(0, (p - 0.12) / 0.88), p < 0.46 ? 2 : 1, .center
            )
        case .promotedCard:
            (17 - 34 * p, -5 + 10 * p, 9 - 18 * p, 0.94 + 0.06 * p, 1, p < 0.46 ? 1 : 3, .center)
        case .newRearCard, .replacementRearCard:
            (77 - 60 * p, -63 + 58 * p, 30 - 21 * p, 0.82 + 0.12 * p, p, 0, .center)
        }
    }
}
