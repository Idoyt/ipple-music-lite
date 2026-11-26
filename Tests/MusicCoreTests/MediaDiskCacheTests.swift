import XCTest

@testable @_spi(Testing) import MusicCore

private final class AudioFixture: @unchecked Sendable {
    let lock = NSLock()
    var requests: [String] = []
    var body = Data("RIFF".utf8) + Data(repeating: 0, count: 400_000)
    var mode = "normal"
    var held: (AudioLoader, Data)?
    func start(_ loader: AudioLoader) {
        let range = loader.request.value(forHTTPHeaderField: "Range") ?? ""
        let bounds = range.dropFirst(6).split(separator: "-")
        let first = Int(bounds.first ?? "0") ?? 0
        let requested = Int(bounds.last ?? "0") ?? 0
        let state = lock.withLock {
            requests.append(range)
            return (mode, body)
        }
        let last = min(requested, state.1.count - 1)
        let data = state.1.subdata(in: first..<(last + 1))
        let status = state.0 == "ignored" ? 200 : 206
        let headerStart = state.0 == "wrong-range" ? first + 1 : first
        let response = HTTPURLResponse(
            url: loader.request.url!, statusCode: status, httpVersion: nil,
            headerFields: [
                "Content-Type": state.0 == "html" ? "text/html" : "audio/wav", "Content-Length": String(data.count),
                "Content-Range": "bytes \(headerStart)-\(last)/\(state.1.count)", "ETag": "fixture-v1",
            ])!
        loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
        if state.0 == "held", data.count > 1 {
            lock.withLock { held = (loader, data) }
            return
        }
        if state.0 == "chunked" {
            for offset in stride(from: 0, to: data.count, by: 1024) {
                loader.client?.urlProtocol(loader, didLoad: data.subdata(in: offset..<min(offset + 1024, data.count)))
            }
        } else {
            let payload = state.0 == "oversized" ? data + Data([0]) : state.0 == "truncated" && data.count > 1 ? data.dropLast() : data
            loader.client?.urlProtocol(loader, didLoad: payload)
        }
        loader.client?.urlProtocolDidFinishLoading(loader)
    }
    func release() {
        let value = lock.withLock {
            let value = held
            held = nil
            return value
        }
        if let (loader, data) = value {
            loader.client?.urlProtocol(loader, didLoad: data)
            loader.client?.urlProtocolDidFinishLoading(loader)
        }
    }
}
private final class AudioLoader: URLProtocol, @unchecked Sendable {
    static let fixture = AudioFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.fixture.start(self) }
    override func stopLoading() {}
}

