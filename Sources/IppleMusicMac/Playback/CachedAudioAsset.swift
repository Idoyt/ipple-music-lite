@preconcurrency import AVFoundation
import Foundation
import MusicCore
import UniformTypeIdentifiers

private final class AudioLoadingRequest: @unchecked Sendable {
    let value: AVAssetResourceLoadingRequest
    init(_ value: AVAssetResourceLoadingRequest) { self.value = value }
}

/// Gives AVPlayer a complete byte-addressed resource: cached ranges first, same-origin HTTP Range for gaps.
/// Segment timestamps are never spliced into the media timeline, preserving native seeking and lyrics.
final class CachedAudioAsset: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let asset: AVURLAsset
    private let resource: MediaResource
    private let segments: [AudioCacheSegment]
    private let client: MusicAPIClient
    private let queue = DispatchQueue(label: "local.ipplemusic.cached-audio")
    private let lock = NSLock()
    private var cachedBytes: Int64 = 0
    var cachedBytesRead: Int64 { lock.withLock { cachedBytes } }
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init?(resource: MediaResource, segments: [AudioCacheSegment], client: MusicAPIClient) {
        guard let prefix = segments.first(where: { $0.offset == 0 }), prefix.isValid,
            segments.allSatisfy({ $0.isValid && $0.matches(prefix) })
        else { return nil }
        self.resource = resource
        self.segments = segments.sorted { $0.offset > $1.offset }
        self.client = client
        asset = AVURLAsset(url: URL(string: "ipple-cache://audio/\(UUID().uuidString)")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let box = AudioLoadingRequest(loadingRequest)
        let id = ObjectIdentifier(loadingRequest)
        let task = Task { [self, box] in
            do {
                try await respond(box)
                if !box.value.isCancelled { box.value.finishLoading() }
            } catch { if !box.value.isCancelled { box.value.finishLoading(with: error) } }
            _ = lock.withLock { tasks.removeValue(forKey: id) }
        }
        lock.withLock { if !loadingRequest.isFinished { tasks[id] = task } }
        return true
    }
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }?.cancel()
    }
    private func respond(_ box: AudioLoadingRequest) async throws {
        let request = box.value
        let metadata = segments[0]
        if let info = request.contentInformationRequest {
            info.contentType = UTType(mimeType: metadata.contentType)?.identifier ?? UTType.audio.identifier
            info.contentLength = metadata.totalLength
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else { return }
        var offset = max(data.currentOffset, data.requestedOffset)
        let end =
            data.requestsAllDataToEndOfResource
            ? metadata.totalLength
            : min(metadata.totalLength, data.requestedOffset + Int64(data.requestedLength))
        while offset < end {
            try Task.checkCancellation()
            guard !request.isCancelled else { throw CancellationError() }
            if let cached = segments.first(where: { $0.offset <= offset && offset < $0.offset + Int64($0.data.count) })
            {
                let start = Int(offset - cached.offset)
                let count = min(Int(end - offset), cached.data.count - start)
                data.respond(with: cached.data.subdata(in: start..<(start + count)))
                lock.withLock { cachedBytes += Int64(count) }
                offset += Int64(count)
            } else {
                let next = segments.filter { $0.offset > offset }.map(\.offset).min() ?? end
                let count = Int(min(256 * 1024, min(end, next) - offset))
                let loaded = try await client.audioRange(resource, offset: offset, length: count)
                guard loaded.matches(metadata) else { throw MusicAPIError(status: 0, code: "AUDIO_CHANGED") }
                guard !request.isCancelled else { throw CancellationError() }
                data.respond(with: loaded.data)
                offset += Int64(loaded.data.count)
            }
        }
    }
    func cancel() {
        let active = lock.withLock {
            let values = Array(tasks.values)
            tasks = [:]
            return values
        }
        for task in active { task.cancel() }
        asset.cancelLoading()
    }
    deinit { cancel() }
}
