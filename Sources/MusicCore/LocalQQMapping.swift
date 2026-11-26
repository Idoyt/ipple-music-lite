import Foundation

enum LocalQQMapping {
    static func track(_ value: JSONValue) -> SourceTrack {
        let album = value["album"]
        let cover = album.first("pmid", "mid", "albummid").text
        return SourceTrack(id: value.first("mid", "songmid").text,
                           title: value.first("title", "name", "songname").text,
                           artists: value["singer"].list.map { $0["name"].text }.filter { !$0.isEmpty },
                           album: album.first("name", "title").text.isEmpty ? value["albumname"].text : album.first("name", "title").text,
                           durationMS: value["interval"].integer * 1000,
                           coverID: cover.isEmpty ? value["albummid"].text : cover, isPlayable: playbackAllowed(value))
    }

    static func playbackAllowed(_ value: JSONValue) -> Bool {
        if value["disabled"].integer == 1 || value["disabled"] == .bool(true) { return false }
        let action = value["action"]
        // Paid flags do not describe this account's entitlement. Do not disable VIP songs on that basis.
        if value["pay"].first("pay_play", "payplay").integer > 0
            || value["pay"].first("pay_download", "paydownload").integer > 0 { return true }
        // A retained preview file is not permission to play the full song.
        // This player resolves full streams, not QQ trial clips.
        let decodedFlags = ["play_lq", "play_hq", "play_sq"].map { action[$0] }
        if decodedFlags.allSatisfy({ $0 != .null }) { return decodedFlags.contains { $0.integer > 0 } }
        let raw = action.first("switch", "switches") == .null
            ? value["switch"] : action.first("switch", "switches")
        let flags: Int64?
        switch raw {
        case .integer(let number): flags = number
        case .string(let string): flags = Int64(string)
        default: flags = nil
        }
        guard let flags, flags >= 0 else { return true }
        // QQ's low/standard/lossless playback permissions are bits 1 through 3.
        return flags & 0xE != 0
    }

    static func album(_ value: JSONValue) -> SourceAlbum {
        let id = value.first("mid", "album_mid", "albummid", "albumMid").text
        let artist = value.first("singername", "singer_name", "singerName").text
        return SourceAlbum(id: id, name: value.first("name", "title", "album_name", "albumname", "albumName").text,
                           artist: artist.isEmpty ? value["singers"].list.map { $0["name"].text }.joined(separator: ", ") : artist,
                           coverID: value["pmid"].text.isEmpty ? id : value["pmid"].text,
                           tracks: value.first("list", "songlist").list.map(track))
    }

    static func playlist(_ value: JSONValue) -> SourcePlaylist {
        SourcePlaylist(id: value.first("dissid", "disstid").text, name: value.first("dissname", "name").text,
                       tracks: value["songlist"].list.map(track))
    }

    static func imageID(_ value: String) -> String? {
        guard let url = imageURL(value) else { return nil }
        return "qq-image." + Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func imageURL(_ value: String) -> URL? {
        guard var parts = URLComponents(string: value), ["http", "https"].contains(parts.scheme ?? ""),
            ["y.gtimg.cn", "qpic.y.qq.com", "p.qpic.cn"].contains(parts.host ?? ""),
            parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
            value.utf8.count <= 1024
        else { return nil }
        parts.scheme = "https"
        return parts.url
    }

    static func coverURL(_ id: String) -> URL? {
        if id.hasPrefix("qq-image.") {
            var value = String(id.dropFirst(9)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            value += String(repeating: "=", count: (4 - value.count % 4) % 4)
            guard let data = Data(base64Encoded: value), let raw = String(data: data, encoding: .utf8) else { return nil }
            return imageURL(raw)
        }
        guard !id.isEmpty, id.count <= 128, id.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
        }) else { return nil }
        return URL(string: "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(id).jpg")
    }

    static func charts(_ body: JSONValue) -> [DiscoveryItem] {
        body.at("toplist", "data", "group").list.flatMap { $0["toplist"].list }.compactMap { value in
            guard !value["period"].text.isEmpty, value["topId"].text != "201" else { return nil }
            return DiscoveryItem(id: value["topId"].text, title: value["title"].text, subtitle: value["updateTime"].text,
                                 kind: "chart", coverID: imageID(value.first("frontPicUrl", "headPicUrl").text),
                                 period: value["period"].text, trackCount: value["totalNum"].integer)
        }
    }
}
