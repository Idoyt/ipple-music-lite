import AppKit
import MusicCore
import SwiftUI

struct PlaybackArtworkSnapshot {
    var identity: String
    var title: String
    var direction: PlaybackArtworkDirection
    var image: DecodedCoverBitmap?
    var blurredImage: DecodedCoverBitmap?
}

@MainActor
final class DecodedPlaybackArtwork {
    let image: DecodedCoverBitmap
    let blurredImage: DecodedCoverBitmap?

    init(image: DecodedCoverBitmap, blurredImage: DecodedCoverBitmap?) {
        self.image = image
        self.blurredImage = blurredImage
    }
}

/// A small decoded image cache shared by the current cover and its queue neighbors.
@MainActor
final class PlaybackArtworkCache {
    private struct Request {
        let id = UUID()
        let task: Task<DecodedPlaybackArtwork?, Never>
    }

    private let decoded = NSCache<NSString, DecodedPlaybackArtwork>()
    private var requests: [String: Request] = [:]

    init() { decoded.countLimit = 5 }

    func artwork(
        for key: String, load: @escaping @MainActor () async -> DecodedPlaybackArtwork?
    ) async -> DecodedPlaybackArtwork? {
        if let artwork = decoded.object(forKey: key as NSString) { return artwork }
        let request = requests[key] ?? Request(task: Task { await load() })
        requests[key] = request
        let artwork = await request.task.value
        if requests[key]?.id == request.id {
            requests[key] = nil
            if let artwork { decoded.setObject(artwork, forKey: key as NSString) }
        }
        return Task.isCancelled || request.task.isCancelled ? nil : artwork
    }

    func cancelRequests(except keys: Set<String>) {
        for key in Array(requests.keys) where !keys.contains(key) {
            requests.removeValue(forKey: key)?.task.cancel()
        }
    }

    func reset() {
        cancelRequests(except: [])
        decoded.removeAllObjects()
    }
}

func playbackBindings(track: LibraryTrack, sources: [SourceConnection]) -> [LibraryBinding] {
    let enabled = Dictionary(
        sources.filter { $0.enabled && $0.state == "active" }.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first })
    return track.bindings.filter { $0.confirmed && enabled[$0.sourceConnectionID] != nil }.sorted { lhs, rhs in
        if lhs.preferred != rhs.preferred { return lhs.preferred }
        return lhs.id < rhs.id
    }
}

func playbackPresentationIdentity(userID: String?, track: LibraryTrack?, sources: [SourceConnection]) -> String {
    guard let track else { return "" }
    let bindings = playbackBindings(track: track, sources: sources).map { binding in
        [
            binding.id, binding.sourceConnectionID, binding.sourceTrackID,
            String(sources.first { $0.id == binding.sourceConnectionID }?.version ?? 0),
        ].joined(separator: ":")
    }
    return ([userID ?? "", track.id, String(track.version)] + bindings).joined(separator: "|")
}

extension AppStore {
    func coverIdentity(sourceID: String, coverID: String) -> DecodedCoverCache.Identity {
        DecodedCoverCache.Identity(
            origin: settings.serverURL, accountID: user?.id ?? "anonymous", sourceID: sourceID,
            sourceVersion: sources.first { $0.id == sourceID }?.version ?? 0,
            coverID: coverID, revision: mediaCache.token())
    }

    func coverImage(
        sourceID: String, coverID: String, maximumPixelSize: Int,
        timing: DecodedCoverCache.DecodeTiming = .immediate
    ) async -> DecodedCoverBitmap? {
        let identity = coverIdentity(sourceID: sourceID, coverID: coverID)
        let image = await DecodedCoverCache.shared.image(
            for: identity, maximumPixelSize: maximumPixelSize, timing: timing
        ) {
            try await self.coverData(sourceID: sourceID, coverID: coverID)
        }
        guard !Task.isCancelled, identity == coverIdentity(sourceID: sourceID, coverID: coverID) else { return nil }
        return image
    }

