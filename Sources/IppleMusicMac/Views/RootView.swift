import AppKit
import MusicCore
import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var compactArtworkFrame = CGRect.zero
    @State private var artworkCache = PlaybackArtworkCache()
    @State private var playbackArtwork: PlaybackArtworkSnapshot?
    @State private var playbackLyrics: (request: LyricsRequest, content: PlaybackLyricsContent)?
    @State private var lyricsRetry = 0
    @State private var detailPresentation = PlaybackDetailPresentation()
    @State private var playbackBackdropMotion = PlaybackBackdropMotion()
    @State private var floatingNavigationHeight: CGFloat = 88

    private var showingPlaybackDetails: Bool { detailPresentation.isPresented }
    private var showsError: Binding<Bool> {
        Binding(get: { store.error != nil }, set: { shown in
            if !shown { store.error = nil }
        })
    }

    var body: some View {
        workspaceDialogs
            .overlay(alignment: .top) { noticeBanner }
            .task(id: showingPlaybackDetails ? nil : store.user?.id) {
                while !showingPlaybackDetails && store.user != nil && !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    if !Task.isCancelled { await store.synchronize() }
                }
            }
    }

    private var workspaceLifecycle: some View {
        let preloads = artworkPreloads
        return workspacePresentation
        .toolbarVisibility(
            // TabView tabs live in the native window toolbar, above content overlays.
            // Hide that toolbar while keeping the underlying tabs and scroll state mounted.
            playbackBackdropMotion.isExpanded ? .hidden
                : (store.user != nil && tab != .profile ? .visible : .automatic),
            for: .windowToolbar
        )
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onChange(of: store.user?.id) { _, _ in
            tab = .recommendations
            detailPresentation.isPresented = false
            playbackBackdropMotion.isExpanded = false
            detailPresentation.standbyPosition = 0
            artworkCache.reset()
            DecodedCoverCache.shared.reset()
            playbackArtwork = nil
            playbackLyrics = nil
        }
        .task(id: [playbackIdentity, String(store.mediaCache.token())]) { await loadPlaybackArtwork() }
        .task(id: lyricsRequest) { await loadPlaybackLyrics() }
        .task(id: [playbackIdentity, String(store.mediaCache.token())] + preloads.map(\.identity), priority: .utility) {
            await preloadArtwork(preloads)
        }
        .onChange(of: store.player.currentTrack?.id) { _, id in
            if id == nil {
                detailPresentation.isPresented = false
                playbackBackdropMotion.isExpanded = false
            }
        }
    }

    private var workspaceDialogs: some View {
        workspaceLifecycle
        .alert("无法完成操作", isPresented: showsError) {
            Button("好", role: .cancel) { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice = store.notice {
            Text(notice).font(.callout).padding(.horizontal, 18).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule()).shadow(radius: 8, y: 3).padding(.top, 10)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(3))
                    if store.notice == notice { store.notice = nil }
                }
        }
    }

    private var workspacePresentation: some View {
        Group {
            if store.user == nil {
                LoginView()
            } else {
                mainWorkspace
                    .environment(\.workspaceIsActive, !showingPlaybackDetails)
                    .accessibilityHidden(showingPlaybackDetails)
                    .overlay {
                        GeometryReader { geometry in
                            if store.player.currentTrack != nil {
                                PlaybackDetailBackdrop(
                                    artwork: currentArtwork, viewport: geometry.frame(in: .global),
                                    cover: compactArtworkFrame, motion: playbackBackdropMotion
                                ) { expanded in
                                    guard expanded, playbackBackdropMotion.isExpanded, store.player.currentTrack != nil
                                    else { return }
                                    detailPresentation.isPresented = true
                                }
                            }
                        }
                        .ignoresSafeArea()
                    }
                    .overlay {
                        if store.player.currentTrack != nil {
                            let content = PlaybackDetailContent(artwork: currentArtwork, lyrics: currentLyrics)
                            PlaybackDetailHost(
                                isPresented: showingPlaybackDetails, snapshot: content, onDismiss: closePlaybackDetails
                            ) {
                                PlaybackDetailView(
                                    artwork: content.artwork, presentation: detailPresentation, lyrics: content.lyrics,
                                    onRetryLyrics: { lyricsRetry &+= 1 }, onClose: closePlaybackDetails
                                ).environment(store)
                            }
                            .allowsHitTesting(showingPlaybackDetails)
                        }
                    }
                    .id(store.user?.id)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showingPlaybackDetails {
                playbackDetailsCloseButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 8).padding(.trailing, 10)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
    }

    @State private var tab = MainTab.recommendations

    private var playbackDetailsCloseButton: some View {
        Button(action: closePlaybackDetails) {
            Image(systemName: "chevron.down")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: WindowControlMetrics.toolbarButtonSide,
                       height: WindowControlMetrics.toolbarButtonSide)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: WindowControlMetrics.toolbarButtonSide,
               height: WindowControlMetrics.toolbarButtonSide)
        .fixedSize()
        .contentShape(Circle())
        .modifier(PlaybackDetailsCloseGlass())
        .environment(\.colorScheme, .dark)
        .help("收起播放详情")
        .accessibilityLabel("收起")
        .accessibilityIdentifier("player-details.close")
    }

    private var mainWorkspace: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(nsColor: .controlAccentColor).opacity(0.055), Color(nsColor: .windowBackgroundColor),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                Group {
                    switch tab {
                    case .recommendations:
                        DiscoveryHomeView(onManageSources: showSources,
                            showsToolbar: !playbackBackdropMotion.isExpanded)
                    case .favorites:
                        FavoritesView(
                            onManageSources: showSources, bottomOverlayClearance: floatingNavigationHeight,
                            showsToolbar: !playbackBackdropMotion.isExpanded)
                    case .profile: profileWorkspace
                    }
                }
            }
            .ignoresSafeArea(.container, edges: tab != .profile ? .bottom : [])
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: tab == .profile ? floatingNavigationHeight : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                FloatingNavigationBar(
                    selection: $tab, artwork: currentArtwork, onArtworkFrame: { compactArtworkFrame = $0 },
                    detailsExpanded: showingPlaybackDetails, onOpenDetails: openPlaybackDetails
                ).padding(.top, 12).padding(.bottom, 18)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        floatingNavigationHeight = $0
                    }
            }
        }
        .onChange(of: store.selection) { _, page in
            switch page {
            case .sources, .source: tab = .profile
            case .favorites: tab = .favorites
            default: break
            }
        }
    }

    private var playbackIdentity: String {
        playbackPresentationIdentity(userID: store.user?.id, track: store.player.currentTrack, sources: store.sources)
    }

    private struct LyricsRequest: Equatable {
        let identity: String
        let cacheVersion: Int
        let retry: Int
    }

    private var lyricsRequest: LyricsRequest {
        LyricsRequest(identity: playbackIdentity, cacheVersion: store.mediaCache.token(), retry: lyricsRetry)
    }

    private var currentLyrics: PlaybackLyricsContent {
        guard let playbackLyrics, playbackLyrics.request == lyricsRequest else { return .loading }
        return playbackLyrics.content
    }

    private func loadPlaybackLyrics() async {
        let request = lyricsRequest
        guard let track = store.player.currentTrack, store.user != nil else {
            playbackLyrics = nil
            return
        }
        var content = PlaybackLyricsContent.unavailable
        for binding in playbackBindings(track: track, sources: store.sources) {
            do {
                let timeline = try await store.sourceLyricsTimeline(
                    sourceID: binding.sourceConnectionID, trackID: binding.sourceTrackID)
                if !timeline.plainText.isEmpty || !timeline.sungCues.isEmpty {
                    content = .loaded(timeline)
                    break
                }
            } catch let failure as MusicAPIError where failure.status == 404 {
                continue
            } catch {
                content = .failed
            }
            guard !Task.isCancelled, request == lyricsRequest else { return }
        }
        guard !Task.isCancelled, request == lyricsRequest else { return }
        detailPresentation.standbyPosition = store.player.lyricPlaybackPosition()
        playbackLyrics = (request, content)
    }

    private var artworkPreloads: [(track: LibraryTrack, identity: String)] {
        guard let userID = store.user?.id else { return [] }
        return store.player.artworkPreloadTracks.map { track in
            (track, playbackPresentationIdentity(userID: userID, track: track, sources: store.sources))
        }
    }

    private var currentArtwork: PlaybackArtworkSnapshot? {
        playbackArtwork?.identity == playbackIdentity ? playbackArtwork : nil
    }

    private func openPlaybackDetails() {
        guard store.player.currentTrack != nil, !playbackBackdropMotion.isExpanded else { return }
        if case .failed = currentLyrics { lyricsRetry &+= 1 }
        playbackBackdropMotion.isExpanded = true
    }

    private func closePlaybackDetails() {
        detailPresentation.standbyPosition = store.player.lyricPlaybackPosition()
        playbackBackdropMotion.isExpanded = false
        detailPresentation.isPresented = false
    }

    private func loadPlaybackArtwork() async {
        let requestedIdentity = playbackIdentity
        let cacheVersion = store.mediaCache.token()
        guard let track = store.player.currentTrack, store.user != nil else {
            playbackArtwork = nil
            return
        }
        let direction = store.player.artworkDirection
        let decoded = await Self.loadCover(
            identity: requestedIdentity, bindings: playbackBindings(track: track, sources: store.sources),
            store: store, cache: artworkCache)
        guard !Task.isCancelled, requestedIdentity == playbackIdentity, cacheVersion == store.mediaCache.token() else {
            return
        }
        playbackArtwork = PlaybackArtworkSnapshot(
            identity: requestedIdentity, title: track.title, direction: direction,
            image: decoded?.image, blurredImage: decoded?.blurredImage)
    }

    private func preloadArtwork(_ preloads: [(track: LibraryTrack, identity: String)]) async {
        guard !Task.isCancelled else { return }
        artworkCache.cancelRequests(
            except: Set(
                ([playbackIdentity] + preloads.map(\.identity)).map { $0 + "|cache:\(store.mediaCache.token())" }))
        let store = store
        let cache = artworkCache
        let requests = preloads.map { preload in
            (preload.identity, playbackBindings(track: preload.track, sources: store.sources))
        }
        await withTaskGroup(of: Void.self) { group in
            for (identity, bindings) in requests {
                group.addTask {
                    _ = await Self.loadCover(identity: identity, bindings: bindings, store: store, cache: cache)
                }
            }
        }
    }

    private static func loadCover(
        identity: String, bindings: [LibraryBinding], store: AppStore, cache: PlaybackArtworkCache
    ) async -> DecodedPlaybackArtwork? {
        guard !Task.isCancelled else { return nil }
        return await cache.artwork(for: identity + "|cache:\(store.mediaCache.token())") {
            for binding in bindings {
                do {
                    let sourceTrack = try await store.api.sourceTrack(
                        id: binding.sourceConnectionID, resourceID: binding.sourceTrackID)
                    try Task.checkCancellation()
                    guard let coverID = sourceTrack.coverID, !coverID.isEmpty else { continue }
                    if let artwork = await store.playbackCover(sourceID: binding.sourceConnectionID, coverID: coverID) {
                        return artwork
                    }
                } catch { if Task.isCancelled { return nil } }
            }
            return nil
        }
    }

    private func showSources() {
        store.selection = nil
        tab = .profile
    }

    private var profileWorkspace: some View {
        AccountSettingsView()
    }

}

struct PageHeader: View {
    var title: String
    var subtitle: String
    var symbol: String
    var count: Int? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: symbol).font(.system(size: 31, weight: .light)).foregroundStyle(
                Color(nsColor: .controlAccentColor)
            )
            .frame(width: 70, height: 70).background(
                Color(nsColor: .controlAccentColor).opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let count { Text("\(count) 首歌曲").font(.callout).foregroundStyle(.secondary) }
        }.padding(.horizontal, 28).padding(.vertical, 25)
    }
}

private struct PlaybackDetailsCloseGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.12)).interactive(), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

func durationText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let value = Int(seconds)
    return String(format: "%d:%02d", value / 60, value % 60)
}
