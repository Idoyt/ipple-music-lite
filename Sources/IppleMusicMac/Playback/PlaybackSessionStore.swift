import Foundation
import MusicCore
import OSLog

struct PlaybackQueueOrigin: Codable, Equatable, Sendable {
    var sourceID: String
    var kind: QQLibraryKind
    var playlistID: String?
}

struct PlaybackQueueContinuation: Codable, Sendable {
    var origin: PlaybackQueueOrigin
    var cursor: QQCollectionCursor
    var expectedTotal: Int64
    var importedCount: Int
}

struct PersonalRadioOrigin: Codable, Equatable, Sendable {
    var id = UUID()
    var sourceID: String
    var connectionVersion: Int64
    var sessionVersion: Int64
}

/// Metadata only: no media URL, Cookie, or AVPlayer resource is serialized.
struct PlaybackSession: Codable, Sendable {
    var formatVersion = 1
    var queue: [LibraryTrack]
    var keys: [UUID]
    var currentKey: UUID?
    var position: Double
    var duration: Double
    var repeatMode: String
    var shuffle: Bool
    var volume: Double
    var navigation: [UUID]
    var navigationIndex: Int
    var visited: Set<UUID>
    var origin: PlaybackQueueOrigin?
    var sourceOffsets: [Int?]?
    var sourceTotal: Int64
    var continuation: PlaybackQueueContinuation?
    var radio: PersonalRadioOrigin? = nil
    var quality: PlaybackQuality? = nil
    var nextTrackKey: UUID? = nil

    var isValid: Bool {
        let identities = Set(keys)
        guard formatVersion == 1, queue.count <= 100_000, queue.count == keys.count,
            identities.count == keys.count, currentKey == nil || identities.contains(currentKey!),
            nextTrackKey.map({ identities.contains($0) && $0 != currentKey }) ?? true,
            position.isFinite, position >= 0, duration.isFinite, duration >= 0,
            volume.isFinite, (0...1).contains(volume), ["off", "all", "one"].contains(repeatMode),
            navigation.count <= 256, navigation.allSatisfy(identities.contains), visited.isSubset(of: identities),
            (-1..<max(navigation.count, 0)).contains(navigationIndex)
        else { return false }
        if let radio {
            guard !radio.sourceID.isEmpty, radio.connectionVersion > 0, radio.sessionVersion > 0,
                origin == nil, continuation == nil, let currentKey,
                let index = keys.firstIndex(of: currentKey), index <= 10, queue.count - index - 1 <= 20
            else { return false }
        }
        if let origin {
            guard origin.kind != .playlists, let sourceOffsets, sourceOffsets.count == queue.count else { return false }
            let offsets = sourceOffsets.compactMap { $0 }
            guard !offsets.isEmpty,
                offsets == offsets.sorted(), Set(offsets).count == offsets.count,
                offsets.allSatisfy({ $0 >= 0 && Int64($0) < sourceTotal })
            else { return false }
        } else if sourceOffsets != nil || continuation != nil {
            return false
        }
        if let continuation {
            let cursor = continuation.cursor
            guard continuation.origin == origin, cursor.hasMore, cursor.limit == 100,
                cursor.sessionVersion.map({ $0 > 0 }) == true,
                (0...100_000).contains(cursor.nextOffset), cursor.nextOffset % cursor.limit == 0,
                cursor.nextOffset == 0 || cursor.total == continuation.expectedTotal,
                continuation.expectedTotal == sourceTotal, sourceTotal > 0,
                (0...cursor.nextOffset).contains(continuation.importedCount),
                continuation.importedCount <= queue.count
            else { return false }
        }
        return true
    }
}

/// One serial writer preserves checkpoint order and keeps JSON/file work off the UI thread.
final class PlaybackSessionStore: Sendable {
    private let directory: URL
    private let io = DispatchQueue(label: "local.ipplemusic.playback-session", qos: .utility)
    private let logger = Logger(subsystem: "local.ipplemusic.mac", category: "PlaybackSession")

    init(directory: URL) { self.directory = directory }

    func load(scope: PlaybackSessionScope) async -> PlaybackSession? {
        await withCheckedContinuation { continuation in
            io.async { [self] in
                let url = directory.appendingPathComponent(scope.key + ".json")
                guard let data = try? Data(contentsOf: url),
                    let session = try? JSONDecoder().decode(PlaybackSession.self, from: data), session.isValid
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: session)
            }
        }
    }

    func save(_ session: PlaybackSession, scope: PlaybackSessionScope) {
        io.async { [self] in
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent(scope.key + ".json")
                try JSONEncoder().encode(session).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                logger.error("Unable to save local playback session.")
            }
        }
    }

    func flush() { io.sync {} }
}
