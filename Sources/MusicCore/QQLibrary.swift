import Foundation

public enum QQLibraryKind: String, Codable, Sendable { case playlists, favorites, playlist }

public struct QQPlaylistSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    public var trackCount: Int64
    public var coverID: String?
    enum CodingKeys: String, CodingKey {
        case id, name, kind, trackCount
        case coverID = "coverId"
    }
}

public struct QQLibraryPage: Codable, Sendable, Equatable {
    public var playlists: [QQPlaylistSummary]
    public var tracks: [SourceTrack]
    public var playlist: QQPlaylistSummary?
    public var offset: Int
    public var limit: Int
    public var total: Int64
    public var hasMore: Bool
    public var sessionVersion: Int64
}

public struct QQImportPageInput: Encodable, Sendable {
    public var kind: QQLibraryKind
    public var playlistID: String?
    public var offset: Int
    public var limit: Int
    public var sessionVersion: Int64
    public var selectedTrackID: String?
    public init(
        kind: QQLibraryKind, playlistID: String? = nil, offset: Int, limit: Int, sessionVersion: Int64,
        selectedTrackID: String? = nil
    ) {
        self.kind = kind
        self.playlistID = playlistID
        self.offset = offset
        self.limit = limit
        self.sessionVersion = sessionVersion
        self.selectedTrackID = selectedTrackID
    }
    enum CodingKeys: String, CodingKey {
        case kind, offset, limit, sessionVersion, selectedTrackID
        case playlistID = "playlistId"
    }
}


public struct QQFavoriteState: Codable, Sendable, Equatable {
    public var liked: [String: Bool]
    public var sessionVersion: Int64
}

struct QQFavoriteCheck: Encodable, Sendable { var ids: [String] }
struct QQFavoriteUpdate: Encodable, Sendable {
    var enabled: Bool
    var sessionVersion: Int64
}

public struct QQPlaybackPage: Decodable, Sendable {
    public var items: [LibraryTrack]
    public var offset: Int
    public var limit: Int
    public var total: Int64
    public var hasMore: Bool
    public var sessionVersion: Int64
}

/// Advances by the upstream window, preserving duplicate song occurrences and filtered rows.
public struct QQCollectionCursor: Codable, Sendable {
    public private(set) var nextOffset = 0
    public private(set) var total: Int64 = 0
    public private(set) var hasMore = true
    public private(set) var sessionVersion: Int64?
    public let limit: Int

    public init(limit: Int, sessionVersion: Int64? = nil) {
        self.limit = limit
        self.sessionVersion = sessionVersion
    }

    public mutating func accept(
        offset: Int, limit: Int, total: Int64, hasMore: Bool, sessionVersion: Int64, count: Int
    ) throws {
        guard self.hasMore, offset == nextOffset, limit == self.limit, (1...100).contains(limit),
            total >= 0, count >= 0, count <= limit, sessionVersion > 0,
            !hasMore || offset + limit <= 100_000
        else { throw MusicAPIError(status: 502, code: "SOURCE_UNAVAILABLE") }
        guard self.sessionVersion == nil || self.sessionVersion == sessionVersion,
            nextOffset == 0 || self.total == total
        else { throw MusicAPIError(status: 409, code: "VERSION_CONFLICT") }
        self.sessionVersion = sessionVersion
        self.total = total
        self.hasMore = hasMore
        nextOffset = offset + limit
    }
}

extension MusicAPIClient {
    public func qqFavoriteState(sourceID: String, ids: [String]) async throws -> QQFavoriteState {
        try await request(
            "POST", ["api", "v1", "sources", sourceID, "qq-favorites", "check"], body: QQFavoriteCheck(ids: ids)
        )
    }

    public func setQQFavorite(sourceID: String, trackID: String, enabled: Bool, sessionVersion: Int64) async throws
        -> QQFavoriteState
    {
        try await request(
            "PUT", ["api", "v1", "sources", sourceID, "qq-favorites", trackID],
            body: QQFavoriteUpdate(enabled: enabled, sessionVersion: sessionVersion))
    }

    public func qqLibrary(
        sourceID: String, kind: QQLibraryKind, playlistID: String? = nil, offset: Int = 0, limit: Int = 50
    ) async throws -> QQLibraryPage {
        var query: [URLQueryItem] = [
            .init(name: "kind", value: kind.rawValue), .init(name: "offset", value: String(offset)),
            .init(name: "limit", value: String(limit)),
        ]
        if let playlistID { query.append(.init(name: "playlist_id", value: playlistID)) }
        return try await request("GET", ["api", "v1", "sources", sourceID, "qq-library"], query: query)
    }
    public func importQQPage(sourceID: String, input: QQImportPageInput) async throws -> [LibraryTrack] {
        try await prepareQQPlaybackPage(sourceID: sourceID, input: input).items
    }

    public func prepareQQPlaybackPage(sourceID: String, input: QQImportPageInput) async throws -> QQPlaybackPage {
        try await request("POST", ["api", "v1", "sources", sourceID, "qq-library", "import"], body: input)
    }
}
