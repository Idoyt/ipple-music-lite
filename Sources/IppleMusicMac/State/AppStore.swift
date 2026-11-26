import Foundation
import MusicCore
import Observation

enum NavigationPage: Hashable {
    case library, favorites, history, sources, queue
    case playlist(String)
    case source(String)
}

private enum AccountWork {
    @TaskLocal static var generation: Int?
}

@MainActor @Observable
final class AppStore {
    let api: MusicAPIClient
    let player: PlaybackController
    let mediaCache: MediaDiskCache
    private let recommendationCache = RecommendationCache()
    var settings = AppSettings.load()
    var user: User?
    var selection: NavigationPage? = .library
    var tracks: [LibraryTrack] = []
    var favorites: [LibraryTrack] = []
    var playlists: [LibraryPlaylist] = []
    var sources: [SourceConnection] = [] {
        didSet {
            player.updateCacheSources(sources)
            recommendationCache.retainScopes(Set(sources.compactMap { try? recommendationScope($0) }))
        }
    }
    var history: [PlayHistoryRecord] = []
    var activePlaylist: LibraryPlaylist?
    var query = ""
    var isLoading = false
    var isSigningIn = false
    var isRestoringSession = true
    var sessionRestoreError: String?
    var error: String?
    var notice: String?
    var lastSync: Date?
    private var cursor: String?
    private var generation = 0
    private var contentRevision = 0
    @ObservationIgnored private var attemptedSessionRestoration = false
    @ObservationIgnored private var authenticationTask: Task<Void, Never>?
    @ObservationIgnored private var authenticationID: UUID?
    @ObservationIgnored private var signingOut = false
    @ObservationIgnored private var credentialReset: Task<Void, Never>?
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var loadingID: UUID?
    @ObservationIgnored private var reloadRequested = false
    @ObservationIgnored private var mutationTasks: [UUID: Task<Void, Never>] = [:]
    private var favoriteRequests = Set<String>()
    private var favoriteAdditions = Set<String>()
    private var qqFavoriteStates: [String: Bool] = [:]
    private(set) var qqFavoriteRevisions: [String: Int] = [:]
    @ObservationIgnored private var recommendationPlaybackID = UUID()
    @ObservationIgnored private var recommendationImportTask: Task<[LibraryTrack], Error>?
    @ObservationIgnored private var playlistRequest = UUID()
    @ObservationIgnored private var lyricTimelines: [String: LyricsTimeline] = [:]
    @ObservationIgnored private var lyricTimelineTasks: [String: Task<LyricsTimeline, Error>] = [:]

    init(
        api: MusicAPIClient = LocalQQRuntime.client(),
        mediaCache: MediaDiskCache = AppSettings.mediaCache
    ) {
        self.api = api
        self.mediaCache = mediaCache
        player = PlaybackController(
            client: api,
            sessionDirectory: CommandLine.arguments.contains("--smoke-test")
                ? nil : AppSettings.playbackSessionDirectory, mediaCache: mediaCache)
        settings.serverURL = MusicAPIClient.localOrigin.absoluteString
    }

    var favoriteIDs: Set<String> {
        Set(
            (tracks + favorites).filter { track in
                guard let binding = qqFavoriteBinding(track) else { return false }
                return qqFavoriteStates[qqFavoriteKey(binding)] == true
            }.map(\.id))
    }
    func isFavorite(_ trackID: String) -> Bool {
        guard
            let track = player.currentTrack.flatMap({ $0.id == trackID ? $0 : nil })
                ?? tracks.first(where: { $0.id == trackID }) ?? favorites.first(where: { $0.id == trackID }),
            let binding = qqFavoriteBinding(track)
        else { return false }
        return qqFavoriteStates[qqFavoriteKey(binding)] == true
    }
    func isUpdatingFavorite(_ trackID: String) -> Bool { favoriteRequests.contains(trackID) }
    func isAddingFavorite(_ trackID: String) -> Bool { favoriteAdditions.contains(trackID) }

