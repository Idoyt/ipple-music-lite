import Foundation

public struct AuthResponse: Codable, Sendable, Equatable {
    public var expiresAt: Date
    public var user: User

    public init(expiresAt: Date, user: User) {
        self.expiresAt = expiresAt
        self.user = user
    }
}

public struct User: Codable, Sendable, Equatable, Identifiable {
    public var createdAt: Date
    public var displayName: String
    public var id: String
    public var role: String
    public var updatedAt: Date
    public var avatarURL: URL?
    public var username: String

    public init(
        createdAt: Date = Date(), displayName: String, id: String, role: String, updatedAt: Date = Date(),
        username: String, avatarURL: URL? = nil
    ) {
        self.createdAt = createdAt
        self.displayName = displayName
        self.id = id
        self.role = role
        self.updatedAt = updatedAt
        self.avatarURL = avatarURL
        self.username = username
    }

    enum CodingKeys: String, CodingKey {
        case createdAt
        case displayName
        case id
        case role
        case updatedAt
        case username
        case avatarURL = "avatarUrl"
    }
}

public struct LibraryError: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var requestID: String

    public init(code: String, message: String, requestID: String) {
        self.code = code
        self.message = message
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case requestID = "requestId"
    }
}

public struct LibraryTrackInput: Codable, Sendable, Equatable {
    public var title: String
    public var artists: [String]?
    public var album: String?
    public var durationMS: Int64?

    public init(title: String, artists: [String]? = nil, album: String? = nil, durationMS: Int64? = nil) {
        self.title = title
        self.artists = artists
        self.album = album
        self.durationMS = durationMS
    }

    enum CodingKeys: String, CodingKey {
        case title
        case artists
        case album
        case durationMS = "durationMs"
    }
}

public struct LibraryBinding: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var trackID: String
    public var sourceConnectionID: String
    public var sourceTrackID: String
    public var confirmed: Bool
    public var preferred: Bool

    public init(
        id: String, trackID: String, sourceConnectionID: String, sourceTrackID: String, confirmed: Bool = false,
        preferred: Bool = false
    ) {
        self.id = id
        self.trackID = trackID
        self.sourceConnectionID = sourceConnectionID
        self.sourceTrackID = sourceTrackID
        self.confirmed = confirmed
        self.preferred = preferred
    }

    enum CodingKeys: String, CodingKey {
        case id
        case trackID = "trackId"
        case sourceConnectionID = "sourceConnectionId"
        case sourceTrackID = "sourceTrackId"
        case confirmed
        case preferred
    }
}

public struct LibraryTrack: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var artists: [String]
    public var album: String
    public var durationMS: Int64
    public var version: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var bindings: [LibraryBinding]

    public init(
        id: String, title: String, artists: [String] = [], album: String, durationMS: Int64 = 0, version: Int64 = 1,
        createdAt: Date = Date(), updatedAt: Date = Date(), bindings: [LibraryBinding] = []
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.durationMS = durationMS
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.bindings = bindings
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.title = try values.decode(String.self, forKey: .title)
        self.artists = try values.decodeIfPresent([String].self, forKey: .artists) ?? []
        self.album = try values.decode(String.self, forKey: .album)
        self.durationMS = try values.decode(Int64.self, forKey: .durationMS)
        self.version = try values.decode(Int64.self, forKey: .version)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        self.bindings = try values.decodeIfPresent([LibraryBinding].self, forKey: .bindings) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artists
        case album
        case durationMS = "durationMs"
        case version
        case createdAt
        case updatedAt
        case bindings
    }
}

public struct LibraryTrackPatch: Codable, Sendable, Equatable {
    public var version: Int64
    public var title: String?
    public var artists: [String]?
    public var album: String?
    public var durationMS: Int64?

    public init(
        version: Int64 = 1, title: String? = nil, artists: [String]? = nil, album: String? = nil,
        durationMS: Int64? = nil
    ) {
        self.version = version
        self.title = title
        self.artists = artists
        self.album = album
        self.durationMS = durationMS
    }

    enum CodingKeys: String, CodingKey {
        case version
        case title
        case artists
        case album
        case durationMS = "durationMs"
    }
}

public struct PlaylistInput: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case name
        case description
    }
}

public struct PlaylistEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var trackID: String
    public var position: Int64
    public var createdAt: Date

    public init(id: String, trackID: String, position: Int64 = 0, createdAt: Date = Date()) {
        self.id = id
        self.trackID = trackID
        self.position = position
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case trackID = "trackId"
        case position
        case createdAt
    }
}

