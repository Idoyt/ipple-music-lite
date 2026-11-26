import MusicCore
import SwiftUI

private enum DiscoveryDestination: Identifiable {
    case album(String)
    case artist(String)
    case chart(DiscoveryItem)
    case charts
    var id: String {
        switch self {
        case .album(let id): "album:" + id
        case .artist(let id): "artist:" + id
        case .chart(let item): "chart:" + item.id
        case .charts: "charts"
        }
    }
}

struct DiscoveryHomeView: View {
    var onManageSources: () -> Void
    var showsToolbar = true
    @Environment(AppStore.self) private var store
    @State private var page: DiscoveryPage?
    private var sources: [SourceConnection] {
        store.sources.filter { $0.kind == "qq" && $0.enabled && $0.state == "active" }
    }
    private var source: SourceConnection? { sources.first { $0.ownerID == store.user?.id } }
    var body: some View {
        Group {
            if let source {
                DiscoveryWorkspace(source: source, onManageSources: onManageSources, page: $page)
                    .id(source.id + String(source.version))
            } else {
                VStack(spacing: 0) {
                    DiscoveryHeader(title: "发现", subtitle: "让好音乐，遇见此刻的你。")
                    SourceEmptyState(onManageSources: onManageSources)
                }
            }
        }
        .toolbar {
            if showsToolbar {
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible, placement: .primaryAction)
                } else {
                    ToolbarItemGroup(placement: .primaryAction) { Spacer() }
                }
                SearchToolbarItem {
                    if page != nil {
                        DiscoveryBackButton { page = nil }
                    } else {
                        DiscoverySearchButton(onManageSources: onManageSources)
                    }
                }
            }
        }
        .onChange(of: source.map { $0.id + String($0.version) }) { _, _ in page = nil }
    }
}

private enum DiscoveryPage {
    case playlist(DiscoveryItem)
    case daily([SourceTrack])
}

private struct DiscoveryWorkspace: View {
    @Environment(AppStore.self) private var store
    @Environment(\.workspaceIsActive) private var workspaceIsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var source: SourceConnection
    var onManageSources: () -> Void
    @Binding var page: DiscoveryPage?

    var body: some View {
        ZStack {
            // Keep recommendations and their scroll position mounted when opening a playlist.
            VStack(spacing: 0) {
                DiscoveryHeader(title: "发现", subtitle: "让好音乐，遇见此刻的你。")
                RecommendationContent(source: source,
                    onOpenPlaylist: { page = .playlist($0) },
                    onOpenDaily: { page = .daily($0) },
                    onDailyInvalidated: { if case .daily = page { page = nil } })
            }
            .opacity(page == nil ? 1 : 0)
            .allowsHitTesting(page == nil)
            .accessibilityHidden(page != nil)
            .environment(\.workspaceIsActive, workspaceIsActive && page == nil)

            if let page {
                ZStack {
                    switch page {
                    case .playlist(let item):
                        QQSourcePlaylistContent(source: source, playlistID: item.id, client: store.api,
                            info: PlaylistPageInfo(title: item.title, coverID: item.coverID, description: item.subtitle),
                            onManageSources: onManageSources)
                            .id(item.id)
                    case .daily(let tracks):
                        DailyRecommendationContent(source: source, tracks: tracks)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    LinearGradient(
                        colors: [Color(nsColor: .controlAccentColor).opacity(0.055),
                                 Color(nsColor: .windowBackgroundColor)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.36), value: page != nil)
    }
}

private struct DiscoveryBackButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .medium))
                .frame(width: WindowControlMetrics.toolbarButtonSide,
                       height: WindowControlMetrics.toolbarButtonSide)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: WindowControlMetrics.toolbarButtonSide,
               height: WindowControlMetrics.toolbarButtonSide)
        .fixedSize()
        .contentShape(Circle())
        .modifier(DiscoveryBackButtonGlass())
        .help("返回发现")
        .accessibilityLabel("返回发现")
        .accessibilityIdentifier("discovery.playlist.back")
    }
}

