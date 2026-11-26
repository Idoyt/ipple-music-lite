import Foundation
import MusicCore
import Observation
import SwiftUI

/// Scroll snapshots are shared with native/SwiftUI scroll views without invalidating the page on every pixel.
@MainActor
final class QQCollectionScrollState {
    var origin: CGPoint?
    var needsRestore = false
    var isActive = false {
        didSet { if !isActive, origin != nil { needsRestore = true } }
    }
}

/// Owned by the tab container, so disappearing tab content cannot reset pagination or cancel a shared request.
@MainActor
@Observable
final class QQCollectionState {
    let kind: QQLibraryKind
    let playlistID: String?
    private(set) var tracks: [SourceTrack] = []
    private(set) var playlists: [QQPlaylistSummary] = []
    private(set) var playlist: QQPlaylistSummary?
    private(set) var cursor = QQCollectionCursor(limit: 50)
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var failure: String?
    private(set) var needsLogin = false
    private(set) var isVisible = false
    var followingPlayback = true
    var followRequest = UUID()
    private(set) var trackScroll = QQCollectionScrollState()
    private(set) var gridScroll = QQCollectionScrollState()
    var gridPosition = ScrollPosition(edge: .top)

    @ObservationIgnored private let client: MusicAPIClient
    @ObservationIgnored private let sourceID: String
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var searching = false
    @ObservationIgnored private var invalidated = false
    @ObservationIgnored private var reloading = false

    init(client: MusicAPIClient, sourceID: String, kind: QQLibraryKind, playlistID: String? = nil) {
        self.client = client
        self.sourceID = sourceID
        self.kind = kind
        self.playlistID = playlistID
    }

    func activate() {
        isVisible = true
        trackScroll.isActive = true
        gridScroll.isActive = true
        if invalidated {
            if !reloading { reloadPreservingContent() }
        } else if !started {
            started = true
            startPage()
        } else if tracks.isEmpty, playlists.isEmpty, failure == nil, cursor.hasMore {
            startPage()
        }
    }

    func deactivate(preservingLayout: Bool = false) {
        let trackNeedsRestore = trackScroll.needsRestore
        let gridNeedsRestore = gridScroll.needsRestore
        isVisible = false
        trackScroll.isActive = false
        gridScroll.isActive = false
        if preservingLayout {
            trackScroll.needsRestore = trackNeedsRestore
            gridScroll.needsRestore = gridNeedsRestore
        }
    }

    func refresh() {
        invalidated = false
        cancelPendingRequest()
        tracks = []
        playlists = []
        playlist = nil
        cursor = QQCollectionCursor(limit: 50)
        failure = nil
        needsLogin = false
        trackScroll = QQCollectionScrollState()
        gridScroll = QQCollectionScrollState()
        gridPosition = ScrollPosition(edge: .top)
        trackScroll.isActive = isVisible
        gridScroll.isActive = isVisible
        started = true
        startPage()
    }

    /// 收藏写入后保留原内容和滚动位置，原位重取已经加载的分页。
    func invalidate() {
        invalidated = true
        if isVisible { reloadPreservingContent() }
    }

