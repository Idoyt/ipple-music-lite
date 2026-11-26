import MusicCore
import Observation
import SwiftUI

@MainActor @Observable
final class PlaybackCommentsModel {
    private(set) var comments: [QQSongComment] = []
    private(set) var total: Int64?
    private(set) var next: QQCommentCursor?
    private(set) var isLoading = false
    private(set) var failure: String?
    private var identity = ""
    private var loaded = false
    private var generation = 0

    func isPrepared(for identity: String) -> Bool { self.identity == identity }

    func prepare(identity: String) {
        guard self.identity != identity else { return }
        self.identity = identity
        generation += 1
        comments = []
        total = nil
        next = nil
        failure = nil
        loaded = false
        isLoading = false
    }

    func load(api: MusicAPIClient, binding: LibraryBinding) async {
        guard !isLoading, !loaded || next != nil else { return }
        let generation = generation
        let cursor = loaded ? next : nil
        isLoading = true
        failure = nil
        defer { if self.generation == generation { isLoading = false } }
        do {
            let page = try await api.qqSongComments(
                sourceID: binding.sourceConnectionID, trackID: binding.sourceTrackID, after: cursor)
            try Task.checkCancellation()
            guard self.generation == generation else { return }
            var seen = Set(comments.map(\.id))
            comments.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
            total = page.total
            next = page.next == cursor ? nil : page.next
            loaded = true
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            failure = "暂时无法加载评论。\(error.localizedDescription)"
        }
    }

    func loadInitial(api: MusicAPIClient, binding: LibraryBinding) async {
        guard !loaded else { return }
        await load(api: api, binding: binding)
    }
}

struct PlaybackCommentsControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: PlaybackCommentsModel
    @Binding var isPresented: Bool
    let isEnabled: Bool
    @State private var motionRevision = 0

    private struct ButtonMotion {
        var x = 0.0
        var y = 0.0
        var angle = 0.0
    }

    var body: some View {
        Button {
            isPresented.toggle()
            if !reduceMotion { motionRevision &+= 1 }
        } label: {
            Image(systemName: isPresented ? "text.bubble.fill" : "text.bubble")
                .frame(width: 32, height: 32)
                .overlay(alignment: .bottomLeading) {
                    if let total = model.total {
                        Text(total > 999 ? "999+" : String(total))
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .fixedSize(horizontal: true, vertical: false)
                            .monospacedDigit().padding(.horizontal, 3).padding(.vertical, 1)
                            .background(.ultraThinMaterial, in: Capsule())
                            .offset(x: 4, y: 2).allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .keyframeAnimator(initialValue: ButtonMotion(), trigger: motionRevision) { [reduceMotion] content, motion in
                    content
                        .rotationEffect(.degrees(reduceMotion ? 0 : motion.angle))
                        .offset(x: reduceMotion ? 0 : motion.x, y: reduceMotion ? 0 : motion.y)
                } keyframes: { _ in
                    KeyframeTrack(\.x) {
                        CubicKeyframe(8, duration: 0.14)
                        LinearKeyframe(8, duration: 0.09)
                        CubicKeyframe(0, duration: 0.2)
                    }
                    KeyframeTrack(\.y) {
                        CubicKeyframe(-3.5, duration: 0.14)
                        LinearKeyframe(-3.5, duration: 0.09)
                        CubicKeyframe(0, duration: 0.2)
                    }
                    KeyframeTrack(\.angle) {
                        CubicKeyframe(12, duration: 0.14)
                        LinearKeyframe(12, duration: 0.09)
                        CubicKeyframe(0, duration: 0.2)
                    }
                }
                .contentShape(Rectangle())
        }
        .help(isPresented ? "收起评论" : "歌曲评论")
        .accessibilityLabel("歌曲评论")
        .accessibilityValue(model.total.map { "\($0) 条评论" } ?? "正在获取评论数量")
        .accessibilityIdentifier("player-details.comments")
        .disabled(!isEnabled)
    }
}

struct PlaybackCommentsPanel: View {
    let model: PlaybackCommentsModel
    let api: MusicAPIClient
    let binding: LibraryBinding
    let trackTitle: String
    let identity: String
    let onClose: () -> Void
    @State private var nearEnd = false

    private struct PageRequest: Equatable {
        let cursor: QQCommentCursor?
        let nearEnd: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("歌曲评论").font(.headline)
                    Text(trackTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }.buttonStyle(.plain).accessibilityLabel("关闭评论")
                    .accessibilityIdentifier("player-details.comments.close")
            }.padding(16)
            if model.isPrepared(for: identity) {
                commentList
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var commentList: some View {
        CommentViewport(
            comments: model.comments, loading: model.isLoading, failure: model.failure, hasMore: model.next != nil,
            onNearEnd: { nearEnd = $0 }, onRetry: { Task { await load() } })
            .task(id: PageRequest(cursor: model.next, nearEnd: nearEnd)) {
                if nearEnd, model.next != nil, model.failure == nil { await load() }
            }
    }

    private func load() async { await model.load(api: api, binding: binding) }
}

struct PlaybackCommentRow: View {
    let comment: QQSongComment
    var onContentChange: @MainActor () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(comment.author.isEmpty ? "QQ 音乐用户" : comment.author)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                if let date = comment.postedAt {
                    Text(date, format: .dateTime.year().month().day())
                        .foregroundStyle(.secondary).font(.caption)
                }
                Spacer(minLength: 4)
                if comment.likeCount > 0 {
                    Label(comment.likeCount.formatted(), systemImage: "hand.thumbsup")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("\(comment.likeCount) 个赞")
                }
            }
            QQCommentBody(comment: comment, onContentChange: onContentChange)
        }
    }
}