public struct LibraryPlaylist: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var version: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var entries: [PlaylistEntry]

    public init(
        id: String, name: String, description: String, version: Int64 = 1, createdAt: Date = Date(),
        updatedAt: Date = Date(), entries: [PlaylistEntry] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.entries = entries
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.name = try values.decode(String.self, forKey: .name)
        self.description = try values.decode(String.self, forKey: .description)
        self.version = try values.decode(Int64.self, forKey: .version)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        self.entries = try values.decodeIfPresent([PlaylistEntry].self, forKey: .entries) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case version
        case createdAt
        case updatedAt
        case entries
    }
}

public struct PlaylistPatch: Codable, Sendable, Equatable {
    public var version: Int64
    public var name: String?
    public var description: String?

    public init(version: Int64 = 1, name: String? = nil, description: String? = nil) {
        self.version = version
        self.name = name
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case version
        case name
        case description
    }
}

public struct PlaylistAddEntry: Codable, Sendable, Equatable {
    public var version: Int64
    public var trackID: String

    public init(version: Int64 = 1, trackID: String) {
        self.version = version
        self.trackID = trackID
    }

    enum CodingKeys: String, CodingKey {
        case version
        case trackID = "trackId"
    }
}

public struct PlaylistReorder: Codable, Sendable, Equatable {
    public var version: Int64
    public var entryIDs: [String]

    public init(version: Int64 = 1, entryIDs: [String] = []) {
        self.version = version
        self.entryIDs = entryIDs
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try values.decode(Int64.self, forKey: .version)
        self.entryIDs = try values.decodeIfPresent([String].self, forKey: .entryIDs) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case version
        case entryIDs = "entryIds"
    }
}

public struct PlayHistoryInput: Codable, Sendable, Equatable {
    public var trackID: String
    public var positionMS: Int64
    public var playedAt: Date?

    public init(trackID: String, positionMS: Int64 = 0, playedAt: Date? = nil) {
        self.trackID = trackID
        self.positionMS = positionMS
        self.playedAt = playedAt
    }

    enum CodingKeys: String, CodingKey {
        case trackID = "trackId"
        case positionMS = "positionMs"
        case playedAt
    }
}

public struct PlayHistoryRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var trackID: String
    public var positionMS: Int64
    public var playedAt: Date

    public init(id: String, trackID: String, positionMS: Int64 = 0, playedAt: Date = Date()) {
        self.id = id
        self.trackID = trackID
        self.positionMS = positionMS
        self.playedAt = playedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case trackID = "trackId"
        case positionMS = "positionMs"
        case playedAt
    }
}

public struct PlaybackSnapshotInput: Codable, Sendable, Equatable {
    public var trackID: String
    public var positionMS: Int64
    public var version: Int64

    public init(trackID: String, positionMS: Int64 = 0, version: Int64 = 1) {
        self.trackID = trackID
        self.positionMS = positionMS
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case trackID = "trackId"
        case positionMS = "positionMs"
        case version
    }
}

public struct PlaybackSnapshot: Codable, Sendable, Equatable {
    public var trackID: String
    public var positionMS: Int64
    public var version: Int64
    public var updatedAt: Date

    public init(trackID: String, positionMS: Int64 = 0, version: Int64 = 1, updatedAt: Date = Date()) {
        self.trackID = trackID
        self.positionMS = positionMS
        self.version = version
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case trackID = "trackId"
        case positionMS = "positionMs"
        case version
        case updatedAt
    }
}

public struct LibraryTrackPage: Codable, Sendable, Equatable {
    public var items: [LibraryTrack]
    public var offset: Int64
    public var limit: Int64
    public var hasMore: Bool

    public init(items: [LibraryTrack] = [], offset: Int64 = 0, limit: Int64 = 0, hasMore: Bool = false) {
        self.items = items
        self.offset = offset
        self.limit = limit
        self.hasMore = hasMore
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.items = try values.decodeIfPresent([LibraryTrack].self, forKey: .items) ?? []
        self.offset = try values.decode(Int64.self, forKey: .offset)
        self.limit = try values.decode(Int64.self, forKey: .limit)
        self.hasMore = try values.decode(Bool.self, forKey: .hasMore)
    }

    enum CodingKeys: String, CodingKey {
        case items
        case offset
        case limit
        case hasMore
    }
}

public struct LibraryPlaylistPage: Codable, Sendable, Equatable {
    public var items: [LibraryPlaylist]
    public var offset: Int64
    public var limit: Int64
    public var hasMore: Bool

