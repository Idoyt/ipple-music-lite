import SwiftUI

struct PlaylistPageInfo {
    var title: String
    var coverID: String?
    var owner: String? = nil
    var tags: [String] = []
    var description: String? = nil
    var trackCount: Int64? = nil
    var coverTrackID: String? = nil
}

/// Shared playlist layout. Callers retain ownership of loading, pagination, playback and actions.
struct PlaylistPage<Actions: View, Content: View>: View {
    var sourceID: String
    var info: PlaylistPageInfo
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                header(coverSize: 136)
                header(coverSize: 96)
            }
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 24)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(coverSize: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 20) {
            SourceCover(sourceID: sourceID, coverID: info.coverID, size: coverSize, sourceTrackID: info.coverTrackID)
                .accessibilityLabel("\(info.title)封面")
            VStack(alignment: .leading, spacing: 9) {
                Text(info.title).font(.system(size: 24, weight: .bold)).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 10) {
                    if let owner = info.owner, !owner.isEmpty { Text(owner).lineLimit(1) }
                    ForEach(info.tags, id: \.self) { Text("#\($0)").lineLimit(1) }
                    if let count = info.trackCount { Text("\(count) 首歌曲").monospacedDigit() }
                }.font(.callout).foregroundStyle(.secondary)
                if let description = info.description, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 6)
                HStack(spacing: 12, content: actions)
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 136, alignment: .topLeading)
        }
    }
}
