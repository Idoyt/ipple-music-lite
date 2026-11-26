import Foundation

public struct QQSessionStatus: Codable, Sendable, Equatable {
    public var state: String
    public var loginAvailable: Bool
    public var accountID: String?
    public var nickname: String?
    public var expiresAt: Date?
    public var avatarURL: URL? = nil

    enum CodingKeys: String, CodingKey {
        case state, loginAvailable, nickname, expiresAt
        case avatarURL = "avatarUrl"
        case accountID = "accountId"
    }
}

public struct QQSessionCandidate: Sendable, Equatable {
    public let cookie: String
    public let expiresAt: Date?
    public let authorizationCode: String?

    private init(cookie: String = "", expiresAt: Date? = nil, authorizationCode: String? = nil) {
        self.cookie = cookie
        self.expiresAt = expiresAt
        self.authorizationCode = authorizationCode
    }

    public static func isAuthorizationCallbackURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "y.qq.com"
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && url.path == "/portal/wx_redirect.html"
    }

    public static func authorizationCallback(from url: URL, expectedState: String) -> Self? {
        guard !expectedState.isEmpty, isAuthorizationCallbackURL(url),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let fragment = components.fragment.flatMap { URLComponents(string: "https://y.qq.com/?" + $0)?.queryItems } ?? []
        let items = (components.queryItems ?? []) + fragment
        guard items.filter({ $0.name == "state" }) == [URLQueryItem(name: "state", value: expectedState)],
            items.filter({ $0.name == "code" }).count == 1,
            items.filter({ $0.name == "login_type" }).count == 1,
            items.first(where: { $0.name == "login_type" })?.value == "1",
            let code = items.first(where: { $0.name == "code" })?.value,
            (16...512).contains(code.utf8.count),
            code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
        else { return nil }
        return Self(authorizationCode: code)
    }

    /// Only music-scoped credentials from QQ-owned domains may leave the ephemeral login view.
    public static func capture(from cookies: [HTTPCookie], now: Date = Date()) -> Self? {
        let allowed = Set([
            "uin", "qqmusic_uin", "wxuin", "qqmusic_key", "music_key", "qm_keyst", "wxopenid", "wxunionid",
            "login_type", "tmeLoginType",
        ])
        let tokens = Set(["qqmusic_key", "music_key", "qm_keyst"])
        let accepted = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return ["qq.com", "y.qq.com"].contains(domain) && allowed.contains(cookie.name)
                && !cookie.value.isEmpty && cookie.value.utf8.allSatisfy { $0 >= 33 && $0 <= 126 && $0 != 59 }
                && (cookie.expiresDate.map { $0 > now } ?? true)
        }.sorted {
            if $0.domain.count != $1.domain.count { return $0.domain.count > $1.domain.count }
            return $0.path.count > $1.path.count
        }
        var values: [String: HTTPCookie] = [:]
        for cookie in accepted where values[cookie.name] == nil { values[cookie.name] = cookie }
        let rawID = values["uin"]?.value ?? values["qqmusic_uin"]?.value ?? values["wxuin"]?.value ?? ""
        let account = rawID.hasPrefix("o") ? String(rawID.dropFirst()) : rawID
        guard (5...20).contains(account.count), account.utf8.allSatisfy({ (48...57).contains($0) }),
            account.contains(where: { $0 != "0" }), values.keys.contains(where: { tokens.contains($0) })
        else { return nil }
        let expiry = values.values.filter { tokens.contains($0.name) }.compactMap(\.expiresDate).min()
        let header = values.keys.sorted().map { "\($0)=\(values[$0]!.value)" }.joined(separator: "; ")
        guard header.utf8.count <= 8192 else { return nil }
        return Self(cookie: header, expiresAt: expiry)
    }
}

extension MusicAPIClient {
    public func qqSession(sourceID: String) async throws -> QQSessionStatus {
        try await request("GET", ["api", "v1", "sources", sourceID, "qq-session"])
    }

}


public struct QQLoginRequest: Encodable, Sendable {
    public var code: String
    public var clientDeviceID: UUID
    public var deviceName: String

    enum CodingKeys: String, CodingKey {
        case code, deviceName
        case clientDeviceID = "clientDeviceId"
    }
}

extension MusicAPIClient {
    public func loginQQ(candidate: QQSessionCandidate, clientDeviceID: UUID, deviceName: String = "Ipple Music · Mac") async throws -> AuthResponse {
        guard let code = candidate.authorizationCode else { throw MusicAPIError(status: 400, code: "QQ_LOGIN_REQUIRED") }
        invalidateRequests()
        return try await request("POST", ["api", "v1", "auth", "qq"],
            body: QQLoginRequest(code: code, clientDeviceID: clientDeviceID, deviceName: deviceName))
    }
}