    func setQQTrackAsNext(_ track: SourceTrack, from source: SourceConnection) async {
        await perform { [self] in
            let imported = try await importQQTrackForRow(track, from: source)
            player.setNextTrack(imported)
            notice = "已将「\(track.title)」设为下一曲"
        }
    }

    func toggleQQTrackFavorite(_ track: SourceTrack, from source: SourceConnection) async {
        await perform { [self] in
            let imported = try await importQQTrackForRow(track, from: source)
            await toggleFavorite(imported)
        }
    }

    private func importQQTrackForRow(_ track: SourceTrack, from source: SourceConnection) async throws -> LibraryTrack {
        let ticket = generation
        let scope = try recommendationScope(source)
        let imported = try await checked(ticket) {
            try await api.importSourceTrack(connectionID: source.id, trackID: track.id)
        }
        guard try recommendationScope(source) == scope else { throw CancellationError() }
        return imported
    }

    private func qqFavoriteBinding(_ track: LibraryTrack) -> LibraryBinding? {
        track.bindings.first { binding in
            binding.confirmed
                && sources.contains {
                    $0.id == binding.sourceConnectionID && $0.kind == "qq" && $0.enabled && $0.state == "active"
                        && $0.ownerID == user?.id
                }
        }
    }
    private func qqFavoriteKey(_ binding: LibraryBinding) -> String {
        binding.sourceConnectionID + ":" + String(sources.first { $0.id == binding.sourceConnectionID }?.version ?? 0)
            + ":" + binding.sourceTrackID
    }
    func refreshQQFavorite(_ track: LibraryTrack) async {
        let ticket = generation
        guard current(ticket), let binding = qqFavoriteBinding(track), favoriteRequests.insert(track.id).inserted else {
            return
        }
        let key = qqFavoriteKey(binding)
        defer { if generation == ticket { favoriteRequests.remove(track.id) } }
        do {
            let result = try await checked(ticket) {
                try await api.qqFavoriteState(sourceID: binding.sourceConnectionID, ids: [binding.sourceTrackID])
            }
            guard key == qqFavoriteKey(binding), let liked = result.liked[binding.sourceTrackID] else { return }
            qqFavoriteStates[key] = liked
        } catch { /* 自动预读失败不打断播放，点击收藏时重新核对并显示错误。 */  }
    }

    func setMenuBarWidth(_ width: Double) throws {
        var updated = settings
        updated.menuBarWidth = AppSettings.normalizedMenuBarWidth(width)
        try updated.save()
        settings = updated
    }

    func coverData(sourceID: String, coverID: String) async throws -> Data {
        let ticket = generation
        let namespace = [settings.serverURL, user?.id ?? "anonymous", sourceID, coverID]
        let api = api
        let data = try await mediaCache.data(namespace: namespace) {
            try await api.coverData(id: sourceID, coverID: coverID)
        }
        try check(ticket)
        return data
    }
    func sourceLyrics(sourceID: String, trackID: String) async throws -> SourceLyrics {
        let ticket = generation
        let sourceVersion = sources.first { $0.id == sourceID }?.version ?? 0
        let namespace = [
            settings.serverURL, user?.id ?? "anonymous", sourceID, String(sourceVersion), trackID, "lyrics-v1",
        ]
        let api = api
        let data = try await mediaCache.data(kind: .lyrics, namespace: namespace) {
            try MusicJSON.encoder().encode(try await api.sourceLyrics(id: sourceID, resourceID: trackID))
        }
        try check(ticket)
        return try MusicJSON.decoder().decode(SourceLyrics.self, from: data)
    }