private struct DiscoveryBackButtonGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

private struct DiscoveryHeader: View {
    var title: String
    var subtitle: String
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 32, weight: .bold, design: .rounded))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 22)
    }
}

private struct SourceEmptyState: View {
    var onManageSources: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("连接音乐，开始探索", systemImage: "music.note.house")
        } description: {
            Text("请在「我的」中检查账户状态后重试。")
        } actions: {
            Button("管理音乐账号", action: onManageSources).buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecommendationContent: View {
    @Environment(AppStore.self) private var store
    var source: SourceConnection
    var onOpenPlaylist: (DiscoveryItem) -> Void
    var onOpenDaily: ([SourceTrack]) -> Void
    var onDailyInvalidated: () -> Void
    @State private var data: SourceDiscovery?
    @State private var failure: String?
    @State private var destination: DiscoveryDestination?
    @State private var revision = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .fixed(DiscoveryCardMetrics.recommendationWidth), spacing: DiscoveryCardMetrics.spacing),
                        count: 2),
                    alignment: .leading, spacing: DiscoveryCardMetrics.spacing
                ) {
                    PersonalRecommendationSection(source: source, mode: .guessLike)
                    PersonalRecommendationSection(source: source, mode: .daily,
                        onOpenDaily: onOpenDaily, onDailyInvalidated: onDailyInvalidated)
                }
                if let data {
                    if !data.playlists.isEmpty {
                        section("精选歌单", caption: "为今天挑选一份新的心情") {
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: DiscoveryCardMetrics.spacing) {
                                    ForEach(data.playlists) { item in
                                        DiscoveryCard(
                                            source: source, title: item.title, subtitle: item.subtitle,
                                            coverID: item.coverID
                                        ) {
                                            onOpenPlaylist(item)
                                        }
                                    }
                                }.padding(.bottom, 6)
                            }.scrollIndicators(.hidden)
                        }
                    }
                    if !data.charts.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("排行榜").font(.title2.bold())
                                Spacer()
                                Button("查看全部", systemImage: "chevron.right") { destination = .charts }.buttonStyle(
                                    .plain
                                ).foregroundStyle(Color(nsColor: .controlAccentColor))
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                                ForEach(Array(data.charts.prefix(6))) { chart in
                                    ChartCard(source: source, chart: chart) { destination = .chart(chart) }
                                }
                            }
                        }
                    }
                    if !data.albums.isEmpty {
                        section("新碟上架", caption: "新的作品，新的循环") {
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: DiscoveryCardMetrics.spacing) {
                                    ForEach(data.albums) { album in
                                        DiscoveryCard(
                                            source: source, title: album.name ?? album.title ?? "专辑",
                                            subtitle: album.artist ?? "", coverID: album.coverID
                                        ) {
                                            destination = .album(album.id)
                                        }
                                    }
                                }.padding(.bottom, 6)
                            }.scrollIndicators(.hidden)
                        }
                    }
                    if !data.tracks.isEmpty {
                        section("新歌速递", caption: "从这一首，开始听") {
                            VStack(spacing: 0) {
                                ForEach(data.tracks) { track in
                                    SourceTrackRow(track: track, source: source)
                                    if track.id != data.tracks.last?.id { Divider().padding(.leading, 82) }
                                }
                            }.background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                } else if let failure {
                    DiscoveryFailure(message: failure) { revision += 1 }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(24)
                }
            }.padding(.horizontal, 32).padding(.bottom, 18)
        }
        .task(id: revision) {
            do {
                let result = try await store.api.discoverSource(id: source.id, mode: .recommendations, limit: 12)
                try Task.checkCancellation()
                data = result
                failure = nil
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .sheet(item: $destination) { DiscoverySheet(source: source, destination: $0) }
        .overlay(alignment: .top) {
            if data != nil, let failure {
                Text(failure).font(.caption).padding(10).background(.regularMaterial, in: Capsule())
            }
        }
    }

    private func section<Content: View>(_ title: String, caption: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.title2.bold())
                Text(caption).font(.callout).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

private struct DiscoveryCard: View {
    var source: SourceConnection
    var title: String
    var subtitle: String
    var coverID: String?
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                SourceCover(sourceID: source.id, coverID: coverID, size: DiscoveryCardMetrics.coverSize)
                    .shadow(color: .black.opacity(0.09), radius: 8, y: 4)
                Text(title).font(.callout.weight(.semibold)).lineLimit(2).frame(height: 36, alignment: .top)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: DiscoveryCardMetrics.coverSize, height: DiscoveryCardMetrics.height, alignment: .topLeading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct ChartCard: View {
    var source: SourceConnection
    var chart: DiscoveryItem
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                SourceCover(sourceID: source.id, coverID: chart.coverID, size: 72)
                VStack(alignment: .leading, spacing: 7) {
                    Text(chart.title).font(.headline).lineLimit(1)
                    Text("\(chart.trackCount ?? 0) 首 · \(chart.subtitle)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }.padding(14).background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}

private struct DiscoverySheet: View {
    var source: SourceConnection
    var destination: DiscoveryDestination
    var body: some View {
        switch destination {
        case .album(let id): SourceDetailView(source: source, selection: .album(id))
        case .artist(let id): SourceDetailView(source: source, selection: .artist(id))
        case .chart(let chart): ChartTracksView(source: source, chart: chart)
        case .charts: ChartListView(source: source)
        }
    }
}

private struct ChartListView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var source: SourceConnection
    @State private var charts: [DiscoveryItem] = []
    @State private var selected: DiscoveryItem?
    @State private var error: String?
    @State private var revision = 0
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("排行榜").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }
            }
            if let error { DiscoveryFailure(message: error) { revision += 1 } }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290))], spacing: 14) {
                    ForEach(charts) { chart in ChartCard(source: source, chart: chart) { selected = chart } }
                }
            }.overlay { if charts.isEmpty && error == nil { ProgressView() } }
        }.padding(24).frame(width: 820, height: 580)
            .task(id: revision) {
                error = nil
                do {
                    let result = try await store.api.discoverSource(id: source.id, mode: .charts)
                    try Task.checkCancellation()
                    charts = result.charts
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .sheet(item: $selected) { ChartTracksView(source: source, chart: $0) }
    }
}

