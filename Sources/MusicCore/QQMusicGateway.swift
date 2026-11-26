import Foundation

/// The app owns the loopback-only Rain120 process. Its secret never leaves this machine.
public struct QQMusicGatewayEndpoint: Sendable {
    public let url: URL
    public let secret: String
    public init(url: URL, secret: String) {
        self.url = url
        self.secret = secret
    }
}

public struct QQMusicAPIRequest: Sendable {
    public let path: String
    public let method: String
    public let query: [String: String]
    public let body: JSONValue?
    public let cookie: String?
}

public protocol QQMusicAPITransport: Sendable {
    func send(_ request: QQMusicAPIRequest) async throws -> JSONValue
}

public struct LocalQQMusicConfiguration: Sendable {
    public let directory: URL
    public let credentials: any SessionCredentialStore
    public let endpoint: @Sendable () async throws -> QQMusicGatewayEndpoint
    public let transport: (any QQMusicAPITransport)?

    public init(
        directory: URL,
        credentials: any SessionCredentialStore = KeychainSessionCredentialStore(service: "local.ipplemusic.qq-session.v1"),
        transport: (any QQMusicAPITransport)? = nil,
        endpoint: @escaping @Sendable () async throws -> QQMusicGatewayEndpoint
    ) {
        self.directory = directory
        self.credentials = credentials
        self.endpoint = endpoint
        self.transport = transport
    }
}

extension JSONValue {
    var dictionary: [String: JSONValue] { if case .object(let value) = self { value } else { [:] } }
    var list: [JSONValue] { if case .array(let value) = self { value } else { [] } }
    var text: String {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .number(let value): String(Int64(value))
        default: ""
        }
    }
    var integer: Int64 {
        switch self {
        case .integer(let value): value
        case .number(let value): value.isFinite && abs(value) < Double(Int64.max) ? Int64(value) : 0
        case .string(let value): Int64(value) ?? 0
        default: 0
        }
    }
    var flag: Bool { if case .bool(let value) = self { value } else { false } }
    subscript(_ key: String) -> JSONValue { dictionary[key] ?? .null }
    func at(_ keys: String...) -> JSONValue { keys.reduce(self) { $0[$1] } }
    func first(_ keys: String...) -> JSONValue {
        for key in keys { if let value = dictionary[key], value != .null, value.text != "" || !value.dictionary.isEmpty || !value.list.isEmpty { return value } }
        return .null
    }
}

actor QQMusicGateway {
    private let endpoint: @Sendable () async throws -> QQMusicGatewayEndpoint
    private let session: URLSession
    private let transport: (any QQMusicAPITransport)?

    init(endpoint: @escaping @Sendable () async throws -> QQMusicGatewayEndpoint, transport: (any QQMusicAPITransport)? = nil) {
        self.endpoint = endpoint
        self.transport = transport
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func call(
        _ path: String, method: String = "GET", query: [String: String] = [:],
        body: JSONValue? = nil, cookie: String? = nil
    ) async throws -> JSONValue {
        if let transport {
            return try normalized(await transport.send(QQMusicAPIRequest(path: path, method: method, query: query, body: body, cookie: cookie)))
        }
        let endpoint = try await endpoint()
        guard endpoint.url.scheme == "http", endpoint.url.host == "127.0.0.1",
            endpoint.secret.utf8.count >= 32, !path.contains(".."), !path.contains("?")
        else { throw MusicAPIError(status: 0, code: "QQ_RUNTIME_UNAVAILABLE") }
        var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false)!
        components.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(endpoint.secret, forHTTPHeaderField: "X-Ipple-QQ-Gateway-Key")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "X-Ipple-QQ-Session") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw MusicAPIError(status: 0, code: Task.isCancelled ? "CANCELLED" : "NETWORK_ERROR") }
        guard let response = response as? HTTPURLResponse,
            let responseURL = response.url, MusicAPIClient.sameOrigin(endpoint.url, responseURL),
            (200...299).contains(response.statusCode), data.count <= 16 * 1024 * 1024
        else { throw MusicAPIError(status: 502, code: "SOURCE_UNAVAILABLE") }
        let result = try JSONDecoder().decode(JSONValue.self, from: data)
        return try normalized(result)
    }

    private func normalized(_ result: JSONValue) throws -> JSONValue {
        if ["expired", "unbound"].contains(result["state"].text) {
            throw MusicAPIError(status: 401, code: "QQ_LOGIN_REQUIRED")
        }
        if ["unavailable", "invalid"].contains(result["state"].text) || result["error"] != .null {
            throw MusicAPIError(status: 502, code: "SOURCE_UNAVAILABLE")
        }
        return result["response"] == .null ? result : result["response"]
    }
}
