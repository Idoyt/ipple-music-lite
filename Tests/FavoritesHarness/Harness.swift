import Foundation
@_spi(Testing) import MusicCore

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(description: message) }
}

private final class Fixture: @unchecked Sendable {
    let lock = NSLock()
    var requests: [String] = []
    var held: Loader?
    var hold: String?
    var failure: String?

    func start(_ loader: Loader) {
        let query = URLComponents(url: loader.request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let kind = query.first { $0.name == "kind" }!.value!
        let offset = Int(query.first { $0.name == "offset" }!.value!)!
        let key = "\(kind):\(offset)"
        let mode: Int = lock.withLock {
            requests.append(key)
            if hold == key {
                hold = nil
                held = loader
                return 1
            }
            if failure == key {
                failure = nil
                return 2
            }
            return 0
        }
        if mode == 1 { return }
        if mode == 2 {
            loader.respond(Data(#"{"code":"SOURCE_UNAVAILABLE"}"#.utf8), status: 503)
        } else {
            respond(loader, kind: kind, offset: offset)
        }
    }

    func respond(_ loader: Loader, kind: String, offset: Int) {
        let tracks =
            kind == "playlists"
            ? []
            : (offset..<min(offset + 50, 125)).map {
                SourceTrack(id: "song-\($0)", title: "Song \($0)", album: "Album")
            }
        let encoded = try! MusicJSON.encoder().encode(tracks)
        let playlists: [[String: Any]] =
            kind == "playlists"
            ? (offset..<min(offset + 50, 125)).map {
                ["id": "\($0 + 1)", "name": "Playlist \($0)", "kind": "playlist", "track_count": 125]
            } : []
        let body: [String: Any] = [
            "tracks": try! JSONSerialization.jsonObject(with: encoded), "playlists": playlists,
            "offset": offset, "limit": 50, "total": 125, "has_more": offset + 50 < 125,
            "session_version": 9,
        ]
        loader.respond(try! JSONSerialization.data(withJSONObject: body))
    }

    func release(kind: String, offset: Int) {
        let loader = lock.withLock {
            let value = held
            held = nil
            return value
        }
        if let loader { respond(loader, kind: kind, offset: offset) }
    }
    var isHeld: Bool { lock.withLock { held != nil } }
    var recorded: [String] { lock.withLock { requests } }
}

private final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixture = Fixture()
    var current: Fixture { lock.withLock { fixture } }
    func reset() -> Fixture {
        lock.withLock {
            fixture = Fixture()
            return fixture
        }
    }
}

private final class Loader: URLProtocol, @unchecked Sendable {
    static let registry = Registry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.registry.current.start(self) }
    override func stopLoading() {}
    func respond(_ data: Data, status: Int = 200) {
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
@MainActor
private struct Harness {
    static func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<1_000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(description: "Timed out waiting for favorites state")
    }

    static func setup() throws -> (QQFavoritesCollections, Fixture) {
        let fixture = Loader.registry.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Loader.self]
        let api = try MusicAPIClient(testFixtureURL: URL(string: "http://127.0.0.1:8080")!, configuration: config)
        return (QQFavoritesCollections(client: api, sourceID: "qq"), fixture)
    }

    static func main() async throws {
        do {
            let (collections, fixture) = try setup()
            let songs = collections.songs
            songs.activate()
            try await wait { songs.tracks.count == 50 }
            songs.requestMore()
            try await wait { songs.tracks.count == 100 }
            songs.trackScroll.origin = CGPoint(x: 0, y: 1200)
            songs.followingPlayback = false
            songs.deactivate()
            collections.playlists.activate()
            try await wait { collections.playlists.playlists.count == 50 }
            collections.playlists.gridScroll.origin = CGPoint(x: 0, y: 760)
            collections.playlists.deactivate()
            for _ in 0..<4 {
                songs.activate()
                songs.deactivate()
            }
            collections.playlists.activate()
            try await Task.sleep(for: .milliseconds(30))
            try require(
                fixture.recorded == ["favorites:0", "favorites:50", "playlists:0"], "tab switch reloaded cached pages")
            try require(songs.tracks.count == 100 && songs.cursor.nextOffset == 100, "pagination was reset")
            try require(
                songs.trackScroll.origin?.y == 1200 && !songs.followingPlayback, "song scroll/follow state lost")
            try require(collections.playlists.gridScroll.origin?.y == 760, "playlist scroll position lost")
            collections.cancelPendingRequests()
            print("PASS repeated tab switches preserve loaded pages, both scroll offsets and follow state")
        }
        do {
            let (collections, fixture) = try setup()
            fixture.hold = "favorites:0"
            collections.songs.activate()
            try await wait { fixture.isHeld }
            collections.songs.deactivate()
            collections.playlists.activate()
            try await wait { collections.playlists.playlists.count == 50 }
            collections.playlists.deactivate()
            collections.songs.activate()
            fixture.release(kind: "favorites", offset: 0)
            try await wait { collections.songs.tracks.count == 50 }
            try require(fixture.recorded == ["favorites:0", "playlists:0"], "switching duplicated an in-flight page")
            try require(
                !collections.songs.loading && collections.songs.failure == nil, "loading got stuck after reactivation")
            collections.cancelPendingRequests()
            print("PASS switching while loading retains and completes a single request")
        }
        do {
            let (collections, fixture) = try setup()
            collections.playlists.activate()
            try await wait { collections.playlists.playlists.count == 50 }
            let playlist = collections.playlists.playlists[0]
            collections.openPlaylist(playlist)
            let detail = collections.details[playlist.id]!
            detail.activate()
            try await wait { detail.tracks.count == 50 }
            detail.trackScroll.origin = CGPoint(x: 0, y: 900)
            detail.deactivate()
            collections.selectedPlaylist = nil
            collections.openPlaylist(playlist)
            try require(collections.details[playlist.id] === detail, "reopening discarded cached playlist detail")
            detail.activate()
            try await Task.sleep(for: .milliseconds(30))
            try require(fixture.recorded == ["playlists:0", "playlist:0"], "reopening reloaded playlist detail")
            try require(detail.trackScroll.origin?.y == 900, "detail scroll position lost")
            collections.cancelPendingRequests()
            print("PASS playlist overview and each opened detail retain separate state")
        }
        do {
            let (collections, fixture) = try setup()
            let songs = collections.songs
            songs.activate()
            try await wait { songs.tracks.count == 50 }
            fixture.failure = "favorites:50"
            songs.requestMore()
            try await wait { songs.failure != nil }
            songs.deactivate()
            songs.activate()
            try await Task.sleep(for: .milliseconds(30))
            try require(fixture.recorded == ["favorites:0", "favorites:50"], "reactivation retried a failed page")
            songs.retryMore()
            try await wait { songs.tracks.count == 100 }
            try require(songs.failure == nil, "explicit retry did not continue from the saved cursor")
            songs.trackScroll.origin = CGPoint(x: 0, y: 800)
            songs.refresh()
            try await wait { !songs.loading }
            try require(
                songs.tracks.count == 50 && songs.cursor.nextOffset == 50, "explicit refresh did not reset pages")
            try require(songs.trackScroll.origin == nil, "explicit refresh retained obsolete scroll state")
            collections.cancelPendingRequests()
            print("PASS failures stay cached until retry and only explicit refresh resets content")
        }
        do {
            let (collections, fixture) = try setup()
            let songs = collections.songs
            songs.activate()
            try await wait { songs.tracks.count == 50 }
            songs.trackScroll.origin = CGPoint(x: 0, y: 900)
            songs.setSearching(true)
            try await wait { !songs.cursor.hasMore && !songs.loadingMore }
            try require(
                songs.matchingTrackIndices("  song 124  ") == [124],
                "search missed a song on the last page or lost its collection index")
            try require(songs.matchingTrackIndices("album").count == 125, "album search was limited to the first page")
            try require(songs.trackScroll.origin?.y == 900, "search reset the saved list position")
            songs.setSearching(false)
            collections.playlists.activate()
            try await wait { collections.playlists.playlists.count == 50 }
            collections.playlists.setSearching(true)
            try await wait { !collections.playlists.cursor.hasMore && !collections.playlists.loadingMore }
            try require(
                collections.playlists.matchingPlaylists("playlist 124").map(\.id) == ["125"],
                "playlist search missed later pages")
            try require(
                fixture.recorded == [
                    "favorites:0", "favorites:50", "favorites:100",
                    "playlists:0", "playlists:50", "playlists:100",
                ], "search duplicated or crossed collection pages")
            collections.cancelPendingRequests()
            print("PASS search covers the full song/playlist collection and preserves original row indices")
        }
        do {
            let (collections, fixture) = try setup()
            let songs = collections.songs
            songs.activate()
            try await wait { songs.tracks.count == 50 }
            fixture.hold = "favorites:50"
            songs.setSearching(true)
            try await wait { fixture.isHeld }
            songs.setSearching(false)
            fixture.release(kind: "favorites", offset: 50)
            try await wait { songs.tracks.count == 100 && !songs.loadingMore }
            try await Task.sleep(for: .milliseconds(30))
            try require(fixture.recorded == ["favorites:0", "favorites:50"], "closed search kept reading more pages")
            songs.setSearching(true)
            try await wait { songs.tracks.count == 125 }
            try require(
                fixture.recorded == ["favorites:0", "favorites:50", "favorites:100"],
                "reopened search restarted cached pages")
            collections.cancelPendingRequests()
            print("PASS closing search stops further pagination and reopening reuses cached content")
        }
        do {
            let (collections, fixture) = try setup()
            let songs = collections.songs
            songs.activate()
            try await wait { songs.tracks.count == 50 }
            songs.trackScroll.origin = CGPoint(x: 0, y: 900)
            songs.followingPlayback = false
            fixture.hold = "favorites:50"
            songs.setSearching(true)
            try await wait { fixture.isHeld }
            songs.deactivate(preservingLayout: true)
            fixture.release(kind: "favorites", offset: 50)
            try await wait { songs.tracks.count == 100 && !songs.loadingMore }
            songs.requestMore()
            try await Task.sleep(for: .milliseconds(30))
            try require(fixture.recorded == ["favorites:0", "favorites:50"], "covered workspace continued pagination")
            try require(
                !songs.trackScroll.needsRestore && !songs.trackScroll.isActive,
                "covered native list lost its attached layout")
            songs.activate()
            try require(
                songs.tracks.count == 100 && songs.trackScroll.origin?.y == 900 && !songs.followingPlayback,
                "resuming reset content, position or manual following")
            songs.requestMore()
            try await wait { songs.tracks.count == 125 }
            try require(
                fixture.recorded == ["favorites:0", "favorites:50", "favorites:100"], "resume reloaded old pages")
            collections.cancelPendingRequests()
            print("PASS covered workspace pauses pagination and resumes cached pages, position and manual follow state")
        }
        do {
            let (collections, fixture) = try setup()
            let songs = collections.songs
            songs.activate()
            try await wait { songs.tracks.count == 50 }
            songs.requestMore()
            try await wait { songs.tracks.count == 100 && !songs.loadingMore }
            songs.trackScroll.origin = CGPoint(x: 0, y: 900)
            songs.followingPlayback = false
            let scroll = songs.trackScroll
            fixture.hold = "favorites:0"
            songs.invalidate()
            try await wait { fixture.isHeld }
            try require(
                songs.tracks.count == 100 && songs.trackScroll === scroll && songs.trackScroll.origin?.y == 900,
                "favorite invalidation cleared loaded content or scroll position")
            fixture.release(kind: "favorites", offset: 0)
            try await wait { !songs.loadingMore && songs.cursor.nextOffset == 100 }
            try require(
                fixture.recorded == ["favorites:0", "favorites:50", "favorites:0", "favorites:50"],
                "favorite reload did not replace the same loaded window")
            try require(
                songs.tracks.count == 100 && !songs.followingPlayback && songs.trackScroll === scroll,
                "favorite reload reset manual follow or native scroll state")
            songs.deactivate()
            let requests = fixture.recorded.count
            songs.invalidate()
            try require(fixture.recorded.count == requests, "hidden collection refetched immediately")
            songs.activate()
            try await wait { !songs.loadingMore && fixture.recorded.count == requests + 2 }
            collections.cancelPendingRequests()
            print("PASS favorite changes refresh loaded windows without clearing content, scroll or manual follow")
        }
        do {
            let (collections, fixture) = try setup()
            let songs = collections.songs
            songs.activate()
            try await wait { songs.tracks.count == 50 }
            songs.requestMore()
            try await wait { songs.tracks.count == 100 && !songs.loadingMore }
            fixture.failure = "favorites:0"
            songs.invalidate()
            try await wait { songs.failure != nil && !songs.loadingMore }
            try require(songs.tracks.count == 100, "failed favorite reload discarded content")
            songs.retryMore()
            try await wait { songs.failure == nil && !songs.loadingMore }
            try require(
                fixture.recorded.suffix(2) == ["favorites:0", "favorites:50"], "retry skipped stale loaded pages")
            fixture.hold = "favorites:0"
            songs.invalidate()
            try await wait { fixture.isHeld }
            songs.deactivate()
            songs.cancelPendingRequest()
            fixture.release(kind: "favorites", offset: 0)
            songs.activate()
            try await wait { !songs.loadingMore }
            try require(
                fixture.recorded.suffix(2) == ["favorites:0", "favorites:50"] && songs.tracks.count == 100,
                "cancelled invalidation was lost when the collection reopened")
            collections.cancelPendingRequests()
            print("PASS failed or interrupted favorite refresh retries the loaded window when resumed")
        }
        print("Favorites state regression harness: 9/9 passed")
    }
}
