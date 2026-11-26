import Foundation

extension MusicAPIClient {
    private func pagination(_ offset: Int, _ limit: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))]
    }

    public func libraryTracks(offset: Int = 0, limit: Int = 50) async throws -> LibraryTrackPage {
        try await request("GET", ["api", "v1", "library", "tracks"], query: pagination(offset, limit))
    }

    public func getLibraryTrack(id: String) async throws -> LibraryTrack {
        try await request("GET", ["api", "v1", "library", "tracks", id])
    }

    public func createLibraryTrack(_ input: LibraryTrackInput, idempotencyKey: String = UUID().uuidString) async throws
        -> LibraryTrack
    {
        try await request(
            "POST", ["api", "v1", "library", "tracks"], body: input, idempotencyKey: idempotencyKey)
    }

    public func updateLibraryTrack(id: String, patch: LibraryTrackPatch, idempotencyKey: String = UUID().uuidString)
        async throws -> LibraryTrack
    {
        try await request(
            "PATCH", ["api", "v1", "library", "tracks", id], body: patch, idempotencyKey: idempotencyKey)
    }

    public func deleteLibraryTrack(id: String, version: Int64, idempotencyKey: String = UUID().uuidString) async throws
    {
        let _: LibraryDeleted = try await request(
            "DELETE", ["api", "v1", "library", "tracks", id], query: [.init(name: "version", value: String(version))],
            idempotencyKey: idempotencyKey)
    }

    public func favorites(offset: Int = 0, limit: Int = 50) async throws -> LibraryTrackPage {
        try await request("GET", ["api", "v1", "favorites"], query: pagination(offset, limit))
    }

    public func setFavorite(trackID: String, enabled: Bool, idempotencyKey: String = UUID().uuidString) async throws {
        let _: LibraryFavoriteResult = try await request(
            enabled ? "PUT" : "DELETE", ["api", "v1", "favorites", trackID], idempotencyKey: idempotencyKey)
    }

    public func playlists(offset: Int = 0, limit: Int = 50) async throws -> LibraryPlaylistPage {
        try await request("GET", ["api", "v1", "playlists"], query: pagination(offset, limit))
    }

    public func getPlaylist(id: String) async throws -> LibraryPlaylist {
        try await request("GET", ["api", "v1", "playlists", id])
    }

    public func createPlaylist(name: String, description: String = "", idempotencyKey: String = UUID().uuidString)
        async throws -> LibraryPlaylist
    {
        try await request(
            "POST", ["api", "v1", "playlists"], body: PlaylistInput(name: name, description: description),
            idempotencyKey: idempotencyKey)
    }

    public func updatePlaylist(id: String, patch: PlaylistPatch, idempotencyKey: String = UUID().uuidString)
        async throws -> LibraryPlaylist
    {
        try await request("PATCH", ["api", "v1", "playlists", id], body: patch, idempotencyKey: idempotencyKey)
    }

    public func deletePlaylist(id: String, version: Int64, idempotencyKey: String = UUID().uuidString) async throws {
        let _: LibraryDeleted = try await request(
            "DELETE", ["api", "v1", "playlists", id], query: [.init(name: "version", value: String(version))],
            idempotencyKey: idempotencyKey)
    }

    public func addPlaylistEntry(
        playlistID: String, trackID: String, version: Int64, idempotencyKey: String = UUID().uuidString
    ) async throws -> LibraryPlaylist {
        try await request(
            "POST", ["api", "v1", "playlists", playlistID, "entries"],
            body: PlaylistAddEntry(version: version, trackID: trackID), idempotencyKey: idempotencyKey)
    }

    public func deletePlaylistEntry(
        playlistID: String, entryID: String, version: Int64, idempotencyKey: String = UUID().uuidString
    ) async throws -> LibraryPlaylist {
        try await request(
            "DELETE", ["api", "v1", "playlists", playlistID, "entries", entryID],
            query: [.init(name: "version", value: String(version))], idempotencyKey: idempotencyKey)
    }

    public func reorderPlaylistEntries(
        playlistID: String, entryIDs: [String], version: Int64, idempotencyKey: String = UUID().uuidString
    ) async throws -> LibraryPlaylist {
        try await request(
            "PUT", ["api", "v1", "playlists", playlistID, "entries", "order"],
            body: PlaylistReorder(version: version, entryIDs: entryIDs), idempotencyKey: idempotencyKey)
    }

    public func addHistory(
        trackID: String, positionMS: Int64, playedAt: Date? = nil, idempotencyKey: String = UUID().uuidString
    ) async throws -> PlayHistoryRecord {
        try await request(
            "POST", ["api", "v1", "play-history"],
            body: PlayHistoryInput(trackID: trackID, positionMS: positionMS, playedAt: playedAt),
            idempotencyKey: idempotencyKey)
    }

    public func playHistory(offset: Int = 0, limit: Int = 50) async throws -> PlayHistoryPage {
        try await request("GET", ["api", "v1", "play-history"], query: pagination(offset, limit))
    }

    public func playbackSnapshot() async throws -> PlaybackSnapshot {
        try await request("GET", ["api", "v1", "playback-snapshot"])
    }

    public func putPlaybackSnapshot(
        trackID: String?, positionMS: Int64, version: Int64, idempotencyKey: String = UUID().uuidString
    ) async throws -> PlaybackSnapshot {
        guard let trackID, !trackID.isEmpty else { throw MusicAPIError(status: 400, code: "INVALID_INPUT") }
        return try await request(
            "PUT", ["api", "v1", "playback-snapshot"],
            body: PlaybackSnapshotInput(trackID: trackID, positionMS: positionMS, version: version),
            idempotencyKey: idempotencyKey)
    }

    public func syncChanges(cursor: String? = nil, limit: Int = 100) async throws -> SyncChangesPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await request("GET", ["api", "v1", "sync", "changes"], query: query)
    }

    public func acknowledgeSync(cursor: String) async throws {
        let _: SyncAcknowledged = try await request(
            "POST", ["api", "v1", "sync", "ack"], body: SyncAckInput(cursor: cursor))
    }
}
