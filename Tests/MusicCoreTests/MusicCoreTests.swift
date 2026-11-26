import Foundation
import XCTest

@testable @_spi(Testing) import MusicCore

extension URLRequest {
    fileprivate var stubBody: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private struct Stub: Sendable {
    let method: String
    let path: String
    let status: Int
    let headers: [String: String]
    let body: String
    let check: @Sendable (URLRequest) -> Void
    init(
        _ method: String, _ path: String, status: Int = 200, headers: [String: String] = [:], body: String,
        check: @escaping @Sendable (URLRequest) -> Void = { _ in }
    ) {
        self.method = method
        self.path = path
        self.status = status
        self.headers = headers
        self.body = body
        self.check = check
    }
}

private final class StubState: @unchecked Sendable {
    let lock = NSLock()
    private var stubs: [Stub] = []
    private var count = 0
    func configure(_ stubs: [Stub]) {
        lock.withLock {
            self.stubs = stubs
            count = 0
        }
    }
    func consume(_ request: URLRequest) -> Stub {
        let next: Stub? = lock.withLock {
            count += 1
            return stubs.isEmpty ? nil : stubs.removeFirst()
        }
        guard let next else {
            XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return Stub("GET", "", status: 500, body: "{}")
        }
        XCTAssertEqual(request.httpMethod, next.method)
        XCTAssertEqual(request.url?.path, next.path)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Service-Key"))
        next.check(request)
        return next
    }
    var remaining: Int { lock.withLock { stubs.count } }
    var requests: Int { lock.withLock { count } }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let state = StubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = Self.state.consume(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class MusicCoreTests: XCTestCase {
    private func client() throws -> MusicAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "Bearer forbidden", "X-Service-Key": "forbidden"]
        return try MusicAPIClient(testFixtureURL: URL(string: "http://127.0.0.1:8080")!, configuration: configuration)
    }

