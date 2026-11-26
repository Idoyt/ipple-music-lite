import Foundation

public struct QQSongComment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let author: String
    public let text: String
    public let postedAt: Date?
    public let likeCount: Int64
    public var images: [URL]? = nil
}

public struct QQCommentCursor: Codable, Equatable, Sendable {
    let page: Int
    let lastCommentID: String

    private enum CodingKeys: String, CodingKey {
        case page
        case lastCommentID = "lastCommentId"
    }
}

public struct QQSongComments: Codable, Equatable, Sendable {
    public let items: [QQSongComment]
    public let next: QQCommentCursor?
    public var total: Int64? = nil
}

extension MusicAPIClient {
    public func qqSongComments(sourceID: String, trackID: String, after cursor: QQCommentCursor? = nil) async throws
        -> QQSongComments
    {
        var query: [URLQueryItem] = []
        if let cursor {
            query = [
                .init(name: "page", value: String(cursor.page)), .init(name: "after", value: cursor.lastCommentID),
            ]
        }
        return try await request("GET", ["api", "v1", "sources", sourceID, "qq-comments", trackID], query: query)
    }
}

extension LocalQQMusicService {
    func songComments(_ mid: String, parameters: [String: String]) async throws -> QQSongComments {
        let page = Int(parameters["page"] ?? "0") ?? -1
        let after = parameters["after"]
        guard (0...50_000).contains(page), page == 0 ? after == nil : Self.validCommentID(after) else {
            throw failure()
        }
        let songID = try await numericSongID(mid)

        let limit = 20
        var query = ["id": String(songID), "pagesize": String(limit)]
        if let after {
            query["pagenum"] = String(page)
            query["rootcommentid"] = after
        }
        let response = try await qq("getComments", query: query)
        let comments = response["comment"]
        guard response["code"].text == "0", comments["commenttotal"] != .null else {
            throw failure(502, "SOURCE_UNAVAILABLE")
        }

        let rows = comments["commentlist"].list
        let items = rows.compactMap { row -> QQSongComment? in
            let id = row.first("commentid", "rootcommentid").text
            let middle = row["middlecommentcontent"].text
            let body = (middle.isEmpty ? row["rootcommentcontent"].text : middle)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let images = QQCommentContent.images(in: row)
            let time = row["time"].integer
            guard !id.isEmpty, !body.isEmpty || !images.isEmpty else { return nil }
            return QQSongComment(
                id: id, author: row.first("nick", "rootcommentnick").text, text: body,
                postedAt: time > 0 ? Date(timeIntervalSince1970: Double(time)) : nil,
                likeCount: max(0, row["praisenum"].integer), images: images.isEmpty ? nil : images)
        }
        let lastID = rows.last?["rootcommentid"].text
        let hasMore = comments["has_more"] == .null
            ? rows.count == limit && Int64((page + 1) * limit) < comments["commenttotal"].integer
            : comments["has_more"].flag
        let next = lastID.flatMap { id in
            hasMore && page < 50_000 && Self.validCommentID(id) && id != after
                ? QQCommentCursor(page: page + 1, lastCommentID: id) : nil
        }
        return QQSongComments(items: items, next: next, total: max(0, comments["commenttotal"].integer))
    }

    private static func validCommentID(_ id: String?) -> Bool {
        guard let id, (1...160).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
