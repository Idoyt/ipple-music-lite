import Foundation

public actor MusicAPIClient {
    public nonisolated static let localOrigin = URL(string: "https://local.qqmusic.invalid")!
    private let localService: LocalQQMusicService?
    private let fixture: PlaybackFixtureTransport?
    private var generation = 0

    public init(localQQ configuration: LocalQQMusicConfiguration) {
        localService = LocalQQMusicService(configuration: configuration)
        fixture = nil
    }

    @_spi(Testing) public init(testFixtureURL origin: URL, configuration: URLSessionConfiguration = .ephemeral) throws {
        localService = nil
        fixture = try PlaybackFixtureTransport(origin: origin, configuration: configuration)
    }

    public func invalidateRequests() { generation &+= 1 }

    public func restoreSession() async throws -> User? {
        let expected = generation
        let user = try await localService?.restore()
        guard expected == generation else { throw CancellationError() }
        return user
    }

    public nonisolated static func validateBaseURL(_ input: URL) throws -> URL {
        guard var parts = URLComponents(url: input, resolvingAgainstBaseURL: false),
            let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
            !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.path.isEmpty || parts.path == "/", parts.port == nil || (1...65535).contains(parts.port!),
            scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
        else {
            throw MusicAPIError(status: 0, code: "INVALID_SERVER_URL")
        }
        parts.scheme = scheme
        parts.host = host
        parts.path = ""
        guard let url = parts.url else { throw MusicAPIError(status: 0, code: "INVALID_SERVER_URL") }
        return url
    }

    public nonisolated static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(), lhs.host?.lowercased() == rhs.host?.lowercased(),
            rhs.user == nil, rhs.password == nil
        else { return false }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return port(lhs) == port(rhs)
    }

    public func localLibraryRemovalKey() async throws -> String {
        guard let localService else { throw MusicAPIError(status: 400, code: "UNSUPPORTED") }
        return try await LocalMusicRepository.directoryKey(localService.requireAccount().accountID)
    }

    public func eraseLocalLibrary(key: String) async throws {
        guard let localService, key.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw MusicAPIError(status: 400, code: "INVALID_INPUT") }
        let directory = localService.configuration.directory.appendingPathComponent("accounts").appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func request<T: Decodable & Sendable>(
        _ method: String, _ segments: [String], query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil, idempotencyKey: String? = nil
    ) async throws -> T {
        let expected = generation
        if let localService {
            let value = try await localService.request(method, segments: segments, query: query, body: body)
            guard expected == generation else { throw CancellationError() }
            guard let typed = value as? T else { throw MusicAPIError(status: 0, code: "INVALID_RESPONSE") }
            return typed
        }
        guard let fixture else { throw MusicAPIError(status: 0, code: "SOURCE_UNAVAILABLE") }
        let data = try await fixture.read(method, segments: segments, query: query, body: body)
        guard expected == generation else { throw CancellationError() }
        if let bytes = data as? T { return bytes }
        return try MusicJSON.decoder().decode(T.self, from: data)
    }

    public func mediaResource(from playback: SourcePlayback) throws -> MediaResource {
        let url: URL
        if let fixture {
            guard let resolved = URL(string: playback.streamURL, relativeTo: fixture.origin)?.absoluteURL,
                  Self.sameOrigin(fixture.origin, resolved) else { throw MusicAPIError(status: 0, code: "UNSAFE_MEDIA_URL") }
            url = resolved
        } else {
            guard let resolved = URL(string: playback.streamURL), Self.isQQAudioURL(resolved)
            else { throw MusicAPIError(status: 0, code: "UNSAFE_MEDIA_URL") }
            url = resolved
        }
        return MediaResource(url: url, cookies: [], contentType: playback.contentType, canSeek: playback.canSeek, expiresAt: playback.expiresAt)
    }

    private nonisolated static func isQQAudioURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "aqqmusic.tc.qq.com" && url.user == nil && url.password == nil &&
            url.port == nil && url.fragment == nil
    }

    public func audioRange(_ resource: MediaResource, offset: Int64, length: Int) async throws -> AudioCacheSegment {
        let allowed = fixture.map { Self.sameOrigin($0.origin, resource.url) } ?? Self.isQQAudioURL(resource.url)
        guard allowed else { throw MusicAPIError(status: 0, code: "UNSAFE_MEDIA_URL") }
        let expected = generation
        let transport = AudioRangeTransport(origin: resource.url, protocolClasses: fixture?.protocolClasses)
        defer { transport.invalidate() }
        let result = try await transport.fetch(resource, offset: offset, length: length)
        guard expected == generation else { throw CancellationError() }
        return result
    }
}

struct EmptyResponse: Decodable, Sendable {}
