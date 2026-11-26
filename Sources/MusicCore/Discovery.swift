import Foundation

public enum DiscoveryMode: String, Sendable {
    case recommendations, charts, chart, hotwords, suggestions
    case guessLike = "guess_like"
    case daily
}

public struct DiscoveryItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var kind: String
    public var coverID: String?
    public var period: String?
    public var trackCount: Int64?

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, kind, period, trackCount
        case coverID = "coverId"
    }
    public var identity: String { kind + ":" + id }
}

public struct SourceDiscovery: Codable, Sendable, Equatable {
    public var dateKey: String?
    public var sessionVersion: Int64?
    public var tracks: [SourceTrack]
    public var albums: [SourceAlbum]
    public var playlists: [DiscoveryItem]
    public var charts: [DiscoveryItem]
    public var hotwords: [String]
    public var suggestions: [DiscoveryItem]
    public var offset: Int
    public var limit: Int
    public var hasMore: Bool
}

extension MusicAPIClient {
    /// Read the entire daily collection before enabling Play All; reject mixed sessions or dates.
    public func dailyRecommendations(id: String) async throws -> SourceDiscovery {
        var result = try await discoverSource(id: id, mode: .daily, limit: 3)
        guard result.dateKey == QQRecommendationDay.key(), let version = result.sessionVersion, version > 0,
            result.offset == 0, result.limit == 3, !result.tracks.isEmpty, result.tracks.count <= 3,
            !result.hasMore || result.tracks.count == 3
        else { throw MusicAPIError(status: 502, code: "SOURCE_UNAVAILABLE") }
        var offset = 3
        var seen = Set(result.tracks.map(\.id))
        while result.hasMore {
            try Task.checkCancellation()
            guard offset <= 10_000 else { throw MusicAPIError(status: 502, code: "SOURCE_UNAVAILABLE") }
            let page = try await discoverSource(id: id, mode: .daily, offset: offset, limit: 20)
            guard page.sessionVersion == version, page.dateKey == result.dateKey,
                page.dateKey == QQRecommendationDay.key(), page.offset == offset, page.limit == 20,
                !page.tracks.isEmpty, page.tracks.count <= 20, !page.hasMore || page.tracks.count == 20,
                page.tracks.allSatisfy({ seen.insert($0.id).inserted })
            else { throw MusicAPIError(status: 409, code: "VERSION_CONFLICT") }
            result.tracks.append(contentsOf: page.tracks)
            result.hasMore = page.hasMore
            offset += 20
        }
        return result
    }

    /// Bound parallel imports, restoring the recommendation order when requests finish out of order.
    public func importSourceQueue(sourceID: String, tracks: [SourceTrack]) async throws -> [LibraryTrack] {
        try await withThrowingTaskGroup(of: (Int, LibraryTrack).self) { group in
            var next = 0
            var ordered = [LibraryTrack?](repeating: nil, count: tracks.count)
            func submit(_ index: Int) {
                group.addTask {
                    (index, try await self.importSourceTrack(connectionID: sourceID, trackID: tracks[index].id))
                }
            }
            while next < min(3, tracks.count) {
                submit(next)
                next += 1
            }
            while let (index, track) = try await group.next() {
                try Task.checkCancellation()
                ordered[index] = track
                if next < tracks.count {
                    submit(next)
                    next += 1
                }
            }
            return ordered.compactMap { $0 }
        }
    }

    public func discoverSource(
        id: String, mode: DiscoveryMode, query: String = "", chartID: String? = nil, offset: Int = 0, limit: Int = 20
    ) async throws -> SourceDiscovery {
        var items: [URLQueryItem] = [
            .init(name: "mode", value: mode.rawValue), .init(name: "offset", value: String(offset)),
            .init(name: "limit", value: String(limit)),
        ]
        if !query.isEmpty { items.append(.init(name: "q", value: query)) }
        if let chartID { items.append(.init(name: "chart_id", value: chartID)) }
        return try await request("GET", ["api", "v1", "sources", id, "discovery"], query: items)
    }
}

public enum QQRecommendationDay {
    public static func key(for date: Date = Date()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func nextBoundary(after date: Date = Date()) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }
}
