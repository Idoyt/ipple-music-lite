import CryptoKit
import Foundation

extension LocalQQMusicService {
    func cacheFile(_ key: String) -> String {
        "qq-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    func remember(_ tracks: [SourceTrack]) throws {
        guard repository != nil else { return }
        for track in tracks where !track.id.isEmpty { repository!.metadata[track.id] = track }
        try repository!.write(repository!.metadata, to: "catalog.json")
    }

    func track(_ id: String) async throws -> SourceTrack {
        if let cached = repository?.metadata[id] { return cached }
        let result = try await qq("getSongInfo", query: ["songmid": id])
        let track = LocalQQMapping.track(result.at("songinfo", "data", "track_info"))
        guard !track.id.isEmpty else { throw failure(404, "NOT_FOUND") }
        try remember([track])
        return track
    }

    func numericSongID(_ mid: String) async throws -> Int64 {
        let info = try await qq("getSongInfo", query: ["songmid": mid])
        let songID = info.at("songinfo", "data", "track_info").first("id", "songid").integer
        guard songID > 0 else { throw failure(404, "NOT_FOUND") }
        return songID
    }

    func similarSongs(_ mid: String) async throws -> [SourceTrack] {
        let songID = try await numericSongID(mid)
        let result = try await qq("ipple/qq/similar-songs", query: ["songid": String(songID)])
        var seen = Set([mid])
        let tracks = result["items"].list.map(LocalQQMapping.track).filter {
            !$0.id.isEmpty && !$0.title.isEmpty && seen.insert($0.id).inserted
        }
        if !tracks.isEmpty { try remember(tracks) }
        return tracks
    }

    func resolve(_ id: String, quality: String?) async throws -> SourcePlayback {
        let quality = switch quality {
        case nil, "", "original": "128"
        case let value?: value
        }
        guard ["128", "320", "m4a", "ape", "flac"].contains(quality) else { throw failure(400, "UNSUPPORTED") }
        let response = try await qq("getMusicPlay", query: ["songmid": id, "quality": quality])
        let raw = response.at("data", "playUrl")[id]["url"].text
        guard var parts = URLComponents(string: raw),
            ["http", "https"].contains(parts.scheme ?? ""), parts.host == "aqqmusic.tc.qq.com",
            parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil
        else { throw failure(422, "NO_PLAYBACK") }
        parts.scheme = "https"
        return SourcePlayback(connectionID: "qq", sourceTrackID: id, streamURL: parts.url!.absoluteString,
                              expiresAt: Date().addingTimeInterval(3600),
                              contentType: quality == "flac" ? "audio/flac" : quality == "m4a" ? "audio/mp4" : "audio/mpeg",
                              canSeek: true)
    }

    func collection(_ parameters: [String: String]) async throws -> QQLibraryPage {
        let kind = parameters["kind"] ?? "favorites"
        let offset = max(0, Int(parameters["offset"] ?? "0") ?? 0)
        let limit = max(1, min(100, Int(parameters["limit"] ?? "50") ?? 50))
        let version = repository!.library.sessionVersion
        let requestGeneration = generation
        let key = cacheFile("collection:\(version):\(kind):\(parameters["playlist_id"] ?? ""):\(offset):\(limit)")
        let result: JSONValue
        do { result = try await qq("ipple/qq/library", query: parameters) }
        catch {
            guard requestGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            if (error as? MusicAPIError)?.status != 401,
                let cached = try repository!.read(key, as: QQLibraryPage.self) { return cached }
            throw error
        }
        var page = QQLibraryPage(playlists: [], tracks: [], playlist: nil, offset: offset, limit: limit,
                                 total: result["total"].integer, hasMore: result["has_more"].flag, sessionVersion: version)
        if kind == "playlists" {
            page.playlists = result["items"].list.compactMap { value in
                let liked = value.first("dirId", "dirid").integer == 201
                let id = liked ? "liked" : value.first("tid", "dissid", "disstid", "id").text
                guard !id.isEmpty else { return nil }
                return QQPlaylistSummary(id: id, name: value.first("dirName", "diss_name", "dissname", "name", "title").text,
                                         kind: liked ? "favorites" : "created", trackCount: value.first("songNum", "song_cnt", "songnum", "total_song_num", "song_count").integer,
                                         coverID: LocalQQMapping.imageID(value.first("picUrl", "picurl", "diss_cover", "logo", "cover").text))
            }
        } else {
            page.tracks = result["items"].list.map(LocalQQMapping.track).filter { !$0.id.isEmpty }
            let value = result["playlist"]
            page.playlist = QQPlaylistSummary(id: kind == "favorites" ? "201" : parameters["playlist_id"] ?? "",
                                              name: kind == "favorites" ? "喜欢的歌曲" : value.first("title", "dissname", "name").text,
                                              kind: kind, trackCount: page.total,
                                              coverID: LocalQQMapping.imageID(value.first("picurl", "cover").text))
            try remember(page.tracks)
        }
        try repository!.write(page, to: key)
        return page
    }

