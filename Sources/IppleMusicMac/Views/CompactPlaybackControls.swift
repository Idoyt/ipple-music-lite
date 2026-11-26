import AppKit
import MusicCore
import SwiftUI

struct CompactPlaybackControls: View {
    @Environment(AppStore.self) private var store
    var artwork: PlaybackArtworkSnapshot?
    var onArtworkFrame: (CGRect) -> Void
    var detailsExpanded: Bool
    var onOpenDetails: () -> Void
    @State private var volumeExpanded = false

    var body: some View {
        let player = store.player
        HStack(spacing: 12) {
            if let track = player.currentTrack {
                HStack(spacing: 9) {
                    PlaybackArtworkButton(symbol: "chevron.up", showsHover: !detailsExpanded, action: onOpenDetails) {
                        PlaybackArtworkWipe(artwork: artwork, animate: !detailsExpanded) { snapshot in
                            PlaybackArtworkView(image: snapshot?.image, title: snapshot?.title ?? track.title, size: 38)
                        }
                    }
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        onArtworkFrame($0)
                    }
                    .help("展开播放详情")
                    .accessibilityLabel("展开播放详情：\(track.title)")
                    .accessibilityIdentifier("compact-player.artwork")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(track.artists.isEmpty ? "未知歌手" : track.artists.joined(separator: " / "))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(width: 124, alignment: .leading)
                        .help(([track.title] + track.artists).joined(separator: " · "))
                }
            }
            PlaybackProgressView().frame(width: 116)
                .opacity(volumeExpanded ? 0 : 1)
                .allowsHitTesting(!volumeExpanded).accessibilityHidden(volumeExpanded)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            PlaybackTransportControls(isActive: !detailsExpanded && !volumeExpanded)
                .opacity(volumeExpanded ? 0 : 1)
                .allowsHitTesting(!volumeExpanded).accessibilityHidden(volumeExpanded)
            PlaybackFavoriteControl()
                .opacity(volumeExpanded ? 0 : 1)
                .allowsHitTesting(!volumeExpanded).accessibilityHidden(volumeExpanded)
            PlaybackVolumeControl(isActive: !detailsExpanded, onVisibilityChange: { volumeExpanded = $0 })
        }
    }
}
