import SwiftUI

struct QQTrackCoverControl: View {
    var sourceID: String
    var coverID: String?
    var title: String
    var isCurrent: Bool
    var isPlaying: Bool
    var isLoading: Bool
    var identifier: String
    var action: () -> Void
    var sourceTrackID: String? = nil
    @State private var hovered = false
    @State private var imageLoading = false

    private var active: Bool { isCurrent && isPlaying }
    private var loading: Bool { isLoading || imageLoading }
    private var actionTitle: String {
        loading ? "正在加载 \(title)" : active ? "暂停 \(title)" : isCurrent ? "继续播放 \(title)" : "播放 \(title)"
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                SourceCover(
                    sourceID: sourceID, coverID: coverID, size: 36, onLoadingChange: { imageLoading = $0 },
                    sourceTrackID: sourceTrackID)
                Color.black.opacity(loading || hovered ? 0.48 : active ? 0.32 : 0)
                if active && !hovered && !loading {
                    NowPlayingIndicator(isPlaying: true, color: .white).accessibilityHidden(true)
                }
                if hovered && !loading {
                    Image(systemName: active ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
                if loading {
                    ProgressView().controlSize(.small).tint(.white)
                        .frame(width: 16, height: 16)
                        .accessibilityLabel("正在加载")
                        .accessibilityIdentifier("favorites.qq-cover.loading")
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain).disabled(isLoading).onHover { hovered = $0 }
        .help(actionTitle).accessibilityLabel(actionTitle)
        .accessibilityIdentifier(identifier)
    }
}