    func sourceRequest(_ method: String, path: [String], parameters: [String: String], body: (any Sendable)?) async throws -> any Sendable {
        if path == ["capabilities"] {
            return SourceCapabilities(search: true, browse: true, lyrics: true, playlistRead: true,
                                               protocolName: "rain120/qq-music-api;local")
        }
        if path == ["qq-session"] {
            let status = try await qq("ipple/qq/session")
            return QQSessionStatus(state: status["state"].text, loginAvailable: true,
                                           accountID: status["account_id"].text, nickname: status["nickname"].text,
                                           expiresAt: credential?.expiresAt,
                                           avatarURL: accountAvatarURL(status["avatar_url"].text) ?? credential?.avatarURL)
        }
        if path == ["qq-library"] { return try await collection(parameters) }
        if path == ["qq-library", "import"] {
            let input: QQImportPageInput = try self.input(body)
            let requestedVersion = input.sessionVersion
            guard requestedVersion == repository!.library.sessionVersion else { throw failure(409, "VERSION_CONFLICT") }
            let parameters = ["kind": input.kind.rawValue, "playlist_id": input.playlistID ?? "",
                              "offset": String(input.offset), "limit": String(input.limit)]
            let page = try await collection(parameters)
            var imported: [LibraryTrack] = []
            for track in page.tracks { imported.append(try repository!.importTrack(track)) }
            try repository!.saveLibrary()
            return QQPlaybackPage(items: imported, offset: page.offset, limit: page.limit, total: page.total,
                                   hasMore: page.hasMore, sessionVersion: page.sessionVersion)
        }
        if path.first == "qq-favorites" {
            let payload: JSONValue
            if path.last == "check" {
                let input: QQFavoriteCheck = try self.input(body)
                payload = .object(["action": .string("check"), "ids": .array(input.ids.map(JSONValue.string))])
            } else {
                let input: QQFavoriteUpdate = try self.input(body)
                guard input.sessionVersion == repository!.library.sessionVersion,
                    let id = path.last else { throw failure(409, "VERSION_CONFLICT") }
                payload = .object(["action": .string("set"), "track_id": .string(id), "enabled": .bool(input.enabled)])
            }
            let result = try await qq("ipple/qq/favorites", method: "POST", body: payload)
            let states = result["liked"].dictionary.mapValues(\.flag)
            var changed = false
            for (id, liked) in states {
                changed = changed || repository!.library.favoriteIDs.contains(id) != liked
                if liked { repository!.library.favoriteIDs.insert(id) }
                else { repository!.library.favoriteIDs.remove(id) }
            }
            if changed { try repository!.saveLibrary() }
            return QQFavoriteState(liked: states, sessionVersion: repository!.library.sessionVersion)
        }
        if path.count == 2, path[0] == "qq-comments", method == "GET" {
            return try await songComments(path[1], parameters: parameters)
        }
        if path.count == 2, path[0] == "qq-similar-songs", method == "GET" {
            return try await similarSongs(path[1])
        }
        if path == ["discovery"] { return try await discover(parameters) }
        if path == ["search"] || path == ["tracks"] || path == ["albums"] || path == ["artists"] || path == ["playlists"] {
            return try await catalog(path[0], parameters: parameters)
        }
        if path == ["import-track"] {
            let value = try await track(input(body, as: TrackReference.self).trackID)
            let imported = try repository!.importTrack(value)
            try repository!.saveLibrary()
            return imported
        }
        if path == ["resolve"] {
            let input: SourceResolveInput = try self.input(body)
            return try await resolve(input.trackID, quality: input.quality)
        }
        if path.count == 2, path[0] == "tracks" { return try await track(path[1]) }
        if path.count == 2, path[0] == "albums" {
            let result = try await qq("getAlbumInfo", query: ["albummid": path[1]])
            let album = LocalQQMapping.album(result["data"])
            try remember(album.tracks ?? [])
            return album
        }
        if path.count == 2, path[0] == "artists" {
            let result = try await qq("getSingerAlbum", query: ["singermid": path[1], "limit": "100", "page": "0"])
            let value = result.at("singer", "data")
            return SourceArtist(id: path[1], name: value.first("singer_name", "singername").text,
                                         albums: value["albumList"].list.map(LocalQQMapping.album))
        }
        if path.count == 2, path[0] == "playlists" {
            let result = try await qq("getSongListDetail", query: ["disstid": path[1]])
            guard let first = result["cdlist"].list.first else { throw failure(404, "NOT_FOUND") }
            let playlist = LocalQQMapping.playlist(first)
            try remember(playlist.tracks)
            return playlist
        }
        if path.count == 2, path[0] == "lyrics" {
            let result = try await qq("getLyric", query: ["songmid": path[1]])
            guard ["code", "retcode"].allSatisfy({ result[$0] == .null || result[$0].text == "0" }),
                case .string(let lyric) = result["lyric"]
            else { throw failure(502, "SOURCE_UNAVAILABLE") }
            var translation = result["trans"].text
            if let bytes = Data(base64Encoded: translation), let decoded = String(data: bytes, encoding: .utf8) { translation = decoded }
            translation = translation.replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
            let lines = try? MusicJSON.decoder().decode([SourceLyricLine].self, from: JSONEncoder().encode(result["word_lines"]))
            return SourceLyrics(trackID: path[1], text: lyric, contentType: "application/x-lrc",
                                         translation: translation == "//" || translation.isEmpty ? nil : translation, lines: lines)
        }
        if path.count == 2, path[0] == "cover" {
            guard let url = LocalQQMapping.coverURL(path[1]) else { throw failure() }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let ticket = generation
            let (data, response) = try await session.data(from: url)
            guard ticket == generation else { throw CancellationError() }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                response.url.flatMap({ LocalQQMapping.imageURL($0.absoluteString) }) != nil,
                data.count <= 20 * 1024 * 1024 else { throw failure(502, "SOURCE_UNAVAILABLE") }
            return data
        }
        throw failure(400, "UNSUPPORTED")
    }
}
