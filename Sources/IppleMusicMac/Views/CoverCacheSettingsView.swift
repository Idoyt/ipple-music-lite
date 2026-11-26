import MusicCore
import SwiftUI

struct CoverCacheSettingsView: View {
    @Environment(\.workspaceIsActive) private var workspaceIsActive
    @Environment(AppStore.self) private var store
    @State private var statistics: MediaDiskCache.Statistics?
    @State private var limitMB = "5120"
    @State private var working = false
    @State private var message: String?
    @State private var error: String?

    private var requestedBytes: Int64? {
        guard let value = Int64(limitMB.trimmingCharacters(in: .whitespacesAndNewlines)),
            (0...(MediaDiskCache.maximumBytes / MediaDiskCache.bytesPerMegabyte)).contains(value)
        else { return nil }
        return value * MediaDiskCache.bytesPerMegabyte
    }

    var body: some View {
        Group {
            if let statistics {
                LabeledContent("已使用") {
                    Text("\(bytes(statistics.usedBytes)) / \(bytes(statistics.limitBytes))").monospacedDigit()
                        .accessibilityIdentifier("media-cache.usage")
                }
                CacheUsageBar(statistics: statistics)
                HStack(spacing: 18) {
                    legend("封面", bytes: statistics.coverBytes, color: Color(nsColor: .controlAccentColor))
                    legend("歌词", bytes: statistics.lyricsBytes, color: .purple)
                    legend("歌曲", bytes: statistics.audioBytes, color: .orange)
                }.font(.caption)

            }
            HStack {
                Text("共享容量上限")
                Spacer()
                TextField("5120", text: $limitMB)
                    .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 100)
                    .accessibilityLabel("媒体缓存容量上限，单位 MB")
                    .accessibilityIdentifier("media-cache.limit")
                    .onSubmit { applyLimit() }
                Text("MB").foregroundStyle(.secondary)
                Button("应用") { applyLimit() }.disabled(working || requestedBytes == nil)
                    .accessibilityIdentifier("media-cache.apply")
            }
            Text("默认 5 GB；设为 0 停用。歌曲保存开头约 20 秒，暂停或中断后另存该位置往后约 20 秒；空间不足时自动清理较久未使用的内容。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("清空全部缓存") {
                    perform {
                        try await store.mediaCache.clear()
                        message = "已清空全部缓存"
                    }
                }.disabled(working).accessibilityIdentifier("media-cache.clear")
                if working { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: workspaceIsActive) {
            guard workspaceIsActive else { return }
            do {
                let initial = try await store.mediaCache.statistics()
                statistics = initial
                limitMB = String(initial.limitBytes / MediaDiskCache.bytesPerMegabyte)
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    statistics = try await store.mediaCache.statistics()
                }
            } catch { if !Task.isCancelled { self.error = "无法读取媒体缓存：\(error.localizedDescription)" } }
        }
    }

    private func legend(_ title: String, bytes value: Int64, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(color).accessibilityHidden(true)
            Text("\(title) \(bytes(value))")
        }
    }
    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }
    private func applyLimit() {
        guard !working, let bytes = requestedBytes else { return }
        perform {
            try await store.mediaCache.setLimit(bytes: bytes)
            message = "已保存共享缓存上限"
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            working = true
            error = nil
            message = nil
            defer { working = false }
            do {
                try await action()
                statistics = try await store.mediaCache.statistics()
            } catch { self.error = "缓存操作失败：\(error.localizedDescription)" }
        }
    }
}

private struct CacheUsageBar: View {
    let statistics: MediaDiskCache.Statistics
    var body: some View {
        GeometryReader { geometry in
            let total = Double(max(statistics.limitBytes, statistics.usedBytes, 1))
            HStack(spacing: 0) {
                Color(nsColor: .controlAccentColor).frame(
                    width: geometry.size.width * Double(statistics.coverBytes) / total)
                Color.purple.frame(width: geometry.size.width * Double(statistics.lyricsBytes) / total)
                Color.orange.frame(width: geometry.size.width * Double(statistics.audioBytes) / total)
                Spacer(minLength: 0)
            }.background(.quaternary).clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("共享媒体缓存用量")
        .accessibilityValue(
            "封面 \(statistics.coverBytes) 字节，歌词 \(statistics.lyricsBytes) 字节，歌曲 \(statistics.audioBytes) 字节，总上限 \(statistics.limitBytes) 字节"
        )
        .accessibilityIdentifier("media-cache.usage-bar")
    }
}
