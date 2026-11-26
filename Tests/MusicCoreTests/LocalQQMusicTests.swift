import Foundation
import XCTest
@testable import MusicCore

private final class LocalQQTestCredentials: SessionCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredSessionCredential?
    func load(origin: String) throws -> StoredSessionCredential? { lock.withLock { value } }
    func save(_ credential: StoredSessionCredential, origin: String) throws { lock.withLock { value = credential } }
    func delete(origin: String) throws { lock.withLock { value = nil } }
}

private actor LocalQQFixture: QQMusicAPITransport {
    var requests: [QQMusicAPIRequest] = []
    var liked = false
    var offline = false
    private var heldPath: String?
    private var heldResponse: CheckedContinuation<Void, Never>?
    private var holdWaiter: CheckedContinuation<Void, Never>?
    func setOffline(_ value: Bool) { offline = value }
    func hold(_ path: String) { heldPath = path }
    func waitUntilHeld() async {
        if heldResponse != nil { return }
        await withCheckedContinuation { holdWaiter = $0 }
    }
    func release() {
        heldPath = nil
        heldResponse?.resume()
        heldResponse = nil
    }
    func send(_ request: QQMusicAPIRequest) async throws -> JSONValue {
        requests.append(request)
        if request.path == heldPath {
            await withCheckedContinuation {
                heldResponse = $0
                holdWaiter?.resume()
                holdWaiter = nil
            }
        }
        if offline { throw MusicAPIError(status: 0, code: "NETWORK_ERROR") }
        let id = request.cookie?.contains("67890") == true ? "67890" : "12345"
        switch request.path {
        case "ipple/qq/login":
            let account = request.body?["code"].text.hasPrefix("second") == true ? "67890" : "12345"
            return .object(["state": .string("connected"), "account_id": .string(account), "nickname": .string("Fixture"),
                            "avatar_url": .string("https://q1.qlogo.cn/avatar/\(account)"),
                            "cookie": .string("uin=\(account); qm_keyst=TEST-MUSIC-KEY"),
                            "expires_at": .string("2030-01-01T00:00:00Z")])
        case "ipple/qq/session":
            return .object(["state": .string("connected"), "account_id": .string(id), "nickname": .string("Fixture")])
        case "getSongInfo":
            return .object(["response": .object(["code": .integer(0), "songinfo": .object(["data": .object(["track_info": song(request.query["songmid"] ?? "song1")])])])])
        case "ipple/qq/similar-songs":
            guard request.query["songid"] == "5105986" else { throw MusicAPIError(status: 400, code: "INVALID_INPUT") }
            return .object(["items": .array([song("song1"), song("song2"), song("song2"), .null, song("song3")])])
        case "getMusicPlay":
            let mid = request.query["songmid"] ?? "song1"
            return .object(["response": .object(["code": .integer(0), "data": .object(["playUrl": .object([
                mid: .object(["url": .string("http://aqqmusic.tc.qq.com/fixture.mp3?vkey=short-lived")])])])])])
        case "getComments":
            guard request.query["id"] == "5105986", request.query["pagesize"] == "20" else {
                throw MusicAPIError(status: 400, code: "INVALID_INPUT")
            }
            let range = request.query["pagenum"] == "1" && request.query["rootcommentid"] == "root_20" ? 21...23 : 1...20
            let comments: [JSONValue] = range.map { index in
                var row: [String: JSONValue] = [
                    "rootcommentid": .string("root_\(index)"), "rootcommentcontent": .string("Comment \(index)"),
                    "nick": .string("Listener"), "time": .integer(1_700_000_000), "praisenum": .integer(5),
                ]
                if index == 1 { row["middlecommentcontent"] = .array([.object(["subcommentcontent": .string("Reply")])]) }
                if index == 2 {
                    row["rootcommentcontent"] = .string("")
                    row["pics"] = .array([.object(["url": .string("https://p.qpic.cn/comment.jpg")])])
                }
                return .object(row)
            }
            return .object(["response": .object(["code": .integer(0), "comment": .object([
                "commentlist": .array(comments), "commenttotal": .integer(23)])])])
        case "ipple/qq/favorites":
            if request.body?["action"].text == "set" {
                guard request.body?["track_id"].text == "song1" else { throw MusicAPIError(status: 400, code: "INVALID_INPUT") }
                liked = request.body?["enabled"].flag == true
            }
            return .object(["liked": .object(["song1": .bool(liked)])])
        case "ipple/qq/library", "ipple/qq/recommendations":
            let offset = Int(request.query["offset"] ?? "0") ?? 0
            let limit = Int(request.query["limit"] ?? "50") ?? 50
            let end = min(30, offset + limit)
            let tracks = offset < end ? (offset..<end).map { song("song\($0 + 1)") } : []
            var value: [String: JSONValue] = ["items": .array(tracks), "total": .integer(30), "has_more": .bool(end < 30)]
            if request.query["kind"] == "daily" { value["date_key"] = .string(QQRecommendationDay.key()) }
            return .object(value)
        case "getLyric":
            let word: JSONValue = .object(["text": .string("Hello"), "start_ms": .integer(1000), "duration_ms": .integer(1000)])
            let line: JSONValue = .object(["text": .string("Hello"), "start_ms": .integer(1000), "duration_ms": .integer(1000), "words": .array([word])])
            return .object(["response": .object([
                "lyric": .string("[00:01.00]Hello"), "trans": .string(Data("[00:01.00]你好".utf8).base64EncodedString()),
                "word_lines": .array([line])
            ])])
        default: throw MusicAPIError(status: 404, code: "UNEXPECTED_QQ_PATH")
        }
    }

    private func song(_ id: String) -> JSONValue {
        .object(["id": .integer(5105986), "mid": .string(id), "name": .string("Song \(id)"), "interval": .integer(120),
                 "album": .object(["name": .string("Album"), "mid": .string("album1")]),
                 "singer": .array([.object(["name": .string("Artist")])])])
    }
}

