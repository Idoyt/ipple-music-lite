import Foundation

/// In-process application data. Only QQ operations cross into the bundled Rain120 dependency.
actor LocalQQMusicService {
    let configuration: LocalQQMusicConfiguration
    let gateway: QQMusicGateway
    var credential: LocalQQCredential?
    var repository: LocalMusicRepository?
    var generation = 0
    var dailyPages: [String: SourceDiscovery] = [:]
    let credentialOrigin = "qq-music-local"

    init(configuration: LocalQQMusicConfiguration) {
        self.configuration = configuration
        gateway = QQMusicGateway(endpoint: configuration.endpoint, transport: configuration.transport)
    }

    /// Local requests carry the same DTOs as HTTP requests without serializing them.
    func input<Value: Sendable>(_ body: (any Sendable)?, as type: Value.Type = Value.self) throws -> Value {
        guard let value = body as? Value else { throw failure() }
        return value
    }
    func failure(_ status: Int = 400, _ code: String = "INVALID_INPUT") -> MusicAPIError {
        MusicAPIError(status: status, code: code)
    }
    func requireAccount() throws -> LocalQQCredential {
        guard let credential, repository != nil else { throw failure(401, "QQ_LOGIN_REQUIRED") }
        return credential
    }
    func accountAvatarURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil,
              ["qq.com", "qlogo.cn", "qpic.cn"].contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return nil }
        return url
    }
    func user(_ credential: LocalQQCredential) -> User {
        User(displayName: credential.nickname, id: "qq:" + credential.accountID, role: "user",
             username: credential.accountID, avatarURL: credential.avatarURL)
    }
    func source() throws -> SourceConnection {
        let account = try requireAccount()
        return SourceConnection(id: "qq", ownerID: "qq:" + account.accountID, name: "QQ 音乐", kind: "qq",
                                baseURL: "local:qq-music-api", enabled: true, state: "active",
                                version: repository!.library.sessionVersion)
    }

    func qq(_ path: String, method: String = "GET", query: [String: String] = [:], body: JSONValue? = nil) async throws -> JSONValue {
        let ticket = generation
        let result = try await gateway.call(path, method: method, query: query, body: body, cookie: credential?.cookie)
        guard ticket == generation, !Task.isCancelled else { throw CancellationError() }
        return result
    }

    func restore() async throws -> User? {
        guard let stored = try configuration.credentials.load(origin: credentialOrigin) else { return nil }
        let saved = try MusicJSON.decoder().decode(LocalQQCredential.self, from: Data(stored.value.utf8))
        generation += 1
        let ticket = generation
        credential = saved
        repository = try LocalMusicRepository(root: configuration.directory, accountID: saved.accountID)
        do {
            let status = try await qq("ipple/qq/session")
            guard ticket == generation else { throw CancellationError() }
            guard status["state"].text == "connected", status["account_id"].text == saved.accountID else {
                throw failure(401, "QQ_LOGIN_REQUIRED")
            }
            credential?.nickname = status["nickname"].text.isEmpty ? saved.nickname : status["nickname"].text
            credential?.avatarURL = accountAvatarURL(status["avatar_url"].text) ?? saved.avatarURL
            return user(credential!)
        } catch let error as MusicAPIError where error.status == 401 {
            try logout()
            return nil
        } catch {
            // A temporary connection failure does not erase the locally saved QQ session.
            if let error = error as? MusicAPIError, ["NETWORK_ERROR", "SOURCE_UNAVAILABLE"].contains(error.code) {
                return user(saved)
            }
            throw error
        }
    }

    func login(_ input: QQLoginRequest) async throws -> AuthResponse {
        generation += 1
        let ticket = generation
        let result = try await gateway.call("ipple/qq/login", method: "POST", body: .object(["code": .string(input.code)]))
        guard ticket == generation, !Task.isCancelled else { throw CancellationError() }
        let id = result["account_id"].text
        let cookie = result["cookie"].text
        guard result["state"].text == "connected", (5...20).contains(id.count),
            id.utf8.allSatisfy({ (48...57).contains($0) }), !cookie.isEmpty,
            cookie.utf8.count <= 8192, !cookie.contains("\r"), !cookie.contains("\n")
        else { throw failure(401, "QQ_LOGIN_REQUIRED") }
        let expires = ISO8601DateFormatter().date(from: result["expires_at"].text) ?? Date().addingTimeInterval(24 * 3600)
        let saved = LocalQQCredential(accountID: id, nickname: result["nickname"].text,
                                      avatarURL: accountAvatarURL(result["avatar_url"].text), cookie: cookie, expiresAt: expires)
        let serialized = String(decoding: try MusicJSON.encoder().encode(saved), as: UTF8.self)
        try configuration.credentials.save(
            StoredSessionCredential(name: "qq-music", value: serialized, expiresAt: expires, secure: true), origin: credentialOrigin)
        credential = saved
        repository = try LocalMusicRepository(root: configuration.directory, accountID: id)
        repository!.library.sessionVersion += 1
        try repository!.saveLibrary()
        dailyPages.removeAll()
        return AuthResponse(expiresAt: expires, user: user(saved))
    }

    func logout() throws {
        generation += 1
        credential = nil
        repository = nil
        dailyPages.removeAll()
        try configuration.credentials.delete(origin: credentialOrigin)
    }

    func request(_ method: String, segments: [String], query: [URLQueryItem], body: (any Sendable)?) async throws -> any Sendable {
        guard segments.prefix(2) == ["api", "v1"] else { throw failure(404, "NOT_FOUND") }
        let path = Array(segments.dropFirst(2))
        let parameters = Dictionary(query.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, value in value })
        let offset = max(0, Int(parameters["offset"] ?? "0") ?? 0)
        let limit = max(1, min(100, Int(parameters["limit"] ?? "50") ?? 50))
        if path == ["auth", "qq"] { return try await login(input(body)) }
        if path == ["auth", "logout"] { try logout(); return EmptyResponse() }
        _ = try requireAccount()
        if path == ["sources"] { return try SourceConnectionPage(items: offset == 0 ? [source()] : [], offset: Int64(offset), limit: Int64(limit)) }
        if path.first == "sources", path.count >= 2 {
            guard path[1] == "qq" else { throw failure(404, "NOT_FOUND") }
            if path.count == 2 || path.count == 3 && path.last == "check" { return try source() }
            return try await sourceRequest(method, path: Array(path.dropFirst(2)), parameters: parameters, body: body)
        }
        if path == ["sync", "ack"] { return SyncAcknowledged(acknowledged: true) }
        if path == ["sync", "changes"] {
            let revision = repository!.library.revision
            let changed = parameters["cursor"].flatMap(Int64.init).map { $0 < revision } ?? false
            let changes: [SyncChange] = changed ? [SyncChange(version: revision, kind: "track", resourceID: "local", operation: "updated", payload: .null)] : []
            return SyncChangesPage(changes: changes, nextCursor: String(revision), currentVersion: revision)
        }
        if path == ["library", "tracks"] {
            if method == "GET" {
                let tracks = repository!.library.tracks.values.sorted { $0.createdAt < $1.createdAt }
                return LibraryTrackPage(items: Array(tracks.dropFirst(offset).prefix(limit)), offset: Int64(offset), limit: Int64(limit), hasMore: offset + limit < tracks.count)
            }
            let input: LibraryTrackInput = try self.input(body)
            let track = LibraryTrack(id: UUID().uuidString, title: input.title, artists: input.artists ?? [],
                                     album: input.album ?? "", durationMS: input.durationMS ?? 0)
            repository!.library.tracks[track.id] = track
            try repository!.saveLibrary()
            return track
        }
        if path.starts(with: ["library", "tracks"]), path.count >= 3 {
            let id = path[2]
            guard var track = repository!.library.tracks[id] else { throw failure(404, "NOT_FOUND") }
            if path.last == "resolve" { return try await resolve(track.bindings.first?.sourceTrackID ?? id, quality: parameters["quality"]) }
            if method == "DELETE" {
                repository!.library.tracks.removeValue(forKey: id)
                repository!.library.favoriteIDs.remove(id)
                try repository!.saveLibrary()
                return LibraryDeleted(deleted: true)
            }
            if method == "PATCH" {
                let patch: LibraryTrackPatch = try self.input(body)
                if let title = patch.title { track.title = title }
                if let album = patch.album { track.album = album }
                if let artists = patch.artists { track.artists = artists }
                track.version += 1
                track.updatedAt = Date()
                repository!.library.tracks[id] = track
                try repository!.saveLibrary()
            }
            return track
        }
        if path.first == "favorites" {
            if path.count == 2 {
                if method == "PUT" { repository!.library.favoriteIDs.insert(path[1]) }
                else { repository!.library.favoriteIDs.remove(path[1]) }
                try repository!.saveLibrary()
                return LibraryFavoriteResult(favorite: method == "PUT")
            }
            let tracks = repository!.library.favoriteIDs.compactMap { repository!.library.tracks[$0] }.sorted { $0.id < $1.id }
            return LibraryTrackPage(items: Array(tracks.dropFirst(offset).prefix(limit)), offset: Int64(offset), limit: Int64(limit), hasMore: offset + limit < tracks.count)
        }
        if path == ["play-history"] {
            if method == "POST" {
                let input: PlayHistoryInput = try self.input(body)
                let record = PlayHistoryRecord(id: UUID().uuidString, trackID: input.trackID, positionMS: input.positionMS)
                repository!.history.insert(record, at: 0)
                repository!.history = Array(repository!.history.prefix(5000))
                try repository!.write(repository!.history, to: "history.json")
                try repository!.saveLibrary()
                return record
            }
            let records = repository!.history
            return PlayHistoryPage(items: Array(records.dropFirst(offset).prefix(limit)), offset: Int64(offset), limit: Int64(limit), hasMore: offset + limit < records.count)
        }
        if path == ["playback-snapshot"] {
            if method == "PUT" {
                let input: PlaybackSnapshotInput = try self.input(body)
                let snapshot = PlaybackSnapshot(trackID: input.trackID, positionMS: input.positionMS,
                                                version: (repository!.playback?.version ?? 0) + 1)
                repository!.playback = snapshot
                try repository!.write(snapshot, to: "playback.json")
                return snapshot
            }
            guard let playback = repository!.playback else { throw failure(404, "NOT_FOUND") }
            return playback
        }
        if path.first == "playlists" { return try playlistRequest(method, path: path, body: body, offset: offset, limit: limit) }
        throw failure(400, "UNSUPPORTED")
    }
}
