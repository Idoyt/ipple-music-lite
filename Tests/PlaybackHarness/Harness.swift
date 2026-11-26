import Foundation
@_spi(Testing) import MusicCore
import Observation

private final class ChangeNotice: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.withLock { changed = true } }
    var value: Bool { lock.withLock { changed } }
}

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(description: message) }
}

private final class Fixture: @unchecked Sendable {
    let lock = NSLock()
    var held: Loader?
    var radioBatches = 0
    var holdRadio = false
    var pendingRadio: (Loader, Int)?
    var holdOffset: Int?
    var failOffset: Int?
    var changedVersion = false
    var filteredIndex: Int?
    var offsets: [Int] = []
    var selections: [Int] = []
    var paths: [String] = []
    var remoteSnapshot: PlaybackSnapshot?
    var holdSelection = false
    var selected: (Loader, Int, String?)?

    func start(_ loader: Loader) {
        let path = loader.request.url!.path
        lock.withLock { paths.append(path) }
        if path == "/api/v1/auth/csrf" {
            loader.respond(Data(#"{"csrf_token":"fixture"}"#.utf8))
        } else if path == "/api/v1/playback-snapshot", loader.request.httpMethod == "GET" {
            if let snapshot = lock.withLock({ remoteSnapshot }) {
                loader.respond(try! MusicJSON.encoder().encode(snapshot))
            } else {
                loader.respond(Data(#"{"code":"NOT_FOUND"}"#.utf8), status: 404)
            }
        } else if path == "/api/v1/sources/radio/discovery" {
            let batch = lock.withLock {
                radioBatches += 1
                return radioBatches - 1
            }
            let held = lock.withLock {
                if holdRadio {
                    holdRadio = false
                    pendingRadio = (loader, batch)
                    return true
                }
                return false
            }
            if !held { respondRadio(loader, batch: batch) }
        } else if path == "/api/v1/sources/radio" {
            loader.respond(
                try! MusicJSON.encoder().encode(
                    SourceConnection(
                        id: "radio", ownerID: "a", name: "QQ", kind: "qq", baseURL: "http://qq.local", enabled: true,
                        state: "active")))
        } else if path == "/api/v1/sources/radio/import-track" {
            let input = try! JSONSerialization.jsonObject(with: loader.requestBody) as! [String: Any]
            let id = input["track_id"] as! String
            let track = LibraryTrack(
                id: id, title: id, album: "", durationMS: 60000,
                bindings: [LibraryBinding(id: id, trackID: id, sourceConnectionID: "radio", sourceTrackID: id)])
            loader.respond(try! MusicJSON.encoder().encode(track))
        } else if path.hasPrefix("/api/v1/library/tracks/"), loader.request.httpMethod == "GET" {
            let track = LibraryTrack(
                id: loader.request.url!.lastPathComponent, title: "Remote", album: "", durationMS: 60_000)
            loader.respond(try! MusicJSON.encoder().encode(track))
        } else if path.hasSuffix("/qq-library/import") {
            let input = try! JSONSerialization.jsonObject(with: loader.requestBody) as! [String: Any]
            let offset = input["offset"] as! Int
            let limit = input["limit"] as! Int
            if limit == 1 {
                let held = lock.withLock {
                    selections.append(offset)
                    if holdSelection {
                        holdSelection = false
                        selected = (loader, offset, input["selected_track_id"] as? String)
                        return true
                    }
                    return false
                }
                if held { return }
                respond(loader, offset: offset, limit: limit, selectedID: input["selected_track_id"] as? String)
                return
            }
            let shouldHold = lock.withLock {
                offsets.append(offset)
                if holdOffset == offset {
                    held = loader
                    holdOffset = nil
                    return true
                }
                return false
            }
            if !shouldHold { respond(loader, offset: offset) }
        } else {
            // Queue tests exercise the actual controller; native QA separately verifies AVPlayer audio.
            loader.respond(Data(#"{"code":"SOURCE_UNAVAILABLE"}"#.utf8), status: 503)
        }
    }

    func respond(_ loader: Loader, offset: Int, limit: Int = 100, selectedID: String? = nil) {
        let failure = lock.withLock {
            if limit == 100 && failOffset == offset {
                failOffset = nil
                return true
            }
            return false
        }
        if failure {
            loader.respond(Data(#"{"code":"SOURCE_UNAVAILABLE"}"#.utf8), status: 503)
            return
        }
        let total = filteredIndex == nil ? 205 : 206
        let ids: [String]
        if let selectedID, limit == 1 {
            ids = [selectedID]
        } else {
            ids = (offset..<min(offset + limit, total)).filter { $0 != filteredIndex }.map {
                String($0 == 100 ? 99 : $0)
            }
        }
        let items = ids.map { id in
            return LibraryTrack(
                id: id, title: id, album: "",
                bindings: [
                    LibraryBinding(id: id, trackID: id, sourceConnectionID: "qq", sourceTrackID: id)
                ])
        }
        let encoded = try! MusicJSON.encoder().encode(items)
        let version = lock.withLock { changedVersion && offset > 0 && limit == 100 ? 10 : 9 }
        let json =
            "{\"items\":\(String(decoding: encoded, as: UTF8.self)),\"offset\":\(offset),\"limit\":\(limit),\"total\":\(total),\"has_more\":\(offset + limit < total),\"session_version\":\(version)}"
        loader.respond(Data(json.utf8))
    }

    func respondRadio(_ loader: Loader, batch: Int) {
        let tracks = (batch * 20..<(batch * 20 + 20)).map {
            ["id": "radio-\($0)", "title": "Radio", "artists": [], "album": "", "duration_ms": 60000] as [String: Any]
        }
        let version = lock.withLock { changedVersion ? 10 : 9 }
        let body: [String: Any] = [
            "tracks": tracks, "albums": [], "playlists": [], "charts": [], "hotwords": [], "suggestions": [],
            "offset": 0, "limit": 20, "has_more": false, "session_version": version,
        ]
        loader.respond(try! JSONSerialization.data(withJSONObject: body))
    }
    var radioIsHeld: Bool { lock.withLock { pendingRadio != nil } }
    var requestedRadioBatches: Int { lock.withLock { radioBatches } }
    func releaseRadio() {
        let pending = lock.withLock {
            let value = pendingRadio
            pendingRadio = nil
            return value
        }
        if let (loader, batch) = pending { respondRadio(loader, batch: batch) }
    }

    func release(offset: Int) {
        let loader = lock.withLock {
            let value = held
            held = nil
            return value
        }
        if let loader { respond(loader, offset: offset) }
    }
    var isHeld: Bool { lock.withLock { held != nil } }
    var requestedOffsets: [Int] { lock.withLock { offsets } }
    var mediaResolves: Int { lock.withLock { paths.filter { $0.hasSuffix("/resolve") }.count } }
    var snapshotRequests: Int { lock.withLock { paths.filter { $0 == "/api/v1/playback-snapshot" }.count } }
    var selectionIsHeld: Bool { lock.withLock { selected != nil } }

    func releaseSelection() {
        let value = lock.withLock {
            let value = selected
            selected = nil
            return value
        }
        if let (loader, offset, id) = value { respond(loader, offset: offset, limit: 1, selectedID: id) }
    }

}

private final class Loader: URLProtocol, @unchecked Sendable {
    static let fixtures = FixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.fixtures.current.start(self) }
    override func stopLoading() {}
    var requestBody: Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return data }
            data.append(buffer, count: count)
        }
    }
    func respond(_ data: Data, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class FixtureRegistry: @unchecked Sendable {
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

@main
@MainActor
private struct Harness {
    static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(description: "Timed out waiting for queue state")
    }

    static func setup(hold: Int? = nil, fail: Int? = nil) throws -> (PlaybackController, Fixture) {
        let fixture = Loader.fixtures.reset()
        fixture.holdOffset = hold
        fixture.failOffset = fail
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Loader.self]
        let api = try MusicAPIClient(testFixtureURL: URL(string: "http://127.0.0.1:8080")!, configuration: config)
        return (PlaybackController(client: api), fixture)
    }

    static func start(_ player: PlaybackController, at index: Int = 0, expected: String? = nil) {
        player.playQQCollection(
            sourceID: "qq", kind: .favorites, playlistID: nil, sessionVersion: 9,
            startIndex: index, expectedTrackID: expected)
    }

    static func sessionDirectory() -> URL {
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["IPPLE_WORKSPACE_ROOT"]
                ?? FileManager.default.currentDirectoryPath)
        return root.appendingPathComponent(".local/test-runs/playback-session/" + UUID().uuidString)
    }

    static func sessionPlayer(_ directory: URL, account: String = "a", server: String = "http://127.0.0.1:8080") throws
        -> PlaybackController
    {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Loader.self]
        let url = URL(string: server)!
        let api = try MusicAPIClient(testFixtureURL: url, configuration: config)
        let player = PlaybackController(client: api, sessionDirectory: directory)
        player.configureSession(serverURL: url, accountID: account)
        return player
    }

    static func personalRadioTests() async throws {
        do {
            let (player, fixture) = try setup()
            let tracks = (0..<3).map {
                ["id": "preview-\($0)", "title": "Preview", "album": "", "duration_ms": 60000] as [String: Any]
            }
            let body: [String: Any] = [
                "tracks": tracks, "albums": [], "playlists": [], "charts": [], "hotwords": [], "suggestions": [],
                "offset": 0, "limit": 3, "has_more": false, "session_version": 9,
            ]
            let preview = try MusicJSON.decoder().decode(
                SourceDiscovery.self, from: JSONSerialization.data(withJSONObject: body))
            await player.startPersonalRadio(sourceID: "radio", connectionVersion: 1, preview: preview)
            try require(
                player.queue.count == 3 && fixture.requestedRadioBatches == 0,
                "three-song preview eagerly fetched a full radio batch")
            await player.next()
            try require(fixture.requestedRadioBatches == 0, "radio refilled before the last preview song")
            await player.next()
            await player.waitForPersonalRadioBatch()
            try require(
                player.currentTrack?.id == "preview-2" && player.queue.count == 23
                    && fixture.requestedRadioBatches == 1,
                "last preview song did not refill twenty new tracks")
            await player.next()
            try require(
                player.currentTrack?.id == "radio-0", "preview-to-refill transition skipped the first new track")
            player.stop()
            print("PASS radio starts with three cached previews and refills twenty only at the last preview song")
        }
        do {
            let fixture = Loader.fixtures.reset()
            let directory = sessionDirectory()
            let player = try sessionPlayer(directory)
            await player.startPersonalRadio(sourceID: "radio", connectionVersion: 1)
            try require(
                player.isPersonalRadio && player.queue.count == 20 && player.currentTrack?.id == "radio-0",
                "radio did not start from its first batch")
            player.shuffleEnabled = true
            player.repeatMode = .one
            player.cyclePlaybackMode()
            try require(player.playbackMode == .repeatOne, "radio accepted a playback mode change")
            await player.playQueueItem(at: 19)
            await player.waitForPersonalRadioBatch()
            try require(
                player.currentQueueIndex == 10 && player.queue.count == 31 && fixture.requestedRadioBatches == 2,
                "last song failed to refill twenty songs and retain ten previous songs")
            for index in 20...59 {
                await player.next()
                await player.waitForPersonalRadioBatch()
                let current = player.currentQueueIndex ?? -1
                try require(
                    player.currentTrack?.id == "radio-\(index)", "radio next repeated, shuffled or skipped a track")
                try require(
                    current <= 10 && current >= 0 && player.queue.count - current - 1 <= 20 && player.queue.count <= 31,
                    "radio window grew without bounds")
            }
            await player.previous()
            try require(
                player.currentTrack?.id == "radio-58" && player.queue.count - player.currentQueueIndex! - 1 <= 20,
                "radio previous broke the future bound")
            player.flushSession()
            player.stop()
            let restored = try sessionPlayer(directory)
            await restored.restoreLocalSession()
            try require(
                restored.isPersonalRadio && restored.currentTrack?.id == "radio-58" && restored.queue.count <= 31,
                "restart lost the special radio mode or its bounded window")
            restored.stop()
            print(
                "PASS continuous radio refills at batch ends, retains ten previous/twenty future tracks and restores privately"
            )
        }
        do {
            let (player, fixture) = try setup()
            await player.startPersonalRadio(sourceID: "radio", connectionVersion: 1)
            fixture.holdRadio = true
            await player.playQueueItem(at: 19)
            try await wait { fixture.radioIsHeld }
            let next = Task { await player.next() }
            await Task.yield()
            try require(player.currentTrack?.id == "radio-19", "radio skipped a pending boundary")
            fixture.releaseRadio()
            await next.value
            try require(player.currentTrack?.id == "radio-20", "radio failed to resume across its fetch boundary")
            player.stop()
            print("PASS radio boundary waits for the shared background fetch without exposing a truncated queue")
        }
        do {
            let (player, fixture) = try setup()
            await player.startPersonalRadio(sourceID: "radio", connectionVersion: 1)
            fixture.holdRadio = true
            await player.playQueueItem(at: 19)
            try await wait { fixture.radioIsHeld }
            player.setQueue([LibraryTrack(id: "normal", title: "Normal", album: "")])
            fixture.releaseRadio()
            try await Task.sleep(for: .milliseconds(50))
            try require(
                !player.isPersonalRadio && player.queue.map(\.id) == ["normal"],
                "late radio response replaced an ordinary queue")
            player.stop()
            print("PASS changing playback cancels radio work and discards late recommendations")
        }
        do {
            let (player, fixture) = try setup()
            await player.startPersonalRadio(sourceID: "radio", connectionVersion: 1)
            fixture.holdRadio = true
            await player.playQueueItem(at: 19)
            try await wait { fixture.radioIsHeld }
            let next = Task { await player.next() }
            await Task.yield()
            player.pause()
            fixture.releaseRadio()
            await next.value
            try require(
                player.currentTrack?.id == "radio-19" && !player.isPlaying,
                "late radio refill resumed playback after a manual pause")
            player.stop()
            print("PASS pausing at a pending radio boundary prevents late data from restarting playback")
        }
    }

    static func sessionTests() async throws {
        let tracks = ["a", "b", "a", "c"].map { LibraryTrack(id: $0, title: $0, album: "", durationMS: 60_000) }
        do {
            let fixture = Loader.fixtures.reset()
            let directory = sessionDirectory()
            let player = try sessionPlayer(directory)
            player.setQueue(tracks)
            await player.playQueueItem(at: 2)
            player.repeatMode = .all
            player.shuffleEnabled = true
            player.volume = 0.35
            player.flushSession()
            player.stop()
            let resolves = fixture.mediaResolves
            let restored = try sessionPlayer(directory)
            await restored.restoreLocalSession()
            try require(
                restored.queue == tracks && restored.currentQueueIndex == 2,
                "restart lost queue order or duplicate occurrence")
            try require(
                restored.currentTrack?.id == "a" && !restored.isPlaying && !restored.isLoading && !restored.canSeek,
                "restoration started playback")
            try require(
                restored.repeatMode == .all && restored.shuffleEnabled && restored.volume == 0.35,
                "playback settings were not restored")
            try require(fixture.mediaResolves == resolves, "restore resolved media before explicit play")
            await restored.previous()
            try require(restored.currentQueueIndex == 1, "previous did not retain restored queue navigation")
            restored.stop()
            print(
                "PASS restart restores full ordered queue, duplicate occurrence and playback settings without autoplay")
        }
        do {
            _ = Loader.fixtures.reset()
            let directory = sessionDirectory()
            let a = try sessionPlayer(directory)
            await a.play(tracks[0], inQueue: tracks)
            a.stop()
            let interruptedStartup = try sessionPlayer(directory)
            interruptedStartup.volume = 0.2
            interruptedStartup.stop()
            let b = try sessionPlayer(directory, account: "b")
            await b.restoreLocalSession()
            try require(b.queue.isEmpty, "account B inherited account A queue")
            await b.play(tracks[1], inQueue: [tracks[1]])
            b.stop()
            let otherServer = try sessionPlayer(directory, server: "http://localhost:8080")
            await otherServer.restoreLocalSession()
            try require(otherServer.queue.isEmpty, "queue crossed servers")
            otherServer.stop()
            let restored = try sessionPlayer(directory, server: "http://127.0.0.1:8080/")
            await restored.restoreLocalSession()
            try require(
                restored.queue == tracks && restored.currentTrack?.id == "a",
                "logout or another account erased the saved queue")
            restored.stop()
            print("PASS local playback sessions isolate accounts and normalized server origins")
        }
        do {
            let fixture = Loader.fixtures.reset()
            fixture.holdOffset = 100
            let directory = sessionDirectory()
            let player = try sessionPlayer(directory)
            start(player, at: 150, expected: "150")
            try await wait { fixture.isHeld }
            try require(player.queue.count == 101, "fixture did not reach partial source queue")
            player.flushSession()
            player.stop()
            fixture.release(offset: 100)
            let resolves = fixture.mediaResolves
            let restored = try sessionPlayer(directory)
            await restored.restoreLocalSession()
            try await wait { !restored.isLoadingQQQueue }
            try require(
                restored.queue.count == 205 && restored.currentQueueIndex == 150,
                "restart truncated or shifted a partially loaded QQ collection")
            try require(fixture.requestedOffsets == [0, 100, 100, 200], "restored QQ cursor restarted from page zero")
            try require(
                restored.currentSourceQueueIndex(sourceID: "qq", kind: .favorites, playlistID: nil) == 150,
                "restored source lost playing row identity")
            try require(!restored.isPlaying && fixture.mediaResolves == resolves, "QQ continuation started audio")
            restored.stop()
            print("PASS restart resumes QQ pagination at the saved cursor and preserves source occurrence")
        }
        do {
            let fixture = Loader.fixtures.reset()
            fixture.holdOffset = 0
            let directory = sessionDirectory()
            let player = try sessionPlayer(directory)
            start(player, at: 150, expected: "150")
            try await wait { fixture.isHeld }
            player.stop()
            fixture.release(offset: 0)
            fixture.changedVersion = true
            let restored = try sessionPlayer(directory)
            await restored.restoreLocalSession()
            try await wait { !restored.isLoadingQQQueue }
            try require(
                restored.currentTrack?.id == "150" && restored.currentQueueIndex == 100,
                "single selected song was lost during restart")
            try require(
                restored.queue.count == 101 && restored.qqQueueError != nil,
                "restoration mixed changed QQ session pages")
            restored.stop()
            print("PASS restart before first QQ page preserves selection and rejects a changed source session")
        }
        do {
            let fixture = Loader.fixtures.reset()
            fixture.remoteSnapshot = PlaybackSnapshot(trackID: "remote", positionMS: 12_300, version: 4)
            let directory = sessionDirectory()
            let player = try sessionPlayer(directory)
            await player.restoreLocalSession()
            try require(player.queue.isEmpty && player.position == 0, "missing checkpoint revived a remote song")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let scope = PlaybackSessionScope(server: URL(string: "http://127.0.0.1:8080")!, accountID: "a")
            let file = directory.appendingPathComponent(scope.key + ".json")
            try Data("broken checkpoint".utf8).write(to: file)
            await player.restoreLocalSession()
            try require(
                player.queue.isEmpty && player.position == 0 && !player.isPlaying && fixture.snapshotRequests == 0,
                "corrupt checkpoint attempted to restore remote playback")
            await player.play(tracks[1], inQueue: tracks)
            player.flushSession()
            let writer = PlaybackSessionStore(directory: directory)
            guard var invalid = await writer.load(scope: scope) else {
                throw Failure(description: "could not save a new checkpoint after corruption")
            }
            invalid.keys = []
            player.stop()
            writer.save(invalid, scope: scope)
            writer.flush()
            let restored = try sessionPlayer(directory)
            await restored.restoreLocalSession()
            try require(
                restored.queue.isEmpty && fixture.snapshotRequests == 0, "invalid keys triggered remote fallback")
            restored.stop()
            print("PASS missing, corrupt and invalid checkpoints start empty without a progress request")
        }
        do {
            let fixture = Loader.fixtures.reset()
            let directory = sessionDirectory()
            let original = try sessionPlayer(directory)
            await original.play(tracks[0], inQueue: tracks)
            original.stop()
            let player = try sessionPlayer(directory)
            await player.play(tracks[1], inQueue: [tracks[1], tracks[1]])
            await player.restoreLocalSession()
            try require(
                player.queue.map(\.id) == ["b", "b"] && player.currentQueueIndex == 0,
                "startup restore overwrote user's new queue")
            player.stop()

            let cancelled = try sessionPlayer(directory)
            let cancelledRestore = Task { await cancelled.restoreLocalSession() }
            cancelledRestore.cancel()
            await cancelledRestore.value
            try require(cancelled.queue.isEmpty && cancelled.currentTrack == nil, "cancelled restore loaded playback")
            cancelled.stop()

            fixture.holdSelection = true
            let selecting = try sessionPlayer(directory)
            start(selecting, at: 150, expected: "150")
            try await wait { fixture.selectionIsHeld }
            await selecting.restoreLocalSession()
            try require(selecting.queue.isEmpty, "startup restore overwrote a pending QQ selection")
            await selecting.prepareCurrentTrack()
            fixture.releaseSelection()
            try await wait { !selecting.isLoadingQQQueue }
            try require(
                selecting.currentQueueIndex == 150 && selecting.queue.count == 205,
                "login preparation cancelled the selected QQ song")
            selecting.stop()
            print("PASS local restoration respects cancellation and preserves new or pending QQ playback")
        }
        do {
            let fixture = Loader.fixtures.reset()
            let directory = sessionDirectory()
            let player = try sessionPlayer(directory)
            await player.play(tracks[1], inQueue: tracks)
            player.moveInQueue(from: IndexSet(integer: 3), to: 0)
            player.removeFromQueue(at: 1)
            let expected = player.queue
            player.stop()
            let restored = try sessionPlayer(directory)
            await restored.restoreLocalSession()
            try require(
                restored.queue == expected && restored.currentQueueIndex == 1, "queue edits were not checkpointed")
            restored.setQueue([])
            restored.stop()
            fixture.remoteSnapshot = PlaybackSnapshot(trackID: "remote")
            let empty = try sessionPlayer(directory)
            await empty.restoreLocalSession()
            try require(
                empty.queue.isEmpty && empty.currentTrack == nil, "explicit empty queue revived the server's old song")
            empty.stop()
            print("PASS queue edits and an explicitly emptied queue survive restart")
        }
        do {
            let fixture = Loader.fixtures.reset()
            fixture.remoteSnapshot = PlaybackSnapshot(trackID: "other-device", positionMS: 55_000, version: 10)
            let directory = sessionDirectory()
            let player = try sessionPlayer(directory)
            player.setQueue(tracks)
            await player.playQueueItem(at: 2)
            player.stop()
            let scope = PlaybackSessionScope(server: URL(string: "http://127.0.0.1:8080")!, accountID: "a")
            let file = directory.appendingPathComponent(scope.key + ".json")
            let data = try Data(contentsOf: file)
            var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            legacy["snapshotVersion"] = 4
            legacy["snapshotSyncPaused"] = true
            legacy["position"] = 12.3
            try JSONSerialization.data(withJSONObject: legacy).write(to: file, options: .atomic)

            let restored = try sessionPlayer(directory)
            await restored.restoreLocalSession()
            try require(
                restored.queue == tracks && restored.currentQueueIndex == 2 && restored.position == 12.3
                    && !restored.isPlaying && restored.playbackNotice == nil && fixture.snapshotRequests == 0,
                "legacy checkpoint lost its local progress or consulted its obsolete remote version")
            restored.stop()
            print("PASS legacy checkpoints keep local progress and ignore old conflict flags and remote versions")
        }
    }

    static func playbackModeTests() async throws {
        _ = Loader.fixtures.reset()
        let directory = sessionDirectory()
        let player = try sessionPlayer(directory)
        defer { player.stop() }
        let tracks = (0..<5).map { LibraryTrack(id: "mode-\($0)", title: "Track \($0)", album: "") }
        player.setQueue(tracks)
        await player.playQueueItem(at: 0)
        try require(player.playbackMode == .sequential, "default mode is not sequential")
        player.cyclePlaybackMode()
        try require(
            player.playbackMode == .shuffle && player.currentQueueIndex == 0, "shuffle switched the current song")
        var played = [0]
        for _ in tracks.dropFirst() {
            await player.next()
            guard let index = player.currentQueueIndex else {
                throw Failure(description: "shuffle lost the current song")
            }
            played.append(index)
        }
        try require(Set(played) == Set(tracks.indices), "shuffle repeated a song before exhausting the queue")
        await player.next()
        try require(player.currentQueueIndex == played.last, "shuffle did not stop at the end of the queue")
        await player.previous()
        try require(player.currentQueueIndex == played[played.count - 2], "shuffle previous ignored playback history")
        await player.next()
        try require(player.currentQueueIndex == played.last, "shuffle next ignored forward history")

        player.cyclePlaybackMode()
        try require(player.playbackMode == .repeatOne && !player.shuffleEnabled, "single repeat retained shuffle")
        await player.playQueueItem(at: 1)
        await player.next()
        try require(player.currentQueueIndex == 2, "manual Next could not leave a looping track")
        player.cyclePlaybackMode()
        try require(
            player.playbackMode == .sequential && player.repeatMode == .off, "mode did not cycle back to sequential")
        // Jump to an arbitrary song first to distinguish queue order from play history.
        await player.playQueueItem(at: 4)
        await player.previous()
        try require(player.currentQueueIndex == 3, "sequential Previous used play history instead of queue order")
        await player.next()
        try require(
            player.currentQueueIndex == 4 && player.queue == tracks, "sequential Next did not follow queue order")
        player.cyclePlaybackMode()
        player.cyclePlaybackMode()
        player.stop()
        let restored = try sessionPlayer(directory)
        defer { restored.stop() }
        await restored.restoreLocalSession()
        try require(restored.playbackMode == .repeatOne, "restart lost the selected playback mode")
        print("PASS three playback modes cycle, traverse the full queue and keep manual navigation in the active mode")
    }

    static func mediaTests() async throws {
        let base = URL(string: ProcessInfo.processInfo.environment["IPPLE_PLAYBACK_FIXTURE_URL"]!)!
        let api = try MusicAPIClient(testFixtureURL: base)
        let player = PlaybackController(client: api)
        player.volume = 0
        let tracks = ["a", "b", "c"].map { LibraryTrack(id: $0, title: $0, album: "", durationMS: 12_000) }
        func state() async throws -> [String: [String: Int]] {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("fixture/state"))
            return try JSONDecoder().decode([String: [String: Int]].self, from: data)
        }
        func waitMedia(_ predicate: @MainActor () async throws -> Bool) async throws {
            for _ in 0..<400 {
                if try await predicate() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw Failure(description: "Timed out waiting for native media/preload: \(player.error ?? "no error")")
        }
        await player.play(tracks[0], inQueue: tracks)
        try await waitMedia { player.isPlaying }
        do {
            let start = player.lyricPlaybackPosition()
            let boundaries = [start + 0.25, start + 0.55]
            var lyricTimes: [Double] = []
            let removeBoundaryObserver = player.observeLyricBoundaries(boundaries) {
                lyricTimes.append(player.lyricPlaybackPosition())
            }
            defer { removeBoundaryObserver() }
            try await waitMedia { lyricTimes.count >= boundaries.count }
            try require(
                zip(lyricTimes, boundaries).allSatisfy { abs($0 - $1) < 0.20 },
                "native lyric boundary observer delivered times outside the active cues")
        }
        try await waitMedia { try await state()["streams"]?["b", default: 0] ?? 0 > 0 }
        try require(player.currentTrack?.id == "a", "preload replaced the audible song")
        try await Task.sleep(for: .milliseconds(300))
        let publications = player.nowPlayingPublicationCount
        try await Task.sleep(for: .seconds(1))
        try require(
            player.nowPlayingPublicationCount == publications, "steady playback kept republishing system media metadata"
        )
        print("PASS steady native playback advances without repeated Now Playing publications")
        await player.next()
        try await waitMedia { player.currentTrack?.id == "b" && player.isPlaying }
        try require(
            player.artworkDirection == .forward && Set(player.artworkPreloadTracks.map(\.id)) == ["a", "c"],
            "next track did not expose forward artwork direction and both adjacent covers")
        var counts = try await state()
        try require(counts["resolves"]?["b"] == 1, "switching resolved a preloaded track again")
        try await waitMedia { try await state()["streams"]?["c", default: 0] ?? 0 > 0 }
        player.seek(to: 11.6)
        try await waitMedia { player.currentTrack?.id == "c" && player.isPlaying }
        counts = try await state()
        try require(counts["resolves"]?["c"] == 1, "natural advance discarded preloaded media")
        try require(counts["failures", default: [:]].isEmpty, "native media lost private cookie authentication")
        player.seek(to: 4)
        try await waitMedia { player.position >= 4 }
        await player.previous()
        try await waitMedia { player.currentTrack?.id == "b" && player.isPlaying }
        try require(player.artworkDirection == .backward, "previous track lost its backward artwork direction")
        player.stop()
        print("PASS real AVPlayer prebuffers, promotes the standby player and advances with private cookies")

        await player.play(tracks[0], inQueue: tracks)
        try await waitMedia { player.canSeek && player.isPlaying }
        player.cyclePlaybackMode()
        player.seek(to: 11.3)
        try await waitMedia { player.currentTrack?.id != "a" && player.canSeek && player.isPlaying }
        let repeatedTrack = player.currentTrack
        player.cyclePlaybackMode()
        player.seek(to: 11.3)
        try await waitMedia { player.position >= 11 && player.isPlaying }
        try await waitMedia { player.position < 2 && player.isPlaying }
        try require(
            player.currentTrack == repeatedTrack, "single repeat advanced to another song at natural completion")
        player.cyclePlaybackMode()
        await player.playQueueItem(at: 2)
        try await waitMedia { player.canSeek && player.isPlaying }
        player.seek(to: 11.3)
        try await waitMedia { player.position >= 11 && player.isPlaying }
        try await waitMedia { !player.isPlaying && player.position >= 11.9 }
        try require(player.currentTrack?.id == "c", "sequential playback wrapped past the last song")
        player.stop()
        print("PASS real AVPlayer shuffles at the end of a song, repeats a single track and stops at the queue end")

        var reset = URLRequest(url: base.appendingPathComponent("fixture/reset"))
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
        let slow = LibraryTrack(id: "slow", title: "slow", album: "", durationMS: 12_000)
        await player.play(tracks[0], inQueue: [tracks[0], slow])
        try await waitMedia { try await state()["resolves"]?["slow", default: 0] ?? 0 > 0 }
        player.stop()
        try await Task.sleep(for: .seconds(1))
        counts = try await state()
        try require(player.currentTrack == nil && !player.isPlaying, "late preload revived a stopped player")
        try require(counts["streams"]?["slow"] == nil, "cancelled preload installed a late media item")
        print("PASS stopping cancels an in-flight native preload without reviving playback")

        let directory = sessionDirectory()
        let savedPlayer = PlaybackController(client: api, sessionDirectory: directory)
        savedPlayer.configureSession(serverURL: base, accountID: "media-fixture")
        savedPlayer.volume = 0
        savedPlayer.setQueue([tracks[0], tracks[1], tracks[0]])
        await savedPlayer.playQueueItem(at: 2)
        try await waitMedia { savedPlayer.canSeek && savedPlayer.isPlaying }
        savedPlayer.seek(to: 5)
        try await waitMedia { savedPlayer.position >= 4.9 && savedPlayer.position < 6 }
        savedPlayer.pause()
        let savedPosition = savedPlayer.position
        savedPlayer.flushSession()
        savedPlayer.stop()
        let beforeRestore = try await state()
        let restoredPlayer = PlaybackController(client: api, sessionDirectory: directory)
        restoredPlayer.configureSession(serverURL: base, accountID: "media-fixture")
        await restoredPlayer.restoreLocalSession()
        try require(
            restoredPlayer.currentQueueIndex == 2 && restoredPlayer.queue.count == 3,
            "native restart lost queue occurrence")
        try require(
            abs(restoredPlayer.position - savedPosition) < 0.1 && !restoredPlayer.isPlaying,
            "native restart lost paused position")
        let afterRestore = try await state()
        try require(
            beforeRestore["resolves"] == afterRestore["resolves"], "native restoration requested an audio resource")
        await restoredPlayer.prepareCurrentTrack()
        try await waitMedia { restoredPlayer.canSeek && !restoredPlayer.isLoading }
        try await waitMedia { (try await state()["resolves"]?["a"] ?? 0) > (afterRestore["resolves"]?["a"] ?? 0) }
        try await Task.sleep(for: .milliseconds(250))
        try require(
            !restoredPlayer.isPlaying && abs(restoredPlayer.position - savedPosition) < 0.5,
            "login prebuffer autoplayed or lost saved position")
        let preparedCounts = try await state()
        await restoredPlayer.resume()
        try await waitMedia { restoredPlayer.isPlaying && restoredPlayer.position >= 4.9 }
        let resumedCounts = try await state()
        try require(
            preparedCounts["resolves"] == resumedCounts["resolves"], "explicit play repeated login's resource resolve")
        try require(
            restoredPlayer.currentQueueIndex == 2 && restoredPlayer.volume == 0,
            "explicit resume shifted occurrence or volume")
        restoredPlayer.stop()
        print("PASS login prebuffers the restored duplicate at its saved position without autoplay or a second resolve")

        let qualityDirectory = sessionDirectory()
        let qualityPlayer = PlaybackController(client: api, sessionDirectory: qualityDirectory)
        qualityPlayer.configureSession(serverURL: base, accountID: "quality-user")
        qualityPlayer.volume = 0
        let qualityTrack = LibraryTrack(id: "quality-track", title: "Quality", album: "", durationMS: 12_000)
        let standardTrack = LibraryTrack(id: "standard-only", title: "Standard", album: "", durationMS: 12_000)
        await qualityPlayer.play(qualityTrack, inQueue: [qualityTrack, standardTrack])
        try await waitMedia { qualityPlayer.canSeek && qualityPlayer.isPlaying }
        let offered = try await qualityPlayer.playbackQualityAvailability()
        try require(offered == [.standard: true, .high: true, .lossless: false],
                    "quality availability did not reflect exact-format source responses")
        let qualityChecks = try await state()["resolves"]
        let cachedOffered = try await qualityPlayer.playbackQualityAvailability()
        let afterCachedCheck = try await state()["resolves"]
        try require(cachedOffered == offered && qualityChecks == afterCachedCheck,
                    "reopening quality controls repeated availability requests")
        qualityPlayer.seek(to: 4)
        try await waitMedia { qualityPlayer.position >= 4 }
        try await qualityPlayer.selectPlaybackQuality(.high)
        try await waitMedia {
            qualityPlayer.playbackQuality == .high && qualityPlayer.canSeek && qualityPlayer.isPlaying
        }
        try require((4..<7).contains(qualityPlayer.position), "quality change lost the playing position")
        try await waitMedia { try await state()["qualities"]?["quality-track:320", default: 0] ?? 0 > 0 }
        do {
            try await qualityPlayer.selectPlaybackQuality(.lossless)
            throw Failure(description: "unavailable lossless quality appeared to succeed")
        } catch let error as MusicAPIError where error.code == "NO_PLAYBACK" {
            try require(
                qualityPlayer.playbackQuality == .high && qualityPlayer.isPlaying && !qualityPlayer.isChangingQuality,
                "unavailable quality interrupted the existing song")
        }
        qualityPlayer.pause()
        let pausedPosition = qualityPlayer.lyricPlaybackPosition()
        try await qualityPlayer.selectPlaybackQuality(.standard)
        try await waitMedia { qualityPlayer.canSeek && qualityPlayer.playbackQuality == .standard }
        try require(
            !qualityPlayer.isPlaying && abs(qualityPlayer.position - pausedPosition) < 0.5,
            "quality change did not preserve pause and position")
        try await qualityPlayer.selectPlaybackQuality(.high)
        await qualityPlayer.next()
        try await waitMedia { qualityPlayer.isPlaying && qualityPlayer.currentTrack?.id == "standard-only" }
        try require(
            qualityPlayer.playbackQuality == .standard && qualityPlayer.preferredQuality == .high,
            "unavailable preference did not fall back to standard for the next song")
        let standardOffered = try await qualityPlayer.playbackQualityAvailability()
        try require(standardOffered == [.standard: true, .high: false, .lossless: false],
                    "switching songs reused another song's availability")
        qualityPlayer.stop()
        let clearedOffered = try await qualityPlayer.playbackQualityAvailability()
        try require(clearedOffered.isEmpty, "stopping leaked previous song quality availability")
        let restoredQuality = PlaybackController(client: api, sessionDirectory: qualityDirectory)
        restoredQuality.configureSession(serverURL: base, accountID: "quality-user")
        await restoredQuality.restoreLocalSession()
        try require(restoredQuality.preferredQuality == .high, "restoration lost the preferred quality")
        restoredQuality.stop()
        print(
            "PASS real AVPlayer quality switching preserves position, pause and preference and handles unavailable audio"
        )

        let racePlayer = PlaybackController(client: api, sessionDirectory: sessionDirectory())
        racePlayer.volume = 0
        let raceTrack = LibraryTrack(id: "quality-race", title: "Quality race", album: "", durationMS: 12_000)
        await racePlayer.play(raceTrack, inQueue: [raceTrack])
        try await waitMedia { racePlayer.canSeek && racePlayer.isPlaying }
        racePlayer.pause()
        let superseded = Task { @MainActor in try await racePlayer.selectPlaybackQuality(.high) }
        try await waitMedia { racePlayer.isChangingQuality }
        // Re-select the currently playing format while the previous network request is still pending.
        try await racePlayer.selectPlaybackQuality(.standard)
        do {
            try await superseded.value
            throw Failure(description: "superseded quality request was allowed to finish")
        } catch is CancellationError {}
        try require(racePlayer.playbackQuality == .standard && racePlayer.preferredQuality == .standard
                    && !racePlayer.isChangingQuality && !racePlayer.isPlaying,
                    "old quality request replaced the latest selection or changed pause state")
        racePlayer.stop()
        print("PASS a newer quality selection supersedes an in-flight request without locking controls")

        let cacheDirectory = sessionDirectory().appendingPathComponent("media")
        let cache = MediaDiskCache(directory: cacheDirectory)
        let cachedPlayer = PlaybackController(client: api, mediaCache: cache)
        cachedPlayer.configureSession(serverURL: base, accountID: "cached-user")
        cachedPlayer.volume = 0
        let cachedTrack = LibraryTrack(id: "cached-audio", title: "cached-audio", album: "", durationMS: 60_000)
        let origin = try MusicAPIClient.validateBaseURL(base).absoluteString
        let namespace = [origin, "cached-user", cachedTrack.id, String(cachedTrack.version), "original-audio-v1"]
        await cachedPlayer.play(cachedTrack)
        try await waitMedia { cachedPlayer.isPlaying && cachedPlayer.position > 0.25 }
        try await waitMedia { try await cache.audioSegments(namespace: namespace).count == 1 }
        var segments = try await cache.audioSegments(namespace: namespace)
        try require(
            segments[0].offset == 0 && segments[0].data.count < segments[0].totalLength / 2,
            "prefix cached a complete song")
        cachedPlayer.seek(to: 30)
        try await waitMedia { cachedPlayer.position >= 30 }
        cachedPlayer.pause()
        try await waitMedia { try await cache.audioSegments(namespace: namespace).count == 2 }
        segments = try await cache.audioSegments(namespace: namespace)
        try require(segments[1].offset > segments[0].totalLength / 3, "pause cached the wrong byte position")
        let pausedBytes = try await cache.statistics().audioBytes
        try await Task.sleep(for: .milliseconds(300))
        let settledBytes = try await cache.statistics().audioBytes
        try require(pausedBytes == settledBytes, "paused cache kept updating without a new interruption")
        cachedPlayer.stop()
        cachedPlayer.configureSession(serverURL: base, accountID: "cached-user")
        await cachedPlayer.play(cachedTrack)
        try await waitMedia { cachedPlayer.isPlaying && cachedPlayer.position > 0.25 }
        try require(cachedPlayer.cachedAudioBytesRead > 0, "native player did not consume cached prefix bytes")
        cachedPlayer.seek(to: 30)
        try await waitMedia { cachedPlayer.isPlaying && cachedPlayer.position >= 30 }
        try await cache.clear()
        let cleared = try await cache.statistics()
        try require(cleared.usedBytes == 0, "active playback prevented one-click clear")
        cachedPlayer.seek(to: 31)
        try await waitMedia { cachedPlayer.isPlaying && cachedPlayer.position >= 31 }
        await cachedPlayer.prepareForTermination()
        try require(!cachedPlayer.isPlaying, "normal termination kept playing while caching the interruption")
        let terminationSegments = try await cache.audioSegments(namespace: namespace)
        try require(
            terminationSegments.count == 2 && terminationSegments.last!.offset > terminationSegments[0].totalLength / 3,
            "normal termination did not finish the prefix and interruption snapshots")
        cachedPlayer.stop()
        try await cache.clear()
        let cachePlaybackState = try await state()
        try require(cachePlaybackState["failures", default: [:]].isEmpty, "range caching lost private cookies")
        try require(
            cachePlaybackState["progress_requests", default: [:]].isEmpty,
            "playback, seek, pause or exit still queried or wrote progress via the API")
        print(
            "PASS real AVPlayer reuses prefix and interruption ranges, preserves seeking and keeps playing after clear")

    }

    static func main() async throws {
        if CommandLine.arguments.contains("--media-fixture") {
            try await mediaTests()
            return
        }
        do {
            let (player, fixture) = try setup(hold: 100)
            start(player)
            try await wait { fixture.isHeld }
            try require(player.currentQueueIndex == 0 && player.queue.count == 100, "first page did not start promptly")
            await player.playQueueItem(at: 99)
            let next = Task { await player.next() }
            await Task.yield()
            try require(player.currentQueueIndex == 99, "next skipped an unloaded page")
            fixture.release(offset: 100)
            await next.value
            try require(
                player.currentQueueIndex == 100 && player.queue.count == 205, "queue stopped at a page boundary")
            try require(player.queue[99].id == player.queue[100].id, "duplicate occurrence was dropped")
            try require(fixture.requestedOffsets == [0, 100, 200], "continuation offsets incorrect")
            player.stop()
            print("PASS immediate start, boundary wait and duplicate queue occurrences")
        }
        do {
            let (player, fixture) = try setup(hold: 0)
            start(player, at: 150, expected: "150")
            try await wait { fixture.isHeld }
            try require(player.currentTrack?.id == "150", "selected song waited for earlier pages")
            try require(player.queue.count == 1, "selection imported a full page before starting")
            try require(fixture.selections == [150], "selection was not imported on its own")
            try require(
                player.currentSourceQueueIndex(sourceID: "qq", kind: .favorites, playlistID: nil) == 150,
                "partial queue lost the original row index")
            let visible = (0..<205).map { SourceTrack(id: String($0), title: String($0), album: "") }
            try require(
                player.currentSourceRow(in: visible, sourceID: "qq", kind: .favorites, playlistID: nil) == 150,
                "partial queue highlighted a different source row")
            try require(
                player.loadingSourceRow(in: visible, sourceID: "other", kind: .favorites, playlistID: nil) == nil,
                "loading cover crossed source accounts")
            fixture.release(offset: 0)
            try await wait { !player.isLoadingQQQueue }
            try require(
                player.currentQueueIndex == 150 && player.queue.count == 205,
                "later selection truncated preceding songs")
            try require(
                player.loadingSourceRow(in: visible, sourceID: "qq", kind: .favorites, playlistID: nil) == nil,
                "playback resolution failure left a permanent loading cover")
            player.stop()
            print("PASS later selection retains the complete collection")
        }
        do {
            let fixture = Loader.fixtures.reset()
            fixture.holdOffset = 0
            let directory = sessionDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let player = try sessionPlayer(directory)
            start(player, at: 150, expected: "150")
            try await wait { fixture.isHeld }
            player.shuffleEnabled = true
            player.setNextTrack(LibraryTrack(id: "requested", title: "Requested next", album: ""))
            try require(player.queue.map(\.id) == ["150", "requested"], "next track did not follow the current one")
            fixture.release(offset: 0)
            try await wait { !player.isLoadingQQQueue }
            try require(
                player.queue.count == 206 && player.queue[151].id == "requested" && player.queue[152].id == "151",
                "a pending favorite page moved or dropped the next track")
            player.flushSession()
            player.stop()
            let restored = try sessionPlayer(directory)
            await restored.restoreLocalSession()
            try require(restored.currentTrack?.id == "150" && restored.shuffleEnabled, "queue position did not restore")
            await restored.next()
            try require(restored.currentTrack?.id == "requested", "shuffle skipped the restored next track")
            restored.stop()
            print("PASS set next survives collection pagination, restore and shuffle")
        }
        do {
            let (player, fixture) = try setup(hold: 0)
            start(player)
            try await wait { fixture.isHeld }
            player.stop()
            fixture.release(offset: 0)
            try await Task.sleep(for: .milliseconds(30))
            try require(player.queue.isEmpty && player.currentTrack == nil, "stopped account revived")
            print("PASS stop cancels pending source playback")
        }
        do {
            let (player, fixture) = try setup(hold: 100)
            start(player)
            try await wait { fixture.isHeld }
            player.setQueue([LibraryTrack(id: "local", title: "local", album: "")])
            fixture.release(offset: 100)
            try await Task.sleep(for: .milliseconds(30))
            try require(player.queue.map(\.id) == ["local"], "old source task overwrote a replacement queue")
            player.stop()
            print("PASS replacing a queue cancels background append")
        }
        do {
            let (player, fixture) = try setup(fail: 100)
            start(player)
            try await wait { !player.isLoadingQQQueue }
            try require(player.queue.count == 100 && player.qqQueueError != nil, "tail failure hidden")
            player.retryQQQueueLoading()
            try await wait { !player.isLoadingQQQueue }
            try require(player.queue.count == 205 && player.qqQueueError == nil, "retry duplicated or lost tracks")
            try require(fixture.requestedOffsets == [0, 100, 100, 200], "retry restarted the collection")
            player.stop()
            print("PASS continuation failure retries without restarting playback")
        }
        do {
            let (player, fixture) = try setup()
            fixture.changedVersion = true
            start(player)
            try await wait { !player.isLoadingQQQueue }
            try require(player.queue.count == 100 && player.qqQueueError != nil, "mixed account versions appended")
            player.stop()
            print("PASS session change rejects mixed source pages")
        }
        do {
            let (player, fixture) = try setup(hold: 100)
            start(player)
            try await wait { fixture.isHeld }
            player.shuffleEnabled = true
            let next = Task { await player.next() }
            await Task.yield()
            try require(player.currentQueueIndex == 0, "shuffle ran against a partial queue")
            fixture.release(offset: 100)
            await next.value
            try require(
                player.queue.count == 205 && player.currentQueueIndex != 0, "shuffle did not wait for all songs")
            player.stop()
            print("PASS shuffle uses the full collection")
        }
        do {
            let (player, fixture) = try setup(hold: 100)
            start(player)
            try await wait { fixture.isHeld }
            player.repeatMode = .all
            let previous = Task { await player.previous() }
            await Task.yield()
            fixture.release(offset: 100)
            await previous.value
            try require(player.currentQueueIndex == 204, "repeat wrapped to a partial queue end")
            player.stop()
            print("PASS repeat wraps across the entire collection")
        }
        do {
            let (player, fixture) = try setup(hold: 100)
            start(player)
            try await wait { fixture.isHeld }
            await player.playQueueItem(at: 99)
            let next = Task { await player.next() }
            await Task.yield()
            let local = LibraryTrack(id: "local", title: "local", album: "")
            await player.play(local, inQueue: [local, local])
            fixture.release(offset: 100)
            await next.value
            try require(
                player.currentQueueIndex == 0 && player.currentTrack?.id == "local",
                "stale next advanced a replacement queue")
            player.stop()
            print("PASS a pending boundary navigation cannot advance a replacement queue")
        }
        do {
            let (player, _) = try setup()
            start(player)
            try await wait { !player.isLoadingQQQueue }
            let tracks = player.queue.map {
                SourceTrack(id: $0.bindings[0].sourceTrackID, title: $0.title, album: $0.album)
            }
            await player.playQueueItem(at: 99)
            let notice = ChangeNotice()
            withObservationTracking {
                _ = player.currentQueueIndex
            } onChange: {
                notice.mark()
            }
            await player.playQueueItem(at: 100)
            try require(notice.value, "playing occurrence did not notify the list")
            try require(
                player.currentSourceRow(in: tracks, sourceID: "qq", kind: .favorites, playlistID: nil) == 100,
                "duplicate song highlighted the wrong occurrence")
            try require(
                player.currentSourceRow(
                    in: Array(tracks.prefix(100)), sourceID: "qq", kind: .favorites, playlistID: nil) == nil,
                "unloaded occurrence highlighted a different duplicate")
            try require(
                player.currentSourceQueueIndex(sourceID: "qq", kind: .favorites, playlistID: nil) == 100,
                "unloaded playing occurrence could not be located for follow pagination")
            try require(
                player.currentSourceQueueIndex(sourceID: "qq", kind: .playlist, playlistID: "other") == nil,
                "follow pagination crossed source collections")
            try require(
                player.currentSourceRow(in: tracks, sourceID: "other", kind: .favorites, playlistID: nil) == nil,
                "song identity crossed source connections")
            player.pause()
            try require(
                player.currentSourceRow(in: tracks, sourceID: "qq", kind: .favorites, playlistID: nil) == 100,
                "paused song lost its highlight")
            player.stop()
            try require(
                player.currentSourceRow(in: tracks, sourceID: "qq", kind: .favorites, playlistID: nil) == nil,
                "stopped queue retained a highlight")
            print("PASS playing row observes duplicate occurrences, source identity and pause")
        }
        do {
            let (player, fixture) = try setup(hold: 0)
            fixture.filteredIndex = 50
            start(player, at: 150, expected: "151")
            try await wait { fixture.isHeld }
            try require(player.currentTrack?.id == "151", "raw offset selected a different song")
            fixture.release(offset: 0)
            try await wait { !player.isLoadingQQQueue }
            try require(player.qqQueueError == nil, "filtered source page rejected a valid selected song")
            try require(
                player.queue.count == 205 && player.currentQueueIndex == 150,
                "filtered page shifted the selected occurrence")
            try require(player.queue[150].id == "151", "background fill overwrote selected occurrence")
            player.stop()
            print("PASS invalid upstream rows do not shift selection or duplicate occurrences")
        }
        try await sessionTests()
        try await personalRadioTests()
        try await playbackModeTests()
        print("Playback queue regression harness: 26/26 passed")
    }
}
