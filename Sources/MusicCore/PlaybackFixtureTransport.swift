import Foundation

/// Loopback fixtures for the playback and pagination test harnesses. Never used by the app.
final class PlaybackFixtureTransport: Sendable {
    let origin: URL
    let protocolClasses: [AnyClass]?
    private let session: URLSession

    init(origin: URL, configuration: URLSessionConfiguration) throws {
        guard origin.scheme == "http", origin.host == "127.0.0.1" || origin.host == "localhost" else {
            throw MusicAPIError(status: 0, code: "INVALID_SERVER_URL")
        }
        self.origin = try MusicAPIClient.validateBaseURL(origin)
        protocolClasses = configuration.protocolClasses
        let isolated = URLSessionConfiguration.ephemeral
        isolated.protocolClasses = configuration.protocolClasses
        isolated.urlCache = nil
        isolated.httpCookieStorage = nil
        session = URLSession(configuration: isolated)
    }

    deinit { session.invalidateAndCancel() }

    func read(_ method: String, segments: [String], query: [URLQueryItem], body: (any Encodable & Sendable)?) async throws -> Data {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = "/" + segments.joined(separator: "/")
        parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.httpBody = try body.map { try MusicJSON.encoder().encode($0) }
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MusicAPIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, code: "SOURCE_UNAVAILABLE")
        }
        return bytes
    }
}