@MainActor
final class LocalQQMusicTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ipple-local-qq-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func client(_ root: URL, _ fixture: LocalQQFixture, _ credentials: LocalQQTestCredentials) -> MusicAPIClient {
        MusicAPIClient(localQQ: LocalQQMusicConfiguration(directory: root, credentials: credentials, transport: fixture) {
            throw MusicAPIError(status: 0, code: "SHOULD_NOT_CONTACT_HTTP_BACKEND")
        })
    }
    private func login(_ api: MusicAPIClient, second: Bool = false) async throws {
        let code = second ? "second-account-authorization" : "first-account-authorization"
        let candidate = try XCTUnwrap(QQSessionCandidate.authorizationCallback(from:
            URL(string: "https://y.qq.com/portal/wx_redirect.html?login_type=1&state=fixture-state&code=\(code)")!, expectedState: "fixture-state"))
        _ = try await api.loginQQ(candidate: candidate, clientDeviceID: UUID())
    }

    private func assertNoCredentialsOnDisk(_ root: URL) throws {
        for file in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! {
            guard let file = file as? URL, file.pathExtension == "json" else { continue }
            XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("TEST-MUSIC-KEY"))
        }
    }

    func testSimilarSongsUseNumericSongIDAndKeepUniqueResultsInOrder() async throws {
        let fixture = LocalQQFixture()
        let api = client(try directory(), fixture, LocalQQTestCredentials())
        try await login(api)
        let similar = try await api.qqSimilarSongs(sourceID: "qq", trackID: "song1")
        XCTAssertEqual(similar.map(\.id), ["song2", "song3"])
        let imported = try await api.importSourceTrack(connectionID: "qq", trackID: "song2")
        XCTAssertEqual(imported.title, "Song song2")
        let requests = await fixture.requests
        XCTAssertEqual(requests.filter { $0.path == "getSongInfo" }.map { $0.query["songmid"] }, ["song1"])
    }

    func testLibraryQueueHistoryAndCredentialsSurviveRestartLocally() async throws {
        let root = try directory(), fixture = LocalQQFixture(), credentials = LocalQQTestCredentials()
        let api = client(root, fixture, credentials)
        try await login(api)
        let track = try await api.importSourceTrack(connectionID: "qq", trackID: "song1")
        let playlist = try await api.createPlaylist(name: "Local playlist")
        _ = try await api.addPlaylistEntry(playlistID: playlist.id, trackID: track.id, version: playlist.version)
        _ = try await api.addHistory(trackID: track.id, positionMS: 2000)
        _ = try await api.putPlaybackSnapshot(trackID: track.id, positionMS: 2500, version: 0)
        let restored = client(root, fixture, credentials)
        let user = try await restored.restoreSession()
        XCTAssertEqual(user?.id, "qq:12345")
        let tracks = try await restored.libraryTracks(), lists = try await restored.playlists()
        let history = try await restored.playHistory(), snapshot = try await restored.playbackSnapshot()
        XCTAssertEqual(tracks.items.map(\.id), ["song1"])
        XCTAssertEqual(lists.items.first?.entries.first?.trackID, "song1")
        XCTAssertEqual(history.items.first?.trackID, "song1")
        XCTAssertEqual(snapshot.positionMS, 2500)
        try assertNoCredentialsOnDisk(root)
        let requests = await fixture.requests
        XCTAssertFalse(requests.contains { $0.path.hasPrefix("api/v1") })
    }

    func testErasingLocalLibraryMigratesLegacyFolderAndPreservesOtherAccount() async throws {
        let root = try directory(), fixture = LocalQQFixture(), credentials = LocalQQTestCredentials()
        let api = client(root, fixture, credentials)
        let legacy = root.appendingPathComponent("accounts/12345")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: legacy.appendingPathComponent("history.json"))
        try await login(api)
        let firstKey = try await api.localLibraryRemovalKey()
        let selected = root.appendingPathComponent("accounts/" + firstKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.appendingPathComponent("history.json").path))
        try await api.logout()
        try await login(api, second: true)
        let secondKey = try await api.localLibraryRemovalKey()
        try await api.logout()
        try await api.eraseLocalLibrary(key: firstKey)
        try await api.eraseLocalLibrary(key: firstKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("accounts/" + secondKey).path))
    }

    func testDailyPagingCachesAcrossClientRestart() async throws {
        let root = try directory(), fixture = LocalQQFixture(), credentials = LocalQQTestCredentials()
        let api = client(root, fixture, credentials)
        try await login(api)
        let daily = try await api.dailyRecommendations(id: "qq")
        XCTAssertEqual(daily.tracks.count, 30)
        let firstRequests = await fixture.requests.filter { $0.path == "ipple/qq/recommendations" }
        XCTAssertEqual(firstRequests.map { $0.query["limit"] }, ["3", "20", "20"])
        let restored = client(root, fixture, credentials)
        _ = try await restored.restoreSession()
        let cached = try await restored.dailyRecommendations(id: "qq")
        XCTAssertEqual(cached, daily)
        let after = await fixture.requests.filter { $0.path == "ipple/qq/recommendations" }
        XCTAssertEqual(after.count, 3)
    }

    func testFavoriteWritesAndMediaUseQQDependency() async throws {
        let root = try directory(), fixture = LocalQQFixture(), credentials = LocalQQTestCredentials()
        let api = client(root, fixture, credentials)
        try await login(api)
        let source = try await api.getSource(id: "qq")
        let state = try await api.setQQFavorite(sourceID: "qq", trackID: "song1", enabled: true, sessionVersion: source.version)
        XCTAssertEqual(state.liked["song1"], true)
        let checked = try await api.qqFavoriteState(sourceID: "qq", ids: ["song1"])
        XCTAssertEqual(checked.liked["song1"], true)
        XCTAssertEqual(checked.sessionVersion, source.version)
        let imported = try await api.importSourceTrack(connectionID: "qq", trackID: "song1")
        let resource = try await api.resolveLibraryTrack(id: imported.id)
        XCTAssertEqual(resource.url.scheme, "https")
        XCTAssertEqual(resource.url.host, "aqqmusic.tc.qq.com")
        XCTAssertTrue(resource.cookies.isEmpty)
        let lyrics = try await api.sourceLyrics(id: "qq", resourceID: "song1")
        XCTAssertEqual(lyrics.translation, "[00:01.00]你好")
        XCTAssertEqual(lyrics.lines?.first?.words.first?.text, "Hello")
    }

    func testCommentPagesUseNumericSongIDAndQQCursor() async throws {
        let root = try directory(), fixture = LocalQQFixture(), credentials = LocalQQTestCredentials()
        let api = client(root, fixture, credentials)
        try await login(api)
        let first = try await api.qqSongComments(sourceID: "qq", trackID: "song1")
        XCTAssertEqual(first.items.count, 20)
        XCTAssertEqual(first.total, 23)
        XCTAssertEqual(first.items.first?.text, "Comment 1")
        XCTAssertEqual(first.items[1].text, "")
        XCTAssertEqual(first.items[1].images?.first?.absoluteString, "https://p.qpic.cn/comment.jpg")
        XCTAssertEqual(first.items.first?.author, "Listener")
        XCTAssertEqual(first.items.first?.likeCount, 5)
        XCTAssertEqual(first.items.first?.postedAt, Date(timeIntervalSince1970: 1_700_000_000))
        let cursor = try XCTUnwrap(first.next)
        let second = try await api.qqSongComments(sourceID: "qq", trackID: "song1", after: cursor)
        XCTAssertEqual(second.items.map(\.id), ["root_21", "root_22", "root_23"])
        XCTAssertNil(second.next)
        XCTAssertEqual(second.total, 23)
        let requests = await fixture.requests.filter { $0.path == "getComments" }
        XCTAssertNil(requests.first?.query["pagenum"])
        XCTAssertTrue(requests.allSatisfy { $0.cookie?.contains("uin=12345") == true })
    }

    func testAvatarSurvivesLoginOfflineRestoreAndMissingSessionAvatar() async throws {
        let root = try directory(), fixture = LocalQQFixture(), credentials = LocalQQTestCredentials()
        let api = client(root, fixture, credentials)
        try await login(api)
        let session = try await api.qqSession(sourceID: "qq")
        XCTAssertEqual(session.avatarURL?.absoluteString, "https://q1.qlogo.cn/avatar/12345")
        await fixture.setOffline(true)
        let restored = try await client(root, fixture, credentials).restoreSession()
        XCTAssertEqual(restored?.avatarURL?.absoluteString, "https://q1.qlogo.cn/avatar/12345")
        let old = Data(#"{"accountId":"12345","nickname":"Old","cookie":"uin=12345; qm_keyst=fixture","expiresAt":"2030-01-01T00:00:00Z"}"#.utf8)
        XCTAssertNil(try MusicJSON.decoder().decode(LocalQQCredential.self, from: old).avatarURL)
    }

    func testAccountIsolationLogoutAndOfflineRestore() async throws {
        let root = try directory(), fixture = LocalQQFixture(), credentials = LocalQQTestCredentials()
        let api = client(root, fixture, credentials)
        try await login(api)
        _ = try await api.importSourceTrack(connectionID: "qq", trackID: "song1")
        await fixture.setOffline(true)
        let offline = client(root, fixture, credentials)
        let user = try await offline.restoreSession()
        XCTAssertEqual(user?.id, "qq:12345")
        let saved = try await offline.libraryTracks()
        XCTAssertEqual(saved.items.count, 1)
        await fixture.setOffline(false)
        try await login(api, second: true)
        let other = try await api.libraryTracks()
        XCTAssertTrue(other.items.isEmpty)
        try await api.logout()
        let loggedOut = client(root, fixture, credentials)
        let absent = try await loggedOut.restoreSession()
        XCTAssertNil(absent)
    }

    func testTypedLocalLibraryMutationsPreservePagingAndOptionalFields() async throws {
        let root = try directory(), fixture = LocalQQFixture(), credentials = LocalQQTestCredentials()
        let api = client(root, fixture, credentials)
        try await login(api)
        let first = try await api.createLibraryTrack(LibraryTrackInput(title: "First"))
        let second = try await api.createLibraryTrack(
            LibraryTrackInput(title: "Second", artists: ["Artist"], album: "Album", durationMS: 12_345))
        XCTAssertEqual(first.artists, [])
        XCTAssertEqual(first.album, "")
        XCTAssertEqual(first.durationMS, 0)
        let changed = try await api.updateLibraryTrack(id: second.id, patch: LibraryTrackPatch(title: "Updated"))
        XCTAssertEqual(changed.title, "Updated")
        XCTAssertEqual(changed.artists, ["Artist"])
        XCTAssertEqual(changed.album, "Album")
        XCTAssertEqual(changed.durationMS, 12_345)
        let page = try await api.libraryTracks(offset: 1, limit: 1)
        XCTAssertEqual(page.items.map(\.id), [second.id])
        XCTAssertEqual(page.offset, 1)
        XCTAssertFalse(page.hasMore)
        try await api.setFavorite(trackID: second.id, enabled: true)
        let favorites = try await api.favorites()
        XCTAssertEqual(favorites.items.map(\.id), [second.id])
        let playlist = try await api.createPlaylist(name: "Playlist", description: "Keep description")
        let withFirst = try await api.addPlaylistEntry(playlistID: playlist.id, trackID: first.id, version: playlist.version)
        let withBoth = try await api.addPlaylistEntry(playlistID: playlist.id, trackID: second.id, version: withFirst.version)
        let reversed = try await api.reorderPlaylistEntries(
            playlistID: playlist.id, entryIDs: withBoth.entries.reversed().map(\.id), version: withBoth.version)
        XCTAssertEqual(reversed.entries.map(\.trackID), [second.id, first.id])
        let renamed = try await api.updatePlaylist(id: playlist.id, patch: PlaylistPatch(name: "Renamed"))
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertEqual(renamed.description, "Keep description")
        let removed = try await api.deletePlaylistEntry(
            playlistID: playlist.id, entryID: reversed.entries[0].id, version: renamed.version)
        XCTAssertEqual(removed.entries.map(\.trackID), [first.id])
        try await api.deletePlaylist(id: playlist.id, version: removed.version)
        try await api.deleteLibraryTrack(id: first.id, version: first.version)
        let lists = try await api.playlists(), remaining = try await api.libraryTracks()
        XCTAssertTrue(lists.items.isEmpty)
        XCTAssertEqual(remaining.items.map(\.id), [second.id])
        try await api.acknowledgeSync(cursor: "0")

    }

    func testTypedQQImportSupportsBothPageConsumersAndRejectsStaleVersion() async throws {
        let api = client(try directory(), LocalQQFixture(), LocalQQTestCredentials())
        try await login(api)
        let source = try await api.getSource(id: "qq")
        let first = try await api.importQQPage(
            sourceID: "qq", input: QQImportPageInput(kind: .favorites, offset: 0, limit: 3, sessionVersion: source.version))
        XCTAssertEqual(first.map(\.id), ["song1", "song2", "song3"])
        let next = try await api.prepareQQPlaybackPage(
            sourceID: "qq", input: QQImportPageInput(kind: .favorites, offset: 3, limit: 3, sessionVersion: source.version))
        XCTAssertEqual(next.items.map(\.id), ["song4", "song5", "song6"])
        XCTAssertEqual(next.offset, 3)
        XCTAssertEqual(next.limit, 3)
        XCTAssertEqual(next.total, 30)
        XCTAssertEqual(next.sessionVersion, source.version)
        XCTAssertTrue(next.hasMore)
        do {
            _ = try await api.prepareQQPlaybackPage(
                sourceID: "qq", input: QQImportPageInput(kind: .favorites, offset: 6, limit: 3, sessionVersion: source.version + 1))
            XCTFail("Stale session must fail")
        } catch let error as MusicAPIError {
            XCTAssertEqual(error.code, "VERSION_CONFLICT")
        }
        let saved = try await api.libraryTracks()
        XCTAssertEqual(saved.items.count, 6)
    }

    func testTypedLocalRequestCannotReturnOldAccountDataAfterLogout() async throws {
        let fixture = LocalQQFixture()
        let api = client(try directory(), fixture, LocalQQTestCredentials())
        try await login(api)
        await fixture.hold("getSongInfo")
        let pending = Task { try await api.sourceTrack(id: "qq", resourceID: "song1") }
        await fixture.waitUntilHeld()
        try await api.logout()
        await fixture.release()
        do {
            _ = try await pending.value
            XCTFail("An old account response must not be returned")
        } catch is CancellationError {
        } catch let error as MusicAPIError {
            XCTAssertEqual(error.code, "CANCELLED")
        }
        try await login(api, second: true)
        let library = try await api.libraryTracks()
        XCTAssertTrue(library.items.isEmpty)
    }
}
