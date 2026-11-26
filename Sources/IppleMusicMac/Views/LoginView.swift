import AppKit
import SwiftUI

struct LoginView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LoginBackdrop()
                ScrollView {
                    panel.padding(24)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize).scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var panel: some View {
        if #available(macOS 26.0, *) {
            panelContent.padding(28).frame(width: 424)
                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            panelContent.padding(28).frame(width: 424)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var panelContent: some View {
        VStack(spacing: 20) {
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .renderingMode(.original)
                    .resizable().scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text("Ipple Music").font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            TypewriterTitle(text: "欢迎回来")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .padding(.top, 8)
            if store.isRestoringSession {
                ProgressView("正在恢复登录…")
                    .controlSize(.small).accessibilityIdentifier("login.restoring")
            } else if store.settings.pendingLocalLogout != nil {
                Text("本机退出清理尚未完成。").font(.callout)
                Button("重试清理") { Task { await store.finishLocalLogout() } }
                    .disabled(store.isSigningIn)
            } else {
                if let message = store.sessionRestoreError {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                    Button("重试恢复登录") { Task { await store.restoreSessionOnStartup(retry: true) } }
                        .accessibilityIdentifier("login.restoreRetry")
                }
                QQInlineLoginView()
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct TypewriterTitle: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderedText = ""
    @State private var isTyping = false

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text).opacity(0).accessibilityHidden(true)
            HStack(spacing: 3) {
                Text(renderedText)
                if isTyping {
                    Rectangle().fill(Color(nsColor: .controlAccentColor)).frame(width: 2, height: 25)
                        .transition(.opacity)
                }
            }.accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("login.title")
        .task(id: "\(text)-\(reduceMotion)") { await typeTitle() }
    }

    private func typeTitle() async {
        var immediate = Transaction(animation: nil)
        immediate.disablesAnimations = true
        withTransaction(immediate) {
            renderedText = reduceMotion ? text : ""
            isTyping = !reduceMotion
        }
        guard !reduceMotion else { return }
        do {
            try await Task.sleep(for: .milliseconds(180))
            for character in text {
                try Task.checkCancellation()
                withTransaction(immediate) { renderedText.append(character) }
                try await Task.sleep(for: .milliseconds(145))
            }
            try await Task.sleep(for: .milliseconds(160))
            withAnimation(.easeOut(duration: 0.16)) { isTyping = false }
        } catch {
            // 切换模式或离开登录页时，由 task(id:) 取消旧标题，避免旧字符写回新界面。
        }
    }
}

private struct LoginBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var artwork = LoginArtwork()
    @State private var drifting = false

    private var moving: Bool { drifting && !reduceMotion }

    var body: some View {
        let images = artwork.images
        GeometryReader { geometry in
            let side = max(geometry.size.width / 4, geometry.size.height / 3) + 70
            ZStack {
                Color(red: 0.09, green: 0.12, blue: 0.14)
                if !images.isEmpty {
                    Canvas { context, _ in
                        for row in 0..<3 {
                            for column in 0..<4 {
                                let image = Image(nsImage: images[(row * 4 + column) % images.count])
                                let tile = CGRect(
                                    x: CGFloat(column) * (side + 18), y: CGFloat(row) * (side + 18),
                                    width: side, height: side)
                                context.draw(image, in: tile)
                            }
                        }
                    }
                    .frame(width: side * 4 + 54, height: side * 3 + 36)
                    .blur(radius: 13)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                        wall in
                        wall.scaleEffect(moving ? 1.08 : 1.0)
                            .rotationEffect(.degrees(moving ? -7 : -12))
                            .offset(x: moving ? 38 : -38, y: moving ? -28 : 28)
                    }
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                Color.black.opacity(0.38)
                LinearGradient(
                    colors: [.black.opacity(0.10), .clear, .black.opacity(0.32)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .ignoresSafeArea().accessibilityHidden(true).allowsHitTesting(false)
        .onAppear { drifting = true }
    }
}

@MainActor
private final class LoginArtwork {
    // State keeps one lazy owner while the backdrop is visible. Leaving login releases
    // its decoded covers instead of keeping them in a process-wide static array.
    lazy var images: [NSImage] = {
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle.main
        #endif
        return (1...8).compactMap { index in
            let name = String(format: "cover-%02d", index)
            guard
                let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "LoginCovers")
                    ?? bundle.url(forResource: name, withExtension: "png")
            else { return nil }
            return NSImage(contentsOf: url)
        }.shuffled()
    }()
}
