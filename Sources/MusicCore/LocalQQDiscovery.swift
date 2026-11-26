import Foundation

extension LocalQQMusicService {
    func discover(_ parameters: [String: String]) async throws -> SourceDiscovery {
        let mode = parameters["mode"] ?? "recommendations"
        let offset = max(0, Int(parameters["offset"] ?? "0") ?? 0)
        let limit = max(1, min(100, Int(parameters["limit"] ?? "20") ?? 20))
        let version = repository!.library.sessionVersion
        var result = SourceDiscovery(dateKey: nil, sessionVersion: nil, tracks: [], albums: [], playlists: [], charts: [],
                                     hotwords: [], suggestions: [], offset: offset, limit: limit, hasMore: false)
        switch mode {
        case "guess_like", "daily":
            let day = mode == "daily" ? QQRecommendationDay.key() : ""
            let key = cacheFile("discovery:\(version):\(mode):\(day):\(offset):\(limit)")
            if mode == "daily", let cached = try repository!.read(key, as: SourceDiscovery.self) { return cached }
            let response = try await qq("ipple/qq/recommendations", query: ["kind": mode, "offset": String(offset), "limit": String(limit)])
            if mode == "daily", response["date_key"].text != day || QQRecommendationDay.key() != day {
                throw failure(409, "VERSION_CONFLICT")
            }
            result.tracks = response["items"].list.map(LocalQQMapping.track).filter { !$0.id.isEmpty }
            result.dateKey = day.isEmpty ? nil : day
            result.sessionVersion = version
            result.hasMore = response["has_more"].flag
            try remember(result.tracks)
            if mode == "daily" { try repository!.write(result, to: key) }
        case "recommendations", "charts", "chart":
            let requestGeneration = generation
            let cache = cacheFile("discovery-home:\(version)")
            let response: JSONValue
            do { response = try await qq("getRecommend") }
            catch {
                guard requestGeneration == generation, !Task.isCancelled else { throw CancellationError() }
                if mode == "recommendations", (error as? MusicAPIError)?.status != 401,
                    let cached = try repository!.read(cache, as: SourceDiscovery.self) { return cached }
                throw error
            }
            result.charts = LocalQQMapping.charts(response)
            if mode == "chart" {
                guard let chart = result.charts.first(where: { $0.id == parameters["chart_id"] }) else { throw failure(404, "NOT_FOUND") }
                let ranks = try await qq("getRanks", query: ["topId": chart.id, "period": chart.period ?? "", "page": String(offset), "limit": String(limit)])
                result.tracks = ranks.at("req_1", "data", "songInfoList").list.map(LocalQQMapping.track).filter { !$0.id.isEmpty }
                result.charts = [chart]
                result.hasMore = offset + result.tracks.count < Int(chart.trackCount ?? 0) && result.tracks.count == limit
            } else if mode == "recommendations" {
                result.tracks = response.at("new_song", "data", "songlist").list.prefix(limit).map(LocalQQMapping.track).filter { !$0.id.isEmpty }
                result.albums = response.at("new_album", "data", "albums").list.map(LocalQQMapping.album).filter { !$0.id.isEmpty }
                result.playlists = response.at("recomPlaylist", "data", "v_hot").list.compactMap { row in
                    let id = row["content_id"].text
                    guard !id.isEmpty else { return nil }
                    return DiscoveryItem(id: id, title: row["title"].text, subtitle: row["username"].text, kind: "playlist",
                                         coverID: LocalQQMapping.imageID(row["cover"].text))
                }
                try repository!.write(result, to: cache)
            }
            try remember(result.tracks + result.albums.flatMap { $0.tracks ?? [] })
        case "hotwords":
            let response = try await qq("getHotkey")
            result.hotwords = response.at("data", "hotkey").list.map { $0["k"].text }.filter { !$0.isEmpty }
        case "suggestions":
            let term = parameters["q"] ?? ""
            guard !term.isEmpty else { return result }
            let response = try await qq("getSmartbox", query: ["key": term])
            for (section, kind) in [("song", "track"), ("album", "album"), ("singer", "artist")] {
                result.suggestions += response.at("data", section, "itemlist").list.compactMap { row in
                    guard !row["mid"].text.isEmpty else { return nil }
                    return DiscoveryItem(id: row["mid"].text, title: row["name"].text, subtitle: row["singer"].text,
                                         kind: kind, coverID: LocalQQMapping.imageID(row["pic"].text))
                }
            }
        default: throw failure(400, "UNSUPPORTED")
        }
        return result
    }

    func catalog(_ kind: String, parameters: [String: String]) async throws -> SourceCatalog {
        let offset = max(0, Int(parameters["offset"] ?? "0") ?? 0)
        let limit = max(1, min(100, Int(parameters["limit"] ?? "50") ?? 50))
        var result = SourceCatalog(tracks: [], albums: [], artists: [], playlists: [], offset: Int64(offset), limit: Int64(limit), hasMore: false)
        let page = offset / limit + 1
        if kind == "search" {
            let response = try await qq("getSearchByKey", query: ["key": parameters["q"] ?? "", "page": String(page), "limit": String(limit)])
            result.tracks = response.at("data", "song", "list").list.map(LocalQQMapping.track)
            result.hasMore = offset + result.tracks.count < Int(response.at("data", "song", "totalnum").integer)
        } else if kind == "albums" {
            let response = try await qq("getNewDisks", query: ["page": String(page), "limit": String(limit)])
            result.albums = response.at("new_album", "data", "albums").list.map(LocalQQMapping.album)
            result.hasMore = result.albums.count == limit
        } else if kind == "artists" {
            let response = try await qq("getSingerList", query: ["page": String(offset / 80 + 1), "limit": "80"])
            result.artists = response.at("singerList", "data", "singerlist").list.dropFirst(offset % 80).prefix(limit).map {
                SourceArtist(id: $0.first("singer_mid", "mid").text, name: $0.first("singer_name", "name").text)
            }
            result.hasMore = result.artists.count == limit
        } else if kind == "playlists" {
            let response = try await qq("getSongLists", query: ["page": String(page - 1), "limit": String(limit)])
            result.playlists = response.at("data", "list").list.map(LocalQQMapping.playlist)
            result.hasMore = result.playlists.count == limit
        }
        try remember(result.tracks)
        return result
    }
}