    public init(items: [LibraryPlaylist] = [], offset: Int64 = 0, limit: Int64 = 0, hasMore: Bool = false) {
        self.items = items
        self.offset = offset
        self.limit = limit
        self.hasMore = hasMore
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.items = try values.decodeIfPresent([LibraryPlaylist].self, forKey: .items) ?? []
        self.offset = try values.decode(Int64.self, forKey: .offset)
        self.limit = try values.decode(Int64.self, forKey: .limit)
        self.hasMore = try values.decode(Bool.self, forKey: .hasMore)
    }

    enum CodingKeys: String, CodingKey {
        case items
        case offset
        case limit
        case hasMore
    }
}

public struct PlayHistoryPage: Codable, Sendable, Equatable {
    public var items: [PlayHistoryRecord]
    public var offset: Int64
    public var limit: Int64
    public var hasMore: Bool

    public init(items: [PlayHistoryRecord] = [], offset: Int64 = 0, limit: Int64 = 0, hasMore: Bool = false) {
        self.items = items
        self.offset = offset
        self.limit = limit
        self.hasMore = hasMore
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.items = try values.decodeIfPresent([PlayHistoryRecord].self, forKey: .items) ?? []
        self.offset = try values.decode(Int64.self, forKey: .offset)
        self.limit = try values.decode(Int64.self, forKey: .limit)
        self.hasMore = try values.decode(Bool.self, forKey: .hasMore)
    }

    enum CodingKeys: String, CodingKey {
        case items
        case offset
        case limit
        case hasMore
    }
}

public struct LibraryDeleted: Codable, Sendable, Equatable {
    public var deleted: Bool

    public init(deleted: Bool = false) {
        self.deleted = deleted
    }

    enum CodingKeys: String, CodingKey {
        case deleted
    }
}

public struct LibraryFavoriteResult: Codable, Sendable, Equatable {
    public var favorite: Bool

    public init(favorite: Bool = false) {
        self.favorite = favorite
    }

    enum CodingKeys: String, CodingKey {
        case favorite
    }
}

public struct SyncChange: Codable, Sendable, Equatable {
    public var version: Int64
    public var kind: String
    public var resourceID: String
    public var operation: String
    public var payload: JSONValue
    public var createdAt: Date

    public init(
        version: Int64 = 1, kind: String, resourceID: String, operation: String, payload: JSONValue,
        createdAt: Date = Date()
    ) {
        self.version = version
        self.kind = kind
        self.resourceID = resourceID
        self.operation = operation
        self.payload = payload
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case version
        case kind
        case resourceID = "resourceId"
        case operation
        case payload
        case createdAt
    }
}

public struct SyncChangesPage: Codable, Sendable, Equatable {
    public var changes: [SyncChange]
    public var nextCursor: String
    public var currentVersion: Int64
    public var hasMore: Bool
    public var resetRequired: Bool

    public init(
        changes: [SyncChange] = [], nextCursor: String, currentVersion: Int64 = 0, hasMore: Bool = false,
        resetRequired: Bool = false
    ) {
        self.changes = changes
        self.nextCursor = nextCursor
        self.currentVersion = currentVersion
        self.hasMore = hasMore
        self.resetRequired = resetRequired
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.changes = try values.decodeIfPresent([SyncChange].self, forKey: .changes) ?? []
        self.nextCursor = try values.decode(String.self, forKey: .nextCursor)
        self.currentVersion = try values.decode(Int64.self, forKey: .currentVersion)
        self.hasMore = try values.decode(Bool.self, forKey: .hasMore)
        self.resetRequired = try values.decode(Bool.self, forKey: .resetRequired)
    }

    enum CodingKeys: String, CodingKey {
        case changes
        case nextCursor
        case currentVersion
        case hasMore
        case resetRequired
    }
}

public struct SyncResetError: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var requestID: String
    public var resetRequired: Bool
    public var currentVersion: Int64
    public var nextCursor: String

    public init(
        code: String, message: String, requestID: String, resetRequired: Bool = false, currentVersion: Int64 = 0,
        nextCursor: String
    ) {
        self.code = code
        self.message = message
        self.requestID = requestID
        self.resetRequired = resetRequired
        self.currentVersion = currentVersion
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case requestID = "requestId"
        case resetRequired
        case currentVersion
        case nextCursor
    }
}

public struct SyncAckInput: Codable, Sendable, Equatable {
    public var cursor: String