    /// The menu bar and detail page share both parsed timelines and in-flight requests.
    func sourceLyricsTimeline(sourceID: String, trackID: String) async throws -> LyricsTimeline {
        let version = sources.first { $0.id == sourceID }?.version ?? 0
        let cacheToken = mediaCache.token()
        let key =
            "\(generation)|\(cacheToken)|\(settings.serverURL)|\(user?.id ?? "")|\(sourceID)|\(version)|\(trackID)"
        if let timeline = lyricTimelines[key] { return timeline }
        if let task = lyricTimelineTasks[key] { return try await task.value }
        let ticket = generation
        let task = Task {
            defer { lyricTimelineTasks[key] = nil }
            let result = try await sourceLyrics(sourceID: sourceID, trackID: trackID)
            try check(ticket)
            guard cacheToken == mediaCache.token() else { throw CancellationError() }
            let timeline = LyricsTimeline(lrc: result.text, translation: result.translation, lines: result.lines)
            if !timeline.plainText.isEmpty || !timeline.sungCues.isEmpty {
                // Keep this small independently of the shared disk cache.
                if lyricTimelines.count >= 8 { lyricTimelines.removeAll(keepingCapacity: true) }
                lyricTimelines[key] = timeline
            }
            return timeline
        }
        lyricTimelineTasks[key] = task
        return try await task.value
    }