@MainActor
final class MediaDiskCacheTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipple-media-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testErasingAccountPreservesOtherOwnersAndRemovesUnattributedLegacyCache() async throws {
        let root = try directory()
        let cache = MediaDiskCache(directory: root)
        let lyric = self.lyric
        for namespace in [["server", "first", "song"], ["server", "second", "song"], ["legacy"]] {
            _ = try await cache.data(kind: .lyrics, namespace: namespace) { lyric }
        }
        let reopened = MediaDiskCache(directory: root)
        try await reopened.clear(owner: MediaDiskCache.ownerKey(server: "server", account: "first"))
        let remaining = try await reopened.statistics()
        XCTAssertEqual(remaining.count, 1)
        let retained = try await reopened.data(kind: .lyrics, namespace: ["server", "second", "song"]) {
            throw CancellationError()
        }
        XCTAssertEqual(retained, lyric)
    }

    private func client() throws -> (MusicAPIClient, MediaResource) {
        AudioLoader.fixture.lock.withLock {
            AudioLoader.fixture.requests = []
            AudioLoader.fixture.mode = "normal"
            AudioLoader.fixture.body = Data("RIFF".utf8) + Data(repeating: 0, count: 400_000)
            AudioLoader.fixture.held = nil
        }
        let url = URL(string: "http://127.0.0.1/audio")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AudioLoader.self]
        return (
            try MusicAPIClient(testFixtureURL: URL(string: "http://127.0.0.1")!, configuration: config),
            MediaResource(url: url, cookies: [], contentType: "audio/wav", canSeek: true, expiresAt: nil)
        )
    }
    private var cover: Data {
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=")!
    }
    private var lyric: Data {
        try! MusicJSON.encoder().encode(
            SourceLyrics(
                trackID: "song", text: "[00:01]你好", contentType: "application/x-lrc", translation: "[00:01]Hello"))
    }

    func testSharedDefaultAndPerTypeStatistics() async throws {
        let (api, resource) = try client()
        let cache = MediaDiskCache(directory: try directory())
        var stats = try await cache.statistics()
        XCTAssertEqual(stats.limitBytes, 5_368_709_120)
        let cover = cover
        let lyric = lyric
        _ = try await cache.data(namespace: ["cover"]) { cover }
        _ = try await cache.data(kind: .lyrics, namespace: ["lyric"]) { lyric }
        await api.cacheAudioSegment(
            resource, cache: cache, namespace: ["song"], slot: .prefix, position: 0, duration: 200)
        stats = try await cache.statistics()
        XCTAssertGreaterThan(stats.coverBytes, 0)
        XCTAssertGreaterThan(stats.lyricsBytes, 0)
        XCTAssertGreaterThan(stats.audioBytes, 0)
        XCTAssertEqual(stats.usedBytes, stats.coverBytes + stats.lyricsBytes + stats.audioBytes)
        XCTAssertEqual(stats.count, 3)
    }
    func testLyricsPersistAndSeparateAccountsWithoutReloading() async throws {
        let url = try directory()
        let cache = MediaDiskCache(directory: url)
        let lyric = lyric
        _ = try await cache.data(kind: .lyrics, namespace: ["server", "alice", "v1"]) { lyric }
        let reopened = MediaDiskCache(directory: url)
        let cached = try await reopened.data(kind: .lyrics, namespace: ["server", "alice", "v1"]) {
            XCTFail("lyric refetched")
            return Data()
        }
        XCTAssertEqual(try MusicJSON.decoder().decode(SourceLyrics.self, from: cached).translation, "[00:01]Hello")
        _ = try await reopened.data(kind: .lyrics, namespace: ["server", "bob", "v1"]) { lyric }
        _ = try await reopened.data(kind: .lyrics, namespace: ["server", "alice", "v2"]) { lyric }
        let stats = try await reopened.statistics()
        XCTAssertEqual(stats.count, 3)
    }
    func testFragmentedRangePreservesExactBytesAndOffset() async throws {
        let (api, resource) = try client()
        let body = Data((0..<2_000_000).map { UInt8($0 % 251) })
        AudioLoader.fixture.lock.withLock {
            AudioLoader.fixture.mode = "chunked"
            AudioLoader.fixture.body = body
        }
        let result = try await api.audioRange(resource, offset: 37, length: 1_500_000)
        XCTAssertEqual(result.offset, 37)
        XCTAssertEqual(result.totalLength, Int64(body.count))
        XCTAssertEqual(result.data, body.subdata(in: 37..<1_500_037))
    }

    func testCancellingRangeDoesNotPoisonFollowingRequest() async throws {
        let (api, resource) = try client()
        AudioLoader.fixture.lock.withLock { AudioLoader.fixture.mode = "held" }
        let request = Task { try await api.audioRange(resource, offset: 20, length: 4096) }
        for _ in 0..<300 {
            if AudioLoader.fixture.lock.withLock({ AudioLoader.fixture.held != nil }) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(AudioLoader.fixture.lock.withLock { AudioLoader.fixture.held != nil })
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("cancelled range returned bytes")
        } catch { }
        AudioLoader.fixture.release()
        AudioLoader.fixture.lock.withLock { AudioLoader.fixture.mode = "chunked" }
        let following = try await api.audioRange(resource, offset: 80, length: 8000)
        XCTAssertEqual(following.offset, 80)
        XCTAssertEqual(following.data.count, 8000)
    }

    func testPlaybackReadEvictsInvalidAudioMetadata() async throws {
        let (api, resource) = try client()
        let folder = try directory()
        let cache = MediaDiskCache(directory: folder)
        await api.cacheAudioSegment(resource, cache: cache, namespace: ["song"], slot: .prefix, position: 0, duration: 200)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "audio" })
        let invalid = AudioCacheSegment(offset: -1, totalLength: 10, contentType: "audio/wav", validator: nil, data: Data([0]))
        try JSONEncoder().encode(invalid).write(to: file)
        let segments = try await cache.audioSegments(namespace: ["song"])
        XCTAssertTrue(segments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPrefixUsesAboutTwentySecondsAndPersistsWithoutRefetching() async throws {
        let (api, resource) = try client()
        let url = try directory()
        let cache = MediaDiskCache(directory: url)
        for _ in 0..<2 {
            await api.cacheAudioSegment(
                resource, cache: cache, namespace: ["song"], slot: .prefix, position: 0, duration: 200)
        }
        let requests = AudioLoader.fixture.lock.withLock { AudioLoader.fixture.requests }
        XCTAssertEqual(requests.count, 2)
        let segments = try await MediaDiskCache(directory: url).audioSegments(namespace: ["song"])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].offset, 0)
        XCTAssertEqual(segments[0].data.count, 40_001)
        XCTAssertEqual(segments[0].totalLength, 400_004)
    }
    func testInterruptedRangeReplacesPreviousRangeWithoutAccumulating() async throws {
        let (api, resource) = try client()
        let cache = MediaDiskCache(directory: try directory())
        await api.cacheAudioSegment(
            resource, cache: cache, namespace: ["song"], slot: .prefix, position: 0, duration: 200)
        for position in [50.0, 80.0] {
            await api.cacheAudioSegment(
                resource, cache: cache, namespace: ["song"], slot: .interrupted, position: position, duration: 200)
        }
        let segments = try await cache.audioSegments(namespace: ["song"])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.last?.offset, 160_001)
        XCTAssertEqual(segments.last?.data.count, 40_001)
        let stats = try await cache.statistics()
        XCTAssertEqual(stats.count, 2)
    }
    func testSharedLRUEvictionAndCapacityPersistence() async throws {
        let (api, resource) = try client()
        let url = try directory()
        let cache = MediaDiskCache(directory: url)
        try await cache.setLimit(bytes: 100_000)
        await api.cacheAudioSegment(
            resource, cache: cache, namespace: ["old"], slot: .prefix, position: 0, duration: 200)
        let lyric = lyric
        _ = try await cache.data(kind: .lyrics, namespace: ["lyrics"]) { lyric }
        await api.cacheAudioSegment(
            resource, cache: cache, namespace: ["new"], slot: .prefix, position: 0, duration: 200)
        let old = try await cache.audioSegments(namespace: ["old"])
        XCTAssertTrue(old.isEmpty)
        let latest = try await cache.audioSegments(namespace: ["new"])
        XCTAssertEqual(latest.count, 1)
        let stats = try await MediaDiskCache(directory: url).statistics()
        XCTAssertEqual(stats.limitBytes, 100_000)
        XCTAssertLessThanOrEqual(stats.usedBytes, 100_000)
    }
    func testInvalidAndIncompleteRangeResponsesNeverEnterCache() async throws {
        for mode in ["ignored", "html", "wrong-range", "truncated", "oversized"] {
            let (api, resource) = try client()
            let cache = MediaDiskCache(directory: try directory())
            AudioLoader.fixture.lock.withLock { AudioLoader.fixture.mode = mode }
            await api.cacheAudioSegment(
                resource, cache: cache, namespace: ["song"], slot: .prefix, position: 0, duration: 200)
            let stats = try await cache.statistics()
            XCTAssertEqual(stats.usedBytes, 0)
            XCTAssertEqual(stats.count, 0)
        }
    }
    func testClearAndResizePreventLateSegmentRefill() async throws {
        for resize in [false, true] {
            let (api, resource) = try client()
            let cache = MediaDiskCache(directory: try directory())
            AudioLoader.fixture.lock.withLock { AudioLoader.fixture.mode = "held" }
            let task = Task {
                await api.cacheAudioSegment(
                    resource, cache: cache, namespace: ["song"], slot: .interrupted, position: 50, duration: 200)
            }
            for _ in 0..<300 {
                if AudioLoader.fixture.lock.withLock({ AudioLoader.fixture.held != nil }) { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            if resize { try await cache.setLimit(bytes: 0) } else { try await cache.clear() }
            AudioLoader.fixture.release()
            await task.value
            let stats = try await cache.statistics()
            XCTAssertEqual(stats.usedBytes, 0)
            XCTAssertEqual(stats.count, 0)
        }
    }
    func testMigratesLegacyCoversIntoFiveGBBudget() async throws {
        let legacy = try directory()
        let target = try directory()
        let old = MediaDiskCache(directory: legacy)
        let cover = cover
        _ = try await old.data(namespace: ["cover"]) { cover }
        try Data(#"{"limitBytes":2000000000}"#.utf8).write(to: legacy.appendingPathComponent("config.json"))
        let cache = MediaDiskCache(directory: target, legacyDirectory: legacy)
        let stats = try await cache.statistics()
        XCTAssertEqual(stats.limitBytes, 5_368_709_120)
        XCTAssertEqual(stats.count, 1)
        let result = try await cache.data(namespace: ["cover"]) {
            XCTFail("migrated cover reloaded")
            return Data()
        }
        XCTAssertEqual(result, cover)
    }
    func testQueuedInterruptionCannotRefillAfterClear() async throws {
        let (api, resource) = try client()
        let cache = MediaDiskCache(directory: try directory())
        let token = cache.token()
        try await cache.clear()
        await api.cacheAudioSegment(
            resource, cache: cache, namespace: ["queued"], slot: .interrupted,
            position: 50, duration: 200, token: token)
        let count = AudioLoader.fixture.lock.withLock { AudioLoader.fixture.requests.count }
        XCTAssertEqual(count, 0)
        let stats = try await cache.statistics()
        XCTAssertEqual(stats.usedBytes, 0)
    }

    func testBinaryCapacityAndExistingDecimalSettingsMigration() async throws {
        XCTAssertEqual(MediaDiskCache.defaultBytes / MediaDiskCache.bytesPerMegabyte, 5120)
        XCTAssertEqual(1024 * MediaDiskCache.bytesPerMegabyte, 1_073_741_824)
        for (old, expected) in [
            (Int64(5_000_000_000), MediaDiskCache.defaultBytes), (Int64(1_024_000_000), Int64(1_073_741_824)),
            (Int64(0), Int64(0)),
        ] {
            let directory = try directory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["version": 2, "limitBytes": old])
            try data.write(to: directory.appendingPathComponent("config.json"))
            let cache = MediaDiskCache(directory: directory)
            let statistics = try await cache.statistics()
            XCTAssertEqual(statistics.limitBytes, expected)
            let reopened = try await MediaDiskCache(directory: directory).statistics()
            XCTAssertEqual(reopened.limitBytes, expected, "binary settings migrated twice")
        }
    }

    func testAudioNamespacesDisableAndClear() async throws {
        let (api, resource) = try client()
        let cache = MediaDiskCache(directory: try directory())
        await api.cacheAudioSegment(
            resource, cache: cache, namespace: ["alice"], slot: .prefix, position: 0, duration: 200)
        let other = try await cache.audioSegments(namespace: ["bob"])
        XCTAssertTrue(other.isEmpty)
        try await cache.setLimit(bytes: 0)
        let count = AudioLoader.fixture.lock.withLock { AudioLoader.fixture.requests.count }
        await api.cacheAudioSegment(
            resource, cache: cache, namespace: ["alice"], slot: .prefix, position: 0, duration: 200)
        XCTAssertEqual(AudioLoader.fixture.lock.withLock { AudioLoader.fixture.requests.count }, count)
        let stats = try await cache.statistics()
        XCTAssertEqual(stats.usedBytes, 0)
    }
}