    func playbackCover(sourceID: String, coverID: String) async -> DecodedPlaybackArtwork? {
        let identity = coverIdentity(sourceID: sourceID, coverID: coverID)
        guard let image = await coverImage(sourceID: sourceID, coverID: coverID, maximumPixelSize: 640) else {
            return nil
        }
        let blurred = await DecodedCoverCache.shared.blurredImage(for: identity, original: image)
        guard !Task.isCancelled, identity == coverIdentity(sourceID: sourceID, coverID: coverID) else { return nil }
        return DecodedPlaybackArtwork(image: image, blurredImage: blurred)
    }
}

struct PlaybackArtworkView: View {
    var image: DecodedCoverBitmap?
    var title: String
    var size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(decorative: image.cgImage, scale: 1).resizable().scaledToFill()
            } else {
                TrackArtwork(title: title, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: min(16, max(6, size * 0.07)), style: .continuous))
        .accessibilityHidden(true)
    }
}

struct PlaybackArtworkButton<Artwork: View>: View {
    var symbol: String
    var showsHover = true
    var action: () -> Void
    @ViewBuilder var artwork: () -> Artwork
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            artwork()
                .overlay {
                    if hovered, showsHover {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.black.opacity(0.45))
                            .overlay {
                                Image(systemName: symbol)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
    }
}

struct PlaybackArtworkWipe<Content: View>: View {
    var artwork: PlaybackArtworkSnapshot?
    var animate = true
    var featherFraction: CGFloat = 0
    var duration = 0.32
    @ViewBuilder var content: (PlaybackArtworkSnapshot?) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed: PlaybackArtworkSnapshot?
    @State private var outgoing: PlaybackArtworkSnapshot?
    @State private var pending: PlaybackArtworkSnapshot?
    @State private var remaining: CGFloat = 1

    var body: some View {
        ZStack {
            content(displayed ?? artwork)
            if let outgoing {
                content(outgoing)
                    .mask { revealMask }
                    .transition(.identity)
            }
        }
        .onChange(of: artwork?.identity, initial: true) { _, _ in accept(artwork) }
        .onChange(of: reduceMotion || !animate) { _, skipWipe in
            if skipWipe { settle(on: artwork ?? displayed) }
        }
        .task(id: outgoing?.identity) {
            guard outgoing != nil else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: duration)) { remaining = 0 }
            do { try await Task.sleep(for: .seconds(duration + 0.02)) } catch { return }
            guard !Task.isCancelled else { return }
            let next = pending
            settle(on: displayed)
            accept(next)
        }
    }

    @ViewBuilder private var revealMask: some View {
        let backward = displayed?.direction == .backward
        if featherFraction > 0 {
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                let feather = width * featherFraction
                HStack(spacing: 0) {
                    Rectangle().fill(.black).frame(width: width)
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: feather)
                }
                .frame(width: width + feather, height: height)
                .offset(x: (width + feather) * (remaining - 1))
                .frame(width: width, height: height, alignment: .leading)
                .scaleEffect(x: backward ? -1 : 1, y: 1)
                .clipped()
            }
        } else {
            Rectangle().scaleEffect(x: remaining, y: 1, anchor: backward ? .trailing : .leading)
        }
    }

    private func accept(_ artwork: PlaybackArtworkSnapshot?) {
        guard let artwork else {
            // A cover that is still loading leaves the last complete frame on screen.
            pending = nil
            return
        }
        guard let displayed, !reduceMotion, animate else {
            settle(on: artwork)
            return
        }
        if outgoing != nil {
            pending = artwork
        } else if displayed.identity != artwork.identity {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                outgoing = displayed
                self.displayed = artwork
                remaining = 1
            }
        }
    }

    private func settle(on artwork: PlaybackArtworkSnapshot?) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayed = artwork
            outgoing = nil
            pending = nil
            remaining = 1
        }
    }
}