private struct ChartTracksView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var source: SourceConnection
    var chart: DiscoveryItem
    @State private var tracks: [SourceTrack] = []
    @State private var offset = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var failure: String?
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                SourceCover(sourceID: source.id, coverID: chart.coverID, size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text(chart.title).font(.title2.bold())
                    Text(chart.period ?? chart.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }.padding(.horizontal, 24)
            if let failure { DiscoveryFailure(message: failure) { Task { await load(reset: tracks.isEmpty) } } }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 0) {
                            Text("\(index + 1)").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(
                                index < 3 ? Color(nsColor: .controlAccentColor) : Color.secondary
                            ).frame(width: 40)
                            SourceTrackRow(track: track, source: source)
                        }
                        Divider().padding(.leading, 94)
                    }
                    if hasMore { Button("加载更多") { Task { await load(reset: false) } }.padding(18).disabled(loading) }
                    if loading { ProgressView().padding(20) }
                    if !loading && failure == nil && tracks.isEmpty {
                        Text("本期榜单暂无歌曲").foregroundStyle(.secondary).padding(40)
                    }
                }
            }
        }.padding(.vertical, 24).frame(width: 820, height: 580).task { await load(reset: true) }
    }
    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let page = try await store.api.discoverSource(
                id: source.id, mode: .chart, chartID: chart.id, offset: reset ? 0 : offset, limit: 30)
            try Task.checkCancellation()
            if reset { tracks = [] }
            let known = Set(tracks.map(\.id))
            tracks.append(contentsOf: page.tracks.filter { !known.contains($0.id) })
            offset = page.offset + page.tracks.count
            hasMore = page.hasMore
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

