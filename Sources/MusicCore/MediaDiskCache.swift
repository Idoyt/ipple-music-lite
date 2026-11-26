import CryptoKit
import Foundation
import ImageIO

public enum MediaCacheKind: String, Sendable, CaseIterable { case cover, lyrics, audio }

private final class MediaCacheEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    var value: Int { lock.withLock { revision } }
    func advance() { lock.withLock { revision += 1 } }
}

/// One disk budget and one LRU for covers, complete lyrics and bounded audio segments.
public actor MediaDiskCache {
    public static let bytesPerMegabyte: Int64 = 1_048_576
    public static let defaultBytes: Int64 = 5 * 1_073_741_824
    public static let maximumBytes: Int64 = 1_099_511_627_776
    public struct Statistics: Sendable {
        public let usedBytes: Int64
        public let limitBytes: Int64
        public let count: Int
        public let coverBytes: Int64
        public let lyricsBytes: Int64
        public let audioBytes: Int64
    }
    private struct Configuration: Codable {
        var version = 3
        var limitBytes: Int64
    }
    private struct Entry {
        var kind: MediaCacheKind
        var size: Int64
        var accessed: Date
    }
    private struct Flight {
        var id = UUID()
        var task: Task<Data, any Error>
    }
    private let directory: URL
    private let legacyDirectory: URL?
    private var entries: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    private var limitBytes = defaultBytes
    private var usedBytes: Int64 = 0
    private var loaded = false
    private var revision = 0
    private nonisolated let epoch = MediaCacheEpoch()
    public nonisolated func token() -> Int { epoch.value }

    public init(directory: URL, legacyDirectory: URL? = nil) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
    }

    public func statistics() throws -> Statistics {
        try load()
        func bytes(_ kind: MediaCacheKind) -> Int64 {
            entries.values.filter { $0.kind == kind }.reduce(0) { $0 + $1.size }
        }
        return Statistics(
            usedBytes: usedBytes, limitBytes: limitBytes, count: entries.count,
            coverBytes: bytes(.cover), lyricsBytes: bytes(.lyrics), audioBytes: bytes(.audio))
    }
    public func setLimit(bytes: Int64) throws {
        guard (0...Self.maximumBytes).contains(bytes) else {
            throw MusicAPIError(status: 0, code: "INVALID_CACHE_LIMIT")
        }
        try load()
        try JSONEncoder().encode(Configuration(limitBytes: bytes)).write(
            to: directory.appendingPathComponent("config.json"), options: .atomic)
        limitBytes = bytes
        cancelPending()
        try trim(to: bytes)
    }
    public func clear() throws {
        try load()
        cancelPending()
        for key in Array(entries.keys) { try remove(key) }
    }
    public nonisolated static func ownerKey(server: String, account: String) -> String {
        SHA256.hash(data: Data((server + "\u{0}" + account).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func clear(owner: String) throws {
        guard owner.count == 64, owner.allSatisfy(\.isHexDigit) else { throw MusicAPIError(status: 400, code: "INVALID_INPUT") }
        try load()
        cancelPending()
        // Pre-ownership cache files cannot be attributed after logout. The confirmation explains their removal.
        for key in Array(entries.keys) where !key.contains("-") || key.hasPrefix(owner + "-") {
            try remove(key)
        }
    }

    private func cancelPending() {
        revision += 1
        epoch.advance()
        for value in flights.values { value.task.cancel() }
        flights = [:]
    }

    public func data(
        kind: MediaCacheKind = .cover, namespace: [String], replacing: Bool = false, token: Int? = nil,
        load loader: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        if let token, token != revision { throw CancellationError() }
        do { try load() } catch { return try await loader() }
        let key = try key(kind, namespace)
        if !replacing, let data = try? read(key, kind: kind) { return data }
        if let flight = flights[key] {
            if !replacing, !flight.task.isCancelled {
                if kind == .audio {
                    return try await withTaskCancellationHandler {
                        try await flight.task.value
                    } onCancel: {
                        flight.task.cancel()
                    }
                }
                return try await flight.task.value
            }
            flight.task.cancel()
        }
        let expected = revision
        let flight = Flight(task: Task { try await loader() })
        flights[key] = flight
        do {
            let data: Data
            if kind == .audio {
                data = try await withTaskCancellationHandler {
                    try await flight.task.value
                } onCancel: {
                    flight.task.cancel()
                }
            } else {
                data = try await flight.task.value
            }
            let ownsFlight = flights[key]?.id == flight.id
            if ownsFlight { flights[key] = nil }
            if ownsFlight, revision == expected, !flight.task.isCancelled, valid(data, kind: kind) {
                try? insert(data, key: key, kind: kind)
            }
            return data
        } catch {
            if flights[key]?.id == flight.id { flights[key] = nil }
            throw error
        }
    }

    public func audioSegments(namespace: [String]) throws -> [AudioCacheSegment] {
        try load()
        return try [AudioCacheSlot.prefix, .interrupted].compactMap { slot in
            let key = try key(.audio, namespace + [slot.rawValue])
            // Decode/validate the bounded base64 payload once, rather than once in read() and again here.
            guard let data = try read(key, kind: .audio, validating: false) else { return nil }
            guard let segment = try? JSONDecoder().decode(AudioCacheSegment.self, from: data), segment.isValid else {
                try? remove(key)
                return nil
            }
            return segment
        }
    }
    public func invalidateAudio(namespace: [String]) throws {
        try load()
        for slot in [AudioCacheSlot.prefix, .interrupted] { try remove(key(.audio, namespace + [slot.rawValue])) }
    }
    public func canStoreAudio() throws -> Bool {
        try load()
        return limitBytes > 0
    }

    private func read(_ key: String, kind: MediaCacheKind, validating: Bool = true) throws -> Data? {
        guard entries[key] != nil else { return nil }
        guard let data = try? Data(contentsOf: file(key)), !data.isEmpty,
            data.count <= (kind == .audio ? 48 : 16) * 1_024 * 1_024, !validating || valid(data, kind: kind) else {
            try? remove(key)
            return nil
        }
        entries[key]?.accessed = Date()
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file(key).path)
        return data
    }
    private func key(_ kind: MediaCacheKind, _ namespace: [String]) throws -> String {
        let digest = SHA256.hash(data: try JSONEncoder().encode(namespace)).map { String(format: "%02x", $0) }.joined()
        let legacy = digest + "." + kind.rawValue
        guard namespace.count >= 2 else { return legacy }
        let scoped = Self.ownerKey(server: namespace[0], account: namespace[1]) + "-" + legacy
        if let entry = entries[legacy], entries[scoped] == nil {
            try FileManager.default.moveItem(at: file(legacy), to: file(scoped))
            entries[legacy] = nil
            entries[scoped] = entry
        }
        return scoped
    }
    private func file(_ key: String) -> URL { directory.appendingPathComponent(key) }
    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return Int64(max(values.fileSize ?? 0, values.totalFileAllocatedSize ?? 0))
    }
    private func valid(_ data: Data, kind: MediaCacheKind) -> Bool {
        guard !data.isEmpty, data.count <= (kind == .audio ? 48 : 16) * 1_024 * 1_024 else { return false }
        switch kind {
        case .cover:
            return CGImageSourceCreateWithData(data as CFData, nil).map { CGImageSourceGetCount($0) > 0 } ?? false
        case .lyrics:
            guard let lyric = try? MusicJSON.decoder().decode(SourceLyrics.self, from: data) else { return false }
            return !lyric.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .audio: return (try? JSONDecoder().decode(AudioCacheSegment.self, from: data))?.isValid == true
        }
    }
    private func load() throws {
        guard !loaded else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path), let legacyDirectory, fm.fileExists(atPath: legacyDirectory.path) {
            try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: legacyDirectory, to: directory)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configURL = directory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let limit = raw["limitBytes"] as? NSNumber
        {
            let old = limit.int64Value
            let version = (raw["version"] as? NSNumber)?.intValue ?? 1
            if version < 3, (version == 1 && old == 2_000_000_000) || (version == 2 && old == 5_000_000_000) {
                limitBytes = Self.defaultBytes
            } else if version < 3, old >= 0, old <= 1_000_000_000_000, old % 1_000_000 == 0 {
                limitBytes = min((old / 1_000_000) * Self.bytesPerMegabyte, Self.maximumBytes)
            } else {
                limitBytes = min(max(old, 0), Self.maximumBytes)
            }
        }
        entries = [:]
        usedBytes = 0
        for url in try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
        {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if url.pathExtension == "partial" {
                try? fm.removeItem(at: url)
                continue
            }
            guard let kind = MediaCacheKind(rawValue: url.pathExtension),
                [64, 129].contains(url.deletingPathExtension().lastPathComponent.count)
            else { continue }
            let size = try fileSize(url)
            entries[url.lastPathComponent] = Entry(
                kind: kind, size: size, accessed: values.contentModificationDate ?? .distantPast)
            usedBytes += size
        }
        try trim(to: limitBytes)
        try JSONEncoder().encode(Configuration(limitBytes: limitBytes)).write(to: configURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        loaded = true
    }
    private func insert(_ data: Data, key: String, kind: MediaCacheKind) throws {
        let reservation = Int64(data.count) + 16_384
        guard limitBytes > 0, reservation <= limitBytes else { return }
        try trim(to: limitBytes - reservation)
        try remove(key)
        let url = file(key)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let size = try fileSize(url)
            entries[key] = Entry(kind: kind, size: size, accessed: Date())
            usedBytes += size
            try trim(to: limitBytes)
        } catch {
            if entries[key] == nil { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
    private func trim(to target: Int64) throws {
        guard usedBytes > target else { return }
        for (key, _) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) {
            guard usedBytes > target else { break }
            try remove(key)
        }
    }
    private func remove(_ key: String) throws {
        guard let entry = entries[key] else { return }
        if FileManager.default.fileExists(atPath: file(key).path) { try FileManager.default.removeItem(at: file(key)) }
        entries[key] = nil
        usedBytes -= entry.size
    }
}