    var trackByID: [String: LibraryTrack] {
        Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func current(_ ticket: Int, signedIn: Bool = true) -> Bool {
        generation == ticket && (!signedIn || user != nil) && !Task.isCancelled
            && (AccountWork.generation == nil || AccountWork.generation == ticket)
    }

    private func check(_ ticket: Int) throws {
        guard current(ticket) else { throw CancellationError() }
    }

    private func checked<Value>(_ ticket: Int, _ request: () async throws -> Value) async throws -> Value {
        try check(ticket)
        let value = try await request()
        try check(ticket)
        return value
    }

    func signInQQ(_ candidate: QQSessionCandidate) async {
        if settings.clientDeviceID == nil { settings.clientDeviceID = UUID() }
        guard let deviceID = settings.clientDeviceID else { return }
        do { try settings.save() } catch {
            show(error)
            return
        }
        await authenticate { api in
            try await api.loginQQ(candidate: candidate, clientDeviceID: deviceID)
        }
    }

    private func authenticate(_ login: @escaping @Sendable (MusicAPIClient) async throws -> AuthResponse) async {
        guard !isSigningIn, !signingOut, settings.pendingLocalLogout == nil else { return }
        let url = MusicAPIClient.localOrigin
        clearAccount()
        let ticket = generation
        let operation = UUID()
        authenticationID = operation
        isSigningIn = true
        let reset = credentialReset
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await reset?.value
                guard current(ticket, signedIn: false) else { return }
                let auth = try await login(api)
                guard current(ticket, signedIn: false) else { return }
                await activate(auth.user, server: url, ticket: ticket)
            } catch {
                guard current(ticket, signedIn: false) else { return }
                await api.invalidateRequests()
                guard current(ticket, signedIn: false) else { return }
                show(error)
            }
        }
        authenticationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if authenticationID == operation {
            authenticationTask = nil
            authenticationID = nil
            isSigningIn = false
        }
    }

    private func activate(_ account: User, server: URL, ticket: Int) async {
        guard current(ticket, signedIn: false) else { return }
        user = account
        player.configureSession(serverURL: server, accountID: account.id)
        settings.serverURL = server.absoluteString
        settings.sessionRestorationEnabled = true
        do { try settings.save() } catch { show(error) }
        await refresh()
        guard current(ticket) else { return }
        let playbackRevision = player.playbackRevision
        await player.restoreLocalSession()
        guard current(ticket), player.playbackRevision == playbackRevision else { return }
        await player.prepareCurrentTrack()
    }

    func restoreSessionOnStartup(retry: Bool = false) async {
        guard user == nil, !signingOut, !isSigningIn,
            retry || !attemptedSessionRestoration
        else { return }
        attemptedSessionRestoration = true
        sessionRestoreError = nil
        guard settings.sessionRestorationEnabled != false else {
            isRestoringSession = false
            return
        }
        let ticket = generation
        let operation = UUID()
        authenticationID = operation
        isRestoringSession = true
        isSigningIn = true
        let reset = credentialReset
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await reset?.value
                guard current(ticket, signedIn: false) else { return }
                let url = MusicAPIClient.localOrigin
                if let account = try await api.restoreSession() {
                    guard current(ticket, signedIn: false) else { return }
                    await activate(account, server: url, ticket: ticket)
                }
            } catch {
                guard current(ticket, signedIn: false) else { return }
                // 暂时断网或钥匙串不可用时保留记录，让用户重试恢复。
                if !(error is CancellationError), (error as? MusicAPIError)?.code != "CANCELLED" {
                    sessionRestoreError = error.localizedDescription
                }
            }
        }
        authenticationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if authenticationID == operation {
            authenticationTask = nil
            authenticationID = nil
            isRestoringSession = false
            isSigningIn = false
        }
    }

    func signOut(eraseLocalData: Bool = false) async {
        guard !signingOut else { return }
        guard let account = user else { return }
        signingOut = true
        do {
            var next = settings
            var cleanup = AppSettings.LogoutCleanup()
            if eraseLocalData {
                let server = MusicAPIClient.localOrigin
                cleanup.libraryKey = try await api.localLibraryRemovalKey()
                cleanup.playbackKey = PlaybackSessionScope(server: server, accountID: account.id).key
                cleanup.mediaOwner = MediaDiskCache.ownerKey(server: server.absoluteString, account: account.id)
            }
            next.pendingLocalLogout = cleanup
            next.sessionRestorationEnabled = false
            try next.save()
            settings = next
        } catch {
            signingOut = false
            show(error)
            return
        }
        resetAccount(clearCredentials: false)
        await finishLocalLogout()
    }

    func finishLocalLogout() async {
        guard user == nil, !signingOut, let cleanup = settings.pendingLocalLogout else { return }
        signingOut = true
        isSigningIn = true
        defer { signingOut = false; isSigningIn = false }
        do {
            try await api.logout()
        } catch {
            self.error = "已停止自动登录，但未能退出当前账户。请重试。"
            return
        }
        do {
            if let key = cleanup.libraryKey { try await api.eraseLocalLibrary(key: key) }
            if let key = cleanup.playbackKey {
                guard key.count == 64, key.allSatisfy(\.isHexDigit) else {
                    throw MusicAPIError(status: 400, code: "INVALID_INPUT")
                }
                let url = AppSettings.playbackSessionDirectory.appendingPathComponent(key + ".json")
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            if let owner = cleanup.mediaOwner { try await mediaCache.clear(owner: owner) }
            var next = settings
            next.pendingLocalLogout = nil
            try next.save()
            settings = next
            error = nil
            notice = cleanup.libraryKey == nil ? "已退出登录" : "已退出并删除此账号的本机数据"
        } catch {
            self.error = "账户已退出，本机清理尚未完成。请重试。"
        }
    }

    func clearAccount() { resetAccount(clearCredentials: true) }

    private func resetAccount(clearCredentials: Bool) {
        generation += 1
        recommendationCache.clear()
        for task in lyricTimelineTasks.values { task.cancel() }
        lyricTimelineTasks.removeAll()
        lyricTimelines.removeAll()
        authenticationTask?.cancel()
        authenticationTask = nil
        authenticationID = nil
        loadingTask?.cancel()
        loadingTask = nil
        loadingID = nil
        for task in mutationTasks.values { task.cancel() }
        mutationTasks.removeAll()
        recommendationImportTask?.cancel()
        recommendationImportTask = nil
        recommendationPlaybackID = UUID()
        favoriteRequests.removeAll()
        favoriteAdditions.removeAll()
        qqFavoriteStates.removeAll()
        qqFavoriteRevisions.removeAll()
        reloadRequested = false
        isLoading = false
        isSigningIn = false
        isRestoringSession = false
        sessionRestoreError = nil
        signingOut = false
        player.stop()
        user = nil
        tracks = []
        favorites = []
        playlists = []
        sources = []
        history = []
        activePlaylist = nil
        cursor = nil
        selection = .library
        query = ""
        lastSync = nil
        error = nil
        notice = nil
        playlistRequest = UUID()
        contentRevision = 0
        if clearCredentials {
            // Every new sign-in waits for this chain, so a delayed reset cannot erase a newer login.
            let previous = credentialReset
            let client = api
            credentialReset = Task {
                await previous?.value
                await client.invalidateRequests()
            }
        }
    }

    func show(_ failure: Error) {
        guard !Task.isCancelled, AccountWork.generation == nil || AccountWork.generation == generation,
            !(failure is CancellationError), (failure as? MusicAPIError)?.code != "CANCELLED"
        else { return }
        if let apiError = failure as? MusicAPIError, apiError.status == 401, user != nil { clearAccount() }
        error = (failure as? MusicAPIError)?.code == "SYNC_BUSY" ? "资料正在持续更新，请稍后刷新。" : failure.localizedDescription
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        let ticket = generation
        guard current(ticket) else { return }
        let id = UUID()
        contentRevision += 1
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await AccountWork.$generation.withValue(ticket) {
                do {
                    try check(ticket)
                    try await action()
                    if current(ticket) { contentRevision += 1 }
                } catch {
                    guard current(ticket) else { return }
                    contentRevision += 1
                    show(error)
                }
            }
        }
        mutationTasks[id] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        mutationTasks.removeValue(forKey: id)
    }

    func refresh() async { await load(force: true) }
    func synchronize() async { await load(force: false) }

    private func load(force: Bool) async {
        let ticket = generation
        guard current(ticket) else { return }
        if let loadingTask {
            if force {
                reloadRequested = true
                await loadingTask.value
            }
            return
        }
        let id = UUID()
        loadingID = id
        isLoading = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var needsFullLoad = force
            repeat {
                guard current(ticket) else { return }
                reloadRequested = false
                do { try await loadAccount(ticket, force: needsFullLoad) } catch { if current(ticket) { show(error) } }
                needsFullLoad = true
            } while reloadRequested && current(ticket)
        }
        loadingTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if loadingID == id {
            loadingTask = nil
            loadingID = nil
            isLoading = false
        }
    }

    private struct SyncHead {
        var cursor: String
        var changed: Bool
        var reset: Bool
    }

    private func syncHead(_ ticket: Int, from cursor: String?) async throws -> SyncHead {
        var next = cursor
        var changed = false
        for _ in 0..<10_000 {
            do {
                let page = try await checked(ticket) { try await api.syncChanges(cursor: next, limit: 100) }
                changed = changed || page.changes.contains { $0.kind != "playback_snapshot" }
                if page.hasMore, page.nextCursor == next || page.changes.isEmpty {
                    throw MusicAPIError(status: 0, code: "INVALID_RESPONSE")
                }
                next = page.nextCursor
                if !page.hasMore { return SyncHead(cursor: page.nextCursor, changed: changed, reset: false) }
            } catch let failure as MusicAPIError where failure.status == 410 {
                try check(ticket)
                guard let anchor = failure.syncResetCursor, !anchor.isEmpty else { throw failure }
                return SyncHead(cursor: anchor, changed: true, reset: true)
            }
        }
        throw MusicAPIError(status: 0, code: "INVALID_RESPONSE")
    }

    private struct Snapshot {
        var tracks: [LibraryTrack]
        var favorites: [LibraryTrack]
        var playlists: [LibraryPlaylist]
        var sources: [SourceConnection]
        var history: [PlayHistoryRecord]
    }

    private func allPages<Item: Identifiable>(_ ticket: Int, fetch: (Int) async throws -> ([Item], Bool)) async throws
        -> [Item]
    {
        var indices: [Item.ID: Int] = [:]
        var unique: [Item] = []
        var offset = 0
        for _ in 0..<10_000 {
            let (items, hasMore) = try await checked(ticket) { try await fetch(offset) }
            let previousCount = unique.count
            for item in items {
                if let index = indices[item.id] {
                    unique[index] = item
                } else {
                    indices[item.id] = unique.count
                    unique.append(item)
                }
            }
            if !hasMore { return unique }
            // Repeated IDs with has_more cannot make progress; never loop through a broken page forever.
            guard !items.isEmpty, unique.count > previousCount,
                offset <= 1_000_000 - items.count
            else { throw MusicAPIError(status: 0, code: "INVALID_RESPONSE") }
            offset += items.count
        }
        throw MusicAPIError(status: 0, code: "INVALID_RESPONSE")
    }

    private func snapshot(_ ticket: Int) async throws -> Snapshot {
        let loadedTracks = try await allPages(ticket) { offset in
            let page = try await api.libraryTracks(offset: offset, limit: 100)
            return (page.items, page.hasMore)
        }
        let loadedFavorites = try await allPages(ticket) { offset in
            let page = try await api.favorites(offset: offset, limit: 100)
            return (page.items, page.hasMore)
        }
        let summaries = try await allPages(ticket) { offset in
            let page = try await api.playlists(offset: offset, limit: 100)
            return (page.items, page.hasMore)
        }
        var loadedPlaylists: [LibraryPlaylist] = []
        for summary in summaries {
            do {
                loadedPlaylists.append(try await checked(ticket) { try await api.getPlaylist(id: summary.id) })
            } catch let failure as MusicAPIError where failure.status == 404 { continue }
        }
        let loadedSources = try await allPages(ticket) { offset in
            let page = try await api.sourcePage(offset: offset, limit: 100)
            return (page.items, page.items.count == 100)
        }
        let loadedHistory = try await allPages(ticket) { offset in
            let page = try await api.playHistory(offset: offset, limit: 100)
            return (page.items, page.hasMore)
        }
        return Snapshot(
            tracks: loadedTracks, favorites: loadedFavorites, playlists: loadedPlaylists, sources: loadedSources,
            history: loadedHistory)
    }

    private func loadAccount(_ ticket: Int, force: Bool) async throws {
        let initial = try await syncHead(ticket, from: cursor)
        if force || cursor == nil || initial.changed || initial.reset {
            var anchor = initial.cursor
            for _ in 0..<3 {
                await player.waitForPersonalRadioBatch()
                try check(ticket)
                // A recommendation batch creates multiple canonical tracks. Wait for that
                // finite mutation before taking a snapshot, without spending sync retries.
                if let imports = recommendationImportTask {
                    _ = await imports.result
                    try check(ticket)
                }
                let revision = contentRevision
                let loaded = try await snapshot(ticket)
                let after = try await syncHead(ticket, from: anchor)
                if after.changed || after.reset || contentRevision != revision {
                    anchor = after.cursor
                    continue
                }
                try check(ticket)
                tracks = loaded.tracks
                favorites = loaded.favorites
                playlists = loaded.playlists
                sources = loaded.sources
                history = loaded.history
                playlistRequest = UUID()
                if case .playlist(let id) = selection {
                    activePlaylist = playlists.first { $0.id == id }
                    if activePlaylist == nil { selection = .library }
                } else {
                    activePlaylist = nil
                }
                if case .source(let id) = selection, !sources.contains(where: { $0.id == id }) { selection = .library }
                cursor = after.cursor
                try await checked(ticket) { try await api.acknowledgeSync(cursor: after.cursor) }
                lastSync = Date()
                return
            }
            // A changing offset projection cannot be acknowledged safely. Keep the old cursor for retry.
            throw MusicAPIError(status: 0, code: "SYNC_BUSY", message: "资料正在持续更新，请稍后刷新。")
        }

        try check(ticket)
        cursor = initial.cursor
        try await checked(ticket) { try await api.acknowledgeSync(cursor: initial.cursor) }
        lastSync = Date()
    }

    func loadPlaylist(_ id: String) async {
        let ticket = generation
        guard current(ticket) else { return }
        let request = UUID()
        playlistRequest = request
        activePlaylist = nil
        do {
            let loaded = try await checked(ticket) { try await api.getPlaylist(id: id) }
            guard playlistRequest == request, selection == .playlist(id) else { return }
            activePlaylist = loaded
        } catch { if current(ticket), playlistRequest == request, selection == .playlist(id) { show(error) } }
    }

    func toggleFavorite(_ track: LibraryTrack) async {
        let ticket = generation
        guard current(ticket), favoriteRequests.insert(track.id).inserted else { return }
        if !isFavorite(track.id) { favoriteAdditions.insert(track.id) }
        defer {
            if current(ticket) {
                favoriteRequests.remove(track.id)
                favoriteAdditions.remove(track.id)
            }
        }
        await perform { [self] in
            guard let binding = qqFavoriteBinding(track) else {
                throw MusicAPIError(status: 422, code: "SOURCE_UNSUPPORTED")
            }
            let key = qqFavoriteKey(binding)
            let before = try await checked(ticket) {
                try await api.qqFavoriteState(sourceID: binding.sourceConnectionID, ids: [binding.sourceTrackID])
            }
            guard key == qqFavoriteKey(binding), let liked = before.liked[binding.sourceTrackID] else {
                throw MusicAPIError(status: 409, code: "VERSION_CONFLICT")
            }
            qqFavoriteStates[key] = liked
            if liked { favoriteAdditions.remove(track.id) }
            else { favoriteAdditions.insert(track.id) }
            do {
                let result = try await checked(ticket) {
                    try await api.setQQFavorite(
                        sourceID: binding.sourceConnectionID, trackID: binding.sourceTrackID, enabled: !liked,
                        sessionVersion: before.sessionVersion)
                }
                guard key == qqFavoriteKey(binding), result.sessionVersion == before.sessionVersion,
                    result.liked[binding.sourceTrackID] == !liked
                else { throw MusicAPIError(status: 409, code: "VERSION_CONFLICT") }
                qqFavoriteStates[key] = !liked
                qqFavoriteRevisions[binding.sourceConnectionID, default: 0] += 1
            } catch {
                // 超时可能发生在 QQ 已写入之后；重新读取真实状态，不用本地乐观值冒充成功。
                if current(ticket),
                    let actual = try? await checked(
                        ticket,
                        {
                            try await api.qqFavoriteState(
                                sourceID: binding.sourceConnectionID, ids: [binding.sourceTrackID])
                        }), key == qqFavoriteKey(binding), let value = actual.liked[binding.sourceTrackID]
                {
                    qqFavoriteStates[key] = value
                    if value != liked { qqFavoriteRevisions[binding.sourceConnectionID, default: 0] += 1 }
                }
                throw error
            }
        }
    }

    func createPlaylist(name: String, description: String = "") async {
        let ticket = generation
        await perform { [self] in
            let playlist = try await checked(ticket) {
                try await api.createPlaylist(name: name, description: description)
            }
            playlists.insert(playlist, at: 0)
            activePlaylist = playlist
            selection = .playlist(playlist.id)
        }
    }

    func add(_ track: LibraryTrack, to playlist: LibraryPlaylist) async {
        let ticket = generation
        await perform { [self] in
            let current = try await checked(ticket) { try await api.getPlaylist(id: playlist.id) }
            let updated = try await checked(ticket) {
                try await api.addPlaylistEntry(playlistID: playlist.id, trackID: track.id, version: current.version)
            }
            if let index = playlists.firstIndex(where: { $0.id == updated.id }) { playlists[index] = updated }
            notice = "已加入「\(playlist.name)」"
            if selection == .playlist(playlist.id) { activePlaylist = updated }
        }
    }

    func deletePlaylist(_ playlist: LibraryPlaylist) async {
        let ticket = generation
        await perform { [self] in
            try await checked(ticket) { try await api.deletePlaylist(id: playlist.id, version: playlist.version) }
            playlists.removeAll { $0.id == playlist.id }
            if selection == .playlist(playlist.id) {
                selection = .library
                activePlaylist = nil
                playlistRequest = UUID()
            }
        }
    }

    func importTrack(_ track: SourceTrack, from source: SourceConnection, play: Bool = false) async {
        let ticket = generation
        let playbackID = UUID()
        if play {
            recommendationImportTask?.cancel()
            recommendationImportTask = nil
            recommendationPlaybackID = playbackID
        }
        await perform { [self] in
            let imported = try await checked(ticket) {
                try await api.importSourceTrack(connectionID: source.id, trackID: track.id)
            }
            if let index = tracks.firstIndex(where: { $0.id == imported.id }) {
                tracks[index] = imported
            } else {
                tracks.append(imported)
            }
            if play {
                try check(ticket)
                guard recommendationPlaybackID == playbackID else { return }
                await player.play(imported)
            } else {
                notice = "已将「\(imported.title)」加入资料库"
            }
        }
    }

    func playRecommendations(_ recommendations: [SourceTrack], from source: SourceConnection) async {
        guard !recommendations.isEmpty, source.ownerID == user?.id else { return }
        let ticket = generation
        let requestID = UUID()
        recommendationImportTask?.cancel()
        recommendationPlaybackID = requestID
        let api = api
        let importTask = Task { try await api.importSourceQueue(sourceID: source.id, tracks: recommendations) }
        recommendationImportTask = importTask
        defer {
            if recommendationPlaybackID == requestID { recommendationImportTask = nil }
        }
        let revision = player.playbackRevision
        let wasPlaying = player.isPlaying
        await perform { [self] in
            let imported = try await checked(ticket) {
                try await withTaskCancellationHandler {
                    try await importTask.value
                } onCancel: {
                    importTask.cancel()
                }
            }
            let current = try await checked(ticket) { try await api.getSource(id: source.id) }
            guard current.version == source.version, current.enabled, current.state == "active" else {
                throw MusicAPIError(status: 409, code: "VERSION_CONFLICT")
            }
            guard recommendationPlaybackID == requestID, player.playbackRevision == revision,
                player.isPlaying == wasPlaying
            else { return }
            let ids = Set(imported.map(\.id))
            tracks.removeAll { ids.contains($0.id) }
            tracks.append(contentsOf: imported)
            if let first = imported.first { await player.play(first, inQueue: imported) }
        }
    }

    private func recommendationScope(_ source: SourceConnection) throws -> String {
        guard let account = user?.id, source.ownerID == account, source.kind == "qq", source.enabled,
            source.state == "active",
            sources.contains(where: {
                $0.id == source.id && $0.ownerID == account && $0.version == source.version && $0.enabled
                    && $0.state == "active"
            })
        else { throw MusicAPIError(status: 409, code: "VERSION_CONFLICT") }
        return [settings.serverURL, account, source.id, String(source.version)].joined(separator: "\u{1f}")
    }

    func recommendationPreview(from source: SourceConnection, mode: DiscoveryMode) async throws -> SourceDiscovery {
        let ticket = generation
        let scope = try recommendationScope(source)
        let result = try await recommendationCache.preview(client: api, sourceID: source.id, scope: scope, mode: mode)
        try check(ticket)
        guard try recommendationScope(source) == scope else { throw CancellationError() }
        return result
    }

    func dailyRecommendations(from source: SourceConnection) async throws -> SourceDiscovery {
        let ticket = generation
        let scope = try recommendationScope(source)
        let result = try await recommendationCache.daily(client: api, sourceID: source.id, scope: scope)
        try check(ticket)
        guard try recommendationScope(source) == scope else { throw CancellationError() }
        return result
    }

    func cachedRadioArtwork(from source: SourceConnection) -> (current: SourceTrack, next: SourceTrack?)? {
        guard let scope = try? recommendationScope(source) else { return nil }
        return recommendationCache.radioArtwork(scope: scope)
    }

    func rememberRadioArtwork(from source: SourceConnection, current: SourceTrack, next: SourceTrack?) {
        guard let scope = try? recommendationScope(source) else { return }
        recommendationCache.rememberRadioArtwork(scope: scope, current: current, next: next)
    }

    func playPersonalRadio(from source: SourceConnection) async {
        guard source.ownerID == user?.id else { return }
        recommendationImportTask?.cancel()
        recommendationPlaybackID = UUID()
        await perform { [self] in
            let scope = try recommendationScope(source)
            let preview = recommendationCache.takeRadioPreview(sourceID: source.id, scope: scope)
            await player.startPersonalRadio(sourceID: source.id, connectionVersion: source.version, preview: preview)
        }
    }
}
