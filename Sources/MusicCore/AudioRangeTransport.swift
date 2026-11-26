import Foundation

private final class RangeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func attach(_ task: URLSessionTask) {
        let stop = lock.withLock {
            self.task = task
            return cancelled
        }
        if stop { task.cancel() }
    }
    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}

/// Persistent same-origin connection pool with bounded response bodies, including servers that ignore Range.
final class AudioRangeTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // A reference keeps the Data buffer uniquely owned while the dictionary retains the request.
    // Copying a struct out of the dictionary before every append otherwise copies all bytes received so far.
    private final class Request {
        let offset: Int64
        let length: Int
        var data = Data()
        var metadata: AudioCacheSegment?
        let continuation: CheckedContinuation<AudioCacheSegment, any Error>
        init(offset: Int64, length: Int, continuation: CheckedContinuation<AudioCacheSegment, any Error>) {
            self.offset = offset
            self.length = length
            self.continuation = continuation
            data.reserveCapacity(length)
        }
    }
    private let origin: URL
    private let lock = NSLock()
    private var requests: [Int: Request] = [:]
    private var session: URLSession!
    init(origin: URL, protocolClasses: [AnyClass]?) {
        self.origin = origin
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }
    func invalidate() { session.invalidateAndCancel() }
    func fetch(_ resource: MediaResource, offset: Int64, length: Int) async throws -> AudioCacheSegment {
        guard offset >= 0, length > 0, length <= 32 * 1_024 * 1_024,
            offset <= Int64.max - Int64(length), MusicAPIClient.sameOrigin(origin, resource.url)
        else { throw MusicAPIError(status: 0, code: "INVALID_AUDIO_RANGE") }
        var request = URLRequest(url: resource.url)
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (key, value) in HTTPCookie.requestHeaderFields(with: resource.cookies) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let cancellation = RangeCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.withLock {
                    requests[task.taskIdentifier] = Request(offset: offset, length: length, continuation: continuation)
                }
                cancellation.attach(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map { MusicAPIClient.sameOrigin(origin, $0) } == true ? request : nil)
    }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let accepted: Bool = lock.withLock {
            guard let http = response as? HTTPURLResponse, http.statusCode == 206,
                let url = http.url, MusicAPIClient.sameOrigin(origin, url),
                let value = requests[dataTask.taskIdentifier],
                let range = http.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes ")
            else { return false }
            let parts = range.dropFirst(6).split(separator: "/")
            guard parts.count == 2, let total = Int64(parts[1]) else { return false }
            let bounds = parts[0].split(separator: "-")
            guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]),
                first == value.offset, first >= 0, last >= first, total > last,
                last - first + 1 <= Int64(value.length), response.expectedContentLength == last - first + 1
            else { return false }
            let type = response.mimeType?.lowercased() ?? "application/octet-stream"
            guard type.hasPrefix("audio/") || ["application/ogg", "application/octet-stream"].contains(type) else {
                return false
            }
            value.metadata = AudioCacheSegment(
                offset: first, totalLength: total, contentType: type,
                validator: http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified"),
                data: Data())
            return true
        }
        completionHandler(accepted ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let accepted = lock.withLock {
            guard let value = requests[dataTask.taskIdentifier], data.count <= value.length - value.data.count else {
                return false
            }
            value.data.append(data)
            return true
        }
        if !accepted { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let value = lock.withLock({ requests.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            value.continuation.resume(throwing: error)
            return
        }
        guard let metadata = value.metadata, !value.data.isEmpty,
            value.data.count == Int(min(Int64(value.length), metadata.totalLength - metadata.offset))
        else {
            value.continuation.resume(throwing: MusicAPIError(status: 0, code: "INVALID_AUDIO_RANGE"))
            return
        }
        let result = AudioCacheSegment(
            offset: metadata.offset, totalLength: metadata.totalLength,
            contentType: metadata.contentType, validator: metadata.validator, data: value.data)
        value.continuation.resume(returning: result)
    }
}

extension MusicAPIClient {
    /// Only called once for the prefix and on explicit playback interruption, never from the progress tick.
    public func cacheAudioSegment(
        _ resource: MediaResource, cache: MediaDiskCache, namespace: [String],
        slot: AudioCacheSlot, position: Double, duration: Double, token: Int? = nil
    ) async {
        guard resource.canSeek, duration.isFinite, duration > 0, position.isFinite, position >= 0, position < duration,
            (try? await cache.canStoreAudio()) == true
        else { return }
        let token = token ?? cache.token()
        do {
            _ = try await cache.data(
                kind: .audio, namespace: namespace + [slot.rawValue], replacing: slot == .interrupted, token: token
            ) {
                let head = try await self.audioRange(resource, offset: 0, length: 1)
                let start =
                    slot == .prefix
                    ? 0 : min(head.totalLength - 1, Int64(Double(head.totalLength) * min(position / duration, 1)))
                let estimated = Double(head.totalLength) * min(20 / duration, 1)
                let length = Int(
                    min(
                        Double(head.totalLength - start),
                        max(1, min(estimated.rounded(.up), Double(32 * 1_024 * 1_024)))))
                let segment = try await self.audioRange(resource, offset: start, length: length)
                guard segment.isValid, segment.matches(head) else {
                    throw MusicAPIError(status: 0, code: "AUDIO_CHANGED")
                }
                return try JSONEncoder().encode(segment)
            }
        } catch {
            // Speculative cache failures never interrupt playback.
        }
    }
}
