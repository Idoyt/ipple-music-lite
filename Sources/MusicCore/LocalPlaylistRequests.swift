import Foundation

extension LocalQQMusicService {
    func playlistRequest(_ method: String, path: [String], body: (any Sendable)?, offset: Int, limit: Int) throws -> any Sendable {
        if path.count == 1 {
            if method == "GET" {
                let playlists = repository!.library.playlists.values.sorted { $0.createdAt < $1.createdAt }
                return LibraryPlaylistPage(items: Array(playlists.dropFirst(offset).prefix(limit)), offset: Int64(offset),
                                                    limit: Int64(limit), hasMore: offset + limit < playlists.count)
            }
            let input: PlaylistInput = try self.input(body)
            let playlist = LibraryPlaylist(id: UUID().uuidString, name: input.name, description: input.description ?? "")
            repository!.library.playlists[playlist.id] = playlist
            try repository!.saveLibrary()
            return playlist
        }
        let id = path[1]
        guard var playlist = repository!.library.playlists[id] else { throw failure(404, "NOT_FOUND") }
        if method == "GET" { return playlist }
        if path.count == 2, method == "DELETE" {
            repository!.library.playlists.removeValue(forKey: id)
            try repository!.saveLibrary()
            return LibraryDeleted(deleted: true)
        }
        if path.count == 2, method == "PATCH" {
            let patch: PlaylistPatch = try self.input(body)
            if let name = patch.name { playlist.name = name }
            if let description = patch.description { playlist.description = description }
        } else if path.count == 3, method == "POST", path[2] == "entries" {
            let trackID = try input(body, as: PlaylistAddEntry.self).trackID
            guard repository!.library.tracks[trackID] != nil else { throw failure(404, "NOT_FOUND") }
            playlist.entries.append(PlaylistEntry(id: UUID().uuidString, trackID: trackID, position: Int64(playlist.entries.count)))
        } else if path.count == 4, method == "DELETE", path[2] == "entries" {
            playlist.entries.removeAll { $0.id == path[3] }
        } else if path.count == 4, path.last == "order" {
            let ids = try input(body, as: PlaylistReorder.self).entryIDs
            guard ids.count == playlist.entries.count, Set(ids) == Set(playlist.entries.map(\.id)) else { throw failure() }
            let entries = Dictionary(uniqueKeysWithValues: playlist.entries.map { ($0.id, $0) })
            playlist.entries = ids.compactMap { entries[$0] }
        } else { throw failure(400, "UNSUPPORTED") }
        for index in playlist.entries.indices { playlist.entries[index].position = Int64(index) }
        playlist.version += 1
        playlist.updatedAt = Date()
        repository!.library.playlists[id] = playlist
        try repository!.saveLibrary()
        return playlist
    }
}