    public init(cursor: String) {
        self.cursor = cursor
    }

    enum CodingKeys: String, CodingKey {
        case cursor
    }
}

public struct SyncAcknowledged: Codable, Sendable, Equatable {
    public var acknowledged: Bool

    public init(acknowledged: Bool = false) {
        self.acknowledged = acknowledged
    }

    enum CodingKeys: String, CodingKey {
        case acknowledged
    }
}

public struct SourceConnection: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var ownerID: String
    public var name: String
    public var kind: String
    public var baseURL: String
    public var enabled: Bool
    public var state: String
    public var version: Int64
    public var lastErrorCode: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String, ownerID: String, name: String, kind: String, baseURL: String, enabled: Bool = false, state: String,
        version: Int64 = 1, lastErrorCode: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.enabled = enabled
        self.state = state
        self.version = version
        self.lastErrorCode = lastErrorCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "ownerId"
        case name
        case kind
        case baseURL = "baseUrl"
        case enabled
        case state
        case version
        case lastErrorCode
        case createdAt
        case updatedAt
        case deletedAt
    }
}

public struct SourceTrack: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var artists: [String]
    public var album: String
    public var durationMS: Int64
    public var coverID: String?
    public var isPlayable: Bool

    public init(
        id: String, title: String, artists: [String] = [], album: String, durationMS: Int64 = 0, coverID: String? = nil, isPlayable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.durationMS = durationMS
        self.coverID = coverID
        self.isPlayable = isPlayable
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.title = try values.decode(String.self, forKey: .title)
        self.artists = try values.decodeIfPresent([String].self, forKey: .artists) ?? []
        self.album = try values.decode(String.self, forKey: .album)
        self.durationMS = try values.decode(Int64.self, forKey: .durationMS)
        self.coverID = try values.decodeIfPresent(String.self, forKey: .coverID)
        self.isPlayable = try values.decodeIfPresent(Bool.self, forKey: .isPlayable) ?? true
    }

    enum CodingKeys: String, CodingKey {
        case isPlayable
        case id
        case title
        case artists
        case album
        case durationMS = "durationMs"
        case coverID = "coverId"
    }
}

public struct SourceCapabilities: Codable, Sendable, Equatable {
    public var search: Bool
    public var browse: Bool
    public var lyrics: Bool
    public var download: Bool
    public var transcoding: Bool
    public var playlistRead: Bool
    public var playlistWrite: Bool
    public var protocolName: String

    public init(
        search: Bool = false, browse: Bool = false, lyrics: Bool = false, download: Bool = false,
        transcoding: Bool = false, playlistRead: Bool = false, playlistWrite: Bool = false, protocolName: String
    ) {
        self.search = search
        self.browse = browse
        self.lyrics = lyrics
        self.download = download
        self.transcoding = transcoding
        self.playlistRead = playlistRead
        self.playlistWrite = playlistWrite
        self.protocolName = protocolName
    }

    enum CodingKeys: String, CodingKey {
        case search
        case browse
        case lyrics
        case download
        case transcoding
        case playlistRead
        case playlistWrite
        case protocolName = "protocol"
    }
}

public struct SourceLyricWord: Codable, Sendable, Equatable {
    public var text: String
    public var startMS: Int64
    public var durationMS: Int64

    public init(text: String, startMS: Int64, durationMS: Int64) {
        self.text = text
        self.startMS = startMS
        self.durationMS = durationMS
    }
    enum CodingKeys: String, CodingKey {
        case text
        case startMS = "startMs"
        case durationMS = "durationMs"
    }
}

public struct SourceLyricLine: Codable, Sendable, Equatable {
    public var text: String
    public var startMS: Int64
    public var durationMS: Int64
    public var words: [SourceLyricWord]

    public init(text: String, startMS: Int64, durationMS: Int64, words: [SourceLyricWord]) {
        self.text = text
        self.startMS = startMS
        self.durationMS = durationMS
        self.words = words
    }
    enum CodingKeys: String, CodingKey {
        case text, words
        case startMS = "startMs"
        case durationMS = "durationMs"
    }
}

public struct SourceLyrics: Codable, Sendable, Equatable {
    public var trackID: String
    public var text: String
    public var contentType: String
    public var translation: String?
    public var lines: [SourceLyricLine]?

