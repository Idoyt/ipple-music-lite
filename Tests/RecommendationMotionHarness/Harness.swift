import AppKit
import SwiftUI

// The fixture supplies only the unrelated empty-artwork fallback.
struct TrackArtwork: View {
    var title: String
    var size: CGFloat
    var body: some View { Color.clear.frame(width: size, height: size) }
}

private struct Failure: Error, CustomStringConvertible { var description: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}

@main @MainActor private enum Harness {
    static func main() throws {
        let outgoing = RecommendationMotion(progress: 0, role: .outgoingBackground)
        let incoming = RecommendationMotion(progress: 0, role: .incomingBackground)
        for step in 1...10 {
            let p = Double(step) / 10
            let old = outgoing.pose(p)
            let new = incoming.pose(p)
            try require(old.x < 0 && old.y > 0 && old.angle < 0, "old background did not rotate toward bottom left")
            if p < 1 {
                try require(new.x > 0 && new.y < 0 && new.angle > 0, "incoming background did not enter from top right")
            }
        }
        let rest = incoming.pose(1)
        try require(
            rest.x == 0 && rest.y == 0 && rest.angle == 0, "incoming background did not settle at its normal bounds")
        print("PASS background rotation exits lower left and enters upper right")

        let front = RecommendationMotion(progress: 0, role: .promotedCard)
        let back = RecommendationMotion(progress: 1, role: .newRearCard)
        let old = RecommendationMotion(progress: 0, role: .outgoingCard)
        let from = front.pose(0)
        let rear = back.pose(1)
        let to = front.pose(1)
        let previous = old.pose(0)
        try require(
            abs(from.x - rear.x) < 0.001 && abs(from.y - rear.y) < 0.001
                && abs(from.angle - rear.angle) < 0.001 && abs(from.scale - rear.scale) < 0.001,
            "the next card jumped instead of starting at the rear card's exact pose")
        try require(
            to.x == previous.x && to.y == previous.y && to.angle == previous.angle && to.scale == previous.scale,
            "promoted card did not occupy the previous front card's exact pose")
        try require(
            front.pose(0).depth < old.pose(0).depth && front.pose(1).depth > old.pose(1).depth,
            "the promoted card did not move from behind to in front")
        let exited = old.pose(1)
        try require(
            exited.x < previous.x && exited.y > previous.y && exited.angle < previous.angle && exited.opacity == 0,
            "the replaced front card did not rotate and disappear toward the lower left")
        print("PASS the real next card promotes from its rear pose to the front without a jump")

        for step in 0...100 {
            let p = Double(step) / 100
            let poses = [outgoing.pose(p), incoming.pose(p), old.pose(p), front.pose(p), back.pose(p)]
            try require(
                poses.allSatisfy {
                    $0.x.isFinite && $0.y.isFinite && $0.angle.isFinite && (0...1).contains($0.opacity)
                },
                "shared animation phase produced invalid geometry")
        }
        try require(
            old.pose(1).opacity == 0 && back.pose(0).opacity == 0,
            "transition retained duplicate old or incoming card layers")
        print("PASS one bounded progress phase controls all background and deck layers")

        let backwardRoles: [(RecommendationMotion.Role, RecommendationMotion)] = [
            (.outgoingBackground, incoming), (.incomingBackground, outgoing),
            (.outgoingCard, front), (.promotedCard, old), (.newRearCard, back),
        ]
        for (role, forward) in backwardRoles {
            let backward = RecommendationMotion(progress: 0, role: role, backward: true)
            for step in 0...20 {
                let phase = Double(step) / 20
                let a = backward.pose(phase)
                let b = forward.pose(1 - phase)
                let samePosition = a.x == b.x && a.y == b.y
                let sameAppearance = a.angle == b.angle && a.scale == b.scale && a.opacity == b.opacity
                try require(
                    samePosition && sameAppearance,
                    "previous-track rotation and fade are not the reverse of next-track motion")
            }
        }
        let departingRear = RecommendationMotion(progress: 0, role: .newRearCard, backward: true)
        try require(
            departingRear.pose(1).x > rear.x && departingRear.pose(1).y < rear.y
                && departingRear.pose(1).opacity == 0,
            "the old rear card did not disappear toward the upper right")
        let replacement = RecommendationMotion(progress: 0, role: .replacementRearCard)
        let demoted = RecommendationMotion(progress: 0, role: .outgoingCard, backward: true, replacesRear: true)
        try require(
            replacement.pose(0).opacity == 0 && replacement.pose(1).opacity == 1
                && demoted.pose(0).opacity == 1 && demoted.pose(1).opacity == 0,
            "a coalesced reverse skip snapped the rear image into place")
        print("PASS previous-track motion reverses both backgrounds and all three cards")
        print("Recommendation motion regression harness: 4/4 passed")
    }
}
