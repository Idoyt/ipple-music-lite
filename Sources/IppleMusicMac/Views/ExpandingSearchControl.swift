import AppKit
import SwiftUI

/// The field remains in the toolbar; results use a separate, non-activating child panel.
struct ExpandingSearchControl<Results: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var query: String
    @Binding var isExpanded: Bool
    let placeholder: String
    let identifier: String
    var onSubmit: () -> Void = {}
    @ViewBuilder var results: () -> Results
    @FocusState private var focused: Bool
    @State private var showsResults = false
    @State private var reservesInputSpace = false
    @State private var extendsGlass = false
    @State private var showsInput = false

    private let buttonSize = WindowControlMetrics.toolbarButtonSide
    private let inputWidth: CGFloat = 288

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .accessibilityIdentifier(identifier + ".query")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("清除搜索")
                        .accessibilityIdentifier(identifier + ".clear")
                }
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(width: inputWidth)
            .frame(width: reservesInputSpace ? inputWidth : 0, alignment: .trailing)
            .opacity(showsInput ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: showsInput)
            .clipped()
            .allowsHitTesting(showsInput)
            .accessibilityHidden(!showsInput)
            Button { isExpanded.toggle() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help(isExpanded ? "收起搜索" : placeholder)
            .accessibilityLabel("搜索")
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            .accessibilityIdentifier(identifier)
        }
        .frame(height: buttonSize)
        .background(alignment: .trailing) {
            Color.clear
                .frame(width: buttonSize + (extendsGlass ? inputWidth : 0), height: buttonSize)
                .modifier(SearchGlass(shape: .capsule))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: extendsGlass)
        }
        // Commit toolbar layout without animating its contents. Only the trailing-anchored
        // glass and input opacity animate; the search icon retains its size and position.
        .transaction { $0.animation = nil }
        .background {
            SearchResultsPanel(isPresented: showsResults, reduceMotion: reduceMotion, onDismiss: close) {
                results()
            }
        }
        .task(id: isExpanded) {
            if isExpanded {
                reservesInputSpace = true
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 16)) } catch { return }
                extendsGlass = true
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 120)) } catch { return }
                showsInput = true
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 100)) } catch { return }
                guard !Task.isCancelled else { return }
                focused = true
                showsResults = true
            } else {
                showsResults = false
                focused = false
                showsInput = false
                extendsGlass = false
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 220)) } catch { return }
                reservesInputSpace = false
            }
        }
        .onExitCommand(perform: close)
        .onDisappear {
            close()
            reservesInputSpace = false
            extendsGlass = false
            showsInput = false
        }
    }

    private func close() {
        showsResults = false
        isExpanded = false
        focused = false
    }
}

struct SearchToolbarItem<Content: View>: ToolbarContent {
    @Environment(AppStore.self) private var store
    @ViewBuilder var content: () -> Content
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                SearchToolbarHost(content: content().environment(store))
            }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                SearchToolbarHost(content: content().environment(store))
            }
        }
    }
}

// Keep one toolbar representation in both states. Otherwise SwiftUI substitutes a native
// toolbar button when collapsed, changing its insets and symbol sizing during expansion.
private struct SearchToolbarHost<Content: View>: NSViewRepresentable {
    var content: Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        view.sizingOptions = [.intrinsicContentSize]
        return view
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
        view.rootView = content
    }
}

private struct SearchGlass: ViewModifier {
    enum Shape { case capsule, panel }
    var shape: Shape
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if shape == .capsule {
                content.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else {
            if shape == .capsule { content.background(.regularMaterial, in: Capsule()) }
            else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
        }
    }
}

private struct SearchResultsPanel<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let reduceMotion: Bool
    let onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> SearchPanelAnchor { SearchPanelAnchor() }
    func updateNSView(_ view: SearchPanelAnchor, context: Context) {
        view.onDismiss = onDismiss
        view.reduceMotion = reduceMotion
        view.update(content: AnyView(content().frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(SearchGlass(shape: .panel)).padding(8)), presented: isPresented)
    }
    static func dismantleNSView(_ view: SearchPanelAnchor, coordinator: ()) { view.close() }
}

final class SearchPanelAnchor: NSView {
    var onDismiss: (() -> Void)?
    var reduceMotion = false
    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var content = AnyView(EmptyView())
    private var presented = false
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { close() } else if presented { show() }
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionPanel()
    }
    override func layout() { super.layout(); positionPanel() }

    func update(content: AnyView, presented: Bool) {
        self.content = content
        self.presented = presented
        guard presented else { close(); return }
        if let host { host.rootView = content; positionPanel() } else { show() }
    }

    private func show() {
        guard let window, panel == nil, presented else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        self.host = host
        positionPanel()
        window.addChildWindow(panel, ordered: .above)
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFront(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let dismiss = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel else { return false }
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return false }
                    if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                    self.onDismiss?()
                    return true
                }
                guard event.window !== panel else { return false }
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.onDismiss?()
                }
                return false
            }
            return dismiss ? nil : event
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.positionPanel() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDismiss?() }
        })
    }

    private func positionPanel() {
        guard let panel, let window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let available = screen.visibleFrame
        let width = min(400.0, available.width - 16)
        let height = min(440.0, max(160, anchor.minY - available.minY - 12))
        let x = min(max(available.minX + 8, anchor.maxX - width + 8), available.maxX - width - 8)
        let y = max(available.minY + 8, anchor.minY - height - 2)
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func close() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.contentView = nil }
        panel = nil
        host = nil
        content = AnyView(EmptyView())
    }
}
