import AppKit
import CoreImage
import ImageIO

/// Immutable pixels shared by views and preloads. Presentation size belongs to the view,
/// not to a shared, mutable NSImage with its own drawing caches.
@MainActor
final class DecodedCoverBitmap {
    let cgImage: CGImage
    init(_ cgImage: CGImage) { self.cgImage = cgImage }
}

/// Views and the small playback preloader own the pixels. This index only shares those live images.
@MainActor
final class DecodedCoverCache {
    enum DecodeTiming: Hashable, Sendable {
        case onDisplay
        case immediate
        var cachesImmediately: Bool { self == .immediate }
    }

    struct Identity: Hashable, Sendable {
        var origin: String
        var accountID: String
        var sourceID: String
        var sourceVersion: Int64
        var coverID: String
        var revision: Int
    }

    private struct Key: Hashable, Sendable {
        let identity: Identity
        let pixels: Int
        let blurred: Bool
        let timing: DecodeTiming
    }

    private final class Entry {
        weak var image: DecodedCoverBitmap?
        var used: UInt64
        init(_ image: DecodedCoverBitmap, used: UInt64) {
            self.image = image
            self.used = used
        }
    }

    @MainActor private final class Result {
        let image: DecodedCoverBitmap
        init(_ image: DecodedCoverBitmap) { self.image = image }
    }

    /// Cancellation marks demand immediately, even before the main actor can remove the request.
    private final class Demand: @unchecked Sendable {
        private let lock = NSLock()
        private var consumers: Set<UUID> = []
        var isNeeded: Bool { lock.withLock { !consumers.isEmpty } }
        func add(_ id: UUID) { _ = lock.withLock { consumers.insert(id) } }
        func addIfNeeded(_ id: UUID) -> Bool {
            lock.withLock {
                guard !consumers.isEmpty else { return false }
                consumers.insert(id)
                return true
            }
        }
        func remove(_ id: UUID) { _ = lock.withLock { consumers.remove(id) } }
        func clear() { lock.withLock { consumers.removeAll() } }
    }

    private struct Request: Sendable {
        let id = UUID()
        let demand: Demand
        let task: Task<Result?, Never>
    }

    static let shared = DecodedCoverCache()
    private let entryLimit: Int
    private var images: [Key: Entry] = [:]
    private var requests: [Key: Request] = [:]
    private var useCounter: UInt64 = 0

    init(entryLimit: Int = 1_024) { self.entryLimit = max(1, entryLimit) }
    var indexedImageCount: Int { images.count }

    func image(
        for identity: Identity, maximumPixelSize: Int, timing: DecodeTiming = .immediate,
        load: @escaping @MainActor () async throws -> Data
    ) async -> DecodedCoverBitmap? {
        // Keep list thumbnails separate from the 640 px covers used by the two animated players.
        let pixels = min(640, max(1, maximumPixelSize))
        return await sharedImage(
            for: Key(identity: identity, pixels: pixels, blurred: false, timing: timing)
        ) {
            demand in
            guard let data = try? await load(), !Task.isCancelled, demand.isNeeded else { return nil }
            let decoded = await Task.detached(priority: Task.currentPriority) {
                autoreleasepool {
                    demand.isNeeded ? decodedCoverThumbnail(data, maximumPixelSize: pixels, timing: timing) : nil
                }
            }.value
            guard !Task.isCancelled, demand.isNeeded, let decoded else { return nil }
            return DecodedCoverBitmap(decoded)
        }
    }

    func blurredImage(for identity: Identity, original: DecodedCoverBitmap) async -> DecodedCoverBitmap? {
        await sharedImage(for: Key(identity: identity, pixels: 256, blurred: true, timing: .immediate)) { demand in
            let sharp = original.cgImage
            let decoded = await Task.detached(priority: Task.currentPriority) {
                autoreleasepool { demand.isNeeded ? blurredCoverThumbnail(sharp) : nil }
            }.value
            guard !Task.isCancelled, demand.isNeeded, let decoded else { return nil }
            return DecodedCoverBitmap(decoded)
        }
    }

    func reset() {
        for request in requests.values {
            request.demand.clear()
            request.task.cancel()
        }
        requests.removeAll()
        images.removeAll()
    }

    private func sharedImage(for key: Key, load: @escaping @MainActor (Demand) async -> DecodedCoverBitmap?) async
        -> DecodedCoverBitmap?
    {
        guard !Task.isCancelled else { return nil }
        useCounter &+= 1
        if let entry = images[key], let image = entry.image {
            entry.used = useCounter
            return image
        }
        let consumer = UUID()
        let request: Request
        if let existing = requests[key], !existing.task.isCancelled, existing.demand.addIfNeeded(consumer) {
            request = existing
        } else {
            requests[key]?.task.cancel()
            let demand = Demand()
            demand.add(consumer)
            request = Request(
                demand: demand,
                task: Task {
                    guard demand.isNeeded, !Task.isCancelled else { return nil }
                    return await load(demand).map(Result.init)
                })
        }
        requests[key] = request
        let result = await withTaskCancellationHandler {
            await request.task.value
        } onCancel: { [weak self] in
            request.demand.remove(consumer)
            Task { @MainActor [weak self] in self?.cancelIfUnneeded(key, requestID: request.id) }
        }
        defer { request.demand.remove(consumer) }
        if Task.isCancelled {
            request.demand.remove(consumer)
            cancelIfUnneeded(key, requestID: request.id)
            return nil
        }
        if requests[key]?.id == request.id {
            requests[key] = nil
            if let image = result?.image, !request.task.isCancelled {
                if images.count >= entryLimit {
                    images = images.filter { $0.value.image != nil }
                    if images.count >= entryLimit, let oldest = images.min(by: { $0.value.used < $1.value.used })?.key {
                        images[oldest] = nil
                    }
                }
                useCounter &+= 1
                images[key] = Entry(image, used: useCounter)
            }
        }
        return request.task.isCancelled ? nil : result?.image
    }

    private func cancelIfUnneeded(_ key: Key, requestID: UUID) {
        guard let request = requests[key], request.id == requestID, !request.demand.isNeeded else { return }
        requests[key] = nil
        request.task.cancel()
    }
}

private func decodedCoverThumbnail(
    _ data: Data, maximumPixelSize: Int, timing: DecodedCoverCache.DecodeTiming
) -> CGImage? {
    guard
        let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: timing.cachesImmediately,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ] as CFDictionary)
}

private func blurredCoverThumbnail(_ sharp: CGImage) -> CGImage? {
    let scale = min(1, 256 / CGFloat(max(sharp.width, sharp.height)))
    let input = CIImage(cgImage: sharp).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14])
        .cropped(to: input.extent)
    return CIContext(options: [.cacheIntermediates: false]).createCGImage(blurred, from: input.extent)
}
