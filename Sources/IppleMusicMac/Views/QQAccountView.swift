import AppKit
import ImageIO
import MusicCore
import SwiftUI
import WebKit

struct QQAccountControl: View {
    @Environment(AppStore.self) private var store
    var source: SourceConnection
    var showsProfile = false
    @Environment(\.workspaceIsActive) private var workspaceIsActive
    @State private var status: QQSessionStatus?
    @State private var error: String?

    private var label: String {
        switch status?.state {
        case "connected": return status?.nickname ?? "已登录 QQ 音乐"
        case "expired": return "QQ 登录已过期"
        case "unavailable": return "QQ 登录状态暂时无法验证"
        default: return "正在检查 QQ 登录状态"
        }
    }

    var body: some View {
        VStack(alignment: showsProfile ? .leading : .trailing, spacing: 10) {
            if showsProfile {
                HStack(spacing: 16) {
                    QQAccountAvatar(url: status?.avatarURL ?? store.user?.avatarURL)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profileName).font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        Text("QQ 音乐").font(.subheadline).foregroundStyle(.secondary)
                        if let account = status?.accountID ?? store.user?.username, !account.isEmpty {
                            Text("账号 \(account)").font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 12)
                    Button { Task { await reload() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless).help("刷新账户信息")
                    .accessibilityLabel("刷新账户信息")
                }.padding(.vertical, 8)
            }
            HStack(spacing: 8) {
                if showsProfile {
                    Label(statusText, systemImage: statusSymbol)
                        .font(.caption).foregroundStyle(status?.state == "expired" ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("qq-session.status.\(source.id)")
                    Spacer()
                } else {
                    Text(label).font(.caption).foregroundStyle(status?.state == "expired" ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("qq-session.status.\(source.id)")
                }
                if status?.state == "expired" || status?.state == "unbound" {
                    Button("重新扫码登录") { Task { await store.signOut() } }
                }
                if !showsProfile {
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("检查 QQ 登录状态")
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: "\(source.version)-\(workspaceIsActive)") {
            guard workspaceIsActive else { return }
            while !Task.isCancelled {
                await reload()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private var profileName: String {
        for value in [status?.nickname, store.user?.displayName] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return "QQ 音乐用户"
    }
    private var statusText: String {
        switch status?.state {
        case "connected": "已连接"
        case "expired": "登录已过期"
        case "unbound": "需要重新登录"
        case "unavailable": "暂时无法验证登录状态"
        default: "正在检查登录状态"
        }
    }
    private var statusSymbol: String {
        switch status?.state {
        case "connected": "checkmark.circle"
        case "expired", "unbound": "exclamationmark.circle"
        default: "network"
        }
    }

    private func reload() async {
        let userID = store.user?.id
        do {
            let result = try await store.api.qqSession(sourceID: source.id)
            guard !Task.isCancelled, store.user?.id == userID else { return }
            status = result
            error = nil
        } catch {
            guard !Task.isCancelled, store.user?.id == userID else { return }
            self.error = error.localizedDescription
        }
    }
}

struct QQInlineLoginView: View {
    @Environment(AppStore.self) private var store
    @State private var loading = true
    @State private var working = false
    @State private var error: String?
    @State private var lastCandidate: QQSessionCandidate?
    @State private var loginTask: Task<Void, Never>?
    @State private var webGeneration = UUID()

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("本项目仅供学习与技术交流。使用此第三方播放器时，请在手机 QQ 核对授权信息后再确认。")
                DisclosureGroup("隐私、安全提示与免责声明") {
                    Text("项目维护者不通过本应用收集或存储你的个人信息。登录凭据保存在本机钥匙串，资料库、播放记录和缓存均保存在这台 Mac 上。\n\n登录、搜索和播放需要连接 QQ 音乐，收藏操作会同步至你的 QQ 音乐账号。可在「我的」中退出并清除本机账号数据。请勿分享登录二维码或授权链接。\n\n软件按 MIT 许可证原样提供。可播放内容取决于账号权限，平台接口变更可能影响登录、播放或同步。")
                        .padding(.top, 4)
                }
            }
            .font(.callout)
            .frame(width: 360, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            QQOfficialLoginWebView(
                onCandidate: { login($0) },
                onError: { loading = false; error = $0 },
                onLoading: { loading = $0 }
            )
            .id(webGeneration)
            .frame(width: 360, height: 480)
            .accessibilityIdentifier("qq-session.official-web")
            .allowsHitTesting(!working)
            .overlay {
                if loading {
                    ProgressView("正在加载二维码…").controlSize(.small)
                        .padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if working {
                ProgressView("正在登录…").controlSize(.small)
            }
            if let message = error {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            Button("刷新二维码") {
                lastCandidate = nil
                error = nil
                loading = true
                webGeneration = UUID()
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(working)
            .accessibilityIdentifier("login.qq.refresh")
        }
        .onDisappear {
            // 登录成功后根页面会移除此视图；后续歌单和队列恢复仍应完成。
            if store.user == nil { loginTask?.cancel() }
            loginTask = nil
            lastCandidate = nil
        }
    }

    private func login(_ candidate: QQSessionCandidate, retry: Bool = false) {
        guard retry || candidate != lastCandidate else { return }
        lastCandidate = candidate
        guard !working else { return }
        working = true
        error = nil
        loginTask = Task { @MainActor in
            defer {
                working = false
                if !Task.isCancelled, error != nil, let latest = lastCandidate, latest != candidate {
                    login(latest, retry: true)
                }
            }
            await store.signInQQ(candidate)
            guard !Task.isCancelled else { return }
            if store.user == nil {
                error = store.error ?? "未能验证 QQ 音乐登录态，请完成官方页面登录后重试。"
                store.error = nil
            }
        }
    }
}

struct QQOfficialLoginWebView: NSViewRepresentable {
    var onCandidate: @MainActor (QQSessionCandidate) -> Void
    var onError: @MainActor (String) -> Void
    var onLoading: @MainActor (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCandidate: onCandidate, onError: onError, onLoading: onLoading)
    }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: QQOfficialLoginPage.appearanceScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(URLRequest(url: context.coordinator.authorizationURL, timeoutInterval: 30))
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onCandidate = onCandidate
        context.coordinator.onError = onError
        context.coordinator.onLoading = onLoading
    }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.close()
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onCandidate: @MainActor (QQSessionCandidate) -> Void
        var onError: @MainActor (String) -> Void
        var onLoading: @MainActor (Bool) -> Void
        weak var webView: WKWebView?
        var popupWindows: [NSWindow] = []
        private let state = UUID().uuidString
        private var consumed = false
        var authorizationURL: URL { QQOfficialLoginPage.url(state: state) }
        var closed = false

        init(
            onCandidate: @escaping @MainActor (QQSessionCandidate) -> Void,
            onError: @escaping @MainActor (String) -> Void,
            onLoading: @escaping @MainActor (Bool) -> Void = { _ in }
        ) {
            self.onCandidate = onCandidate
            self.onError = onError
            self.onLoading = onLoading
        }
        func handleCallback(_ url: URL) -> Bool {
            guard QQSessionCandidate.isAuthorizationCallbackURL(url) else { return false }
            guard !closed, !consumed else { return true }
            guard let candidate = QQSessionCandidate.authorizationCallback(from: url, expectedState: state) else {
                onLoading(false)
                onError("未能确认本次扫码授权，请刷新二维码重试。")
                return true
            }
            consumed = true
            onLoading(false)
            onCandidate(candidate)
            return true
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if handleCallback(url) { return .cancel }
            let host = url.host?.lowercased() ?? ""
            let allowed = url.absoluteString == "about:blank"
                || (url.scheme == "https" && (host == "qq.com" || host.hasSuffix(".qq.com")))
            return allowed ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            // 重定向可能只产生响应策略回调；在网页执行前截获一次性授权码。
            if let url = navigationResponse.response.url, handleCallback(url) { return .cancel }
            return .allow
        }
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard !closed else { return nil }
            configuration.websiteDataStore = webView.configuration.websiteDataStore
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 620), styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.title = "QQ 音乐官方登录"
            window.isReleasedWhenClosed = false
            window.contentView = popup
            window.center()
            window.makeKeyAndOrderFront(nil)
            popupWindows.append(window)
            return popup
        }
        func webViewDidClose(_ webView: WKWebView) {
            popupWindows.first(where: { $0.contentView === webView })?.close()
        }
        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            guard (error as NSError).code != NSURLErrorCancelled, !closed else { return }
            onLoading(false)
            onError("QQ 官方登录页暂时无法加载，请刷新二维码重试。")
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            if !closed, webView === self.webView { onLoading(true) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !closed, webView === self.webView { onLoading(false) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !closed else { return }
            onLoading(false)
            onError("QQ 官方登录页已中断，请刷新二维码重试。")
        }
        func close() {
            closed = true
            for window in popupWindows {
                if let view = window.contentView as? WKWebView {
                    view.stopLoading()
                    view.navigationDelegate = nil
                    view.uiDelegate = nil
                }
                window.close()
            }
            popupWindows.removeAll()
            if let dataStore = webView?.configuration.websiteDataStore {
                dataStore.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast,
                    completionHandler: {})
            }
        }
    }
}

/// The same authorization entry used by QQ Music's official web login.
/// Its native narrow layout retains the QR code, permissions and agreement links together.
enum QQOfficialLoginPage {
    static func url(state: String) -> URL {
        var components = URLComponents(string: "https://graph.qq.com/oauth2.0/authorize")!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: "100497308"),
            .init(name: "redirect_uri", value: "https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/"),
            .init(name: "state", value: state),
            .init(name: "display", value: "pc"),
            .init(name: "scope", value: "get_user_info"),
        ]
        return components.url!
    }

    // Presentation only: never reads credentials, checks consent boxes or submits authorization.
    static let appearanceScript = """
    (() => {
        if (!["graph.qq.com", "xui.ptlogin2.qq.com", "ssl.ptlogin2.qq.com"].includes(location.hostname)) return;
        const style = document.createElement("style");
        style.textContent = `
            html, body { background: transparent !important; color: #eeeeee !important; }
            #combine_page.vertical { width: 100% !important; max-width: 100% !important; }
            .accredit_info_op li, .oauth_tips, .oauth_item_title, .cnt_wording,
            .title, .info, .tips, .bottom { color: #eeeeee !important; }
            a { color: #9bc8ff !important; }
        `;
        document.head.appendChild(style);
    })();
    """
}

struct QQAccountAvatar: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().scaledToFit().foregroundStyle(.tertiary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
        .accessibilityLabel("账户头像")
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await QQAccountAvatarCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// Small public avatars have their own bounded decoded cache; QQ credentials never accompany image requests.
@MainActor private final class QQAccountAvatarCache {
    static let shared = QQAccountAvatarCache()
    private let cache = NSCache<NSURL, NSImage>()
    private let session: URLSession

    private init() {
        cache.countLimit = 16
        cache.totalCostLimit = 1_024 * 1_024
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL) async -> NSImage? {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              ["qq.com", "qlogo.cn", "qpic.cn"].contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2 * 1_024 * 1_024,
                  !Task.isCancelled else { return nil }
            let decoded = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160,
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled, let decoded else { return nil }
            let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
            cache.setObject(image, forKey: url as NSURL, cost: decoded.bytesPerRow * decoded.height)
            return image
        } catch { return nil }
    }
}