private struct DiscoveryFailure: View {
    var message: String
    var retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("暂时无法读取音乐", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("重试", action: retry)
        }
    }
}

struct DiscoverySearchButton: View {
    var onManageSources: () -> Void
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var isExpanded = false
    @State private var searchRevision = 0
    @State private var destination: DiscoveryDestination?

    private var source: SourceConnection? {
        guard let userID = store.user?.id else { return nil }
        return store.sources.first {
            $0.kind == "qq" && $0.enabled && $0.state == "active" && $0.ownerID == userID
        }
    }

    var body: some View {
        ExpandingSearchControl(query: $query, isExpanded: $isExpanded,
            placeholder: "歌曲、歌手或专辑", identifier: "recommendations.search",
            onSubmit: { searchRevision += 1 }) {
            if let source {
                DiscoverySearchResults(source: source, query: query, searchRevision: searchRevision,
                    onSearch: { query = $0; searchRevision += 1 },
                    onOpen: { destination = $0; isExpanded = false },
                    onDismiss: { isExpanded = false })
                    .id(source.id + String(source.version)).environment(store)
            } else {
                SourceEmptyState(onManageSources: { isExpanded = false; onManageSources() })
            }
        }
        .sheet(item: $destination) { destination in
            if let source { DiscoverySheet(source: source, destination: destination).environment(store) }
        }
    }
}

