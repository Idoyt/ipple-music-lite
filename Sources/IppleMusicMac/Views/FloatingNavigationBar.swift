import AppKit
import SwiftUI

enum MainTab: String, CaseIterable {
    case recommendations = "发现"
    case favorites = "收藏"
    case profile = "我的"
    var symbol: String {
        switch self {
        case .recommendations: "sparkles"
        case .favorites: "heart.fill"
        case .profile: "person.crop.circle.fill"
        }
    }
    var identifier: String {
        switch self {
        case .recommendations: "nav.recommendations"
        case .favorites: "nav.favorites"
        case .profile: "nav.profile"
        }
    }
}

struct FloatingNavigationBar: View {
    @Binding var selection: MainTab
    var artwork: PlaybackArtworkSnapshot?
    var onArtworkFrame: (CGRect) -> Void
    var detailsExpanded: Bool
    var onOpenDetails: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionSpace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { selection = tab }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbol).font(.system(size: 17, weight: .semibold))
                            .frame(height: 19)
                        Text(tab.rawValue).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(
                        selection == tab ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.7)
                    )
                    .frame(width: 64, height: 48)
                    .background {
                        if selection == tab {
                            Capsule().fill(Color.gray.opacity(0.18))
                                .matchedGeometryEffect(id: "selection", in: selectionSpace)
                        }
                    }
                    .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier(tab.identifier)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
            if store.player.currentTrack != nil {
                Divider().frame(height: 28).padding(.horizontal, 9)
                    .accessibilityHidden(true)
                CompactPlaybackControls(
                    artwork: artwork, onArtworkFrame: onArtworkFrame, detailsExpanded: detailsExpanded,
                    onOpenDetails: onOpenDetails
                ).padding(.trailing, 7)
                    .transition(.opacity)
            }
        }.padding(5).modifier(NavigationGlass())
            .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: store.player.currentTrack != nil)
    }
}

private struct NavigationGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 0.5))
        }
    }
}
