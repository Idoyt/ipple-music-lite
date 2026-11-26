import AppKit
import MusicCore
import SwiftUI

struct AccountSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var error: String?
    @State private var confirmingErasure = false
    @State private var menuBarWidth = AppSettings.defaultMenuBarWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("我的").font(.largeTitle.bold())
                .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 8)
            Form {
                Section {
                    if let user = store.user {
                        if let source = store.sources.first(where: { $0.kind == "qq" && $0.ownerID == user.id }) {
                            QQAccountControl(source: source, showsProfile: true)
                        } else {
                            HStack { QQAccountAvatar(url: user.avatarURL); Text(user.displayName).font(.title2.weight(.semibold)) }
                        }
                        Button("退出当前账户") { Task { await store.signOut() } }
                        Group {
                            Button("退出并删除此账号的本机数据", role: .destructive) { confirmingErasure = true }
                                .confirmationDialog("删除此账号在这台 Mac 上的数据？", isPresented: $confirmingErasure) {
                                    Button("删除并退出", role: .destructive) { Task { await store.signOut(eraseLocalData: true) } }
                                    Button("取消", role: .cancel) {}
                                } message: {
                                    Text("将删除本机资料库、听歌历史、播放队列和该账号的媒体缓存。")
                                }
                        }
                    } else {
                        Text("登录后管理账户与设置。").foregroundStyle(.secondary)
                    }
                }
                Section("菜单栏") {
                    LabeledContent("宽度") {
                        Slider(value: $menuBarWidth, in: AppSettings.menuBarWidthRange) { editing in
                            if !editing { saveMenuBarWidth() }
                        }
                        .frame(maxWidth: 260)
                        .accessibilityLabel("菜单栏宽度")
                        .accessibilityIdentifier("settings.menu-bar.width")
                        Text("\(Int(menuBarWidth.rounded())) pt").monospacedDigit().frame(
                            width: 64, alignment: .trailing)
                    }
                    HStack {
                        Text("歌词较长时会在设定宽度内滚动。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") {
                            menuBarWidth = AppSettings.defaultMenuBarWidth
                            saveMenuBarWidth()
                        }
                    }
                }
                Section("媒体缓存") {
                    CoverCacheSettingsView()
                }
                Section("关于") {
                    HStack(spacing: 12) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable().scaledToFit().frame(width: 40, height: 40)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Ipple Music").font(.headline)
                            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("macOS").foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                    Text("收藏缓存和播放记录保存在这台 Mac 上。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: store.user?.id) {

            error = nil

            menuBarWidth = store.settings.resolvedMenuBarWidth

        }
        .onChange(of: store.settings.resolvedMenuBarWidth) { _, width in menuBarWidth = width }
    }

    private func saveMenuBarWidth() {
        do {
            try store.setMenuBarWidth(menuBarWidth)
            menuBarWidth = store.settings.resolvedMenuBarWidth
        } catch { self.error = error.localizedDescription }
    }

}
