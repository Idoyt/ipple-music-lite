import Foundation

public enum SourceBrowseKind: String, Codable, Sendable, CaseIterable {
    case tracks, albums, artists, playlists
}

public struct SourceConnectionPage: Codable, Sendable, Equatable {
    public var items: [SourceConnection]
    public var offset: Int64
    public var limit: Int64
    public init(items: [SourceConnection] = [], offset: Int64 = 0, limit: Int64 = 50) {
        self.items = items
        self.offset = offset
        self.limit = limit
    }
}

/// Cookies are immutable snapshots from this client's private in-memory jar.
/// Pass them to AVURLAssetHTTPCookiesKey; never persist the resource or cookie values.
public struct MediaResource: @unchecked Sendable {
    public let url: URL
    public let cookies: [HTTPCookie]
    public let contentType: String
    public let canSeek: Bool
    public let expiresAt: Date?

}

struct TrackReference: Encodable, Sendable {
    let trackID: String
    enum CodingKeys: String, CodingKey { case trackID = "trackId" }
}

extension MusicAPIClient {
    public func sourcePage(offset: Int = 0, limit: Int = 50) async throws -> SourceConnectionPage {
        try await request(
            "GET", ["api", "v1", "sources"],
            query: [.init(name: "offset", value: String(offset)), .init(name: "limit", value: String(limit))])
    }

    public func sources(offset: Int = 0, limit: Int = 50) async throws -> [SourceConnection] {
        try await sourcePage(offset: offset, limit: limit).items
    }

    public func getSource(id: String) async throws -> SourceConnection {
        try await request("GET", ["api", "v1", "sources", id])
    }

    public func checkSource(id: String) async throws -> SourceConnection {
        try await request("POST", ["api", "v1", "sources", id, "check"])
    }
    public func sourceCapabilities(id: String) async throws -> SourceCapabilities {
        try await request("GET", ["api", "v1", "sources", id, "capabilities"])
    }

    public func searchSource(id: String, query: String, offset: Int = 0, limit: Int = 50) async throws -> SourceCatalog
    {
        try await request(
            "GET", ["api", "v1", "sources", id, "search"],
            query: [
                .init(name: "q", value: query), .init(name: "offset", value: String(offset)),
                .init(name: "limit", value: String(limit)),
            ])
    }

    public func browseSource(id: String, kind: SourceBrowseKind, offset: Int = 0, limit: Int = 50) async throws
        -> SourceCatalog
    {
        try await request(
            "GET", ["api", "v1", "sources", id, kind.rawValue],
            query: [.init(name: "offset", value: String(offset)), .init(name: "limit", value: String(limit))])
    }

    public func sourceTrack(id: String, resourceID: String) async throws -> SourceTrack {
        try await request("GET", ["api", "v1", "sources", id, "tracks", resourceID])
    }
    public func qqSimilarSongs(sourceID: String, trackID: String) async throws -> [SourceTrack] {
        try await request("GET", ["api", "v1", "sources", sourceID, "qq-similar-songs", trackID])
    }
    public func sourceAlbum(id: String, resourceID: String) async throws -> SourceAlbum {
        try await request("GET", ["api", "v1", "sources", id, "albums", resourceID])
    }
    public func sourceArtist(id: String, resourceID: String) async throws -> SourceArtist {
        try await request("GET", ["api", "v1", "sources", id, "artists", resourceID])
    }
    public func sourcePlaylist(id: String, resourceID: String) async throws -> SourcePlaylist {
        try await request("GET", ["api", "v1", "sources", id, "playlists", resourceID])
    }
    public func sourceLyrics(id: String, resourceID: String) async throws -> SourceLyrics {
        try await request("GET", ["api", "v1", "sources", id, "lyrics", resourceID])
    }

    public func importSourceTrack(connectionID: String, trackID: String) async throws -> LibraryTrack {
        try await request(
            "POST", ["api", "v1", "sources", connectionID, "import-track"],
            body: TrackReference(trackID: trackID))
    }

    public func resolveSourceTrack(connectionID: String, trackID: String, quality: String = "original") async throws
        -> MediaResource
    {
        let playback: SourcePlayback = try await request(
            "POST", ["api", "v1", "sources", connectionID, "resolve"],
            body: SourceResolveInput(trackID: trackID, quality: quality))
        return try mediaResource(from: playback)
    }

    public func resolveLibraryTrack(id: String, quality: String = "original") async throws -> MediaResource {
        let playback: SourcePlayback = try await request(
            "POST", ["api", "v1", "library", "tracks", id, "resolve"], query: [.init(name: "quality", value: quality)])
        return try mediaResource(from: playback)
    }

    public func coverData(id: String, coverID: String, trackID: String? = nil, quality: String? = nil) async throws
        -> Data
    {
        var query = [URLQueryItem]()
        if let trackID { query.append(.init(name: "track_id", value: trackID)) }
        if let quality { query.append(.init(name: "quality", value: quality)) }
        return try await request("GET", ["api", "v1", "sources", id, "cover", coverID], query: query)
    }
}
