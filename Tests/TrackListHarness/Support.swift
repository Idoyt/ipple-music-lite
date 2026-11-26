import AppKit
import MusicCore
import Observation
import SwiftUI

// Isolate list rendering from network, playback, user credentials and disk caches.
@MainActor @Observable final class AppStore {
    let player = FixturePlayer()
    func isFavorite(_ id: String) -> Bool { true }
    func isUpdatingFavorite(_ id: String) -> Bool { false }
    func toggleFavorite(_ track: LibraryTrack) async {}
    func toggleQQTrackFavorite(_ track: SourceTrack, from source: SourceConnection) async {}
    func setQQTrackAsNext(_ track: SourceTrack, from source: SourceConnection) async {}
    func refreshQQFavorite(_ track: LibraryTrack) async {}
}
@MainActor final class FixturePlayer { func togglePlayPause() async {} }
struct HistoryTrackRow: Equatable {
    var record: PlayHistoryRecord
    var track: LibraryTrack?
    var qqTrackID: String?
}
struct SourceCover: View {
    var sourceID: String
    var coverID: String?
    var size: CGFloat
    var onLoadingChange: ((Bool) -> Void)? = nil
    var sourceTrackID: String? = nil
    var body: some View {
        Image(systemName: "music.note").frame(width: size, height: size).background(.quaternary)
    }
}
func durationText(_ seconds: Double) -> String { "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))" }