    private func reloadPreservingContent() {
        cancelPendingRequest()
        invalidated = true
        reloading = true
        started = true
        let ticket = revision
        let end = max(cursor.limit, cursor.nextOffset)
        loading = tracks.isEmpty && playlists.isEmpty
        loadingMore = !loading
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var next = QQCollectionCursor(limit: 50)
                var newTracks: [SourceTrack] = []
                var newPlaylists: [QQPlaylistSummary] = []
                while next.hasMore && next.nextOffset < end {
                    let page = try await client.qqLibrary(
                        sourceID: sourceID, kind: kind, playlistID: playlistID, offset: next.nextOffset,
                        limit: next.limit)
                    guard revision == ticket, !Task.isCancelled else { return }
                    try next.accept(
                        offset: page.offset, limit: page.limit, total: page.total, hasMore: page.hasMore,
                        sessionVersion: page.sessionVersion,
                        count: kind == .playlists ? page.playlists.count : page.tracks.count)
                    newTracks.append(contentsOf: page.tracks)
                    newPlaylists.append(contentsOf: page.playlists)
                    if let playlist = page.playlist { self.playlist = playlist }
                }
                guard revision == ticket, !Task.isCancelled else { return }
                tracks = newTracks
                playlists = newPlaylists
                cursor = next
                failure = nil
                needsLogin = false
                invalidated = false
            } catch {
                guard revision == ticket, !Task.isCancelled else { return }
                failure = error.localizedDescription
                invalidated = true
            }
            guard revision == ticket else { return }
            task = nil
            reloading = false
            loading = false
            loadingMore = false
        }
    }

    func requestMore() {
        guard isVisible, failure == nil, cursor.hasMore else { return }
        if invalidated {
            if !reloading { reloadPreservingContent() }
            return
        }
        startPage()
    }

    func retryMore() {
        failure = nil
        needsLogin = false
        if invalidated, isVisible { reloadPreservingContent() } else { requestMore() }
    }

    func setSearching(_ value: Bool) {
        searching = value
        if value { requestMore() }
    }

    func matchingTrackIndices(_ query: String) -> [Int] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return tracks.indices.filter { index in
            let track = tracks[index]
            return ([track.title, track.album] + track.artists).contains { $0.localizedStandardContains(text) }
        }
    }

    func matchingPlaylists(_ query: String) -> [QQPlaylistSummary] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return playlists.filter { $0.kind != "favorites" && $0.name.localizedStandardContains(text) }
    }

    func cancelPendingRequest() {
        revision = UUID()
        task?.cancel()
        task = nil
        reloading = false
        loading = false
        loadingMore = false
    }

    private func startPage() {
        guard task == nil, cursor.hasMore else { return }
        let ticket = revision
        loading = tracks.isEmpty && playlists.isEmpty
        loadingMore = !loading
        let offset = cursor.nextOffset
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let page = try await self.client.qqLibrary(
                    sourceID: self.sourceID, kind: self.kind, playlistID: self.playlistID,
                    offset: offset, limit: self.cursor.limit)
                guard self.revision == ticket, !Task.isCancelled else { return }
                try self.cursor.accept(
                    offset: page.offset, limit: page.limit, total: page.total, hasMore: page.hasMore,
                    sessionVersion: page.sessionVersion,
                    count: self.kind == .playlists ? page.playlists.count : page.tracks.count)
                self.tracks.append(contentsOf: page.tracks)
                if let playlist = page.playlist { self.playlist = playlist }
                let existing = Set(self.playlists.map(\.id))
                self.playlists.append(contentsOf: page.playlists.filter { !existing.contains($0.id) })
                self.failure = nil
                self.needsLogin = false
            } catch {
                guard self.revision == ticket, !Task.isCancelled else { return }
                self.failure = error.localizedDescription
                self.needsLogin = ["SOURCE_CREDENTIALS", "SOURCE_AUTH_REQUIRED"].contains(
                    (error as? MusicAPIError)?.code ?? "")
            }
            guard self.revision == ticket else { return }
            self.task = nil
            self.loading = false
            self.loadingMore = false
            if self.isVisible, self.failure == nil, self.cursor.hasMore,
                self.searching || (self.kind == .playlists ? self.playlists.isEmpty : self.tracks.isEmpty)
            {
                self.startPage()
            }
        }
    }
}

@MainActor
@Observable
final class QQFavoritesCollections {
    let songs: QQCollectionState
    let playlists: QQCollectionState
    private(set) var details: [String: QQCollectionState] = [:]
    var selectedPlaylist: QQPlaylistSummary?
    @ObservationIgnored private let client: MusicAPIClient
    @ObservationIgnored private let sourceID: String

    init(client: MusicAPIClient, sourceID: String) {
        self.client = client
        self.sourceID = sourceID
        songs = QQCollectionState(client: client, sourceID: sourceID, kind: .favorites)
        playlists = QQCollectionState(client: client, sourceID: sourceID, kind: .playlists)
    }

    func openPlaylist(_ playlist: QQPlaylistSummary) {
        if details[playlist.id] == nil {
            details[playlist.id] = QQCollectionState(
                client: client, sourceID: sourceID, kind: .playlist, playlistID: playlist.id)
        }
        selectedPlaylist = playlist
    }

    func cancelPendingRequests() {
        for state in [songs, playlists] + Array(details.values) {
            state.setSearching(false)
            state.deactivate()
            state.cancelPendingRequest()
        }
    }
}
