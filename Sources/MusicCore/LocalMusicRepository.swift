import CryptoKit
import Foundation

/// Account-scoped files contain metadata only. QQ credentials remain in Keychain.
struct LocalMusicLibrary: Codable {
    var tracks: [String: LibraryTrack] = [:]
    var favoriteIDs: Set<String> = []
    var playlists: [String: LibraryPlaylist] = [:]
    var revision: Int64 = 1
    var sessionVersion: Int64 = 1
    enum CodingKeys: String, CodingKey {
        case tracks, playlists, revision, sessionVersion
        case favoriteIDs = "favoriteIds"
    }
}

struct LocalQQCredential: Codable, Sendable {
    var accountID: String
    var nickname: String
    var avatarURL: URL? = nil
    var cookie: String
    var expiresAt: Date
    enum CodingKeys: String, CodingKey {
        case nickname, cookie, expiresAt
        case avatarURL = "avatarUrl"
        case accountID = "accountId"
    }
}

struct LocalMusicRepository {
    let directory: URL
    var library = LocalMusicLibrary()
    var history: [PlayHistoryRecord] = []
    var playback: PlaybackSnapshot?
    var metadata: [String: SourceTrack] = [:]

    init(root: URL, accountID: String) throws {
        guard !accountID.isEmpty, accountID.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw MusicAPIError(status: 0, code: "INVALID_RESPONSE")
        }
        let accounts = root.appendingPathComponent("accounts", isDirectory: true)
        let fm = FileManager.default
        let legacy = accounts.appendingPathComponent(accountID)
        directory = accounts.appendingPathComponent(Self.directoryKey(accountID), isDirectory: true)
        if fm.fileExists(atPath: legacy.path) {
            try fm.moveItem(at: legacy, to: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        library = try read("library.json", as: LocalMusicLibrary.self) ?? LocalMusicLibrary()
        history = try read("history.json", as: [PlayHistoryRecord].self) ?? []
        playback = try read("playback.json", as: PlaybackSnapshot.self)
        metadata = try read("catalog.json", as: [String: SourceTrack].self) ?? [:]
    }

    static func directoryKey(_ accountID: String) -> String {
        SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func read<Value: Decodable>(_ file: String, as: Value.Type) throws -> Value? {
        let url = directory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try MusicJSON.decoder().decode(Value.self, from: Data(contentsOf: url))
    }

    func write<Value: Encodable>(_ value: Value, to file: String) throws {
        let url = directory.appendingPathComponent(file)
        try MusicJSON.encoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    mutating func importTrack(_ track: SourceTrack) throws -> LibraryTrack {
        if let known = library.tracks[track.id] { return known }
        let result = LibraryTrack(
            id: track.id, title: track.title, artists: track.artists, album: track.album, durationMS: track.durationMS,
            bindings: [LibraryBinding(id: "qq:" + track.id, trackID: track.id, sourceConnectionID: "qq",
                                      sourceTrackID: track.id, confirmed: true, preferred: true)])
        library.tracks[track.id] = result
        metadata[track.id] = track
        return result
    }

    mutating func saveLibrary() throws {
        library.revision += 1
        try write(library, to: "library.json")
        try write(metadata, to: "catalog.json")
    }
}
