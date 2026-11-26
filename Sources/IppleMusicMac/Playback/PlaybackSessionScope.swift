import CryptoKit
import Foundation

struct PlaybackSessionScope: Equatable, Sendable {
    let server: URL
    let accountID: String

    var key: String {
        let origin = [
            server.scheme ?? "", server.host ?? "", String(server.port ?? (server.scheme == "https" ? 443 : 80)),
        ]
        let data = (try? JSONEncoder().encode(origin + [accountID])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