    public init(
        trackID: String, text: String, contentType: String, translation: String? = nil, lines: [SourceLyricLine]? = nil
    ) {
        self.trackID = trackID
        self.text = text
        self.contentType = contentType
        self.translation = translation
        self.lines = lines
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try values.decode(String.self, forKey: .trackID)
        text = try values.decode(String.self, forKey: .text)
        contentType = try values.decode(String.self, forKey: .contentType)
        translation = try values.decodeIfPresent(String.self, forKey: .translation)
        // Optional word timing must never hide otherwise valid line lyrics.
        lines = try? values.decodeIfPresent([SourceLyricLine].self, forKey: .lines)
    }

    enum CodingKeys: String, CodingKey {
        case trackID = "trackId"
        case text, contentType, translation, lines
    }
}

public struct SourceResolveInput: Codable, Sendable, Equatable {
    public var trackID: String
    public var quality: String?

    public init(trackID: String, quality: String? = nil) {
        self.trackID = trackID
        self.quality = quality
    }

    enum CodingKeys: String, CodingKey {
        case trackID = "trackId"
        case quality
    }
}

public struct SourcePlayback: Codable, Sendable, Equatable {
    public var connectionID: String
    public var sourceTrackID: String
    public var streamURL: String
    public var expiresAt: Date
    public var contentType: String
    public var canSeek: Bool

    public init(
        connectionID: String, sourceTrackID: String, streamURL: String, expiresAt: Date = Date(), contentType: String,
        canSeek: Bool = false
    ) {
        self.connectionID = connectionID
        self.sourceTrackID = sourceTrackID
        self.streamURL = streamURL
        self.expiresAt = expiresAt
        self.contentType = contentType
        self.canSeek = canSeek
    }

    enum CodingKeys: String, CodingKey {
        case connectionID = "connectionId"
        case sourceTrackID = "sourceTrackId"
        case streamURL = "streamUrl"
        case expiresAt
        case contentType
        case canSeek
    }
}

public struct SourceAlbum: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String?
    public var title: String?
    public var artist: String?
    public var coverID: String?
    public var tracks: [SourceTrack]?

    public init(
        id: String, name: String? = nil, title: String? = nil, artist: String? = nil, coverID: String? = nil,
        tracks: [SourceTrack]? = nil
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.artist = artist
        self.coverID = coverID
        self.tracks = tracks
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case artist
        case coverID = "coverId"
        case tracks
    }
}

public struct SourceArtist: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var albums: [SourceAlbum]?

    public init(id: String, name: String, albums: [SourceAlbum]? = nil) {
        self.id = id
        self.name = name
        self.albums = albums
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case albums
    }
}

public struct SourcePlaylist: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String?
    public var title: String?
    public var tracks: [SourceTrack]

    public init(id: String, name: String? = nil, title: String? = nil, tracks: [SourceTrack] = []) {
        self.id = id
        self.name = name
        self.title = title
        self.tracks = tracks
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.name = try values.decodeIfPresent(String.self, forKey: .name)
        self.title = try values.decodeIfPresent(String.self, forKey: .title)
        self.tracks = try values.decodeIfPresent([SourceTrack].self, forKey: .tracks) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case tracks
    }
}

public struct SourceCatalog: Codable, Sendable, Equatable {
    public var tracks: [SourceTrack]
    public var albums: [SourceAlbum]
    public var artists: [SourceArtist]
    public var playlists: [SourcePlaylist]
    public var offset: Int64
    public var limit: Int64
    public var hasMore: Bool

    public init(
        tracks: [SourceTrack] = [], albums: [SourceAlbum] = [], artists: [SourceArtist] = [],
        playlists: [SourcePlaylist] = [], offset: Int64 = 0, limit: Int64 = 0, hasMore: Bool = false
    ) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.offset = offset
        self.limit = limit
        self.hasMore = hasMore
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.tracks = try values.decodeIfPresent([SourceTrack].self, forKey: .tracks) ?? []
        self.albums = try values.decodeIfPresent([SourceAlbum].self, forKey: .albums) ?? []
        self.artists = try values.decodeIfPresent([SourceArtist].self, forKey: .artists) ?? []
        self.playlists = try values.decodeIfPresent([SourcePlaylist].self, forKey: .playlists) ?? []
        self.offset = try values.decode(Int64.self, forKey: .offset)
        self.limit = try values.decode(Int64.self, forKey: .limit)
        self.hasMore = try values.decode(Bool.self, forKey: .hasMore)
    }

    enum CodingKeys: String, CodingKey {
        case tracks
        case albums
        case artists
        case playlists
        case offset
        case limit
        case hasMore
    }
}
