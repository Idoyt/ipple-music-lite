import Foundation

/// Account-scoped recommendation metadata survives view recreation; radio refills bypass this cache.
@MainActor
public final class RecommendationCache {
    private struct Key: Hashable {
        var scope: String
        var sourceID: String
        var mode: String
        var day: String
        var offset: Int
        var limit: Int
    }
    private struct Request {
        var id: UUID
        var task: Task<SourceDiscovery, Error>
    }
    private var pages: [Key: SourceDiscovery] = [:]
    private var requests: [Key: Request] = [:]
    private var completedDaily: [Key: SourceDiscovery] = [:]
    private var consumedRadio = Set<String>()
    private var scopeIDs: [String: UUID] = [:]
    private var artwork: [String: (current: SourceTrack, next: SourceTrack?)] = [:]
    private let now: @MainActor () -> Date

    public init(now: @escaping @MainActor () -> Date = { Date() }) { self.now = now }

    public func clear() { retainScopes([]) }

    public func retainScopes(_ scopes: Set<String>) {
        pages = pages.filter { scopes.contains($0.key.scope) }
        completedDaily = completedDaily.filter { scopes.contains($0.key.scope) }
        for (key, request) in requests where !scopes.contains(key.scope) { request.task.cancel() }
        requests = requests.filter { scopes.contains($0.key.scope) }
        consumedRadio.formIntersection(scopes)
        scopeIDs = scopeIDs.filter { scopes.contains($0.key) }
        artwork = artwork.filter { scopes.contains($0.key) }
    }

    private func pruneDays() {
        let day = QQRecommendationDay.key(for: now())
        pages = pages.filter { $0.key.day.isEmpty || $0.key.day == day }
        completedDaily = completedDaily.filter { $0.key.day == day }
        for (key, request) in requests where !key.day.isEmpty && key.day != day { request.task.cancel() }
        requests = requests.filter { $0.key.day.isEmpty || $0.key.day == day }
    }

    private func key(scope: String, sourceID: String, mode: DiscoveryMode, offset: Int = 0, limit: Int = 3) -> Key {
        Key(
            scope: scope, sourceID: sourceID, mode: mode.rawValue,
            day: mode == .daily ? QQRecommendationDay.key(for: now()) : "", offset: offset, limit: limit)
    }

    public func preview(client: MusicAPIClient, sourceID: String, scope: String, mode: DiscoveryMode) async throws
        -> SourceDiscovery
    {
        guard mode == .daily || mode == .guessLike else { throw MusicAPIError(status: 400, code: "INVALID_INPUT") }
        pruneDays()
        if scopeIDs[scope] == nil { scopeIDs[scope] = UUID() }
        let key = key(scope: scope, sourceID: sourceID, mode: mode)
        if let completed = completedDaily[key] { return completed }
        return try await page(client: client, key: key, mode: mode)
    }

    public func daily(client: MusicAPIClient, sourceID: String, scope: String) async throws -> SourceDiscovery {
        pruneDays()
        let scopeID = scopeIDs[scope] ?? UUID()
        scopeIDs[scope] = scopeID
        let initialKey = key(scope: scope, sourceID: sourceID, mode: .daily)
        if let completed = completedDaily[initialKey] { return completed }
        var result = try await page(client: client, key: initialKey, mode: .daily)
        guard scopeIDs[scope] == scopeID else { throw CancellationError() }
        let version = result.sessionVersion
        var seen = Set(result.tracks.map(\.id))
        var offset = result.limit
        while result.hasMore {
            guard offset <= 10_000, initialKey.day == QQRecommendationDay.key(for: now()) else {
                throw MusicAPIError(status: 409, code: "VERSION_CONFLICT")
            }
            let nextKey = Key(
                scope: scope, sourceID: sourceID, mode: DiscoveryMode.daily.rawValue,
                day: initialKey.day, offset: offset, limit: 20)
            let next = try await page(client: client, key: nextKey, mode: .daily)
            guard scopeIDs[scope] == scopeID else { throw CancellationError() }
            guard next.sessionVersion == version, next.dateKey == result.dateKey,
                next.tracks.allSatisfy({ seen.insert($0.id).inserted })
            else {
                pages = pages.filter { $0.key.scope != scope || $0.key.day != initialKey.day }
                throw MusicAPIError(status: 409, code: "VERSION_CONFLICT")
            }
            result.tracks.append(contentsOf: next.tracks)
            result.hasMore = next.hasMore
            offset += next.limit
        }
        try Task.checkCancellation()
        guard scopeIDs[scope] == scopeID, pages[initialKey] != nil,
            initialKey.day == QQRecommendationDay.key(for: now())
        else {
            throw CancellationError()
        }
        completedDaily[initialKey] = result
        return result
    }

    /// The three preview songs may seed playback once, even after leaving and returning to the page.
    public func takeRadioPreview(sourceID: String, scope: String) -> SourceDiscovery? {
        let initialKey = key(scope: scope, sourceID: sourceID, mode: .guessLike)
        guard !consumedRadio.contains(scope), let page = pages[initialKey] else { return nil }
        consumedRadio.insert(scope)
        return page
    }

    public func rememberRadioArtwork(scope: String, current: SourceTrack, next: SourceTrack?) {
        artwork[scope] = (current, next)
    }

    public func radioArtwork(scope: String) -> (current: SourceTrack, next: SourceTrack?)? { artwork[scope] }

    private func page(client: MusicAPIClient, key: Key, mode: DiscoveryMode) async throws -> SourceDiscovery {
        if let cached = pages[key] { return cached }
        if let pending = requests[key] { return try await pending.task.value }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            defer { if requests[key]?.id == id { requests[key] = nil } }
            let result = try await client.discoverSource(
                id: key.sourceID, mode: mode, offset: key.offset, limit: key.limit)
            try Task.checkCancellation()
            guard requests[key]?.id == id, key.day.isEmpty || key.day == QQRecommendationDay.key(for: now()) else {
                throw CancellationError()
            }
            guard let version = result.sessionVersion, version > 0,
                result.offset == key.offset, result.limit == key.limit,
                !result.tracks.isEmpty, result.tracks.count <= key.limit,
                Set(result.tracks.map(\.id)).count == result.tracks.count,
                !result.hasMore || result.tracks.count == key.limit,
                mode != .daily || result.dateKey == key.day,
                mode != .guessLike || !result.hasMore
            else { throw MusicAPIError(status: 502, code: "SOURCE_UNAVAILABLE") }
            pages[key] = result
            return result
        }
        requests[key] = Request(id: id, task: task)
        return try await task.value
    }
}