    private func recommendationPage(
        offset: Int, limit: Int, count: Int, more: Bool, version: Int64 = 9,
        day: String = QQRecommendationDay.key(), prefix: String = "song"
    ) throws -> String {
        let tracks = (offset..<(offset + count)).map {
            ["id": "\(prefix)-\($0)", "title": "Song", "artists": ["Artist"], "album": "Album", "duration_ms": 180000]
                as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "tracks": tracks, "albums": [], "playlists": [], "charts": [], "hotwords": [], "suggestions": [],
            "offset": offset, "limit": limit, "has_more": more, "date_key": day, "session_version": version,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func recommendationStub(
        offset: Int, limit: Int, count: Int, more: Bool, version: Int64 = 9,
        day: String = QQRecommendationDay.key(), prefix: String = "song"
    ) throws -> Stub {
        Stub(
            "GET", "/api/v1/sources/qq/discovery",
            body: try recommendationPage(
                offset: offset, limit: limit,
                count: count, more: more, version: version, day: day, prefix: prefix),
            check: { request in
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(items.first { $0.name == "offset" }?.value, String(offset))
                XCTAssertEqual(items.first { $0.name == "limit" }?.value, String(limit))
            })
    }

    func testDailyRecommendationsReadAllPagesAndRejectSessionChanges() async throws {
        let client = try client()
        StubProtocol.state.configure([
            try recommendationStub(offset: 0, limit: 3, count: 3, more: true),
            try recommendationStub(offset: 3, limit: 20, count: 20, more: true),
            try recommendationStub(offset: 23, limit: 20, count: 7, more: false),
        ])
        let result = try await client.dailyRecommendations(id: "qq")
        XCTAssertEqual(result.tracks.count, 30)
        XCTAssertEqual(result.tracks.first?.id, "song-0")
        XCTAssertEqual(result.tracks.last?.id, "song-29")
        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(StubProtocol.state.remaining, 0)
        StubProtocol.state.configure([
            try recommendationStub(offset: 0, limit: 3, count: 3, more: true),
            try recommendationStub(offset: 3, limit: 20, count: 20, more: true, version: 10),
        ])
        do {
            _ = try await client.dailyRecommendations(id: "qq")
            XCTFail("mixed QQ sessions were accepted")
        } catch let error as MusicAPIError { XCTAssertEqual(error.code, "VERSION_CONFLICT") }
    }

    func testRecommendationPreviewCacheAndRadioConsumptionSurvivePageRecreation() async throws {
        let client = try client()
        let cache = RecommendationCache()
        StubProtocol.state.configure([try recommendationStub(offset: 0, limit: 3, count: 3, more: false)])
        let first = try await cache.preview(client: client, sourceID: "qq", scope: "account-a", mode: .guessLike)
        let second = try await cache.preview(client: client, sourceID: "qq", scope: "account-a", mode: .guessLike)
        XCTAssertEqual(first, second)
        XCTAssertEqual(StubProtocol.state.requests, 1)
        XCTAssertEqual(cache.takeRadioPreview(sourceID: "qq", scope: "account-a")?.tracks.count, 3)
        XCTAssertNil(cache.takeRadioPreview(sourceID: "qq", scope: "account-a"))
        _ = try await cache.preview(client: client, sourceID: "qq", scope: "account-a", mode: .guessLike)
        XCTAssertNil(cache.takeRadioPreview(sourceID: "qq", scope: "account-a"))
        StubProtocol.state.configure([try recommendationStub(offset: 0, limit: 3, count: 3, more: false, prefix: "b")])
        cache.retainScopes(["account-b"])
        let next = try await cache.preview(client: client, sourceID: "qq", scope: "account-b", mode: .guessLike)
        XCTAssertEqual(next.tracks.first?.id, "b-0")
        XCTAssertEqual(cache.takeRadioPreview(sourceID: "qq", scope: "account-b")?.tracks.count, 3)
    }

    func testDailyCacheReusesPreviewAndLoadedPagesUntilShanghaiMidnight() async throws {
        let client = try client()
        var now = ISO8601DateFormatter().date(from: "2026-11-17T02:00:00Z")!
        let cache = RecommendationCache(now: { now })
        StubProtocol.state.configure([
            try recommendationStub(offset: 0, limit: 3, count: 3, more: true, day: "2026-11-17"),
            try recommendationStub(offset: 3, limit: 20, count: 20, more: true, day: "2026-11-17"),
            try recommendationStub(offset: 23, limit: 20, count: 7, more: false, day: "2026-11-17"),
        ])
        let preview = try await cache.preview(client: client, sourceID: "qq", scope: "a", mode: .daily)
        XCTAssertEqual(preview.tracks.count, 3)
        XCTAssertEqual(StubProtocol.state.requests, 1)
        let full = try await cache.daily(client: client, sourceID: "qq", scope: "a")
        XCTAssertEqual(full.tracks.count, 30)
        let repeated = try await cache.daily(client: client, sourceID: "qq", scope: "a")
        let reopened = try await cache.preview(client: client, sourceID: "qq", scope: "a", mode: .daily)
        XCTAssertEqual(repeated, full)
        XCTAssertEqual(reopened, full)
        XCTAssertEqual(StubProtocol.state.requests, 3)
        now = ISO8601DateFormatter().date(from: "2026-11-17T16:00:00Z")!
        StubProtocol.state.configure([
            try recommendationStub(offset: 0, limit: 3, count: 3, more: true, day: "2026-11-18", prefix: "newday")
        ])
        let next = try await cache.preview(client: client, sourceID: "qq", scope: "a", mode: .daily)
        XCTAssertEqual(next.dateKey, "2026-11-18")
        XCTAssertEqual(next.tracks.first?.id, "newday-0")
    }

    func testFailedDailyCompletionRetainsAlreadyLoadedPagesForRetry() async throws {
        let client = try client()
        let cache = RecommendationCache()
        StubProtocol.state.configure([
            try recommendationStub(offset: 0, limit: 3, count: 3, more: true),
            try recommendationStub(offset: 3, limit: 20, count: 20, more: true),
            Stub("GET", "/api/v1/sources/qq/discovery", status: 503, body: "{}"),
        ])
        do {
            _ = try await cache.daily(client: client, sourceID: "qq", scope: "a")
            XCTFail("failed page accepted")
        } catch {}
        StubProtocol.state.configure([try recommendationStub(offset: 23, limit: 20, count: 7, more: false)])
        let result = try await cache.daily(client: client, sourceID: "qq", scope: "a")
        XCTAssertEqual(result.tracks.count, 30)
        XCTAssertEqual(StubProtocol.state.requests, 1)
    }

    func testRecommendationDateUsesShanghaiMidnight() throws {
        let format = ISO8601DateFormatter()
        let before = try XCTUnwrap(format.date(from: "2026-11-16T15:59:59Z"))
        let after = try XCTUnwrap(format.date(from: "2026-11-16T16:00:00Z"))
        XCTAssertEqual(QQRecommendationDay.key(for: before), "2026-11-16")
        XCTAssertEqual(QQRecommendationDay.key(for: after), "2026-11-17")
        XCTAssertEqual(QQRecommendationDay.nextBoundary(after: before), after)
    }

    func testQQCursorAdvancesUpstreamWindowsWithoutDroppingDuplicateOccurrences() throws {
        var cursor = QQCollectionCursor(limit: 50)
        try cursor.accept(offset: 0, limit: 50, total: 103, hasMore: true, sessionVersion: 9, count: 49)
        XCTAssertEqual(cursor.nextOffset, 50)
        try cursor.accept(offset: 50, limit: 50, total: 103, hasMore: true, sessionVersion: 9, count: 50)
        try cursor.accept(offset: 100, limit: 50, total: 103, hasMore: false, sessionVersion: 9, count: 3)
        XCTAssertFalse(cursor.hasMore)
        XCTAssertEqual(cursor.total, 103)
    }

    func testQQCursorRejectsRepeatedOrChangedSessionPagesWithoutAdvancing() throws {
        var cursor = QQCollectionCursor(limit: 50, sessionVersion: 9)
        try cursor.accept(offset: 0, limit: 50, total: 101, hasMore: true, sessionVersion: 9, count: 50)
        XCTAssertThrowsError(
            try cursor.accept(offset: 0, limit: 50, total: 101, hasMore: true, sessionVersion: 9, count: 50))
        XCTAssertThrowsError(
            try cursor.accept(offset: 50, limit: 50, total: 101, hasMore: true, sessionVersion: 10, count: 50))
        XCTAssertThrowsError(
            try cursor.accept(offset: 50, limit: 50, total: 102, hasMore: true, sessionVersion: 9, count: 50))
        XCTAssertEqual(cursor.nextOffset, 50)
    }

    func testQQCursorCanPassAWindowContainingOnlyUnrecognizedTracks() throws {
        var cursor = QQCollectionCursor(limit: 100, sessionVersion: 9)
        try cursor.accept(offset: 0, limit: 100, total: 101, hasMore: true, sessionVersion: 9, count: 0)
        try cursor.accept(offset: 100, limit: 100, total: 101, hasMore: false, sessionVersion: 9, count: 1)
        XCTAssertFalse(cursor.hasMore)
        XCTAssertEqual(cursor.nextOffset, 200)
    }

    func testSnakeCaseCodecDatesAndLargeSyncIntegers() throws {
        let raw = Data(
            #"{"id":"track","title":"歌","artists":["艺人"],"album":"专辑","duration_ms":180000,"version":2,"created_at":"2026-11-13T01:02:03Z","updated_at":"2026-11-13T01:02:03.123456Z","bindings":[{"id":"binding","track_id":"track","source_connection_id":"nas","source_track_id":"source","confirmed":true,"preferred":false}]}"#
                .utf8)
        let track = try MusicJSON.decoder().decode(LibraryTrack.self, from: raw)
        XCTAssertEqual(track.durationMS, 180000)
        XCTAssertEqual(track.bindings.first?.sourceConnectionID, "nas")
        let encoded = try MusicJSON.encoder().encode(PlaylistReorder(version: 3, entryIDs: ["one", "two"]))
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(object?["entry_ids"] as? [String], ["one", "two"])
        XCTAssertNil(object?["entry_i_ds"])
        let payload = try MusicJSON.decoder().decode(JSONValue.self, from: Data("9007199254740993".utf8))
        XCTAssertEqual(payload, .integer(9_007_199_254_740_993))
        let playlist = try MusicJSON.decoder().decode(
            SourcePlaylist.self, from: Data(#"{"id":"remote-list","name":"列表","tracks":null}"#.utf8))
        XCTAssertEqual(playlist.tracks, [])
        let malformed = Data(#"{"id":"remote-list","tracks":[],"name":123}"#.utf8)
        XCTAssertThrowsError(try MusicJSON.decoder().decode(SourcePlaylist.self, from: malformed))
    }
}
