import AppKit
import ImageIO
import MusicCore
import SwiftUI

struct QQCommentBody: View {
    let comment: QQSongComment
    let onContentChange: @MainActor () -> Void
    @State private var emojiImages: [URL: NSImage] = [:]

    private let parts: [QQCommentPart]
    private let photos: [URL]

    init(comment: QQSongComment, onContentChange: @escaping @MainActor () -> Void = {}) {
        self.onContentChange = onContentChange
        self.comment = comment
        let parts = QQCommentContent.parse(comment.text)
        self.parts = parts
        var result: [URL] = []
        for part in parts {
            if case .image(let url) = part, !result.contains(url) { result.append(url) }
        }
        for url in comment.images ?? [] where !result.contains(url) {
            if let safe = QQCommentContent.mediaURL(url.absoluteString) { result.append(safe) }
        }
        self.photos = Array(result.prefix(9))
        var cachedEmoji: [URL: NSImage] = [:]
        for part in parts {
            if case .emoji(_, let url) = part {
                cachedEmoji[url] = QQCommentImages.shared.cachedImage(url, emoji: true)
            }
        }
        _emojiImages = State(initialValue: cachedEmoji)
    }
    private var text: Text {
        parts.reduce(Text("")) { result, part in
            switch part {
            case .text(let string): return result + Text(string)
            case .emoji(_, let url):
                if let image = emojiImages[url] { return result + Text(Image(nsImage: image)).baselineOffset(-3) }
                return result + Text(Image(systemName: "face.smiling"))
                    .font(.system(size: 20)).foregroundColor(.secondary).baselineOffset(-3)
            case .image: return result
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            text.font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ForEach(photos, id: \.self) { url in QQCommentPhoto(url: url, onContentChange: onContentChange) }
        }
        .task(id: comment.text) {
            var seen = Set<URL>()
            for part in parts {
                guard !Task.isCancelled else { return }
                if case .emoji(_, let url) = part, seen.insert(url).inserted, seen.count <= 32,
                   let image = await QQCommentImages.shared.image(url, emoji: true) {
                    guard !Task.isCancelled else { return }
                    if emojiImages[url] !== image {
                        emojiImages[url] = image
                        onContentChange()
                    }
                }
            }
        }
    }
}

private struct QQCommentPhoto: View {
    let url: URL
    let onContentChange: @MainActor () -> Void
    @State private var media: QQCommentMedia?
    @State private var loading = true
    @State private var revision = 0

    init(url: URL, onContentChange: @escaping @MainActor () -> Void) {
        self.onContentChange = onContentChange
        self.url = url
        let cached = QQCommentImages.shared.cachedMedia(url, emoji: false)
        _media = State(initialValue: cached)
        _loading = State(initialValue: cached == nil)
    }

    var body: some View {
        Group {
            if let media {
                CommentMediaView(media: media)
                    .frame(maxWidth: 350, maxHeight: 220, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("评论图片")
            } else if loading {
                VStack(spacing: 7) {
                    CommentImageLoadingIndicator().frame(width: 16, height: 16)
                    Text("加载中…").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 100, height: 72)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("正在加载评论图片")
            } else {
                Button { revision += 1 } label: { Label("重新加载图片", systemImage: "photo") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .task(id: revision) {
            guard media == nil else { return }
            if !loading {
                loading = true
                onContentChange()
            }
            let result = await QQCommentImages.shared.media(url, emoji: false)
            guard !Task.isCancelled else { return }
            media = result
            loading = false
            onContentChange()
        }
    }
}

/// Core Animation rotates a pre-drawn ring without a SwiftUI timer or per-frame body updates.
private struct CommentImageLoadingIndicator: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    final class RingView: NSView {
        private let ring = CAShapeLayer()
        var reduceMotion = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            ring.fillColor = nil
            ring.strokeColor = NSColor.white.withAlphaComponent(0.65).cgColor
            ring.lineWidth = 1.7
            ring.lineCap = .round
            ring.strokeEnd = 0.72
            layer?.addSublayer(ring)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateAnimation()
        }

        func updateAnimation() {
            guard window != nil, !reduceMotion else {
                ring.removeAllAnimations()
                return
            }
            guard ring.animation(forKey: "loading") == nil else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Double.pi * 2
            spin.duration = 0.85
            spin.repeatCount = .infinity
            ring.add(spin, forKey: "loading")
        }

        func stop() { ring.removeAllAnimations() }
    }

    func makeNSView(context: Context) -> RingView { RingView(frame: .zero) }

    func updateNSView(_ view: RingView, context: Context) {
        view.reduceMotion = reduceMotion
        view.updateAnimation()
    }

    static func dismantleNSView(_ view: RingView, coordinator: ()) { view.stop() }
}

/// Public comment media never carries QQ session cookies. Keep decoded pixels bounded and coalesce emoji loads.
@MainActor
private final class QQCommentImages {
    static let shared = QQCommentImages()
    private let cache = NSCache<NSString, QQCommentMedia>()
    private var requests: [String: Task<QQCommentMedia?, Never>] = [:]
    private let session: URLSession

    init() {
        cache.totalCostLimit = 8 * 1024 * 1024
        cache.countLimit = 100
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
    }

    func cachedImage(_ url: URL, emoji: Bool) -> NSImage? {
        cachedMedia(url, emoji: emoji)?.image
    }

    func cachedMedia(_ url: URL, emoji: Bool) -> QQCommentMedia? {
        cache.object(forKey: (url.absoluteString + (emoji ? "#emoji" : "#photo")) as NSString)
    }

    func image(_ url: URL, emoji: Bool) async -> NSImage? {
        await media(url, emoji: emoji)?.image
    }

    func media(_ url: URL, emoji: Bool) async -> QQCommentMedia? {
        guard QQCommentContent.mediaURL(url.absoluteString) != nil else { return nil }
        let key = url.absoluteString + (emoji ? "#emoji" : "#photo")
        if let media = cache.object(forKey: key as NSString) { return media }
        if let request = requests[key] { return await request.value }
        let task = Task<QQCommentMedia?, Never> { [session] in
            guard let (data, response) = try? await session.data(from: url),
                  let response = response as? HTTPURLResponse, response.statusCode == 200,
                  data.count <= 8 * 1024 * 1024,
                  response.mimeType?.hasPrefix("image/") == true || data.starts(with: Array("GIF8".utf8)) else { return nil }
            let payload = await Task.detached(priority: .utility) {
                autoreleasepool { CommentMediaPayload.decode(data, emoji: emoji) }
            }.value
            guard let payload else { return nil }
            let media = QQCommentMedia(payload, emoji: emoji)
            cache.setObject(media, forKey: key as NSString, cost: media.cost)
            return media
        }
        requests[key] = task
        let result = await task.value
        requests[key] = nil
        return result
    }
}