private struct DiscoverySearchResults: View {
    @Environment(AppStore.self) private var store
    var source: SourceConnection
    var query: String
    var searchRevision: Int
    var onSearch: (String) -> Void
    var onOpen: (DiscoveryDestination) -> Void
    var onDismiss: () -> Void
    @State private var submitted = ""
    @State private var hotwords: [String] = []
    @State private var suggestions: [DiscoveryItem] = []
    @State private var catalog: SourceCatalog?
    @State private var loading = false
    @State private var suggesting = false
    @State private var failure: String?
    @State private var suggestionFailure: String?
    @State private var hotwordFailure: String?
    @State private var openingTrack = false
    @State private var hotwordRevision = 0
    @State private var resultTask: Task<Void, Never>?
    @State private var resultGeneration = UUID()
    private var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if text.isEmpty {
                    heading("大家都在搜")
                    if let hotwordFailure {
                        Text(hotwordFailure).font(.caption).foregroundStyle(.secondary).padding(12)
                        Button("重新加载热搜") { hotwordRevision += 1 }.padding(.horizontal, 12)
                    }
                    ForEach(Array(hotwords.enumerated()), id: \.offset) { index, word in
                        Button { onSearch(word) } label: {
                            HStack(spacing: 12) {
                                Text(String(format: "%02d", index + 1)).monospacedDigit()
                                    .foregroundStyle(index < 3 ? Color.accentColor : Color.secondary)
                                Text(word).lineLimit(1)
                                Spacer()
                                Image(systemName: "arrow.up.left").foregroundStyle(.tertiary)
                            }.padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if hotwords.isEmpty && hotwordFailure == nil { loadingRow("正在读取热搜…") }
                } else if submitted == text {
                    heading("歌曲结果")
                    if loading { loadingRow("正在搜索…") }
                    if let failure {
                        Text(failure).font(.caption).foregroundStyle(.secondary).padding(12)
                        Button("重试") { search(offset: 0) }.padding(.horizontal, 12)
                    }
                    if let catalog {
                        if catalog.tracks.isEmpty {
                            Text("未找到相关歌曲").foregroundStyle(.secondary).padding(14)
                        }
                        ForEach(catalog.tracks) { track in
                            Button { play(track) } label: {
                                resultRow(title: track.title, subtitle: track.artists.joined(separator: " / "),
                                    coverID: track.coverID, symbol: "play.fill")
                            }.buttonStyle(.plain)
                                .disabled(openingTrack || !track.isPlayable)
                                .opacity(track.isPlayable ? 1 : 0.6)
                                .accessibilityIdentifier("search.result." + track.id)
                        }
                        HStack {
                            if catalog.offset > 0 {
                                Button("上一页") { search(offset: max(0, Int(catalog.offset) - 30)) }
                            }
                            Spacer()
                            if catalog.hasMore { Button("下一页") { search(offset: Int(catalog.offset) + 30) } }
                        }.padding(12).disabled(loading)
                    }
                } else {
                    heading("搜索建议")
                    if suggesting { loadingRow("正在获取建议…") }
                    if let suggestionFailure {
                        Text(suggestionFailure).font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(suggestions, id: \.identity) { item in
                        Button { open(item) } label: {
                            resultRow(title: item.title, subtitle: item.subtitle, coverID: item.coverID,
                                symbol: item.kind == "track" ? "play.fill" : "chevron.right")
                        }.buttonStyle(.plain).disabled(openingTrack)
                            .accessibilityIdentifier("search.suggestion." + item.identity)
                    }
                    Button { onSearch(text) } label: {
                        Label("搜索“\(text)”", systemImage: "magnifyingglass")
                            .lineLimit(1).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            }.padding(.vertical, 10)
        }
        .task(id: hotwordRevision) {
            hotwordFailure = nil
            do {
                let page = try await store.api.discoverSource(id: source.id, mode: .hotwords)
                try Task.checkCancellation()
                hotwords = page.hotwords
            } catch { if !Task.isCancelled { hotwordFailure = error.localizedDescription } }
        }
        .task(id: text) {
            suggestions = []
            suggestionFailure = nil
            suggesting = false
            guard !text.isEmpty else { return }
            suggesting = true
            do {
                try await Task.sleep(for: .milliseconds(300))
                let page = try await store.api.discoverSource(id: source.id, mode: .suggestions, query: text)
                try Task.checkCancellation()
                suggestions = page.suggestions
                suggesting = false
            } catch {
                if !Task.isCancelled { suggestionFailure = error.localizedDescription; suggesting = false }
            }
        }
        .onChange(of: searchRevision, initial: true) { _, revision in
            guard revision > 0, !text.isEmpty else { return }
            submitted = text
            search(offset: 0)
        }
        .onDisappear { resultTask?.cancel(); resultTask = nil }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func loadingRow(_ title: String) -> some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(title).font(.caption).foregroundStyle(.secondary) }
            .padding(14)
    }

    private func resultRow(title: String, subtitle: String, coverID: String?, symbol: String) -> some View {
        HStack(spacing: 10) {
            SourceCover(sourceID: source.id, coverID: coverID, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func search(offset: Int) {
        resultTask?.cancel()
        let generation = UUID()
        resultGeneration = generation
        let requested = submitted
        loading = true
        failure = nil
        catalog = nil
        resultTask = Task {
            defer { if resultGeneration == generation { loading = false } }
            do {
                let result = try await store.api.searchSource(id: source.id, query: requested, offset: offset, limit: 30)
                try Task.checkCancellation()
                guard generation == resultGeneration, requested == submitted, requested == text else { return }
                catalog = result
            } catch {
                if !Task.isCancelled, generation == resultGeneration { failure = error.localizedDescription }
            }
        }
    }

    private func play(_ track: SourceTrack) {
        guard track.isPlayable, !openingTrack else { return }
        openingTrack = true
        Task {
            defer { openingTrack = false }
            await store.importTrack(track, from: source, play: true)
            onDismiss()
        }
    }

    private func open(_ item: DiscoveryItem) {
        switch item.kind {
        case "album": onOpen(.album(item.id))
        case "artist": onOpen(.artist(item.id))
        case "track":
            guard !openingTrack else { return }
            openingTrack = true
            Task {
                defer { openingTrack = false }
                let userID = store.user?.id
                do {
                    let track = try await store.api.sourceTrack(id: source.id, resourceID: item.id)
                    guard store.user?.id == userID, !Task.isCancelled else { return }
                    await store.importTrack(track, from: source, play: true)
                    onDismiss()
                } catch { if store.user?.id == userID { store.error = error.localizedDescription } }
            }
        default: break
        }
    }
}
