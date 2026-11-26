import Foundation
import MusicCore

struct AppSettings: Codable {
    var serverURL = MusicAPIClient.localOrigin.absoluteString
    var clientDeviceID: UUID?
    var sessionRestorationEnabled: Bool?
    // Persist cleanup intent before detaching the user, so a failed deletion can be retried after restart.
    struct LogoutCleanup: Codable {
        var libraryKey: String?
        var playbackKey: String?
        var mediaOwner: String?
    }
    var pendingLocalLogout: LogoutCleanup?
    var menuBarWidth: Double?

    static let defaultMenuBarWidth: Double = 160
    static let menuBarWidthRange: ClosedRange<Double> = 140...240
    static func normalizedMenuBarWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMenuBarWidth }
        return min(menuBarWidthRange.upperBound, max(menuBarWidthRange.lowerBound, value.rounded()))
    }
    var resolvedMenuBarWidth: Double { Self.normalizedMenuBarWidth(menuBarWidth ?? Self.defaultMenuBarWidth) }

    private static var developmentDirectory: URL? {
        #if DEBUG
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/" {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("IppleMusicMac.xcodeproj").path) {
                return root.appendingPathComponent(".local/public-player")
            }
            root.deleteLastPathComponent()
        }
        #endif
        return nil
    }

    private static var support: URL {
        developmentDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IppleMusicPublic")
    }
    static var localMusicDirectory: URL { support.appendingPathComponent("library") }
    static var playbackSessionDirectory: URL { support.appendingPathComponent("playback") }
    static let mediaCache = MediaDiskCache(directory: (developmentDirectory
        ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("IppleMusicPublic"))
        .appendingPathComponent("media"))
    static let coverCache = mediaCache
    private static var fileURL: URL? { support.appendingPathComponent("settings.json") }

    static func load() -> AppSettings {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
            let settings = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return settings
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
